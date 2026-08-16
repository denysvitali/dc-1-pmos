package ask

import "testing"

// fakeSurface is a caller-owned panel: a shadow buffer plus a blit counter. It
// implements the Surface interface screen.go defines, so the in-process
// binding is proven without a DRM device or a touchscreen.
type fakeSurface struct {
	w, h   int
	stride int
	pix    []byte
	blits  int
}

func (f *fakeSurface) Size() (int, int) { return f.w, f.h }
func (f *fakeSurface) Stride() int      { return f.stride }
func (f *fakeSurface) Shadow() []byte   { return f.pix }
func (f *fakeSurface) Blit() error      { f.blits++; return nil }

// newTestScreen builds a Screen over a fake surface with a scripted tap, the
// screen.go analogue of runScript (which drives the same dialogs through the
// dc1-ask CLI path). close is a no-op so Close can be exercised safely.
func newTestScreen(taps ...[2]int) (*Screen, *fakeSurface) {
	const w, h = 1200, 1600
	f := &fakeSurface{w: w, h: h, stride: w * 4, pix: make([]byte, w*h*4)}
	script := &tapScript{taps: taps}
	return &Screen{u: bindScreen(f, script.tap), close: func() {}}, f
}

// TestBindScreen proves the in-process contract: the dialogs draw into the
// caller's shadow buffer and blit through the caller's blit, never a buffer or
// modeset of their own. That is the whole reason Screen exists -- a second
// modeset blackens this panel (see internal/drm).
func TestBindScreen(t *testing.T) {
	const w, h = 1200, 1600
	f := &fakeSurface{w: w, h: h, stride: w * 4, pix: make([]byte, w*h*4)}
	u := bindScreen(f, func() (int, int, error) { return 0, 0, nil })

	if u.w != w || u.h != h {
		t.Fatalf("canvas %dx%d, want %dx%d", u.w, u.h, w, h)
	}
	if u.stride != w*4 {
		t.Fatalf("stride %d, want %d", u.stride, w*4)
	}
	if &u.pix[0] != &f.pix[0] {
		t.Fatal("canvas pix does not alias the caller's shadow buffer")
	}
	u.blit()
	if f.blits != 1 {
		t.Fatalf("blit forwarded %d times, want 1", f.blits)
	}
}

func TestScreenMenu(t *testing.T) {
	s, f := newTestScreen([2]int{600, 280})
	i, err := s.Menu("DC-1 INSTALLER", []string{"one", "two"})
	if err != nil || i != 0 {
		t.Fatalf("Menu = (%d, %v), want (0, nil)", i, err)
	}
	if f.blits == 0 {
		t.Fatal("menu never blitted")
	}
}

func TestScreenText(t *testing.T) {
	s, _ := newTestScreen(tapA, tapB, tapOK)
	got, cancelled, err := s.Text("USERNAME", "")
	if err != nil || cancelled || got != "ab" {
		t.Fatalf("Text = (%q, %v, %v), want (ab, false, nil)", got, cancelled, err)
	}
}

func TestScreenSecret(t *testing.T) {
	s, _ := newTestScreen(tapA, tapOK)
	got, cancelled, err := s.Secret("PASSWORD")
	if err != nil || cancelled || got != "a" {
		t.Fatalf("Secret = (%q, %v, %v), want (a, false, nil)", got, cancelled, err)
	}
}

func TestScreenInfo(t *testing.T) {
	s, _ := newTestScreen([2]int{600, 1450})
	if err := s.Info("USB INSTALL", []string{"line"}); err != nil {
		t.Fatalf("Info: %v", err)
	}
}

// TestScreenClose releases the touchscreen (the injected close runs) but must
// leave the caller's panel surface alone -- the surface is PID 1's for the
// life of the boot.
func TestScreenClose(t *testing.T) {
	const w, h = 1200, 1600
	f := &fakeSurface{w: w, h: h, stride: w * 4, pix: make([]byte, w*h*4)}
	closed := false
	s := &Screen{
		u:     bindScreen(f, func() (int, int, error) { return 0, 0, nil }),
		close: func() { closed = true },
	}
	s.Close()
	if !closed {
		t.Fatal("Close did not release the touchscreen")
	}
	if f.blits != 0 {
		t.Fatal("Close touched the panel surface")
	}
}
