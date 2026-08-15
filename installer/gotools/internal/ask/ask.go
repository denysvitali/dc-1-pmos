// Package ask is dc1-ask: the single-purpose touch prompt screen the
// installer's tui.sh drives.
//
//	dc1-ask menu   TITLE OPTION...     -> prints the chosen 0-based index
//	dc1-ask text   TITLE [DEFAULT]     -> on-screen keyboard, prints the text
//	dc1-ask secret TITLE               -> like text, echoed as '*'
//	dc1-ask info   TITLE [LINE...]     -> message + OK button, prints nothing
//
// Exit codes: 0 answered, 1 cancelled (text/secret X button), 2 unusable
// (no framebuffer or no touchscreen -- callers fall back to the USB flow).
// tui.sh parses both the exit code and the stdout bytes, so neither is free
// to change.
//
// Why hand-rolled instead of buffyboard/unl0kr: buffyboard injects keys via
// /dev/uinput, which the pinned jagar kernel does not enable
// (CONFIG_INPUT_UINPUT is absent from jagar_defconfig); unl0kr is no longer
// packaged in Alpine, shows only a hardcoded password prompt, and drags in
// libinput + xkbcommon + a running udevd -- none of which can be exercised
// before first boot on hardware. This tool is one static binary with no
// runtime dependencies: a cached shadow buffer blitted to the panel (fb.go)
// and the built-in evdev touchscreen (CONFIG_TOUCHSCREEN_ILITEK=y,
// CONFIG_INPUT_EVDEV=y).
//
// NEITHER of those two paths has been observed working on the device, and the
// framebuffer one is inherited from a channel PID 1 has since abandoned --
// read fb.go's header and touch.go's tap() before trusting this screen.
// dc1-ask is an addition; the USB install flow is the proven path and the
// fallback, and tui.sh takes it whenever this exits 2.
//
// Secrets: the entered text goes to stdout only. Nothing is written to kmsg,
// no temp files, no argv leakage.
package ask

import (
	"fmt"
	"io"
)

// ui is everything a dialog needs: a canvas to paint, a way to put it on the
// panel, and a blocking source of taps in screen coordinates. Keeping the
// dialogs behind it is what lets the offline tests drive the whole CLI
// contract with no framebuffer and no touchscreen.
type ui struct {
	*canvas
	blit func()
	tap  func() (x, y int, err error)
}

// menu paints one page of options at a time and returns the index tapped.
func (u *ui) menu(title string, opts []string) (int, error) {
	g := newMenuGeom(u.w, len(opts))
	page := 0
	for {
		u.drawTitle(title)
		count := g.count(page, len(opts))
		for i := 0; i < count; i++ {
			u.drawButton(g.x, g.buttonY(i), g.w, g.h, cKey, cKeyTxt, 4,
				opts[page*menuPage+i])
		}
		if g.pages > 1 {
			u.drawButton(g.x, g.moreY, g.w, g.h, cBox, cAccent, 4,
				fmt.Sprintf("MORE (%d/%d)", page+1, g.pages))
		}
		u.blit()

		x, y, err := u.tap()
		if err != nil {
			return 0, err
		}
		if i, more := g.hit(page, len(opts), x, y); more {
			page = (page + 1) % g.pages
		} else if i >= 0 {
			return i, nil
		}
	}
}

// info shows a message until OK is tapped.
func (u *ui) info(title string, lines []string) error {
	g := newMenuGeom(u.w, 0)
	placed, okY := infoLayout(u.w, u.h, lines)

	u.drawTitle(title)
	for _, l := range placed {
		u.drawText(40, l.y, l.s, cFG, l.text)
	}
	u.drawButton(g.x, okY, g.w, g.h, cOK, cFG, 5, "OK")
	u.blit()

	for {
		x, y, err := u.tap()
		if err != nil {
			return err
		}
		if inRect(x, y, g.x, okY, g.w, g.h) {
			return nil
		}
	}
}

// text runs the on-screen keyboard. It reports the entered string, or that
// the user hit the X.
func (u *ui) text(title, initial string, secret bool) (string, bool, error) {
	e := editor{}
	if !secret {
		e.buf = initial
		if len(e.buf) > maxText {
			e.buf = e.buf[:maxText]
		}
	}
	g := kbGeometry(u.w, u.h)

	for {
		u.drawTitle(title)
		// cancel box, top right
		cx, cy, cw, ch := u.w-140, 30, 100, 100
		u.drawButton(cx, cy, cw, ch, cBox, cDim, 5, "X")

		// entry box
		const ey, eh, s = 260, 120, 4
		u.fillRect(40, ey, u.w-80, eh, cBox)
		tail := entryTail(e.masked(secret), u.w, s)
		u.drawText(60, ey+(eh-7*s)/2, s, cAccent, tail)
		u.fillRect(60+textW(s, tail)+4, ey+20, 8, eh-40, cAccent) // caret

		u.drawKeyboard(g, e.layer, e.shifted)
		u.blit()

		x, y, err := u.tap()
		if err != nil {
			return "", false, err
		}
		if inRect(x, y, cx, cy, cw, ch) {
			return "", true, nil
		}
		if e.key(kbHit(g, e.layer, e.shifted, x, y)) {
			return e.buf, false, nil
		}
	}
}

// run is the CLI contract, with the devices already open. Every failure to
// reach an answer is exit 2, which is tui.sh's signal to fall back to the USB
// flow.
func run(u *ui, args []string, stdout, stderr io.Writer) int {
	mode, title, rest := args[0], args[1], args[2:]

	switch mode {
	case "menu":
		if len(rest) == 0 {
			fmt.Fprintln(stderr, "dc1-ask: menu needs options")
			return 2
		}
		i, err := u.menu(title, rest)
		if err != nil {
			return 2
		}
		fmt.Fprintf(stdout, "%d\n", i)
		return 0

	case "text", "secret":
		initial := ""
		if mode == "text" && len(rest) > 0 {
			initial = rest[0]
		}
		answer, cancelled, err := u.text(title, initial, mode == "secret")
		if err != nil {
			return 2
		}
		if cancelled {
			return 1
		}
		fmt.Fprintf(stdout, "%s\n", answer)
		return 0

	case "info":
		if err := u.info(title, rest); err != nil {
			return 2
		}
		return 0
	}

	fmt.Fprintf(stderr, "dc1-ask: unknown mode %s\n", mode)
	return 2
}

// Main is the `dc1-ask` applet entry point.
func Main(args []string, stdout, stderr io.Writer) int {
	if len(args) < 2 {
		fmt.Fprintln(stderr, "usage: dc1-ask menu|text|secret|info TITLE ...")
		return 2
	}

	fb, err := openFB()
	if err != nil {
		fmt.Fprintln(stderr, "dc1-ask: no framebuffer")
		return 2
	}
	defer fb.close()

	t, err := openTouch()
	if err != nil {
		fmt.Fprintln(stderr, "dc1-ask: no touchscreen")
		return 2
	}
	defer t.close()

	u := &ui{
		canvas: fb.c,
		blit:   fb.blit,
		tap:    func() (int, int, error) { return t.tap(fb.c.w, fb.c.h) },
	}
	return run(u, args, stdout, stderr)
}
