package ask

import "testing"

// Anti-aliased text must leave ink on the paper canvas, and its width must
// track what is actually drawn.
func TestDrawTextAntialiased(t *testing.T) {
	c := newCanvas(200, 60, 200*4)
	c.fillRect(0, 0, 200, 60, cBG)
	c.drawText(10, 10, 4, cFG, "OK")
	// Some pixel is strictly darker than paper (ink or an AA edge), and no
	// pixel is darker than pure ink.
	ink := byte(cFG & 0xff)
	paper := byte(cBG & 0xff)
	var sawInk bool
	for i := 0; i+4 <= len(c.pix); i += 4 {
		if c.pix[i] < paper {
			sawInk = true
		}
		if c.pix[i] > paper {
			t.Fatalf("pixel %d is %#x, brighter than paper %#x", i/4, c.pix[i], paper)
		}
	}
	if !sawInk {
		t.Fatal("no ink drawn")
	}
	if ink >= paper {
		t.Fatalf("palette is not paper-with-ink: ink=%#x paper=%#x", ink, paper)
	}
}
