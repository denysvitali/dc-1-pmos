// Package server is the control plane the Flutter UI talks to: plain
// HTTP/JSON over a Unix domain socket, plus one NDJSON progress stream.
//
// It never binds TCP. The USB host (172.16.42.1, DC1-INSTALL-V1 on port 5555)
// and any future Wi-Fi peer must not be able to reach onboarding; a Unix
// socket at mode 0600 is the whole access-control story, which is why there
// is no auth layer here.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/cmdrunner"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/events"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/provision"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/screen"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/secret"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/validate"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/wifi"
)

// maxBody caps a request body: every endpoint here takes a handful of short
// fields.
const maxBody = 64 << 10

// Config builds a Server.
type Config struct {
	Root    string // rootfs prefix; "/" in production
	Runner  cmdrunner.Runner
	Bus     *events.Bus
	Now     func() time.Time
	NewUUID func() string
	// Screen captures the panel for GET /screenshot. Defaults to grim.
	Screen screen.Capturer
}

// Server holds the handlers and the state they share.
type Server struct {
	bus    *events.Bus
	prov   *provision.Provisioner
	wifi   *wifi.Manager
	mux    *http.ServeMux
	runner cmdrunner.Runner
	root   string
	screen screen.Capturer

	// onboardMu serialises onboarding so two concurrent submissions cannot
	// both pass the marker gate.
	onboardMu sync.Mutex
}

// New wires a Server. Runner must be set; Bus is created if absent.
func New(cfg Config) *Server {
	bus := cfg.Bus
	if bus == nil {
		bus = events.NewBus()
		bus.Now = cfg.Now
	}
	root := cfg.Root
	if root == "" {
		root = "/"
	}
	s := &Server{
		bus: bus,
		prov: &provision.Provisioner{
			Root:    root,
			Runner:  cfg.Runner,
			Bus:     bus,
			Now:     cfg.Now,
			NewUUID: cfg.NewUUID,
		},
		wifi: &wifi.Manager{
			Root:    root,
			Runner:  cfg.Runner,
			Bus:     bus,
			NewUUID: cfg.NewUUID,
		},
		mux:    http.NewServeMux(),
		runner: cfg.Runner,
		root:   root,
		screen: cfg.Screen,
	}
	if s.screen == nil {
		s.screen = screen.Grim{Root: root}
	}
	s.mux.HandleFunc("/wifi/scan", s.handleWiFiScan)
	s.mux.HandleFunc("/wifi/connect", s.handleWiFiConnect)
	s.mux.HandleFunc("/onboard", s.handleOnboard)
	s.mux.HandleFunc("/events", s.handleEvents)
	s.mux.HandleFunc("/status", s.handleStatus)
	s.mux.HandleFunc("/finish", s.handleFinish)
	s.mux.HandleFunc("/screenshot", s.handleScreenshot)
	return s
}

// POST /finish -> {"status":"rebooting"}
//
// Onboarding renames the autologin user, moves its home, sets the hostname and
// may join a network -- but the Sway session that is running while all that
// happens still holds the pre-onboarding identity. Without this the user is
// left on a "Done" screen with no way into the system they just described.
// Rebooting is the honest finish: every service comes back up against the new
// passwd, hostname and connection.
//
// Gated on the marker so a stray call cannot reboot a device that is still
// mid-setup, or one that never onboarded at all.
func (s *Server) handleFinish(w http.ResponseWriter, r *http.Request) {
	if !allow(w, r, http.MethodPost) {
		return
	}
	if !s.prov.Provisioned() {
		writeJSON(w, http.StatusConflict, map[string]string{
			"error": "not provisioned",
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "rebooting"})
	// Reply first. The reboot is deferred a moment so the shell actually
	// receives it -- otherwise the socket dies mid-write and the last thing
	// the user sees is a transport error on a run that in fact succeeded.
	go func() {
		time.Sleep(rebootGrace)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_, _ = s.runner.Run(ctx, "reboot", nil, nil)
	}()
}

// Long enough for the JSON reply to reach the shell and be drawn, short
// enough that the device does not look hung. A var so the tests can shrink
// it rather than sleeping a second and a half.
var rebootGrace = 1500 * time.Millisecond

// Handler exposes the routes (also used by the tests).
func (s *Server) Handler() http.Handler { return s.mux }

// Bus exposes the progress bus.
func (s *Server) Bus() *events.Bus { return s.bus }

// GET /status -> {"provisioned":bool,"version":"<commit>"}
func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if !allow(w, r, http.MethodGet) {
		return
	}
	writeJSON(w, http.StatusOK, statusResponse{
		Provisioned: s.prov.Provisioned(),
		Version:     s.installerVersion(),
	})
}

type statusResponse struct {
	Provisioned bool   `json:"provisioned"`
	Version     string `json:"version"`
}

// VersionPath is where the dc1-ui package stages the commit it was built
// from, relative to the rootfs root. scripts/build-ui-payload.sh writes it
// into the payload and the APKBUILD installs it; the file is one line.
const VersionPath = "usr/share/dc1-ui/version"

// versionMax bounds the read. The value is rendered on the panel, so a file
// that is not what we think it is must not turn into a screenful of text --
// and must not be streamed into a JSON response unbounded either.
const versionMax = 128

// installerVersion returns the build this system was installed from, or ""
// when it cannot be established.
//
// "" is a real answer and the UI renders it as such: a missing or unreadable
// file means we do not know, and inventing "unknown" here would be
// indistinguishable from a build that literally recorded the string
// "unknown". Anything non-printable is dropped rather than escaped, because
// the only consumer is a line of text under a setup screen.
func (s *Server) installerVersion() string {
	f, err := os.Open(filepath.Join(s.root, VersionPath))
	if err != nil {
		return ""
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, versionMax))
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e {
			return -1
		}
		return r
	}, strings.TrimSpace(line))
}

// GET /wifi/scan -> [{"ssid":...,"signal":...}, ...], strongest first.
func (s *Server) handleWiFiScan(w http.ResponseWriter, r *http.Request) {
	if !allow(w, r, http.MethodGet) {
		return
	}
	nets, err := s.wifi.Scan(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if nets == nil {
		nets = []wifi.Network{}
	}
	writeJSON(w, http.StatusOK, nets)
}

type wifiConnectRequest struct {
	SSID string        `json:"ssid"`
	PSK  secret.Secret `json:"psk"`
}

// POST /wifi/connect {"ssid":...,"psk":...}
func (s *Server) handleWiFiConnect(w http.ResponseWriter, r *http.Request) {
	if !allow(w, r, http.MethodPost) {
		return
	}
	var req wifiConnectRequest
	defer func() { req.PSK.Wipe() }()
	if err := decodeBody(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	// Bad answers are the client's fault (400); a failing nmcli is not (502).
	// Manager.Connect re-checks both, as provision.sh re-validates.
	if err := validate.SSID(req.SSID); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if err := validate.PSK(req.PSK.Bytes()); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	if err := s.wifi.Connect(r.Context(), req.SSID, req.PSK); err != nil {
		s.bus.Publish(events.StateWiFiFailed, req.SSID)
		writeError(w, http.StatusBadGateway, err)
		return
	}
	s.bus.Publish(events.StateWiFiConnected, req.SSID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "connected", "ssid": req.SSID})
}

// POST /onboard {"user","password","hostname","timezone"[,"ssid","psk"]}
func (s *Server) handleOnboard(w http.ResponseWriter, r *http.Request) {
	if !allow(w, r, http.MethodPost) {
		return
	}
	var req provision.Request
	defer req.Wipe()
	if err := decodeBody(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	s.onboardMu.Lock()
	res, err := s.prov.Apply(r.Context(), &req)
	s.onboardMu.Unlock()
	if err != nil {
		// Bad answers are the client's fault (400). Everything else Apply can
		// fail on -- the shadow rewrite, a missing zoneinfo file, the marker
		// -- is ours, and must not be reported as if the user could fix it by
		// retyping.
		var invalid provision.InvalidRequest
		if errors.As(err, &invalid) {
			writeError(w, http.StatusBadRequest, err)
			return
		}
		writeError(w, http.StatusInternalServerError, err)
		return
	}
	if res.AlreadyProvisioned {
		writeJSON(w, http.StatusOK, map[string]any{"status": "already-provisioned"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":          "provisioned",
		"user":            res.User,
		"hostname":        res.Hostname,
		"timezone":        res.Timezone,
		"wifi_configured": res.WiFiConfigured,
	})
}

// GET /events -> NDJSON, one event per line, until the client goes away.
func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	if !allow(w, r, http.MethodGet) {
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, errors.New("streaming unsupported"))
		return
	}
	ch, cancel := s.bus.Subscribe()
	defer cancel()

	w.Header().Set("Content-Type", "application/x-ndjson")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)

	enc := json.NewEncoder(w)
	// Replay the current state so a UI attaching late is not left blank.
	if last, ok := s.bus.Last(); ok {
		if err := enc.Encode(last); err != nil {
			return
		}
	} else if err := enc.Encode(events.Event{State: events.StateIdle}); err != nil {
		return
	}
	flusher.Flush()

	for {
		select {
		case <-r.Context().Done():
			return
		case ev, ok := <-ch:
			if !ok {
				return
			}
			if err := enc.Encode(ev); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// ---------------------------------------------------------------- plumbing

func allow(w http.ResponseWriter, r *http.Request, method string) bool {
	if r.Method == method {
		return true
	}
	w.Header().Set("Allow", method)
	writeError(w, http.StatusMethodNotAllowed, fmt.Errorf("method %s not allowed", r.Method))
	return false
}

// decodeBody reads the whole body into a buffer we own, decodes it and wipes
// the buffer: a request body carrying a password or a PSK must not linger in
// a heap block after the handler returns.
//
// The buffer is allocated once at the cap rather than grown by io.ReadAll:
// ReadAll reallocates as it grows, and every array it abandons still holds a
// copy of the credential that the wipe below can no longer reach.
func decodeBody(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBody)
	// maxBody+1 so a body that is exactly at the cap is still distinguishable
	// from one over it.
	buf := make([]byte, maxBody+1)
	defer secret.Zero(buf)
	n, err := io.ReadFull(r.Body, buf)
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		return errors.New("could not read request body")
	}
	if n > maxBody {
		return errors.New("request body too large")
	}
	if err := json.Unmarshal(buf[:n], dst); err != nil {
		// The body may hold a credential, so the decoder's message (which can
		// quote the offending input) never reaches the client or a log.
		return errors.New("malformed JSON body")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, err error) {
	writeJSON(w, code, map[string]string{"error": err.Error()})
}

// Listen creates the Unix socket at path, mode 0600, removing a stale socket
// left behind by a crashed instance. It refuses to steal a socket that is
// still being served.
func Listen(path string) (*net.UnixListener, error) {
	if _, err := os.Stat(path); err == nil {
		if c, derr := net.Dial("unix", path); derr == nil {
			c.Close()
			return nil, fmt.Errorf("%s is already served by another instance", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	// Fail closed: bind(2) applies the umask to the new socket inode, so
	// without this the socket exists at the umask's mode (0755 under the
	// usual 0022) for the window between bind and chmod, and anything on the
	// system can connect to onboarding during it. 0177 leaves 0600.
	umaskMu.Lock()
	old := syscall.Umask(0o177)
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	syscall.Umask(old)
	umaskMu.Unlock()
	if err != nil {
		return nil, err
	}
	// Belt and braces: the bind above already created it at 0600.
	if err := os.Chmod(path, 0o600); err != nil {
		l.Close()
		return nil, err
	}
	return l, nil
}

// umaskMu serialises the umask window in Listen: the umask is process-wide,
// so two concurrent Listen calls must not interleave their save/restore.
var umaskMu sync.Mutex
