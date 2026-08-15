package server

import (
	"context"
	"errors"
	"net/http"
	"testing"
)

type fakeScreen struct {
	png []byte
	err error
}

func (f fakeScreen) Capture(context.Context) ([]byte, error) { return f.png, f.err }

func TestScreenshotServesPNG(t *testing.T) {
	h := newHarness(t)
	want := append([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}, []byte("body")...)
	h.srv.screen = fakeScreen{png: want}

	resp, body := h.do(t, http.MethodGet, "/screenshot", "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d: %s", resp.StatusCode, body)
	}
	if got := resp.Header.Get("Content-Type"); got != "image/png" {
		t.Fatalf("content-type = %q", got)
	}
	if body != string(want) {
		t.Fatalf("body = %q, want %q", body, want)
	}
}

// No compositor is an ordinary state (early boot, or after the onboarding
// reboot), not a server fault: 503 says "try again", 500 says "this is
// broken".
func TestScreenshotWithoutACompositorIsUnavailable(t *testing.T) {
	h := newHarness(t)
	h.srv.screen = fakeScreen{err: errors.New("no wayland socket")}

	resp, _ := h.do(t, http.MethodGet, "/screenshot", "")
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", resp.StatusCode)
	}
}

func TestScreenshotRejectsNonGET(t *testing.T) {
	h := newHarness(t)
	h.srv.screen = fakeScreen{png: []byte("x")}
	resp, _ := h.do(t, http.MethodPost, "/screenshot", "")
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", resp.StatusCode)
	}
}
