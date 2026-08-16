package installerinit

import (
	"encoding/binary"
	"strconv"
	"strings"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/textfont"
)

// The status screen: a banner, up to eight status lines, a progress bar, and
// a tick that proves PID 1 is still alive even when nothing else changes.
//
// Text is anti-aliased from internal/textfont, a focused font package shared
// with internal/ask: it owns no keyboard, evdev reader or DRM surface, so PID
// 1 can depend on it to draw eight lines of text without pulling the touch UI
// in. The palette is greyscale because the panel is monochrome.
//
// The status file may carry a "PROGRESS <n>" line (integer percentage 0..100).
// StatusLines skips it and the caller surfaces the parsed value to PaintStatus,
// which fills the bar accordingly; the last such line in the file wins.
const (
	maxStatusLines = 8

	colBackground uint32 = 0xfff0f0f0 // paper
	colBanner     uint32 = 0xff141414 // ink (banner)
	colText       uint32 = 0xff141414 // ink (status lines)
	colSecondary  uint32 = 0xff888888 // secondary (heartbeat tick, progress track border)

	// Progress bar geometry: full width minus the side margins, anchored just
	// above the tick line.
	progressLeft   = 40
	progressRight  = 40
	progressHeight = 12
	progressGap    = 30 // gap between the bar and the tick line below it
	progressBorder = 2  // secondary border around the paper track
)

// StatusLines splits the status file into the lines the screen shows: at most
// maxStatusLines, blanks dropped, so a trailing newline does not push the
// first line off the top. A "PROGRESS " line drives the bar, not the text, so
// it is skipped here and surfaced separately by ProgressPct.
func StatusLines(status string) []string {
	var out []string
	for _, line := range strings.Split(status, "\n") {
		line = strings.TrimRight(line, "\r ")
		if line == "" || strings.HasPrefix(line, "PROGRESS ") {
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

// ProgressPct returns the percentage carried by the last syntactically-valid
// "PROGRESS <n>" line in the status text, clamped to 0..100. The second value
// is false when no such line is present. A line whose value is not a
// non-negative integer (empty, "abc", "-5") is not a progress line and is
// ignored, so an earlier valid line keeps winning.
func ProgressPct(status string) (int, bool) {
	last := 0
	found := false
	for _, line := range strings.Split(status, "\n") {
		line = strings.TrimRight(line, "\r ")
		if !strings.HasPrefix(line, "PROGRESS ") {
			continue
		}
		rest := strings.TrimSpace(line[len("PROGRESS "):])
		n, err := strconv.Atoi(rest)
		if err != nil || n < 0 {
			continue
		}
		if n > 100 {
			n = 100
		}
		last = n
		found = true
	}
	return last, found
}

// PaintStatus draws the whole screen into a 32bpp XRGB8888 buffer. pct < 0
// means "no percentage": the track is drawn empty (no fill); otherwise the bar
// is filled from the left to pct% (clamped to 0..100).
func PaintStatus(pix []byte, stride, w, h int, lines []string, tick uint64, pct int) {
	fill(pix, stride, w, h, 0, 0, w, h, colBackground)

	// Banner.
	drawText(pix, stride, w, h, 40, 40, 6, colBanner, "DC-1 INSTALLER")

	y := 160
	for _, line := range lines {
		drawText(pix, stride, w, h, 40, y, 4, colText, strings.ToUpper(line))
		y += 60
	}

	drawProgress(pix, stride, w, h, pct)

	// A tick that changes every second: on a screen that can legitimately
	// show the same status for minutes, this is the difference between
	// "working" and "hung".
	drawText(pix, stride, w, h, 40, h-70, 3, colSecondary, "TICK "+utoa(tick))
}

// drawProgress paints a horizontal bar just above the tick line: a secondary
// border around a paper track, filled from the left with ink to pct%.
func drawProgress(pix []byte, stride, w, h, pct int) {
	bw := w - progressLeft - progressRight
	if bw < 2*progressBorder+2 {
		return
	}
	y := h - 70 - progressGap - progressHeight
	inner := bw - 2*progressBorder
	fill(pix, stride, w, h, progressLeft, y, bw, progressHeight, colSecondary)
	fill(pix, stride, w, h, progressLeft+progressBorder, y+progressBorder,
		inner, progressHeight-2*progressBorder, colBackground)
	if pct < 0 {
		return
	}
	if pct > 100 {
		pct = 100
	}
	fillW := inner * pct / 100
	if fillW > 0 {
		fill(pix, stride, w, h, progressLeft+progressBorder, y+progressBorder,
			fillW, progressHeight-2*progressBorder, colText)
	}
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
