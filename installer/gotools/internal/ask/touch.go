package ask

// evdev touchscreen input. The device is the kernel's own ILITEK driver
// (CONFIG_TOUCHSCREEN_ILITEK=y, CONFIG_INPUT_EVDEV=y) -- no libinput, no
// udevd, nothing that has to come up before first boot.

import (
	"errors"
	"fmt"
	"io"
	"os"
)

// linux/input-event-codes.h, only what this tool looks at.
const (
	evSyn = 0x00
	evKey = 0x01
	evAbs = 0x03

	absX = 0x00
	absY = 0x01

	absMTPositionX  = 0x35
	absMTPositionY  = 0x36
	absMTTrackingID = 0x39
	absMax          = 0x3f

	btnTouch = 0x14a
)

// touchState is the tap detector, split out from the file so the offline
// tests can drive it with synthetic events.
//
// This is deliberately NOT a full multitouch implementation, and it is the C
// tool's behaviour unchanged. ABS_MT_SLOT is ignored: the last reported
// ABS_MT_POSITION_{X,Y} wins whichever contact it belonged to, because the
// only question ever asked is "where did the finger come up". Both ways a
// contact can end are honoured -- ABS_MT_TRACKING_ID == -1 (type B) and
// BTN_TOUCH 0 -- since a panel may report either or both, and the decision is
// taken only at EV_SYN, where the position and the release are known to
// belong to the same frame.
type touchState struct {
	x, y    int
	down    bool
	wasDown bool
}

// feed applies one event and reports whether a complete tap (down, then up)
// just finished; x/y then hold the release position in raw device units.
func (t *touchState) feed(typ, code uint16, value int32) bool {
	switch typ {
	case evAbs:
		switch code {
		case absMTPositionX, absX:
			t.x = int(value)
		case absMTPositionY, absY:
			t.y = int(value)
		case absMTTrackingID:
			t.down = value >= 0
		}
	case evKey:
		if code == btnTouch {
			t.down = value != 0
		}
	case evSyn:
		if t.wasDown && !t.down {
			// C re-read was_down from the device state on the next call
			// into touch_tap; latching it here is the same thing.
			t.wasDown = t.down
			return true
		}
		t.wasDown = t.down
	}
	return false
}

// decodeEvent pulls type, code and value out of one struct input_event. The
// leading struct timeval is skipped: the tool never looks at the timestamp.
func decodeEvent(b []byte) (typ, code uint16, value int32) {
	return uint16(b[timevalSize]) | uint16(b[timevalSize+1])<<8,
		uint16(b[timevalSize+2]) | uint16(b[timevalSize+3])<<8,
		int32(uint32(b[timevalSize+4]) | uint32(b[timevalSize+5])<<8 |
			uint32(b[timevalSize+6])<<16 | uint32(b[timevalSize+7])<<24)
}

// touch is an open touchscreen: the event file plus the axis ranges needed to
// scale a raw position onto the panel.
type touch struct {
	f                      *os.File
	minX, maxX, minY, maxY int
	st                     touchState
	buf                    []byte
}

func hasBit(bits []byte, bit int) bool {
	return bits[bit/8]>>(bit%8)&1 == 1
}

// openTouch takes the first /dev/input/event* that reports absolute
// positions. Nothing here matches on a device name: the installer runs before
// any udev rules exist, and the ILITEK node has landed on different event
// numbers across boots. DC1_INPUT names one device instead (tests).
func openTouch() (*touch, error) {
	if dev := os.Getenv("DC1_INPUT"); dev != "" {
		return openTouchDev(dev)
	}
	for i := 0; i < 32; i++ {
		t, err := openTouchDev(fmt.Sprintf("/dev/input/event%d", i))
		if err == nil {
			return t, nil
		}
	}
	return nil, errors.New("no absolute-position input device")
}

func openTouchDev(path string) (*touch, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	bits := make([]byte, (absMax+8)/8)
	if err := ioctl(f.Fd(), eviocgbit(evAbs, len(bits)), bits); err != nil {
		f.Close()
		return nil, err
	}
	ax, ay := -1, -1
	switch {
	case hasBit(bits, absMTPositionX) && hasBit(bits, absMTPositionY):
		ax, ay = absMTPositionX, absMTPositionY
	case hasBit(bits, absX) && hasBit(bits, absY):
		ax, ay = absX, absY
	default:
		f.Close()
		return nil, fmt.Errorf("%s reports no position axes", path)
	}
	minX, maxX, err := absRange(f, ax)
	if err != nil {
		f.Close()
		return nil, err
	}
	minY, maxY, err := absRange(f, ay)
	if err != nil {
		f.Close()
		return nil, err
	}
	return &touch{
		f:    f,
		minX: minX, maxX: maxX, minY: minY, maxY: maxY,
		buf: make([]byte, eventSize),
	}, nil
}

// absRange reads one axis' range. A degenerate maximum is widened to
// minimum+1 so the scaling below can never divide by zero.
func absRange(f *os.File, axis int) (int, int, error) {
	info := make([]byte, absinfoSize)
	if err := ioctl(f.Fd(), eviocgabs(axis), info); err != nil {
		return 0, 0, err
	}
	lo := int(int32(le32(info[4:]))) // struct input_absinfo.minimum
	hi := int(int32(le32(info[8:]))) // .maximum
	if hi <= lo {
		hi = lo + 1
	}
	return lo, hi, nil
}

func le32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}

func (t *touch) close() { t.f.Close() }

// tap blocks until a complete tap and returns the release position scaled to
// screen coordinates: a straight linear scale per axis, no swap and no
// inversion, i.e. the touchscreen is assumed to be oriented like the
// framebuffer. [inferred: carried over from src/ask.c, which is the version
// that was used on the device]
func (t *touch) tap(w, h int) (int, int, error) {
	for {
		if _, err := io.ReadFull(t.f, t.buf); err != nil {
			return 0, 0, err
		}
		if !t.st.feed(decodeEvent(t.buf)) {
			continue
		}
		x := (t.st.x - t.minX) * w / (t.maxX - t.minX)
		y := (t.st.y - t.minY) * h / (t.maxY - t.minY)
		return x, y, nil
	}
}
