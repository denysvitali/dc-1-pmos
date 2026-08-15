package wifi

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/cmdrunner"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/secret"
)

// recorder captures what Connect told the user, so the tests can assert on the
// words that reach the panel rather than on the nmcli calls behind them.
type recorder struct {
	events []struct{ state, detail string }
}

func (r *recorder) Publish(state, detail string) {
	r.events = append(r.events, struct{ state, detail string }{state, detail})
}

const testUUID = "11111111-2222-4333-8444-555555555555"

func TestParseScan(t *testing.T) {
	// nmcli -t escapes ':' and '\' inside a value.
	out := []byte(strings.Join([]string{
		"HomeNet:72",
		"HomeNet:41", // same SSID seen on a second band: keep the stronger
		"Cafe\\: Wifi:55",
		"back\\\\slash:12",
		"--:90",   // hidden network
		":88",     // empty SSID
		"Broken",  // no signal field
		"Bad:xyz", // unparseable signal
		"",
	}, "\n"))
	got := ParseScan(out)
	want := []Network{
		{SSID: "HomeNet", Signal: 72},
		{SSID: "Cafe: Wifi", Signal: 55},
		{SSID: "back\\slash", Signal: 12},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ParseScan = %+v, want %+v", got, want)
	}
}

func TestParseScanSortsTiesBySSID(t *testing.T) {
	got := ParseScan([]byte("beta:50\nalpha:50\n"))
	if len(got) != 2 || got[0].SSID != "alpha" || got[1].SSID != "beta" {
		t.Fatalf("ParseScan = %+v", got)
	}
}

func TestScanUsesTheDocumentedNmcliInvocation(t *testing.T) {
	fake := &cmdrunner.Fake{Func: func(string, []string, []byte) ([]byte, error) {
		return []byte("HomeNet:72\n"), nil
	}}
	m := &Manager{Root: t.TempDir(), Runner: fake}
	nets, err := m.Scan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(nets) != 1 {
		t.Fatalf("nets = %+v", nets)
	}
	call, err := fake.FindCall("nmcli")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"-t", "-f", "SSID,SIGNAL", "device", "wifi", "list"}
	if !reflect.DeepEqual(call.Args, want) {
		t.Fatalf("args = %q, want %q", call.Args, want)
	}
}

const testPSK = "correct-horse"

func TestWriteKeyfileMatchesProvisionSh(t *testing.T) {
	root := t.TempDir()
	uuid, err := WriteKeyfile(root, "MyNet", []byte(testPSK), "11111111-2222-4333-8444-555555555555")
	if err != nil {
		t.Fatal(err)
	}
	if uuid != "11111111-2222-4333-8444-555555555555" {
		t.Fatalf("uuid = %q", uuid)
	}
	path := filepath.Join(root, KeyfileRel)
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	// Byte-for-byte what installer/src/provision.sh:218-238 writes.
	want := "[connection]\n" +
		"id=MyNet\n" +
		"uuid=11111111-2222-4333-8444-555555555555\n" +
		"type=wifi\n" +
		"autoconnect=true\n" +
		"\n" +
		"[wifi]\n" +
		"mode=infrastructure\n" +
		"ssid=MyNet\n" +
		"\n" +
		"[wifi-security]\n" +
		"key-mgmt=wpa-psk\n" +
		"psk=" + testPSK + "\n" +
		"\n" +
		"[ipv4]\n" +
		"method=auto\n" +
		"\n" +
		"[ipv6]\n" +
		"method=auto\n"
	if string(got) != want {
		t.Fatalf("keyfile mismatch:\n got %q\nwant %q", got, want)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("keyfile mode = %o, want 600", st.Mode().Perm())
	}
}

func TestWriteKeyfileTightensAPreExistingLaxMode(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, KeyfileRel)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteKeyfile(root, "MyNet", []byte(testPSK), "u"); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("keyfile mode = %o, want 600", st.Mode().Perm())
	}
}

func TestConnectKeepsThePSKOffEveryArgv(t *testing.T) {
	root := t.TempDir()
	fake := &cmdrunner.Fake{}
	m := &Manager{
		Root:    root,
		Runner:  fake,
		NewUUID: func() string { return "11111111-2222-4333-8444-555555555555" },
	}
	psk := secret.Secret(testPSK)
	if err := m.Connect(context.Background(), "MyNet", psk); err != nil {
		t.Fatal(err)
	}
	calls := fake.Calls()
	if len(calls) != 2 {
		t.Fatalf("calls = %+v", calls)
	}
	if got := calls[0].Line(); got != "nmcli connection reload" {
		t.Fatalf("call 0 = %q", got)
	}
	if got := calls[1].Line(); got != "nmcli connection up uuid 11111111-2222-4333-8444-555555555555" {
		t.Fatalf("call 1 = %q", got)
	}
	for _, c := range calls {
		if strings.Contains(c.Line(), testPSK) {
			t.Fatalf("PSK reached an argv: %q", c.Line())
		}
		if strings.Contains(string(c.Stdin), testPSK) {
			t.Fatal("PSK was piped to nmcli; it belongs in the keyfile only")
		}
	}
	b, err := os.ReadFile(filepath.Join(root, KeyfileRel))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "psk="+testPSK+"\n") {
		t.Fatal("keyfile does not carry the passphrase")
	}
}

func TestConnectValidates(t *testing.T) {
	m := &Manager{Root: t.TempDir(), Runner: &cmdrunner.Fake{}}
	if err := m.Connect(context.Background(), "", secret.Secret("longenough")); err == nil {
		t.Error("empty SSID accepted")
	}
	if err := m.Connect(context.Background(), "MyNet", secret.Secret("short")); err == nil {
		t.Error("short PSK accepted")
	}
	if err := m.Connect(context.Background(), "MyNet", secret.Secret("short")); err != nil &&
		strings.Contains(err.Error(), "short") {
		t.Error("error message quoted the passphrase")
	}
}

func TestNewUUIDShape(t *testing.T) {
	u := NewUUID()
	if len(u) != 36 || strings.Count(u, "-") != 4 {
		t.Fatalf("NewUUID = %q", u)
	}
}

// Field shapes taken from a real device: NetworkManager indexes a field only
// when it has more than one value, so ADDRESS and DNS arrive as
// "IP4.ADDRESS[1]" while a lone GATEWAY does not. Values here are generic --
// this is a public repo and a real device's LAN is not test data.
const nmcliIP4 = `IP4.ADDRESS[1]:192.168.1.42/24
IP4.GATEWAY:192.168.1.1
IP4.DNS[1]:192.168.1.1
IP4.DNS[2]:9.9.9.9
`

func TestParseIP4(t *testing.T) {
	got := ParseIP4([]byte(nmcliIP4))
	if len(got.Addresses) != 1 || got.Addresses[0] != "192.168.1.42/24" {
		t.Fatalf("addresses = %q", got.Addresses)
	}
	if got.Gateway != "192.168.1.1" {
		t.Fatalf("gateway = %q", got.Gateway)
	}
	if len(got.DNS) != 2 || got.DNS[1] != "9.9.9.9" {
		t.Fatalf("dns = %q", got.DNS)
	}
	want := "IP 192.168.1.42/24 · gateway 192.168.1.1 · DNS 192.168.1.1, 9.9.9.9"
	if got.Summary() != want {
		t.Fatalf("summary = %q, want %q", got.Summary(), want)
	}
}

// Every IPv6 address contains the separator nmcli splits records on, so a
// naive SplitN(line, ":", 2) on the value side truncates it.
func TestParseIP4KeepsColonsInValues(t *testing.T) {
	got := ParseIP4([]byte("IP4.DNS[1]:2606:4700:4700::1111\n"))
	if len(got.DNS) != 1 || got.DNS[0] != "2606:4700:4700::1111" {
		t.Fatalf("dns = %q", got.DNS)
	}
}

// NetworkManager prints "--" for a field it has no value for; rendering that
// on the panel as an address would be worse than saying nothing.
func TestParseIP4IgnoresPlaceholders(t *testing.T) {
	got := ParseIP4([]byte("IP4.ADDRESS[1]:--\nIP4.GATEWAY:\n"))
	if len(got.Addresses) != 0 || got.Gateway != "" {
		t.Fatalf("got %+v", got)
	}
	if got.Summary() != "" {
		t.Fatalf("summary = %q, want empty", got.Summary())
	}
}

// Joining and getting no address must not be reported as a bare success.
func TestConnectReportsWhenThereIsNoAddress(t *testing.T) {
	root := t.TempDir()
	bus := &recorder{}
	m := &Manager{Root: root, Bus: bus, NewUUID: func() string { return testUUID },
		Runner: &cmdrunner.Fake{Func: func(name string, args []string, _ []byte) ([]byte, error) {
			if len(args) > 0 && args[0] == "-t" {
				return []byte("IP4.ADDRESS[1]:--\n"), nil
			}
			return nil, nil
		}}}
	if err := m.Connect(context.Background(), "net", secret.Secret("passphrase")); err != nil {
		t.Fatal(err)
	}
	last := bus.events[len(bus.events)-1]
	if !strings.Contains(last.detail, "no IP address yet") {
		t.Fatalf("last event = %+v", last)
	}
}

func TestConnectReportsTheAddressItGot(t *testing.T) {
	root := t.TempDir()
	bus := &recorder{}
	m := &Manager{Root: root, Bus: bus, NewUUID: func() string { return testUUID },
		Runner: &cmdrunner.Fake{Func: func(name string, args []string, _ []byte) ([]byte, error) {
			if len(args) > 0 && args[0] == "-t" {
				return []byte(nmcliIP4), nil
			}
			return nil, nil
		}}}
	if err := m.Connect(context.Background(), "net", secret.Secret("passphrase")); err != nil {
		t.Fatal(err)
	}
	last := bus.events[len(bus.events)-1]
	if !strings.Contains(last.detail, "192.168.1.42/24") ||
		!strings.Contains(last.detail, "gateway 192.168.1.1") {
		t.Fatalf("last event = %+v", last)
	}
}
