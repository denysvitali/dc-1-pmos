package ask

// Screen layout and the text-editing model: the parts of the dialogs that are
// arithmetic rather than I/O, kept pure so the offline tests can check every
// tap-to-answer mapping without a panel or a touchscreen.

// MAX_TEXT in the C tool: the WPA-PSK maximum, and the longest field the
// installer collects.
const maxText = 63

// menuPage is how many options fit on one page; the rest go behind MORE.
const menuPage = 6

// menuGeom is the option-button grid. The numbers are the C tool's, which
// were chosen against the 1200x1600 panel: a 130px button is comfortably
// larger than a fingertip at this DPI.
type menuGeom struct {
	x, w, h, gap, y0 int
	moreY            int
	pages            int
}

func newMenuGeom(fbw, n int) menuGeom {
	g := menuGeom{x: 40, w: fbw - 80, h: 130, gap: 24, y0: 220}
	g.moreY = g.y0 + menuPage*(g.h+g.gap) + 20
	g.pages = (n + menuPage - 1) / menuPage
	if g.pages < 1 {
		g.pages = 1
	}
	return g
}

// count is how many options page shows out of n.
func (g menuGeom) count(page, n int) int {
	c := n - page*menuPage
	if c > menuPage {
		c = menuPage
	}
	if c < 0 {
		c = 0
	}
	return c
}

// buttonY is the top edge of the i-th button on the current page.
func (g menuGeom) buttonY(i int) int { return g.y0 + i*(g.h+g.gap) }

// hit maps a tap to an option index (0-based over the whole list), or reports
// the MORE button. Taps that land on neither are ignored, exactly as in C:
// this is a touchscreen, and a stray press must not answer the question.
func (g menuGeom) hit(page, n, x, y int) (index int, more bool) {
	first := page * menuPage
	for i := 0; i < g.count(page, n); i++ {
		if inRect(x, y, g.x, g.buttonY(i), g.w, g.h) {
			return first + i, false
		}
	}
	if g.pages > 1 && inRect(x, y, g.x, g.moreY, g.w, g.h) {
		return -1, true
	}
	return -1, false
}

// infoLine is one placed line of an info screen.
type infoLine struct {
	y, s int
	text string
}

// infoLayout places the message lines above the OK button, shrinking any line
// that is too wide and dropping the ones that would collide with the button.
// There is no word wrapping (there was none in C either): callers pass
// pre-split lines.
func infoLayout(fbw, fbh int, lines []string) (placed []infoLine, okY int) {
	okY = fbh - 200
	y := 220
	for _, l := range lines {
		if y >= okY-40 {
			break
		}
		placed = append(placed, infoLine{y: y, s: fitScale(3, 1, l, fbw-80), text: l})
		y += 60
	}
	return placed, okY
}

// entryTail is what fits in the entry box: the END of the string, so the
// caret and the characters just typed stay visible on a long PSK.
func entryTail(shown string, fbw, s int) string {
	maxcols := (fbw - 120) / (6 * s)
	if maxcols < 0 {
		maxcols = 0
	}
	if len(shown) > maxcols {
		return shown[len(shown)-maxcols:]
	}
	return shown
}

// editor is the text-entry model: the buffer plus which keyboard layer is up.
type editor struct {
	buf     string
	layer   int // 0 = letters, 1 = symbols
	shifted int
}

// key applies one keypress and reports whether the user accepted the entry.
func (e *editor) key(k int) (accept bool) {
	switch k {
	case keyNone:
	case keyShift:
		e.shifted ^= 1
	case keySym:
		e.layer ^= 1
		e.shifted = 0
	case keyBS:
		if len(e.buf) > 0 {
			e.buf = e.buf[:len(e.buf)-1]
		}
	case keyOK:
		return true
	default:
		// Anything else is a printable byte. Shift is one-shot, and only
		// spent when a character actually went in.
		if k >= 0x20 && k <= 0x7e && len(e.buf) < maxText {
			e.buf += string(byte(k))
			e.shifted = 0
		}
	}
	return false
}

// masked is what the entry box shows: the text itself, or one '*' per
// character when the field is a secret.
func (e *editor) masked(secret bool) string {
	if !secret {
		return e.buf
	}
	stars := make([]byte, len(e.buf))
	for i := range stars {
		stars[i] = '*'
	}
	return string(stars)
}
