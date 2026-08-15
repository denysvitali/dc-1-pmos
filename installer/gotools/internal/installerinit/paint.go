package installerinit

import (
	"encoding/binary"
	"strings"
)

// The status screen: a banner, up to eight status lines, and a tick that
// proves PID 1 is still alive even when nothing else changes.
//
// The font is deliberately a second, tiny copy rather than a dependency on
// internal/ask: that package is the touch UI, it owns a keyboard and an evdev
// reader, and PID 1 pulling all of that in to draw eight lines of text would
// be the wrong direction of dependency. Both descend from the same 5x7 table
// in the C sources.
const (
	maxStatusLines = 8

	colBackground uint32 = 0xff000000
	colBanner     uint32 = 0xff00ff00
	colText       uint32 = 0xffffffff
	colTick       uint32 = 0xff808080
)

// StatusLines splits the status file into the lines the screen shows: at most
// maxStatusLines, blanks dropped, so a trailing newline does not push the
// first line off the top.
func StatusLines(status string) []string {
	var out []string
	for _, line := range strings.Split(status, "\n") {
		line = strings.TrimRight(line, "\r ")
		if line == "" {
			continue
		}
		out = append(out, line)
		if len(out) == maxStatusLines {
			break
		}
	}
	if len(out) == 0 {
		out = []string{DefaultStatus}
	}
	return out
}

// PaintStatus draws the whole screen into a 32bpp XRGB8888 buffer.
func PaintStatus(pix []byte, stride, w, h int, lines []string, tick uint64) {
	fill(pix, stride, w, h, 0, 0, w, h, colBackground)

	// Banner.
	drawText(pix, stride, w, h, 40, 40, 6, colBanner, "DC-1 INSTALLER")

	y := 160
	for _, line := range lines {
		drawText(pix, stride, w, h, 40, y, 4, colText, strings.ToUpper(line))
		y += 60
	}

	// A tick that changes every second: on a screen that can legitimately
	// show the same status for minutes, this is the difference between
	// "working" and "hung".
	drawText(pix, stride, w, h, 40, h-70, 3, colTick, "TICK "+utoa(tick))
}

func fill(pix []byte, stride, w, h, x0, y0, rw, rh int, col uint32) {
	for y := y0; y < y0+rh && y < h; y++ {
		if y < 0 {
			continue
		}
		row := y * stride
		for x := x0; x < x0+rw && x < w; x++ {
			if x < 0 {
				continue
			}
			binary.LittleEndian.PutUint32(pix[row+x*4:], col)
		}
	}
}

// drawText renders str at scale s. Unknown bytes render as blanks rather than
// panicking: this runs as PID 1, where a panic is a dead device.
func drawText(pix []byte, stride, w, h, x0, y0, s int, col uint32, str string) {
	x := x0
	for i := 0; i < len(str); i++ {
		g := glyph(str[i])
		for cx := 0; cx < 5; cx++ {
			bits := g[cx]
			for cy := 0; cy < 7; cy++ {
				if bits&(1<<uint(cy)) == 0 {
					continue
				}
				fill(pix, stride, w, h, x+cx*s, y0+cy*s, s, s, col)
			}
		}
		x += 6 * s
	}
}

func utoa(v uint64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}
