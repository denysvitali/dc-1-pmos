package ask

import (
	"bytes"
	"errors"
	"testing"
)

// tapScript is a fake touchscreen: a list of screen coordinates handed out in
// order, then a read error, which is what a real one does when the device
// goes away. Coordinates below are literal panel pixels, taken from the
// layout the C tool drew.
type tapScript struct {
	taps  [][2]int
	n     int
	blits int
}

func (s *tapScript) tap() (int, int, error) {
	if s.n >= len(s.taps) {
		return 0, 0, errors.New("no more taps")
	}
	t := s.taps[s.n]
	s.n++
	return t[0], t[1], nil
}

// runScript drives run() with a real canvas (so every drawing routine is
// exercised, and a panic in one is a test failure) and a scripted touchscreen.
func runScript(args []string, taps ...[2]int) (rc int, stdout, stderr string, s *tapScript, c *canvas) {
	s = &tapScript{taps: taps}
	c = newCanvas(testW, testH, testW*4)
	u := &ui{canvas: c, blit: func() { s.blits++ }, tap: s.tap}
	var out, errb bytes.Buffer
	rc = run(u, args, &out, &errb)
	return rc, out.String(), errb.String(), s, c
}

// Menu taps: option 0 at y=280, option 1 at y=400, MORE at y=1200.
func TestRunMenu(t *testing.T) {
	opts := []string{"Install from network (recommended)",
		"Install via USB from a computer", "Reboot to fastboot"}

	cases := []struct {
		name string
		args []string
		taps [][2]int
		rc   int
		out  string
	}{
		{
			name: "first option",
			args: append([]string{"menu", "DC-1 INSTALLER"}, opts...),
			taps: [][2]int{{600, 280}},
			out:  "0\n",
		},
		{
			name: "third option",
			args: append([]string{"menu", "DC-1 INSTALLER"}, opts...),
			taps: [][2]int{{600, 530}},
			out:  "2\n",
		},
		{
			name: "taps that hit nothing are ignored",
			args: append([]string{"menu", "DC-1 INSTALLER"}, opts...),
			taps: [][2]int{{600, 100}, {5, 280}, {600, 360}, {600, 400}},
			out:  "1\n",
		},
		{
			name: "no options is unusable, not an empty answer",
			args: []string{"menu", "EMPTY"},
			rc:   2,
		},
		{
			name: "a dead touchscreen is exit 2",
			args: append([]string{"menu", "DC-1 INSTALLER"}, opts...),
			rc:   2,
		},
	}
	for _, c := range cases {
		rc, out, _, _, _ := runScript(c.args, c.taps...)
		if rc != c.rc || out != c.out {
			t.Errorf("%s: rc=%d out=%q, want rc=%d out=%q", c.name, rc, out, c.rc, c.out)
		}
	}
}

// Paging: 8 options, so MORE appears and the second page starts at index 6.
func TestRunMenuPaging(t *testing.T) {
	args := []string{"menu", "CHOOSE WI-FI NETWORK"}
	for i := 0; i < 8; i++ {
		args = append(args, "net")
	}
	rc, out, _, _, _ := runScript(args, [2]int{600, 1200}, [2]int{600, 400})
	if rc != 0 || out != "7\n" {
		t.Errorf("MORE then option 1: rc=%d out=%q, want 0 and \"7\\n\"", rc, out)
	}
	// MORE wraps back to the first page.
	rc, out, _, _, _ = runScript(args, [2]int{600, 1200}, [2]int{600, 1200}, [2]int{600, 280})
	if rc != 0 || out != "0\n" {
		t.Errorf("MORE twice: rc=%d out=%q, want 0 and \"0\\n\"", rc, out)
	}
}

// Keyboard taps on a 1200x1600 panel: cells are 120x145 and the keyboard
// starts at y=875. 'a' is row 2 col 0, 'b' row 3 col 5, '!' row 1 col 0 of
// the symbol layer; OK is the bottom right, backspace the end of row 3, shift
// the start of row 3, and the cancel X sits at the top right of the title.
var (
	tapA      = [2]int{60, 1200}
	tapB      = [2]int{600, 1350}
	tapBang   = [2]int{60, 1030}
	tapSpace  = [2]int{600, 1500}
	tapShift  = [2]int{60, 1350}
	tapBS     = [2]int{1100, 1350}
	tapSym    = [2]int{100, 1500}
	tapOK     = [2]int{1100, 1500}
	tapCancel = [2]int{1100, 80}
)

func TestRunText(t *testing.T) {
	cases := []struct {
		name string
		args []string
		taps [][2]int
		rc   int
		out  string
	}{
		{
			name: "typed answer",
			args: []string{"text", "USERNAME"},
			taps: [][2]int{tapA, tapB, tapOK},
			out:  "ab\n",
		},
		{
			name: "the default is offered and can be accepted untouched",
			args: []string{"text", "HOSTNAME", "dc1"},
			taps: [][2]int{tapOK},
			out:  "dc1\n",
		},
		{
			name: "the default can be edited",
			args: []string{"text", "HOSTNAME", "dc1"},
			taps: [][2]int{tapBS, tapA, tapOK},
			out:  "dca\n",
		},
		{
			name: "shift capitalises exactly one character",
			args: []string{"text", "USERNAME"},
			taps: [][2]int{tapShift, tapA, tapA, tapOK},
			out:  "Aa\n",
		},
		{
			name: "the symbol layer types symbols",
			args: []string{"text", "TIMEZONE"},
			taps: [][2]int{tapSym, tapBang, tapOK},
			out:  "!\n",
		},
		{
			name: "space is a character like any other",
			args: []string{"text", "SSID"},
			taps: [][2]int{tapA, tapSpace, tapA, tapOK},
			out:  "a a\n",
		},
		{
			name: "an empty answer is still an answer",
			args: []string{"text", "SSID"},
			taps: [][2]int{tapOK},
			out:  "\n",
		},
		{
			name: "X cancels: exit 1 and nothing on stdout",
			args: []string{"text", "USERNAME"},
			taps: [][2]int{tapA, tapCancel},
			rc:   1,
		},
		{
			name: "secret ignores a default and still prints the answer",
			args: []string{"secret", "PASSWORD", "hunter2"},
			taps: [][2]int{tapA, tapOK},
			out:  "a\n",
		},
		{
			name: "secret cancels the same way",
			args: []string{"secret", "PASSWORD"},
			taps: [][2]int{tapCancel},
			rc:   1,
		},
		{
			name: "a dead touchscreen is exit 2, not an empty answer",
			args: []string{"text", "USERNAME"},
			rc:   2,
		},
	}
	for _, c := range cases {
		rc, out, _, _, _ := runScript(c.args, c.taps...)
		if rc != c.rc || out != c.out {
			t.Errorf("%s: rc=%d out=%q, want rc=%d out=%q", c.name, rc, out, c.rc, c.out)
		}
	}
}

// A default longer than the field maximum is truncated to it, rather than
// overflowing a buffer the user cannot see the end of.
func TestRunTextLongDefault(t *testing.T) {
	long := ""
	for i := 0; i < maxText+20; i++ {
		long += "x"
	}
	rc, out, _, _, _ := runScript([]string{"text", "SSID", long}, tapOK)
	if rc != 0 || len(out) != maxText+1 {
		t.Errorf("rc=%d, %d bytes out, want 0 and %d", rc, len(out), maxText+1)
	}
}

func TestRunInfo(t *testing.T) {
	args := []string{"info", "USB INSTALL", "line one", "", "line two"}
	rc, out, _, s, _ := runScript(args, [2]int{600, 100}, [2]int{600, 1450})
	if rc != 0 || out != "" {
		t.Errorf("rc=%d out=%q, want 0 and no output", rc, out)
	}
	if s.blits != 1 {
		t.Errorf("info blitted %d times, want 1 (it is a static screen)", s.blits)
	}

	// A title with no lines is legal (tui.sh sends one when a status file
	// turns out to be empty).
	if rc, _, _, _, _ := runScript([]string{"info", "INSTALL FAILED"}, [2]int{600, 1450}); rc != 0 {
		t.Errorf("info with no lines: rc=%d, want 0", rc)
	}
	if rc, _, _, _, _ := runScript([]string{"info", "INSTALL FAILED"}); rc != 2 {
		t.Errorf("info with a dead touchscreen: rc=%d, want 2", rc)
	}
}

func TestRunUnknownMode(t *testing.T) {
	rc, out, errs, _, _ := runScript([]string{"dialog", "TITLE"}, [2]int{600, 280})
	if rc != 2 || out != "" || errs == "" {
		t.Errorf("rc=%d out=%q err=%q, want 2, no output, a diagnostic", rc, out, errs)
	}
}

func TestMainUsage(t *testing.T) {
	var out, errb bytes.Buffer
	// No mode and no title: refused before any device is touched, so this
	// runs anywhere.
	if rc := Main([]string{"text"}, &out, &errb); rc != 2 {
		t.Errorf("rc=%d, want 2", rc)
	}
	if out.Len() != 0 || errb.Len() == 0 {
		t.Errorf("stdout=%q stderr=%q, want the usage on stderr only", out.String(), errb.String())
	}
}

// Every dialog paints before it waits for a tap: a screen that never blits is
// a black panel and a user with nothing to press.
func TestDialogsPaint(t *testing.T) {
	cases := []struct {
		name string
		args []string
		taps [][2]int
	}{
		{"menu", []string{"menu", "TITLE", "one"}, [][2]int{{600, 280}}},
		{"text", []string{"text", "TITLE"}, [][2]int{tapOK}},
		{"secret", []string{"secret", "TITLE"}, [][2]int{tapOK}},
		{"info", []string{"info", "TITLE", "hello"}, [][2]int{{600, 1450}}},
	}
	for _, c := range cases {
		_, _, _, s, canv := runScript(c.args, c.taps...)
		if s.blits == 0 {
			t.Errorf("%s: never blitted", c.name)
		}
		if !bytes.Contains(canv.pix, []byte{0xf0, 0xf0, 0xf0, 0xff}) {
			t.Errorf("%s: no paper background on the canvas, so the screen "+
				"never got filled", c.name)
		}
	}
}
