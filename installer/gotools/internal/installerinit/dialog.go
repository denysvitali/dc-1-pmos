package installerinit

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/ask"
)

// serveDialogs is the touch UI's dialog server. It listens on a unix socket,
// reads one dialog request per connection, runs it against the panel PID 1
// owns, and writes the answer back. It never returns: it is intended to run in
// its own goroutine, and a malformed or panicking request must not take PID 1
// down (see serveOne).
func serveDialogs(path string, run func([]string) ask.DialogResponse, log io.Writer) {
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		fmt.Fprintf(log, "[dc1-installer] dialog server: %v\n", err)
		return
	}
	defer ln.Close()

	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		serveOne(conn, run, log)
	}
}

// serveOne handles a single dc1-ask connection: decode one request, run it,
// encode one response. It recovers from a panic in the dialog code, because an
// unrecovered panic in any goroutine kills the process -- and this process is
// PID 1. The client sees the connection close and, per its contract, exits 2
// (falls back) rather than hanging.
func serveOne(conn net.Conn, run func([]string) ask.DialogResponse, log io.Writer) {
	defer conn.Close()
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(log, "[dc1-installer] dialog: panic: %v\n", r)
		}
	}()

	var req ask.DialogRequest
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		return
	}
	resp := run(req.Args)
	_ = json.NewEncoder(conn).Encode(resp)
}
