package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/cmdrunner"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/events"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/provision"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/wifi"
)

const (
	testHash     = "$6$testsalt$abcdefghijklmnopqrstuvwxyz0123456789"
	testPassword = "correct-horse-battery"
	testPSK      = "hunter2hunter2"
	scanOutput   = "HomeNet:72\nCafe\\: Wifi:55\nHomeNet:30\n--:99\n"
)

// harness starts a Server on a real Unix socket in t.TempDir() and returns a
// client bound to it. Nothing here touches /etc, nmcli or cryptpw.
type harness struct {
	client *http.Client
	fake   *cmdrunner.Fake
	root   string
	socket string
	bus    *events.Bus
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	root := fakeRootfs(t)
	fake := &cmdrunner.Fake{Func: func(name string, args []string, _ []byte) ([]byte, error) {
		switch name {
		case "cryptpw":
			return []byte(testHash + "\n"), nil
		case "nmcli":
			if len(args) > 0 && args[0] == "-t" {
				return []byte(scanOutput), nil
			}
			return nil, nil
		}
		t.Errorf("unexpected command %q", name)
		return nil, nil
	}}
	bus := events.NewBus()
	srv := New(Config{
		Root:    root,
		Runner:  fake,
		Bus:     bus,
		Now:     func() time.Time { return time.Unix(1700000000, 0).UTC() },
		NewUUID: func() string { return "11111111-2222-4333-8444-555555555555" },
	})

	// Short socket name: sun_path is 108 bytes.
	socket := filepath.Join(t.TempDir(), "s.sock")
	l, err := Listen(socket)
	if err != nil {
		t.Fatal(err)
	}
	hs := &http.Server{Handler: srv.Handler()}
	go func() { _ = hs.Serve(l) }()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = hs.Shutdown(ctx)
	})

	client := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", socket)
			},
		},
	}
	return &harness{client: client, fake: fake, root: root, socket: socket, bus: bus}
}

func (h *harness) do(t *testing.T, method, path, body string) (*http.Response, string) {
	t.Helper()
	var rdr io.Reader
	if body != "" {
		rdr = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, "http://unix"+path, rdr)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp, string(b)
}

func fakeRootfs(t *testing.T) string {
	t.Helper()
	r := t.TempDir()
	for _, d := range []string{"etc/NetworkManager", "home/dc1", "usr/share/zoneinfo/Europe", "var/lib"} {
		if err := os.MkdirAll(filepath.Join(r, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	files := map[string]string{
		"etc/passwd":                       "root:x:0:0:root:/root:/bin/sh\ndc1:x:10000:10000::/home/dc1:/bin/ash\n",
		"etc/shadow":                       "root:!::0:::::\ndc1:!:19000:0:99999:7:::\n",
		"etc/group":                        "root:x:0:\nwheel:x:10:dc1\n",
		"etc/hosts":                        "127.0.0.1\tlocalhost\n",
		"etc/hostname":                     "oldname\n",
		"usr/share/zoneinfo/Europe/Zurich": "TZif",
	}
	for rel, content := range files {
		if err := os.WriteFile(filepath.Join(r, rel), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return r
}

func TestSocketIsUnixAndMode0600(t *testing.T) {
	h := newHarness(t)
	st, err := os.Stat(h.socket)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode()&os.ModeSocket == 0 {
		t.Fatalf("%s is not a socket (mode %v)", h.socket, st.Mode())
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode = %o, want 600", st.Mode().Perm())
	}
}

func TestListenReplacesAStaleSocketAndRefusesALiveOne(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.sock")
	// A stale file left behind by a crashed instance.
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	l, err := Listen(path)
	if err != nil {
		t.Fatalf("stale socket not replaced: %v", err)
	}
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	if _, err := Listen(path); err == nil {
		t.Fatal("stole a socket that is still being served")
	}
}

func TestWiFiScan(t *testing.T) {
	h := newHarness(t)
	resp, body := h.do(t, http.MethodGet, "/wifi/scan", "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d: %s", resp.StatusCode, body)
	}
	var nets []wifi.Network
	if err := json.Unmarshal([]byte(body), &nets); err != nil {
		t.Fatalf("body %q: %v", body, err)
	}
	want := []wifi.Network{{SSID: "HomeNet", Signal: 72}, {SSID: "Cafe: Wifi", Signal: 55}}
	if len(nets) != len(want) {
		t.Fatalf("nets = %+v, want %+v", nets, want)
	}
	for i := range want {
		if nets[i] != want[i] {
			t.Fatalf("nets = %+v, want %+v", nets, want)
		}
	}
}

func TestWiFiConnectKeepsThePSKOffArgvAndWritesTheKeyfile(t *testing.T) {
	h := newHarness(t)
	resp, body := h.do(t, http.MethodPost, "/wifi/connect", `{"ssid":"MyNet","psk":"`+testPSK+`"}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d: %s", resp.StatusCode, body)
	}
	if !strings.Contains(body, `"status":"connected"`) {
		t.Fatalf("body = %s", body)
	}
	for _, c := range h.fake.Calls() {
		if strings.Contains(c.Line(), testPSK) {
			t.Fatalf("PSK on an argv: %q", c.Line())
		}
	}
	keyfile, err := os.ReadFile(filepath.Join(h.root, wifi.KeyfileRel))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(keyfile), "psk="+testPSK+"\n") {
		t.Fatal("keyfile does not carry the passphrase")
	}
	st, err := os.Stat(filepath.Join(h.root, wifi.KeyfileRel))
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("keyfile mode = %o", st.Mode().Perm())
	}
}

func TestWiFiConnectRejectsAShortPSKWithoutQuotingIt(t *testing.T) {
	h := newHarness(t)
	resp, body := h.do(t, http.MethodPost, "/wifi/connect", `{"ssid":"MyNet","psk":"short"}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d: %s", resp.StatusCode, body)
	}
	if strings.Contains(body, "short") {
		t.Fatalf("error echoed the passphrase: %s", body)
	}
	if len(h.fake.Calls()) != 0 {
		t.Fatalf("ran nmcli despite an invalid passphrase: %+v", h.fake.Calls())
	}
	if _, err := os.Stat(filepath.Join(h.root, wifi.KeyfileRel)); !os.IsNotExist(err) {
		t.Fatal("wrote a keyfile for an invalid passphrase")
	}
}

func TestOnboardAppliesAndIsIdempotent(t *testing.T) {
	h := newHarness(t)
	req := `{"user":"alice","password":"` + testPassword + `","hostname":"mydc1","timezone":"Europe/Zurich"}`
	resp, body := h.do(t, http.MethodPost, "/onboard", req)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d: %s", resp.StatusCode, body)
	}
	if !strings.Contains(body, `"status":"provisioned"`) {
		t.Fatalf("body = %s", body)
	}
	if got, err := os.ReadFile(filepath.Join(h.root, "etc/hostname")); err != nil || string(got) != "mydc1\n" {
		t.Fatalf("hostname = %q, %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(h.root, provision.MarkerRel)); err != nil {
		t.Fatalf("marker missing: %v", err)
	}

	// GET /status now reports provisioned.
	_, statusBody := h.do(t, http.MethodGet, "/status", "")
	if !strings.Contains(statusBody, `"provisioned":true`) {
		t.Fatalf("status = %s", statusBody)
	}

	// A second submission must not rename the user or rewrite anything.
	second := `{"user":"bob","password":"` + testPassword + `","hostname":"other","timezone":"Europe/Zurich"}`
	resp2, body2 := h.do(t, http.MethodPost, "/onboard", second)
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("status = %d: %s", resp2.StatusCode, body2)
	}
	if !strings.Contains(body2, `"status":"already-provisioned"`) {
		t.Fatalf("body = %s", body2)
	}
	passwd, err := os.ReadFile(filepath.Join(h.root, "etc/passwd"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(passwd), "bob") {
		t.Fatalf("second onboard modified passwd:\n%s", passwd)
	}
}

func TestOnboardRejectsInvalidAnswers(t *testing.T) {
	cases := map[string]string{
		"reserved user":  `{"user":"root","password":"` + testPassword + `","hostname":"mydc1","timezone":"UTC"}`,
		"bad hostname":   `{"user":"alice","password":"` + testPassword + `","hostname":"bad-","timezone":"UTC"}`,
		"bad timezone":   `{"user":"alice","password":"` + testPassword + `","hostname":"mydc1","timezone":"../../etc/shadow"}`,
		"empty password": `{"user":"alice","password":"","hostname":"mydc1","timezone":"UTC"}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			resp, got := h.do(t, http.MethodPost, "/onboard", body)
			if resp.StatusCode != http.StatusBadRequest {
				t.Fatalf("status = %d: %s", resp.StatusCode, got)
			}
			if strings.Contains(got, testPassword) {
				t.Fatalf("error echoed the password: %s", got)
			}
			if _, err := os.Stat(filepath.Join(h.root, provision.MarkerRel)); !os.IsNotExist(err) {
				t.Fatal("marker written for an invalid request")
			}
		})
	}
}

// A well-formed request this side cannot honour is a 500, not a 400: the
// answers are fine, so telling the user to retype them is a lie. Europe/Zurich
// is the only zoneinfo file in the fake rootfs, so Asia/Tokyo passes every
// validator and then fails in applyTimezone.
func TestOnboardReportsApplyFailuresAsServerErrors(t *testing.T) {
	h := newHarness(t)
	req := `{"user":"alice","password":"` + testPassword + `","hostname":"mydc1","timezone":"Asia/Tokyo"}`
	resp, body := h.do(t, http.MethodPost, "/onboard", req)
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500: %s", resp.StatusCode, body)
	}
	if strings.Contains(body, testPassword) {
		t.Fatalf("error echoed the password: %s", body)
	}
	if _, err := os.Stat(filepath.Join(h.root, provision.MarkerRel)); !os.IsNotExist(err) {
		t.Fatal("marker written after a failed step")
	}
}

func TestMalformedBodyIsNotEchoed(t *testing.T) {
	h := newHarness(t)
	resp, body := h.do(t, http.MethodPost, "/onboard", `{"user":"alice","password":"`+testPassword+`"`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d: %s", resp.StatusCode, body)
	}
	if strings.Contains(body, testPassword) {
		t.Fatalf("malformed-body error echoed the password: %s", body)
	}
}

// decodeBody reads into one pre-sized buffer instead of growing one, so that
// the wipe reaches every byte of a credential. This covers the sizes where
// that matters: a body far past io.ReadAll's initial 512 bytes still decodes,
// and one past the cap is still refused.
func TestBodiesLargerThanTheReadBufferAreHandled(t *testing.T) {
	h := newHarness(t)
	pad := strings.Repeat("x", 40<<10)
	body := `{"user":"alice","password":"` + testPassword +
		`","hostname":"mydc1","timezone":"Europe/Zurich","note":"` + pad + `"}`
	resp, got := h.do(t, http.MethodPost, "/onboard", body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d: %s", resp.StatusCode, got)
	}

	h2 := newHarness(t)
	over := `{"user":"alice","note":"` + strings.Repeat("y", 70<<10) + `"}`
	resp2, got2 := h2.do(t, http.MethodPost, "/onboard", over)
	if resp2.StatusCode == http.StatusOK {
		t.Fatalf("accepted a body past the cap: %s", got2)
	}
	if _, err := os.Stat(filepath.Join(h2.root, provision.MarkerRel)); !os.IsNotExist(err) {
		t.Fatal("marker written for an over-cap body")
	}
}

func TestMethodNotAllowed(t *testing.T) {
	h := newHarness(t)
	for _, c := range []struct{ method, path string }{
		{http.MethodPost, "/wifi/scan"},
		{http.MethodGet, "/wifi/connect"},
		{http.MethodGet, "/onboard"},
		{http.MethodPost, "/events"},
	} {
		resp, _ := h.do(t, c.method, c.path, "")
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s %s: status = %d", c.method, c.path, resp.StatusCode)
		}
	}
}

func TestEventsStreamsNDJSON(t *testing.T) {
	h := newHarness(t)
	req, err := http.NewRequest(http.MethodGet, "http://unix/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	resp, err := h.client.Do(req.WithContext(ctx))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if got := resp.Header.Get("Content-Type"); got != "application/x-ndjson" {
		t.Fatalf("content-type = %q", got)
	}

	br := bufio.NewReader(resp.Body)
	next := func() events.Event {
		t.Helper()
		line, err := br.ReadBytes('\n')
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		var ev events.Event
		if err := json.Unmarshal(line, &ev); err != nil {
			t.Fatalf("line %q: %v", line, err)
		}
		return ev
	}

	// The stream opens with the current state, so a late client is not blank.
	if ev := next(); ev.State != events.StateIdle {
		t.Fatalf("first event = %+v", ev)
	}

	onboard := `{"user":"alice","password":"` + testPassword + `","hostname":"mydc1","timezone":"Europe/Zurich","ssid":"MyNet","psk":"` + testPSK + `"}`
	if resp, body := h.do(t, http.MethodPost, "/onboard", onboard); resp.StatusCode != http.StatusOK {
		t.Fatalf("onboard: %d %s", resp.StatusCode, body)
	}

	want := []string{
		events.StateHashingPassword,
		events.StateApplyingSystem,
		events.StateApplyingUser,
		events.StateWritingWiFi,
		events.StateComplete,
	}
	for _, state := range want {
		ev := next()
		if ev.State != state {
			t.Fatalf("event = %+v, want state %q", ev, state)
		}
		if ev.Time == "" {
			t.Fatalf("event has no timestamp: %+v", ev)
		}
		if strings.Contains(ev.Detail, testPassword) || strings.Contains(ev.Detail, testPSK) {
			t.Fatalf("event leaked a credential: %+v", ev)
		}
	}
}

// syncRecorder is a ResponseWriter safe to read while the handler writes.
type syncRecorder struct {
	mu  sync.Mutex
	hdr http.Header
	buf bytes.Buffer
}

func (r *syncRecorder) Header() http.Header {
	if r.hdr == nil {
		r.hdr = make(http.Header)
	}
	return r.hdr
}

func (r *syncRecorder) Write(b []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.buf.Write(b)
}

func (r *syncRecorder) WriteHeader(int) {}

func (r *syncRecorder) Flush() {}

func (r *syncRecorder) String() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.buf.String()
}

func TestEventsReplaysTheLastStateToALateSubscriber(t *testing.T) {
	h := newHarness(t)
	h.bus.Publish(events.StateWiFiConnected, "MyNet")

	// httptest request path: the handler must emit the replay line and return
	// as soon as the client goes away.
	srv := New(Config{Root: h.root, Runner: h.fake, Bus: h.bus})
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodGet, "/events", nil).WithContext(ctx)
	rec := &syncRecorder{}
	done := make(chan struct{})
	go func() {
		srv.Handler().ServeHTTP(rec, req)
		close(done)
	}()
	deadline := time.After(2 * time.Second)
	for !strings.Contains(rec.String(), events.StateWiFiConnected) {
		select {
		case <-deadline:
			t.Fatalf("no replay line: %q", rec.String())
		default:
			time.Sleep(5 * time.Millisecond)
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("handler did not return after the client went away")
	}
}
