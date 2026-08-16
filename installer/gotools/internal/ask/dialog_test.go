package ask

import (
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
)

// TestDialogRoundTrip drives the client against a real unix socket with a stub
// server, so the wire format (one DialogRequest in, one DialogResponse out) is
// pinned. The stub plays the part of PID 1's dialog server; dialog() is what
// dc1-ask's Main runs.
func TestDialogRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dc1-ask.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var req DialogRequest
		if err := json.NewDecoder(conn).Decode(&req); err != nil {
			return
		}
		_ = json.NewEncoder(conn).Encode(DialogResponse{RC: 0, Out: "0\n", Err: ""})
	}()

	resp, ok := dialog(path, []string{"menu", "DC-1 INSTALLER", "one", "two"})
	if !ok {
		t.Fatal("dialog reported the server unreachable")
	}
	if resp.RC != 0 || resp.Out != "0\n" {
		t.Fatalf("dialog = %+v, want rc 0 out \"0\\n\"", resp)
	}
}

// TestDialogUnreachable is the fallback contract: no server means ok=false, and
// Main turns that into exit 2, which tui.sh already treats as "USB flow only".
func TestDialogUnreachable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "does-not-exist.sock")
	if _, ok := dialog(path, []string{"menu", "TITLE", "x"}); ok {
		t.Fatal("dialog reached a server that is not listening")
	}
}

// TestScreenRun drives the in-process dispatch path: the same argv dc1-ask
// would get, the same exit code and stdout the subprocess would print.
func TestScreenRun(t *testing.T) {
	s, _ := newTestScreen([2]int{600, 280}) // taps option 0
	rc, out, errOut := s.Run([]string{"menu", "DC-1 INSTALLER", "one", "two"})
	if rc != 0 || out != "0\n" || errOut != "" {
		t.Fatalf("Run = (%d, %q, %q), want (0, \"0\\n\", \"\")", rc, out, errOut)
	}
}

func TestScreenRunCancel(t *testing.T) {
	s, _ := newTestScreen(tapCancel)
	rc, out, _ := s.Run([]string{"text", "USERNAME"})
	if rc != 1 || out != "" {
		t.Fatalf("Run = (%d, %q), want (1, \"\")", rc, out)
	}
}
