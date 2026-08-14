package server

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The control plane must never be reachable over the network: the USB host
// (172.16.42.1) and any joined Wi-Fi network must not be able to onboard the
// device. Two independent checks, because either one alone can be fooled.

func TestListenerIsAUnixSocketNotTCP(t *testing.T) {
	l, err := Listen(filepath.Join(t.TempDir(), "s.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if _, ok := any(l).(*net.UnixListener); !ok {
		t.Fatalf("listener type = %T, want *net.UnixListener", l)
	}
	if got := l.Addr().Network(); got != "unix" {
		t.Fatalf("listener network = %q, want unix", got)
	}
}

func TestNoTCPBindAnywhereInTheModule(t *testing.T) {
	// Built by concatenation so this file does not match its own scan.
	forbidden := []string{
		"net.Listen" + `("tcp`,
		"net.Listen" + "TCP",
		"net.Listen" + "Packet",
		"ListenAnd" + "Serve",
		"httptest.New" + "Server",
		"httptest.New" + "UnstartedServer",
	}
	root := filepath.Join("..", "..") // the module root
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".go") {
			return nil
		}
		if filepath.Base(path) == "notcp_test.go" {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, bad := range forbidden {
			if strings.Contains(string(b), bad) {
				t.Errorf("%s contains %q: the backend must bind only a unix socket", path, bad)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
