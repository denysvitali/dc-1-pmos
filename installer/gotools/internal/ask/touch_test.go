package ask

import (
	"os"
	"path/filepath"
	"testing"
)

// event encodes one struct input_event the way the kernel writes it.
func event(typ, code uint16, value int32) []byte {
	b := make([]byte, eventSize)
	b[timevalSize] = byte(typ)
	b[timevalSize+1] = byte(typ >> 8)
	b[timevalSize+2] = byte(code)
	b[timevalSize+3] = byte(code >> 8)
	v := uint32(value)
	b[timevalSize+4] = byte(v)
	b[timevalSize+5] = byte(v >> 8)
	b[timevalSize+6] = byte(v >> 16)
	b[timevalSize+7] = byte(v >> 24)
	return b
}

func TestDecodeEvent(t *testing.T) {
	if eventSize != 24 {
		t.Logf("struct input_event is %d bytes on this GOARCH", eventSize)
	}
	cases := []struct {
		typ, code uint16
		value     int32
	}{
		{evAbs, absMTPositionX, 1234},
		{evAbs, absMTTrackingID, -1}, // the release, and the sign matters
		{evKey, btnTouch, 1},
		{evSyn, 0, 0},
		{evAbs, absY, 0x7fffffff},
	}
	for _, c := range cases {
		typ, code, value := decodeEvent(event(c.typ, c.code, c.value))
		if typ != c.typ || code != c.code || value != c.value {
			t.Errorf("decodeEvent(%d,%d,%d) = %d,%d,%d",
				c.typ, c.code, c.value, typ, code, value)
		}
	}
}

// The tap detector, driven with the frames a panel actually emits.
func TestTouchStateFeed(t *testing.T) {
	type ev struct {
		typ, code uint16
		value     int32
	}
	cases := []struct {
		name   string
		frames []ev
		taps   int
		x, y   int
	}{
		{
			name: "type B down then up",
			frames: []ev{
				{evAbs, absMTTrackingID, 7},
				{evAbs, absMTPositionX, 100},
				{evAbs, absMTPositionY, 200},
				{evSyn, 0, 0},
				{evAbs, absMTTrackingID, -1},
				{evSyn, 0, 0},
			},
			taps: 1, x: 100, y: 200,
		},
		{
			name: "BTN_TOUCH only, single-touch panel",
			frames: []ev{
				{evKey, btnTouch, 1},
				{evAbs, absX, 10},
				{evAbs, absY, 20},
				{evSyn, 0, 0},
				{evKey, btnTouch, 0},
				{evSyn, 0, 0},
			},
			taps: 1, x: 10, y: 20,
		},
		{
			name: "the last position before the release wins",
			frames: []ev{
				{evAbs, absMTTrackingID, 1},
				{evAbs, absMTPositionX, 100},
				{evAbs, absMTPositionY, 100},
				{evSyn, 0, 0},
				{evAbs, absMTPositionX, 300},
				{evAbs, absMTPositionY, 400},
				{evSyn, 0, 0},
				{evAbs, absMTTrackingID, -1},
				{evSyn, 0, 0},
			},
			taps: 1, x: 300, y: 400,
		},
		{
			name: "a move with no release is not a tap",
			frames: []ev{
				{evAbs, absMTTrackingID, 1},
				{evAbs, absMTPositionX, 5},
				{evSyn, 0, 0},
				{evAbs, absMTPositionX, 6},
				{evSyn, 0, 0},
			},
			taps: 0,
		},
		{
			name: "position without a SYN does not fire",
			frames: []ev{
				{evAbs, absMTTrackingID, 1},
				{evSyn, 0, 0},
				{evAbs, absMTTrackingID, -1},
			},
			taps: 0,
		},
		{
			name: "two taps in a row",
			frames: []ev{
				{evAbs, absMTTrackingID, 1},
				{evAbs, absMTPositionX, 1},
				{evSyn, 0, 0},
				{evAbs, absMTTrackingID, -1},
				{evSyn, 0, 0},
				{evAbs, absMTTrackingID, 2},
				{evAbs, absMTPositionX, 2},
				{evSyn, 0, 0},
				{evAbs, absMTTrackingID, -1},
				{evSyn, 0, 0},
			},
			taps: 2, x: 2,
		},
		{
			// The tool starts listening whenever tui.sh asks a question,
			// which can be mid-contact: a release with no down before it
			// must not answer the new question.
			name: "release we never saw the start of",
			frames: []ev{
				{evAbs, absMTTrackingID, -1},
				{evSyn, 0, 0},
			},
			taps: 0,
		},
		{
			name: "an unrelated axis is ignored",
			frames: []ev{
				{evAbs, absMTTrackingID, 1},
				{evAbs, absMTPositionX, 9},
				{evAbs, absMTPositionY, 9},
				{evAbs, 0x18, 42}, // ABS_PRESSURE
				{evSyn, 0, 0},
				{evAbs, absMTTrackingID, -1},
				{evSyn, 0, 0},
			},
			taps: 1, x: 9, y: 9,
		},
	}

	for _, c := range cases {
		var st touchState
		taps := 0
		for _, e := range c.frames {
			if st.feed(e.typ, e.code, e.value) {
				taps++
			}
		}
		if taps != c.taps {
			t.Errorf("%s: %d taps, want %d", c.name, taps, c.taps)
			continue
		}
		if c.taps > 0 && (st.x != c.x || st.y != c.y) {
			t.Errorf("%s: released at %d,%d, want %d,%d", c.name, st.x, st.y, c.x, c.y)
		}
	}
}

// tap() over a file of synthetic events: the read loop and the scaling from
// raw device units onto the panel. raw is physical-aligned, logical == physical,
// so this is a straight linear scale (the 180 scanout rotation lives in
// internal/drm.Surface.Blit, not here).
func TestTapScaling(t *testing.T) {
	var raw []byte
	for _, e := range [][]byte{
		event(evAbs, absMTTrackingID, 0),
		event(evAbs, absMTPositionX, 2160), // half of a 0..4320 axis
		event(evAbs, absMTPositionY, 1440), // a quarter of 0..5760
		event(evSyn, 0, 0),
		event(evAbs, absMTTrackingID, -1),
		event(evSyn, 0, 0),
	} {
		raw = append(raw, e...)
	}
	path := filepath.Join(t.TempDir(), "events")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	tc := &touch{f: f, maxX: 4320, maxY: 5760, buf: make([]byte, eventSize)}
	x, y, err := tc.tap(testW, testH)
	if err != nil {
		t.Fatalf("tap: %v", err)
	}
	// raw x = half -> 600; raw y = quarter -> 400 (straight scale).
	if x != 600 || y != 400 {
		t.Errorf("tap = %d,%d, want 600,400", x, y)
	}

	// Out of events: the caller must see the error, not a phantom tap at
	// the last position.
	if _, _, err := tc.tap(testW, testH); err == nil {
		t.Error("tap after EOF returned no error")
	}
}

func TestHasBit(t *testing.T) {
	bits := make([]byte, (absMax+8)/8)
	if len(bits) != 8 {
		t.Fatalf("abs bitmap is %d bytes, want 8", len(bits))
	}
	bits[absMTPositionX/8] |= 1 << (absMTPositionX % 8)
	if !hasBit(bits, absMTPositionX) {
		t.Error("hasBit missed the bit it was given")
	}
	if hasBit(bits, absMTPositionY) || hasBit(bits, absX) {
		t.Error("hasBit reported an unset bit")
	}
}
