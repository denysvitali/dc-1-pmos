// Command dc1-backend is the DC-1 UI's control plane: one static binary
// (CGO_ENABLED=0, musl-safe) serving HTTP/JSON to the Flutter shell over a
// Unix domain socket. It binds no TCP port, ever.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/cmdrunner"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/server"
)

// DefaultSocket is the control-plane socket. Overridable only so the tests
// can use a temp directory.
const DefaultSocket = "/run/dc1-ui.sock"

func main() {
	socket := flag.String("socket", DefaultSocket, "unix socket to serve on")
	root := flag.String("root", "/", "rootfs prefix to provision (for testing)")
	flag.Parse()

	log.SetFlags(0)
	log.SetPrefix("dc1-backend: ")

	l, err := server.Listen(*socket)
	if err != nil {
		log.Fatal(err)
	}

	srv := &http.Server{
		Handler: server.New(server.Config{
			Root:   *root,
			Runner: cmdrunner.Exec{},
		}).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// No WriteTimeout: GET /events is a long-lived stream.
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	log.Printf("listening on %s", *socket)
	if err := srv.Serve(l); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
	// net.UnixListener removes the socket on Close; belt and braces.
	_ = os.Remove(*socket)
}
