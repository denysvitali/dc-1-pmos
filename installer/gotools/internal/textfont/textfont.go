// Package textfont renders anti-aliased greyscale text into a 32bpp
// little-endian framebuffer.
//
// The DC-1 panel is monochrome (a reflective LCD with a white frontlight), so
// colour is meaningless and text quality IS the UI: every pixel is a grey
// level (R==G==B), and the old 5x7 bitmap read as jagged because it had no
// anti-aliasing. The font is the Go font bundled as a byte slice in
// x/image/font/gofont/goregular (BSD-licensed, nothing committed), rasterized
// on the CPU, so callers stay a single static CGO_ENABLED=0 binary with no
// runtime dependency. It is shared by internal/ask (the dialogs) and
// internal/installerinit (the status screen), and owns no keyboard, evdev
// reader or DRM surface, so PID 1 can depend on it without pulling the touch
// UI in.
package textfont

import (
	"errors"
	"image"
	"sync"

	"golang.org/x/image/font"
	"golang.org/x/image/font/gofont/goregular"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

// faceScale maps the caller's integer glyph scale s to a face point size: the
// old 5x7 box was 7px tall per unit, so 9px of point size per unit gives a
// comparable cap height with room for descenders.
const faceScale = 9.0

var errNoFont = errors.New("bundled font failed to parse")

var (
	parsedOnce sync.Once
	parsedFont *opentype.Font
)

func face(size float64) (font.Face, error) {
	parsedOnce.Do(func() {
		f, err := opentype.Parse(goregular.TTF)
		if err != nil {
			return
		}
		parsedFont = f
	})
	if parsedFont == nil {
		return nil, errNoFont
	}
	return opentype.NewFace(parsedFont, &opentype.FaceOptions{
		Size:    size,
		DPI:     72,
		Hinting: font.HintingFull,
	})
}

// faceCache memoises one face per scale; the set is tiny (s in 1..12).
var faceCache sync.Map

// FaceAt returns the face for scale s, or nil if the bundled font failed to
// parse (a compile-time constant that always parses in practice).
func FaceAt(s int) font.Face {
	if v, ok := faceCache.Load(s); ok {
		return v.(font.Face)
	}
	f, err := face(faceScale * float64(s))
	if err != nil {
		return nil
	}
	faceCache.Store(s, f)
	return f
}

// Measure is the width of str at scale s in pixels.
func Measure(s int, str string) int {
	if f := FaceAt(s); f != nil {
		return font.MeasureString(f, str).Ceil()
	}
	return len(str) * 6 * s
}

// Draw blends ink text (grey level ink) at scale s into pix, a 32bpp
// little-endian buffer of stride bytes per row, with the text's top-left at
// (x0,y0), clipped to w x h. If the font cannot be loaded, Draw renders
// nothing rather than panicking -- PID 1 must never die.
func Draw(pix []byte, stride, w, h, x0, y0, s int, ink byte, str string) {
	f := FaceAt(s)
	if f == nil {
		return
	}
	asc := f.Metrics().Ascent.Ceil()
	desc := f.Metrics().Descent.Ceil()
	tw := font.MeasureString(f, str).Ceil()
	th := asc + desc
	if tw <= 0 || th <= 0 {
		return
	}
	mask := image.NewAlpha(image.Rect(0, 0, tw, th))
	d := &font.Drawer{Dst: mask, Src: image.Opaque, Face: f, Dot: fixed.P(0, asc)}
	d.DrawString(str)
	for y := 0; y < th; y++ {
		py := y0 + y
		if py < 0 || py >= h {
			continue
		}
		row := py * stride
		for x := 0; x < tw; x++ {
			a := mask.AlphaAt(x, y).A
			if a == 0 {
				continue
			}
			px := x0 + x
			if px < 0 || px >= w {
				continue
			}
			off := row + px*4
			if off+4 > len(pix) {
				continue
			}
			bg := uint32(pix[off])
			v := byte((uint32(ink)*uint32(a) + bg*uint32(255-a) + 127) / 255)
			pix[off] = v
			pix[off+1] = v
			pix[off+2] = v
			pix[off+3] = 0xff
		}
	}
}
