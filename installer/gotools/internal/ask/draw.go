package ask

import (
	"encoding/binary"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/textfont"
)

// Canvas: the shadow buffer every screen is painted into before one blit
// puts it on the panel, so the user never sees a half-drawn keyboard. It is
// exactly stride*h bytes, i.e. the visible span of the mapping.
type canvas struct {
	w, h, stride int
	pix          []byte
}

func newCanvas(w, h, stride int) *canvas {
	return &canvas{w: w, h: h, stride: stride, pix: make([]byte, stride*h)}
}

func (c *canvas) px(x, y int, col uint32) {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return
	}
	off := y*c.stride + x*4
	if off+4 <= len(c.pix) {
		binary.LittleEndian.PutUint32(c.pix[off:], col)
	}
}

func (c *canvas) fillRect(x0, y0, w, h int, col uint32) {
	for y := y0; y < y0+h; y++ {
		for x := x0; x < x0+w; x++ {
			c.px(x, y, col)
		}
	}
}

// drawText renders anti-aliased ink (the low byte of col is the grey level)
// with its top at y0, via the shared font package. A face that cannot be built
// renders nothing rather than panicking.
func (c *canvas) drawText(x0, y0, s int, col uint32, str string) {
	textfont.Draw(c.pix, c.stride, c.w, c.h, x0, y0, s, byte(col&0xff), str)
}

func inRect(x, y, rx, ry, rw, rh int) bool {
	return x >= rx && x < rx+rw && y >= ry && y < ry+rh
}

// ------------------------------ chrome -----------------------------------

// Palette: greyscale, because the panel is monochrome. Paper (near-white
// background) with ink (near-black text) reads best on a reflective panel in
// ambient light; colour is meaningless, so R==G==B and the low byte is the
// grey level. Values are 0xAARRGGBB written as 0xff g g g.
const (
	cBG      uint32 = 0xfff0f0f0 // paper
	cFG      uint32 = 0xff141414 // ink
	cAccent  uint32 = 0xff141414 // caret, MORE label
	cKey     uint32 = 0xffdddddd // key face
	cKeyTxt  uint32 = 0xff141414 // key label
	cBox     uint32 = 0xffcccccc // box / chrome
	cDim     uint32 = 0xff888888 // secondary / disabled
	cShiftOn uint32 = 0xff5a5a5a // active shift
	cOK      uint32 = 0xff909090 // OK / primary (darkest button)
)

func (c *canvas) drawTitle(title string) {
	c.fillRect(0, 0, c.w, c.h, cBG)
	c.fillRect(0, 0, c.w, 8, cFG)
	s := fitScale(5, 2, title, c.w-80)
	c.drawText(40, 60, s, cFG, title)
}

// drawButton draws one rounded-off button; label centred.
func (c *canvas) drawButton(x, y, w, h int, bg, fg uint32, s int, label string) {
	c.fillRect(x, y, w, h, bg)
	s = fitScale(s, 1, label, w-20)
	tx := x + (w-textW(s, label))/2
	ty := y + (h-7*s)/2
	c.drawText(tx, ty, s, fg, label)
}
