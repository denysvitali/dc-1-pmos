package ask

import "encoding/binary"

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

func (c *canvas) drawText(x0, y0, s int, col uint32, str string) {
	x := x0
	for i := 0; i < len(str); i++ {
		g := glyph(str[i])
		for gc := 0; gc < 5; gc++ {
			for row := 0; row < 7; row++ {
				if g[gc]&(1<<row) != 0 {
					c.fillRect(x+gc*s, y0+row*s, s, s, col)
				}
			}
		}
		x += 6 * s
	}
}

func inRect(x, y, rx, ry, rw, rh int) bool {
	return x >= rx && x < rx+rw && y >= ry && y < ry+rh
}

// ------------------------------ chrome -----------------------------------

// Palette, identical to the C tool. The panel is little-endian 32bpp, so
// 0xAABBGGRR as the C code wrote it.
const (
	cBG      uint32 = 0xff000000
	cFG      uint32 = 0xffffffff
	cAccent  uint32 = 0xff00ff00
	cKey     uint32 = 0xff303030
	cKeyTxt  uint32 = 0xffffffff
	cBox     uint32 = 0xff202020
	cDim     uint32 = 0xff808080
	cShiftOn uint32 = 0xff005000
	cOK      uint32 = 0xff006000
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
