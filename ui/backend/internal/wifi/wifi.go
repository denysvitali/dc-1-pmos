// Package wifi drives NetworkManager on the installed system.
//
// The installed rootfs always has NetworkManager: the device package ships
// /etc/NetworkManager/conf.d/60-dc1-usb0.conf
// (pmaports/device/testing/device-daylight-jagar/APKBUILD:52-53), which is
// also why provision.sh's NetworkManager branch is the only reachable one on
// hardware (installer/src/provision.sh:211).
//
// Connecting is therefore done exactly the way provision.sh configures Wi-Fi:
// write the mode-0600 keyfile at the same fixed path, then `nmcli connection
// reload` + `nmcli connection up uuid <uuid>`. The alternative,
// `nmcli device wifi connect SSID password PSK`, is rejected on two counts:
// it puts the passphrase on an argv, and it would create a second,
// differently named profile competing with the one provision.sh writes.
package wifi

import (
	"context"
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/cmdrunner"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/secret"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/validate"
)

// KeyfileRel is the fixed keyfile path provision.sh writes, relative to the
// rootfs (installer/src/provision.sh:212-214).
const KeyfileRel = "etc/NetworkManager/system-connections/wifi.nmconnection"

// Network is one scan result.
type Network struct {
	SSID   string `json:"ssid"`
	Signal int    `json:"signal"`
}

// Publisher is the subset of events.Bus this package uses.
type Publisher interface {
	Publish(state, detail string)
}

// Manager owns the Wi-Fi side of the control plane.
type Manager struct {
	Root   string // rootfs prefix; "/" in production, a temp dir in tests
	Runner cmdrunner.Runner
	Bus    Publisher
	// NewUUID is overridable for tests; nil means the production source
	// (/proc/sys/kernel/random/uuid, then crypto/rand).
	NewUUID func() string
}

// Scan runs `nmcli -t -f SSID,SIGNAL device wifi list` and returns the
// networks, strongest first.
func (m *Manager) Scan(ctx context.Context) ([]Network, error) {
	if m.Bus != nil {
		m.Bus.Publish("SCANNING WI-FI NETWORKS", "")
	}
	out, err := m.Runner.Run(ctx, "nmcli", []string{"-t", "-f", "SSID,SIGNAL", "device", "wifi", "list"}, nil)
	if err != nil {
		return nil, err
	}
	return ParseScan(out), nil
}

// ParseScan turns nmcli's terse output into a deduplicated, sorted list.
//
// In terse mode nmcli separates fields with ':' and backslash-escapes any ':'
// or '\' inside a value, so a naive strings.Split mangles SSIDs containing a
// colon.
func ParseScan(out []byte) []Network {
	best := make(map[string]int)
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		fields := splitTerse(line)
		if len(fields) < 2 {
			continue
		}
		ssid := fields[len(fields)-2]
		signal, err := strconv.Atoi(strings.TrimSpace(fields[len(fields)-1]))
		if err != nil {
			continue
		}
		// nmcli prints "--" for a hidden network: nothing to offer the user.
		if ssid == "" || ssid == "--" {
			continue
		}
		if cur, ok := best[ssid]; !ok || signal > cur {
			best[ssid] = signal
		}
	}
	nets := make([]Network, 0, len(best))
	for ssid, signal := range best {
		nets = append(nets, Network{SSID: ssid, Signal: signal})
	}
	sort.Slice(nets, func(i, j int) bool {
		if nets[i].Signal != nets[j].Signal {
			return nets[i].Signal > nets[j].Signal
		}
		return nets[i].SSID < nets[j].SSID
	})
	return nets
}

// splitTerse splits one terse nmcli record on unescaped ':'.
func splitTerse(line string) []string {
	var (
		fields []string
		cur    strings.Builder
	)
	for i := 0; i < len(line); i++ {
		switch line[i] {
		case '\\':
			if i+1 < len(line) {
				i++
				cur.WriteByte(line[i])
			}
		case ':':
			fields = append(fields, cur.String())
			cur.Reset()
		default:
			cur.WriteByte(line[i])
		}
	}
	fields = append(fields, cur.String())
	return fields
}

// Connect writes the NetworkManager keyfile and brings the profile up. The
// passphrase goes from memory into a mode-0600 file and nowhere else: not an
// argv, not the environment, not an error string.
func (m *Manager) Connect(ctx context.Context, ssid string, psk secret.Secret) error {
	if err := validate.SSID(ssid); err != nil {
		return err
	}
	if err := validate.PSK(psk.Bytes()); err != nil {
		return err
	}
	uuid, err := WriteKeyfile(m.Root, ssid, psk.Bytes(), m.uuid())
	if err != nil {
		return err
	}
	if m.Bus != nil {
		m.Bus.Publish("CONNECTING TO WI-FI", ssid)
	}
	if _, err := m.Runner.Run(ctx, "nmcli", []string{"connection", "reload"}, nil); err != nil {
		return err
	}
	if m.Bus != nil {
		m.Bus.Publish("REQUESTING IP ADDRESS", ssid)
	}
	// "uuid <uuid>" and not "id <ssid>": the uuid is ours, so an SSID that
	// collides with another profile's id cannot select the wrong connection.
	if _, err := m.Runner.Run(ctx, "nmcli", []string{"connection", "up", "uuid", uuid}, nil); err != nil {
		return err
	}
	return nil
}

// WriteKeyfile writes the NetworkManager keyfile byte-for-byte as
// installer/src/provision.sh:218-238 does, at mode 0600, and returns the uuid
// it used. An empty uuid means "generate one".
func WriteKeyfile(root, ssid string, psk []byte, uuid string) (string, error) {
	if uuid == "" {
		uuid = NewUUID()
	}
	path := filepath.Join(root, KeyfileRel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	var b strings.Builder
	b.WriteString("[connection]\n")
	fmt.Fprintf(&b, "id=%s\n", ssid)
	fmt.Fprintf(&b, "uuid=%s\n", uuid)
	b.WriteString("type=wifi\n")
	b.WriteString("autoconnect=true\n\n")
	b.WriteString("[wifi]\n")
	b.WriteString("mode=infrastructure\n")
	fmt.Fprintf(&b, "ssid=%s\n\n", ssid)
	b.WriteString("[wifi-security]\n")
	b.WriteString("key-mgmt=wpa-psk\n")
	b.WriteString("psk=")

	// The passphrase is copied in as raw bytes and the buffer is wiped as soon
	// as it has been written, so no cleartext copy survives this function.
	// The buffer is sized up front and filled with copy() rather than grown
	// with append(): a reallocation would leave the old array — passphrase
	// still in it — on the heap, un-zeroed and unreachable, and the wipe below
	// would only cover the final one.
	head := b.String()
	tail := "\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n"
	buf := make([]byte, len(head)+len(psk)+len(tail))
	defer secret.Zero(buf)
	n := copy(buf, head)
	n += copy(buf[n:], psk)
	copy(buf[n:], tail)

	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return "", err
	}
	if _, err := f.Write(buf); err != nil {
		f.Close()
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	// Explicit chmod: the file may have pre-existed with a laxer mode, and
	// O_CREATE's mode is only applied on creation (and masked by umask).
	if err := os.Chmod(path, 0o600); err != nil {
		return "", err
	}
	return uuid, nil
}

func (m *Manager) uuid() string {
	if m.NewUUID != nil {
		return m.NewUUID()
	}
	return NewUUID()
}

// NewUUID mirrors provision.sh's source of connection uuids: the kernel's
// random uuid file, with a local fallback (installer/src/provision.sh:215).
func NewUUID() string {
	if b, err := os.ReadFile("/proc/sys/kernel/random/uuid"); err == nil {
		if s := strings.TrimSpace(string(b)); len(s) == 36 {
			return s
		}
	}
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "6d1f5a6e-0000-4000-8000-000000000000"
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 1
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
