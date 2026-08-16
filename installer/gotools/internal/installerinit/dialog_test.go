package installerinit

import (
	"encoding/json"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/ask"
)

// dial performs one client round-trip against the server at path.
func dial(path string, args []string) (ask.DialogResponse, error) {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return ask.DialogResponse{}, err
	}
	defer conn.Close()
	if err := json.NewEncoder(conn).Encode(ask.DialogRequest{Args: args}); err != nil {
		return ask.DialogResponse{}, err
	}
	var resp ask.DialogResponse
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return ask.DialogResponse{}, err
	}
	return resp, nil
}

// waitForSocket polls until the server's listener is up, so a test never races
// the goroutine that is creating the socket.
func waitForSocket(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		conn, err := net.Dial("unix", path)
		if err == nil {
			conn.Close()
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("socket %s never appeared", path)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestServeDialogsRoundTrip pins the server's wire behaviour: one request in,
// one response out, with the injected runner deciding the answer.
func TestServeDialogsRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sock")
	run := func(args []string) ask.DialogResponse {
		return ask.DialogResponse{RC: 0, Out: "chosen: " + args[1]}
	}
	go serveDialogs(path, run, io.Discard)
	waitForSocket(t, path)

	resp, err := dial(path, []string{"menu", "TITLE", "a"})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if resp.RC != 0 || resp.Out != "chosen: TITLE" {
		t.Fatalf("resp = %+v", resp)
	}
}

// TestServeDialogsSurvivesAPanic is the load-bearing safety property: this
// server runs inside PID 1, where an unrecovered panic in any goroutine kills
// the device. A panicking request must be caught, its connection closed, and
// the accept loop left serving the next request.
func TestServeDialogsSurvivesAPanic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sock")
	calls := 0
	run := func(args []string) ask.DialogResponse {
		calls++
		if calls == 1 {
			panic("dialog bug")
		}
		return ask.DialogResponse{RC: 0, Out: "ok"}
	}
	var logBuf strings.Builder
	go serveDialogs(path, run, &logBuf)
	waitForSocket(t, path)

	// First request panics: the client sees the connection close (a decode
	// error), not an answer.
	if _, err := dial(path, []string{"menu", "TITLE"}); err == nil {
		t.Fatal("a panicking request produced a response")
	}
	// Second request is served normally, proving the accept loop survived.
	resp, err := dial(path, []string{"menu", "TITLE"})
	if err != nil {
		t.Fatalf("server did not survive the panic: %v", err)
	}
	if resp.Out != "ok" {
		t.Fatalf("resp = %+v", resp)
	}
	if !strings.Contains(logBuf.String(), "panic") {
		t.Fatalf("the panic was not logged: %q", logBuf.String())
	}
}
