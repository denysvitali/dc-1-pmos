package textfont

import (
	"testing"

	"golang.org/x/image/font"
)

// The bundled font must parse and produce non-zero text, or the dialogs and
// status screen render blank on hardware. This fails fast in CI rather than
// silently shipping an installer with no readable text.
func TestFaceAt(t *testing.T) {
	f := FaceAt(4)
	if f == nil {
		t.Fatal("FaceAt(4) returned nil -- the bundled font failed to parse")
	}
	if font.MeasureString(f, "OK").Ceil() <= 0 {
		t.Fatal("the face measures zero-width text")
	}
	if Measure(4, "OK") <= 0 {
		t.Fatal("Measure returned non-positive width")
	}
	if Measure(2, "abc") >= Measure(4, "abc") {
		t.Fatal("Measure must grow with scale")
	}
}

// Draw must leave ink darker than paper, never brighter, and stay within the
// buffer.
func TestDrawBlendsInk(t *testing.T) {
	const w, h, stride = 200, 60, 200 * 4
	pix := make([]byte, stride*h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			o := y*stride + x*4
			pix[o], pix[o+1], pix[o+2], pix[o+3] = 0xf0, 0xf0, 0xf0, 0xff // paper
		}
	}
	Draw(pix, stride, w, h, 10, 10, 4, 0x14, "OK")

	sawInk := false
	for i := 0; i+4 <= len(pix); i += 4 {
		if pix[i] < 0xf0 {
			sawInk = true
		}
		if pix[i] > 0xf0 {
			t.Fatalf("pixel %d is %#x, brighter than paper 0xf0", i/4, pix[i])
		}
	}
	if !sawInk {
		t.Fatal("no ink drawn")
	}
}
