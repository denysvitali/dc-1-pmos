package installerinit

import (
	"encoding/binary"
	"strings"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/textfont"
)

// The status screen: a banner, up to eight status lines, and a tick that
// proves PID 1 is still alive even when nothing else changes.
//
// Text is anti-aliased from internal/textfont, a focused font package shared
// with internal/ask: it owns no keyboard, evdev reader or DRM surface, so PID
// 1 can depend on it to draw eight lines of text without pulling the touch UI
// in. The palette is greyscale because the panel is monochrome.
const (
	maxStatusLines = 8

	colBackground uint32 = 0xfff0f0f0 // paper
	colBanner     uint32 = 0xff141414 // ink (banner)
	colText       uint32 = 0xff141414 // ink (status lines)
	colTick       uint32 = 0xff888888 // secondary (the heartbeat tick)
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

// drawText renders str at scale s with anti-aliased text from the shared font.
// A face that cannot be built renders nothing rather than panicking: this runs
// as PID 1, where a panic is a dead device.
func drawText(pix []byte, stride, w, h, x0, y0, s int, col uint32, str string) {
	textfont.Draw(pix, stride, w, h, x0, y0, s, byte(col&0xff), str)
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
