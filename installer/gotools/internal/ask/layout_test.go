package ask

import "testing"

// The panel this was written against; every coordinate below is in its
// pixels, spelled out rather than recomputed from the geometry it is meant to
// check.
const (
	testW = 1200
	testH = 1600
)

func TestKbGeometry(t *testing.T) {
	g := kbGeometry(testW, testH)
	if g.cellH != 145 || g.cellW != 120 || g.top != 875 {
		t.Fatalf("kbGeometry = %+v, want {top:875 cellW:120 cellH:145}", g)
	}
	if bottom := g.top + 5*g.cellH; bottom != testH {
		t.Errorf("keyboard ends at y=%d, not at the bottom of the panel", bottom)
	}
}

func TestKbHit(t *testing.T) {
	g := kbGeometry(testW, testH)
	cases := []struct {
		name           string
		layer, shifted int
		x, y           int
		want           int
	}{
		{"above the keyboard", 0, 0, 600, 800, keyNone},
		{"row 0 first key", 0, 0, 10, 880, '1'},
		{"row 0 last key", 0, 0, 1190, 880, '0'},
		{"row 1 lower", 0, 0, 60, 1030, 'q'},
		{"row 1 shifted", 0, 1, 60, 1030, 'Q'},
		{"row 1 symbols", 1, 0, 60, 1030, '!'},
		{"row 2 dash", 0, 0, 1080, 1170, '-'},
		{"row 3 shift key", 0, 0, 60, 1320, keyShift},
		{"row 3 backspace", 0, 0, 1100, 1320, keyBS},
		{"row 3 symbol layer starts with SYM", 1, 0, 60, 1320, keySym},
		{"bottom row layer key", 0, 0, 100, 1500, keySym},
		{"bottom row space", 0, 0, 600, 1500, ' '},
		{"bottom row at sign", 0, 0, 900, 1500, '@'},
		{"bottom row tilde in symbols", 1, 0, 900, 1500, '~'},
		{"bottom row OK", 0, 0, 1100, 1500, keyOK},
		{"last column of the symbol row", 1, 0, 1190, 1320, keyBS},
		// x can land exactly on the panel width when the touchscreen
		// reports its maximum; the C tool clamped the column, so do we.
		{"x at the panel edge", 0, 0, 1200, 880, '0'},
	}
	for _, c := range cases {
		if got := kbHit(g, c.layer, c.shifted, c.x, c.y); got != c.want {
			t.Errorf("%s: kbHit(%d,%d) = %d (%q), want %d (%q)",
				c.name, c.x, c.y, got, rune(got), c.want, rune(c.want))
		}
	}
}

// The grid is 10 columns wide on every layer, which is why kbHit's
// past-the-end guard is only defensive: a short row here would silently make
// the last key of that row unreachable.
func TestKbRowsAreFullWidth(t *testing.T) {
	for _, rows := range [][]string{rowsLower, rowsUpper, rowsSym} {
		for r, row := range rows {
			if len(row) != 10 {
				t.Errorf("row %d is %d cells wide, want 10: %q", r, len(row), row)
			}
		}
	}
}

// Every cell of every layer must map back to the character drawn in it:
// a keyboard that draws one key and types another is the failure that would
// cost a user a wrong Wi-Fi password with no way to see why.
func TestKbHitMatchesLayout(t *testing.T) {
	g := kbGeometry(testW, testH)
	for _, layer := range []int{0, 1} {
		for _, shifted := range []int{0, 1} {
			rows := kbRows(layer, shifted)
			for r, row := range rows {
				for c := 0; c < len(row); c++ {
					x := c*g.cellW + g.cellW/2
					y := g.top + r*g.cellH + g.cellH/2
					if got := kbHit(g, layer, shifted, x, y); got != int(row[c]) {
						t.Errorf("layer %d shift %d row %d col %d: got %d, want %d",
							layer, shifted, r, c, got, row[c])
					}
				}
			}
		}
	}
}

func TestEditor(t *testing.T) {
	cases := []struct {
		name   string
		keys   []int
		want   string
		accept bool
		layer  int
		shift  int
	}{
		{name: "plain typing", keys: []int{'a', 'b', 'c'}, want: "abc"},
		{name: "backspace", keys: []int{'a', 'b', keyBS}, want: "a"},
		{name: "backspace on empty", keys: []int{keyBS, keyBS, 'a'}, want: "a"},
		{name: "accept", keys: []int{'a', keyOK}, want: "a", accept: true},
		{name: "shift latches", keys: []int{keyShift}, shift: 1},
		{name: "shift is one-shot", keys: []int{keyShift, 'A', 'b'}, want: "Ab"},
		{name: "shift toggles off", keys: []int{keyShift, keyShift}, shift: 0},
		{name: "sym switches layer", keys: []int{keySym}, layer: 1},
		{name: "sym clears shift", keys: []int{keyShift, keySym}, layer: 1, shift: 0},
		{name: "none is ignored", keys: []int{'a', keyNone}, want: "a"},
	}
	for _, c := range cases {
		e := editor{}
		accept := false
		for _, k := range c.keys {
			accept = e.key(k)
		}
		if e.buf != c.want || accept != c.accept || e.layer != c.layer || e.shifted != c.shift {
			t.Errorf("%s: buf=%q accept=%v layer=%d shift=%d, want %q/%v/%d/%d",
				c.name, e.buf, accept, e.layer, e.shifted,
				c.want, c.accept, c.layer, c.shift)
		}
	}
}

// maxText is the WPA-PSK maximum: the buffer must stop there, and stopping
// must not spend the shift either.
func TestEditorLength(t *testing.T) {
	e := editor{}
	for i := 0; i < maxText+10; i++ {
		e.key('x')
	}
	if len(e.buf) != maxText {
		t.Fatalf("buffer grew to %d, want %d", len(e.buf), maxText)
	}
	e.key(keyShift)
	e.key('Y')
	if e.shifted != 1 {
		t.Error("a rejected character spent the shift")
	}
	e.key(keyBS)
	e.key('y')
	if e.buf[maxText-1] != 'y' {
		t.Errorf("after backspace the buffer ends %q, want 'y'", e.buf[maxText-1])
	}
}

func TestEditorMasked(t *testing.T) {
	e := editor{buf: "hunter2"}
	if got := e.masked(true); got != "*******" {
		t.Errorf("masked secret = %q", got)
	}
	if got := e.masked(false); got != "hunter2" {
		t.Errorf("masked text = %q", got)
	}
}

func TestEntryTail(t *testing.T) {
	// (1200-120)/(6*4) = 45 columns fit in the entry box.
	long := ""
	for i := 0; i < 63; i++ {
		long += string(rune('a' + i%26))
	}
	cases := []struct{ in, want string }{
		{"", ""},
		{"short", "short"},
		{long, long[len(long)-45:]},
	}
	for _, c := range cases {
		if got := entryTail(c.in, testW, 4); got != c.want {
			t.Errorf("entryTail(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestMenuGeom(t *testing.T) {
	cases := []struct{ n, pages int }{{1, 1}, {6, 1}, {7, 2}, {12, 2}, {13, 3}}
	for _, c := range cases {
		if g := newMenuGeom(testW, c.n); g.pages != c.pages {
			t.Errorf("%d options: %d pages, want %d", c.n, g.pages, c.pages)
		}
	}
	g := newMenuGeom(testW, 8)
	if g.count(0, 8) != menuPage || g.count(1, 8) != 2 {
		t.Errorf("counts = %d,%d, want 6,2", g.count(0, 8), g.count(1, 8))
	}
	if g.moreY != 1164 {
		t.Errorf("moreY = %d, want 1164", g.moreY)
	}
	if g.moreY+g.h > testH {
		t.Errorf("the MORE button (y=%d h=%d) runs off a %d-pixel panel",
			g.moreY, g.h, testH)
	}
}

func TestMenuHit(t *testing.T) {
	g := newMenuGeom(testW, 8)
	cases := []struct {
		name string
		page int
		x, y int
		want int
		more bool
	}{
		{name: "first option", x: 600, y: 280, want: 0},
		{name: "second option", x: 600, y: 400, want: 1},
		{name: "last on page", x: 600, y: 1050, want: 5},
		{name: "gap between buttons", x: 600, y: 360, want: -1},
		{name: "left of the buttons", x: 10, y: 280, want: -1},
		{name: "title area", x: 600, y: 100, want: -1},
		{name: "more button", x: 600, y: 1200, want: -1, more: true},
		{name: "page 1 first option", page: 1, x: 600, y: 280, want: 6},
		{name: "page 1 second option", page: 1, x: 600, y: 400, want: 7},
		{name: "page 1 empty slot", page: 1, x: 600, y: 600, want: -1},
	}
	for _, c := range cases {
		got, more := g.hit(c.page, 8, c.x, c.y)
		if got != c.want || more != c.more {
			t.Errorf("%s: hit = %d,%v, want %d,%v", c.name, got, more, c.want, c.more)
		}
	}
	// With one page there is no MORE button to tap.
	one := newMenuGeom(testW, 3)
	if _, more := one.hit(0, 3, 600, 1200); more {
		t.Error("single page reported a MORE hit")
	}
}

func TestInfoLayout(t *testing.T) {
	lines := []string{"first", "second", "third"}
	placed, okY := infoLayout(testW, testH, lines)
	if okY != 1400 {
		t.Fatalf("okY = %d, want 1400", okY)
	}
	if len(placed) != 3 {
		t.Fatalf("placed %d lines, want 3", len(placed))
	}
	for i, l := range placed {
		if want := 220 + 60*i; l.y != want {
			t.Errorf("line %d at y=%d, want %d", i, l.y, want)
		}
		if l.s != 3 {
			t.Errorf("line %d scale %d, want 3", i, l.s)
		}
	}

	// Lines that would collide with the OK button are dropped, not drawn
	// over it: (1400-40-220)/60 = 19 fit.
	many := make([]string, 40)
	for i := range many {
		many[i] = "x"
	}
	placed, _ = infoLayout(testW, testH, many)
	if len(placed) != 19 {
		t.Errorf("placed %d of 40 lines, want 19", len(placed))
	}
	if last := placed[len(placed)-1]; last.y+7*last.s >= okY {
		t.Errorf("last line at y=%d overlaps the OK button at %d", last.y, okY)
	}

	// A line too wide for the panel is shrunk, not clipped.
	wide := ""
	for i := 0; i < 100; i++ {
		wide += "W"
	}
	placed, _ = infoLayout(testW, testH, []string{wide})
	if placed[0].s != 1 {
		t.Errorf("a 100-character line got scale %d, want 1", placed[0].s)
	}
}

func TestFitScale(t *testing.T) {
	cases := []struct {
		s, floor, maxW int
		label          string
		want           int
	}{
		{5, 2, 1120, "DC-1 INSTALLER", 5},
		{5, 2, 100, "A VERY LONG TITLE THAT DOES NOT FIT", 2}, // floors, never 0
		{4, 1, 116, "OK", 4},
		{4, 1, 5, "OK", 1},
	}
	for _, c := range cases {
		if got := fitScale(c.s, c.floor, c.label, c.maxW); got != c.want {
			t.Errorf("fitScale(%d,%d,%q,%d) = %d, want %d",
				c.s, c.floor, c.label, c.maxW, got, c.want)
		}
	}
	// textW is now measured from the anti-aliased face, not a fixed 6px/char;
	// assert it is sane rather than a magic bitmap number.
	if textW(4, "abc") <= 0 {
		t.Errorf("textW(4,\"abc\") = %d, want > 0", textW(4, "abc"))
	}
	if textW(2, "abc") >= textW(4, "abc") {
		t.Errorf("textW must grow with scale")
	}
	if textW(4, "abc") >= textW(4, "abcd") {
		t.Errorf("textW must grow with length")
	}
}
