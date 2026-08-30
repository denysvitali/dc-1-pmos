package installd

import (
	"errors"
	"net"
	"testing"
	"time"
)

func TestIdleDeadlineConnReadTimesOut(t *testing.T) {
	old := sessionIdleTimeout
	sessionIdleTimeout = 20 * time.Millisecond
	defer func() { sessionIdleTimeout = old }()

	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	started := time.Now()
	_, err := (&idleDeadlineConn{Conn: server}).Read(make([]byte, 1))
	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("Read() error = %v, want network timeout", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("idle read took %s, want under 1s", elapsed)
	}
}

func TestIdleDeadlineConnWriteTimesOut(t *testing.T) {
	old := sessionIdleTimeout
	sessionIdleTimeout = 20 * time.Millisecond
	defer func() { sessionIdleTimeout = old }()

	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	started := time.Now()
	_, err := (&idleDeadlineConn{Conn: server}).Write([]byte("blocked"))
	var netErr net.Error
	if !errors.As(err, &netErr) || !netErr.Timeout() {
		t.Fatalf("Write() error = %v, want network timeout", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("idle write took %s, want under 1s", elapsed)
	}
}
