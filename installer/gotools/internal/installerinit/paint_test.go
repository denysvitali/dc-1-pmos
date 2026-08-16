package installerinit

import (
	"encoding/binary"
	"testing"
)

func TestProgressPct(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		wantPct int
		wantOK  bool
	}{
		{"absent", "no progress here", 0, false},
		{"empty", "", 0, false},
		{"simple", "PROGRESS 42\n", 42, true},
		{"last wins", "PROGRESS 10\nPROGRESS 90\n", 90, true},
		{"last valid wins", "PROGRESS 10\nPROGRESS oops\nPROGRESS 60\n", 60, true},
		{"trailing invalid ignored", "PROGRESS 10\nPROGRESS abc\n", 10, true},
		{"non-numeric", "PROGRESS abc\n", 0, false},
		{"no value", "PROGRESS\n", 0, false},
		{"trailing junk", "PROGRESS 12x\n", 0, false},
		{"clamp high", "PROGRESS 150\n", 100, true},
		{"negative rejected", "PROGRESS -5\n", 0, false},
		{"extra spaces trimmed", "PROGRESS   7\n", 7, true},
		{"mixed with text", "DOWNLOADING\nPROGRESS 33\n42 MiB\n", 33, true},
	}
	for _, tc := range cases {
		got, ok := ProgressPct(tc.in)
		if got != tc.wantPct || ok != tc.wantOK {
			t.Errorf("%s: ProgressPct(%q) = (%d, %v), want (%d, %v)",
				tc.name, tc.in, got, ok, tc.wantPct, tc.wantOK)
		}
	}
}

func TestStatusLinesSkipsProgressLines(t *testing.T) {
	got := StatusLines("DOWNLOADING rootfs\nPROGRESS 42\nVERIFYING\n")
	want := []string{"DOWNLOADING rootfs", "VERIFYING"}
	if len(got) != len(want) {
		t.Fatalf("StatusLines = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("StatusLines = %v, want %v", got, want)
		}
	}
}

func pixelAt(pix []byte, stride, x, y int) uint32 {
	return binary.LittleEndian.Uint32(pix[y*stride+x*4:])
}

func TestPaintProgressBarFillsWhenPresent(t *testing.T) {
	const w, h = 1200, 1600
	stride := w * 4
	pix := make([]byte, stride*h)
	PaintStatus(pix, stride, w, h, []string{"WRITING"}, 0, 50)

	barY := h - 70 - progressGap - progressHeight
	rowY := barY + progressHeight/2

	// The left half is ink, the right half is the paper track interior.
	if c := pixelAt(pix, stride, progressLeft+progressBorder+10, rowY); c != colText {
		t.Fatalf("filled bar pixel = %#x, want ink %#x", c, colText)
	}
	if c := pixelAt(pix, stride, progressLeft+(w-progressLeft-progressRight)/2+100, rowY); c != colBackground {
		t.Fatalf("unfilled bar pixel = %#x, want paper %#x", c, colBackground)
	}
}

func TestPaintProgressBarEmptyWhenAbsent(t *testing.T) {
	const w, h = 1200, 1600
	stride := w * 4
	pix := make([]byte, stride*h)
	PaintStatus(pix, stride, w, h, []string{"WRITING"}, 0, -1)

	barY := h - 70 - progressGap - progressHeight
	rowY := barY + progressHeight/2
	for x := progressLeft + progressBorder; x < w-progressRight-progressBorder; x++ {
		if c := pixelAt(pix, stride, x, rowY); c == colText {
			t.Fatalf("bar filled at x=%d with no percentage present", x)
		}
	}
}
