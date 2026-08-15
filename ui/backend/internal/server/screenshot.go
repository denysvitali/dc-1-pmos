package server

import (
	"context"
	"net/http"
	"time"
)

// GET /screenshot -> image/png of the panel as it is right now.
//
// This device is developed at the end of a USB cable, and until this existed
// the only way to know what onboarding actually looked like was for somebody
// to be holding it. That made every UI claim in this repo unfalsifiable from
// a build machine.
//
// It is a read-only observation endpoint and it stays on the Unix socket with
// everything else: the panel can show a Wi-Fi passphrase being typed, so this
// is strictly more sensitive than the rest of the API, not less, and must
// never become reachable from the USB host or a Wi-Fi peer.
func (s *Server) handleScreenshot(w http.ResponseWriter, r *http.Request) {
	if !allow(w, r, http.MethodGet) {
		return
	}
	// Bounded: a compositor that has stopped answering must fail the request
	// rather than hold a connection open for as long as the client waits.
	ctx, cancel := context.WithTimeout(r.Context(), screenshotTimeout)
	defer cancel()
	png, err := s.screen.Capture(ctx)
	if err != nil {
		// 503, not 500: the usual cause is that there is no compositor
		// running yet, which is a state that resolves itself.
		writeError(w, http.StatusServiceUnavailable, err)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(png)
}

const screenshotTimeout = 15 * time.Second
