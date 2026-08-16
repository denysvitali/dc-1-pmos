package ask

import "bytes"

// Screen is the touch dialog engine bound to a panel surface the caller owns.
//
// This is the in-process entry point for the on-device setup flow: the DC-1's
// mediatek-drm driver lights the panel only via its one-time boot handoff, and
// any SUBSEQUENT modeset blackens it (see internal/drm). So the setup UI must
// draw into PID 1's already-acquired surface, never modeset one of its own.
// The dialogs here only write the shadow buffer and blit; DRM master stays
// with whoever constructed the Screen.
//
// Surface is the minimal panel a dialog needs: geometry, a shadow buffer to
// draw into, and a blit that puts the shadow on the glass. *drm.Surface
// satisfies it directly.
type Surface interface {
	Size() (w, h int)
	Stride() int
	Shadow() []byte
	Blit() error
}

// Screen drives the menu/text/secret/info dialogs against one Surface. A
// Screen owns the touchscreen it reads taps from and releases it on Close;
// the panel surface it draws into is the caller's.
type Screen struct {
	u     *ui
	close func()
}

// NewScreen binds the dialog engine to an already-acquired panel. It opens the
// touchscreen itself and fails if there is none, so a caller can fall back to
// the USB flow the way tui.sh did on dc1-ask's exit 2.
func NewScreen(s Surface) (*Screen, error) {
	t, err := openTouch()
	if err != nil {
		return nil, err
	}
	w, h := s.Size()
	u := bindScreen(s, func() (int, int, error) { return t.tap(w, h) })
	return &Screen{u: u, close: t.close}, nil
}

// bindScreen ties a Surface's geometry, shadow buffer and blit to the dialog
// engine. It is NewScreen's device-free core, split out so the binding -- draw
// into the caller's shadow, blit through the caller's blit -- is testable
// without a touchscreen or a DRM device.
func bindScreen(s Surface, tap func() (int, int, error)) *ui {
	w, h := s.Size()
	c := &canvas{w: w, h: h, stride: s.Stride(), pix: s.Shadow()}
	return &ui{
		canvas: c,
		blit:   func() { _ = s.Blit() },
		tap:    tap,
	}
}

// Close releases the touchscreen. The panel surface is NOT released: the
// caller owns it (PID 1 holds it for the life of the boot).
func (s *Screen) Close() { s.close() }

// Menu shows a page of options and returns the tapped index.
func (s *Screen) Menu(title string, opts []string) (int, error) {
	return s.u.menu(title, opts)
}

// Text runs the on-screen keyboard for a non-secret value. It returns the
// entered string and whether the user cancelled (hit X).
func (s *Screen) Text(title, initial string) (string, bool, error) {
	return s.u.text(title, initial, false)
}

// Secret runs the on-screen keyboard with the entry masked.
func (s *Screen) Secret(title string) (string, bool, error) {
	return s.u.text(title, "", true)
}

// Info shows a message until OK is tapped.
func (s *Screen) Info(title string, lines []string) error {
	return s.u.info(title, lines)
}

// Run dispatches one dc1-ask CLI request against this Screen, returning the
// exit code, stdout and stderr exactly as the dc1-ask applet would print them.
// It is the in-process twin of ask.run: the same modes and the same exit-code
// contract (0 answered, 1 cancelled, 2 unusable), so the dialog server serves
// requests without a second copy of the dispatch.
func (s *Screen) Run(args []string) (rc int, out, errOut string) {
	var ob, eb bytes.Buffer
	rc = run(s.u, args, &ob, &eb)
	return rc, ob.String(), eb.String()
}
