package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

func init() {
	register(40, "input", "touch, pen, buttons, hall switch (capabilities; -interactive for events)", checkInput)
	register(45, "sensors", "accelerometer, ADC, I2C inventory and safety assertions", checkSensors)
}

const (
	evSyn                     = 0
	evKey                     = 1
	evAbs                     = 3
	evSW                      = 5
	synReport                 = 0
	synDropped                = 3
	absX, absY, absPressure   = 0, 1, 24
	absMTSlot                 = 47
	absMTX, absMTY, absMTID   = 53, 54, 57
	btnToolPen, btnToolRubber = 0x140, 0x141
	btnTouch, btnStylus       = 0x14a, 0x14b
	keyVolDown, keyVolUp      = 114, 115
	keyPower                  = 116
	keyProg1, keyProg2        = 148, 149
)

var boardInputNames = []string{"ilitek_ts", "Wacom I2C Digitizer", "mtk-pmic-keys", "mt6779-keypad", "hall-switch"}

type inputDev struct {
	name    string
	sys     string
	event   string
	problem string
	absMax  map[int][2]int32
}

func inputDevices(c *Ctx) map[string]*inputDev {
	m := map[string]*inputDev{}
	for _, s := range c.glob("/sys/class/input/input[0-9]*") {
		name, err := c.read(s + "/name")
		if err != nil || name == "" {
			continue
		}
		d := &inputDev{name: name, sys: s}
		if ev := c.glob(s + "/event[0-9]*"); len(ev) == 1 {
			base := filepath.Base(ev[0])
			if _, err := strconv.ParseUint(strings.TrimPrefix(base, "event"), 10, 32); err == nil {
				d.event = "/dev/input/" + base
			}
		}
		if previous := m[name]; previous != nil {
			previous.problem = "multiple input devices have this board device name; refusing ambiguous selection"
			continue
		}
		m[name] = d
	}
	return m
}

// Linux's supported 64-bit targets expose most-significant-first hex words.
func bit(bitmap string, n int) bool {
	if n < 0 {
		return false
	}
	w := strings.Fields(bitmap)
	i := len(w) - 1 - n/64
	if i < 0 || i >= len(w) {
		return false
	}
	v, err := strconv.ParseUint(w[i], 16, 64)
	return err == nil && v>>(uint(n)%64)&1 == 1
}

func inputCaps(c *Ctx, d *inputDev, kind string) (string, error) {
	s, err := c.read(d.sys + "/capabilities/" + kind)
	if err != nil {
		return "", err
	}
	if s == "" {
		return "", fmt.Errorf("empty %s capabilities", kind)
	}
	for _, w := range strings.Fields(s) {
		if _, err := strconv.ParseUint(w, 16, 64); err != nil {
			return "", fmt.Errorf("malformed %s capabilities: %w", kind, err)
		}
	}
	return s, nil
}

func ioctl(fd uintptr, req uintptr, arg unsafe.Pointer) error {
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, req, uintptr(arg)); e != 0 {
		return e
	}
	return nil
}

// EVIOCGABS reads value, minimum, maximum, fuzz, flat and resolution.
func absInfo(f *os.File, axis int) (min, max, res int32, err error) {
	var a [6]int32
	err = ioctl(f.Fd(), uintptr(0x80184540+axis), unsafe.Pointer(&a[0]))
	return a[1], a[2], a[5], err
}

func checkInput(c *Ctx, r *Reporter) {
	devs := inputDevices(c)
	for _, name := range boardInputNames {
		d := devs[name]
		if d == nil {
			r.Fail(name, "input device absent")
			continue
		}
		if d.problem != "" {
			r.Fail(name, "%s", d.problem)
			continue
		}
		if d.event == "" {
			r.Fail(name, "no unique event node")
			continue
		}
		var kind string
		var codes []int
		switch name {
		case "ilitek_ts":
			kind, codes = "abs", []int{absMTX, absMTY, absMTSlot, absMTID}
		case "Wacom I2C Digitizer":
			kind, codes = "abs", []int{absX, absY, absPressure}
		case "mtk-pmic-keys":
			kind, codes = "key", []int{keyPower, keyVolUp}
		case "mt6779-keypad":
			kind, codes = "key", []int{keyVolDown}
		case "hall-switch":
			kind, codes = "ev", []int{evSW}
		}
		caps, err := inputCaps(c, d, kind)
		if err != nil {
			r.Fail(name, "capabilities: %v", err)
			continue
		}
		var missing []string
		for _, code := range codes {
			if !bit(caps, code) {
				missing = append(missing, fmt.Sprintf("%s:%d", kind, code))
			}
		}
		if name == "Wacom I2C Digitizer" {
			keys, err := inputCaps(c, d, "key")
			if err != nil {
				r.Fail(name, "key capabilities: %v", err)
				continue
			}
			for _, code := range []int{btnToolPen, btnToolRubber, btnTouch, btnStylus} {
				if !bit(keys, code) {
					missing = append(missing, fmt.Sprintf("key:%d", code))
				}
			}
		}
		if len(missing) > 0 {
			r.Fail(name, "missing %s (%s)", strings.Join(missing, ","), d.event)
		} else {
			r.Pass(name, "present as %s with expected capabilities; no event functionality implied", d.event)
		}
	}
	if d := devs["mt6779-keypad"]; d != nil && d.problem == "" {
		kb, err := inputCaps(c, d, "key")
		if err != nil {
			r.Fail("spare-keys", "%v", err)
		} else {
			switch {
			case bit(kb, keyProg1) && bit(kb, keyProg2):
				r.Pass("spare-keys", "kernel exposes KEY_PROG1/KEY_PROG2; physical mapping not yet tested")
			case bit(kb, 87) && bit(kb, 88):
				r.Info("spare-keys", "kernel exposes KEY_F11/F12; hwdb remap is above raw evdev, verify desktop mapping separately")
			default:
				r.Warn("spare-keys", "keypad exposes neither F11/F12 nor PROG1/PROG2")
			}
		}
	}
	axisRanges(c, r, devs)
	if !c.Interactive {
		r.Skip("events", "needs -interactive (button presses, touch, pen)")
		return
	}
	if filepath.Clean(c.Root) != "/" {
		r.Skip("events", "relocated root: device opens and ioctls disabled")
		return
	}
	interactiveInput(c, r, devs)
}

func axisRanges(c *Ctx, r *Reporter, devs map[string]*inputDev) {
	for _, spec := range []struct {
		name string
		axes []int
	}{
		{"ilitek_ts", []int{absMTX, absMTY, absMTSlot}},
		{"Wacom I2C Digitizer", []int{absX, absY, absPressure}},
	} {
		d := devs[spec.name]
		if d == nil || d.event == "" || d.problem != "" {
			continue
		}
		if filepath.Clean(c.Root) != "/" {
			r.Skip(spec.name+"-axes", "relocated root: device opens and ioctls disabled")
			continue
		}
		f, err := os.Open(c.path(d.event))
		if err != nil {
			r.Skip(spec.name+"-axes", "%s", permHint(err))
			continue
		}
		d.absMax = map[int][2]int32{}
		var parts []string
		valid := true
		for _, a := range spec.axes {
			mn, mx, res, err := absInfo(f, a)
			if err != nil {
				r.Fail(spec.name+"-axes", "axis %d: %v", a, err)
				valid = false
				continue
			}
			if mx <= mn || res < 0 || (a == absMTSlot && mn != 0) {
				r.Fail(spec.name+"-axes", "axis %d has invalid range %d..%d or resolution %d", a, mn, mx, res)
				valid = false
				continue
			}
			if spec.name == "Wacom I2C Digitizer" && (a == absX || a == absY) && res == 0 {
				r.Fail(spec.name+"-axes", "axis %d has zero resolution; libinput requires tablet resolution", a)
				valid = false
			}
			d.absMax[a] = [2]int32{mn, mx}
			parts = append(parts, fmt.Sprintf("axis %d: %d..%d res %d", a, mn, mx, res))
		}
		if err := f.Close(); err != nil {
			r.Fail(spec.name+"-axes", "close: %v", err)
			valid = false
		}
		if valid {
			r.Pass(spec.name+"-axes", "%s; advertised ranges only", strings.Join(parts, "; "))
		}
	}
}

type event struct {
	dev       string
	typ, code uint16
	value     int32
}

type session struct {
	ch      chan event
	errCh   chan error
	fds     []int
	ctx     context.Context
	cancel  context.CancelFunc
	wg      sync.WaitGroup
	once    sync.Once
	mu      sync.Mutex
	failure error
}

func newInputSession(parent context.Context) *session {
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithCancel(parent)
	return &session{ch: make(chan event, 4096), errCh: make(chan error, 1), ctx: ctx, cancel: cancel}
}

func openSession(c *Ctx, devs map[string]*inputDev, grab bool) (*session, error) {
	if filepath.Clean(c.Root) != "/" {
		return nil, errors.New("relocated root: device opens and ioctls disabled")
	}
	s := newInputSession(c.Cancel)
	// Only the five built-in board devices are opened/grabbed, never USB keyboards/mice.
	for _, name := range boardInputNames {
		if err := s.sessionError(); err != nil {
			s.close()
			return nil, err
		}
		d := devs[name]
		if d == nil {
			continue
		}
		if d.problem != "" {
			s.close()
			return nil, errors.New(d.problem)
		}
		if d.event == "" {
			s.close()
			return nil, fmt.Errorf("%s: no event node", name)
		}
		fd, err := syscall.Open(c.path(d.event), syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
		if err != nil {
			s.close()
			return nil, fmt.Errorf("open %s: %w", d.event, err)
		}
		s.fds = append(s.fds, fd)
		var st syscall.Stat_t
		if err = syscall.Fstat(fd, &st); err != nil || st.Mode&syscall.S_IFMT != syscall.S_IFCHR {
			s.close()
			return nil, fmt.Errorf("%s is not a readable character device (stat error: %v)", d.event, err)
		}
		if grab {
			one := int32(1)
			if err := ioctl(uintptr(fd), 0x40044590, unsafe.Pointer(&one)); err != nil {
				s.close()
				return nil, fmt.Errorf("grab %s: %w", d.event, err)
			}
		}
		// Keep the raw nonblocking descriptor: os.File.Fd/Read can switch it to blocking.
		s.wg.Add(1)
		go s.readEvents(name, fd)
	}
	if len(s.fds) == 0 {
		s.close()
		return nil, errors.New("no board input event nodes")
	}
	return s, nil
}

func (s *session) fail(err error) {
	s.mu.Lock()
	if s.failure == nil {
		s.failure = err
		select {
		case s.errCh <- err:
		default:
		}
	}
	s.mu.Unlock()
	s.cancel()
}

func (s *session) sessionError() error {
	s.mu.Lock()
	err := s.failure
	s.mu.Unlock()
	if err != nil {
		return err
	}
	return s.ctx.Err()
}

func (s *session) readEvents(name string, fd int) {
	defer s.wg.Done()
	buf := make([]byte, 24*64) // linux/arm64 and linux/amd64 input_event ABI
	tick := time.NewTicker(5 * time.Millisecond)
	defer tick.Stop()
	for {
		if s.ctx.Err() != nil {
			return
		}
		n, err := syscall.Read(fd, buf)
		if err == syscall.EINTR {
			continue
		}
		if err == syscall.EAGAIN || err == syscall.EWOULDBLOCK {
			select {
			case <-tick.C:
				continue
			case <-s.ctx.Done():
				return
			}
		}
		if err != nil {
			s.fail(fmt.Errorf("%s event read: %w", name, err))
			return
		}
		if n == 0 {
			s.fail(fmt.Errorf("%s event stream ended", name))
			return
		}
		if n%24 != 0 {
			s.fail(fmt.Errorf("%s truncated input_event (%d bytes)", name, n))
			return
		}
		// Validate the entire batch before making any of its events observable.
		for i := 0; i < n; i += 24 {
			e := decodeEvent(name, buf[i:i+24])
			if e.typ == evSyn && e.code == synDropped {
				s.fail(fmt.Errorf("%s SYN_DROPPED: lost events invalidate this input session", name))
				return
			}
		}
		for i := 0; i < n; i += 24 {
			e := decodeEvent(name, buf[i:i+24])
			if s.ctx.Err() != nil {
				return
			}
			select {
			case s.ch <- e:
			default:
				s.fail(fmt.Errorf("%s event queue overflow: lost events invalidate this input session", name))
				return
			}
		}
	}
}

func decodeEvent(name string, buf []byte) event {
	return event{name, uint16(buf[16]) | uint16(buf[17])<<8, uint16(buf[18]) | uint16(buf[19])<<8,
		int32(uint32(buf[20]) | uint32(buf[21])<<8 | uint32(buf[22])<<16 | uint32(buf[23])<<24)}
}

func (s *session) close() {
	s.once.Do(func() {
		s.cancel()
		// Join raw readers before closing: no cross-goroutine close or fd reuse race.
		s.wg.Wait()
		for _, fd := range s.fds {
			_ = syscall.Close(fd)
		} // close releases EVIOCGRAB
	})
}

// One absolute deadline cannot be starved by a continuous event stream.
func (s *session) until(d time.Duration, fn func(event) bool) (bool, error) {
	deadline := time.Now().Add(d)
	t := time.NewTimer(d)
	defer t.Stop()
	for {
		if err := s.sessionError(); err != nil {
			return false, err
		}
		if !time.Now().Before(deadline) {
			return false, nil
		}
		select {
		case e := <-s.ch:
			if e.typ == evSyn && e.code == synDropped {
				s.fail(fmt.Errorf("%s SYN_DROPPED", e.dev))
				return false, s.sessionError()
			}
			if fn(e) {
				return true, s.sessionError()
			}
		case err := <-s.errCh:
			return false, err
		case <-s.ctx.Done():
			return false, s.sessionError()
		case <-t.C:
			return false, s.sessionError()
		}
	}
}

func (s *session) drain() error {
	// Drain only the current bounded queue, never loop forever under fresh events.
	for n := len(s.ch); n > 0; n-- {
		if err := s.sessionError(); err != nil {
			return err
		}
		select {
		case e := <-s.ch:
			if e.typ == evSyn && e.code == synDropped {
				s.fail(fmt.Errorf("%s SYN_DROPPED", e.dev))
				return s.sessionError()
			}
		default:
			return s.sessionError()
		}
	}
	return s.sessionError()
}

func reportInputError(r *Reporter, name string, err error) {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		r.Skip(name, "input session cancelled: %v", err)
	} else {
		r.Fail(name, "input session invalid: %v", err)
	}
}

func interactiveInput(c *Ctx, r *Reporter, devs map[string]*inputDev) {
	s, err := openSession(c, devs, true)
	if err != nil {
		if errors.Is(err, os.ErrPermission) {
			r.Skip("events", "%s", permHint(err))
		} else {
			reportInputError(r, "events", err)
		}
		return
	}
	defer s.close()
	c.say("Only built-in DC-1 input devices are grabbed: GNOME will not see these presses until cleanup.")
	keys := []struct {
		name, label, dev string
		codes            []uint16
	}{
		{"power-button", "POWER button", "mtk-pmic-keys", []uint16{keyPower}},
		{"volume-up", "VOLUME UP", "mtk-pmic-keys", []uint16{keyVolUp}},
		{"volume-down", "VOLUME DOWN", "mt6779-keypad", []uint16{keyVolDown}},
		{"quick-action", "QUICK ACTION button", "mt6779-keypad", []uint16{keyProg1, 87, 88, keyProg2}},
		{"back-button", "BACK button", "mt6779-keypad", []uint16{keyProg2, 88, 87, keyProg1}},
	}
	seen := map[string]bool{}
	for _, k := range keys {
		if err := s.drain(); err != nil {
			reportInputError(r, "events", err)
			return
		}
		if devs[k.dev] == nil {
			r.Skip(k.name, "required device %s absent", k.dev)
			continue
		}
		c.say("Press the %s (20 s)...", k.label)
		var got uint16
		ok, err := s.until(20*time.Second, func(e event) bool {
			if e.dev != k.dev || e.typ != evKey || e.value != 1 {
				return false
			}
			for _, code := range k.codes {
				if e.code == code {
					got = code
					return true
				}
			}
			return false
		})
		if err != nil {
			reportInputError(r, k.name, err)
			return
		}
		id := fmt.Sprintf("%s:%d", k.dev, got)
		switch {
		case !ok:
			r.Fail(k.name, "no press event from %s within 20 s", k.dev)
		case seen[id]:
			r.Fail(k.name, "code %d on %s already reported by a different button", got, k.dev)
		default:
			seen[id] = true
			if got == k.codes[0] {
				r.Pass(k.name, "raw event code %d", got)
			} else {
				r.Warn(k.name, "raw event code %d, expected %d; hwdb can remap above evdev, verify desktop separately", got, k.codes[0])
			}
		}
	}
	touchTest(c, r, s, devs)
	if err := s.sessionError(); err != nil {
		return
	}
	penTest(c, r, s, devs)
	if err := s.sessionError(); err != nil {
		return
	}
	if devs["hall-switch"] == nil {
		r.Skip("hall-switch-event", "device absent")
		return
	}
	// Avoid a blocking confirmation read while board devices remain grabbed.
	c.say("Hall switch (15 s): toggle with the cover/magnet if available; otherwise this check will be skipped.")
	if err := s.drain(); err != nil {
		reportInputError(r, "hall-switch-event", err)
		return
	}
	ok, err := s.until(15*time.Second, func(e event) bool { return e.dev == "hall-switch" && e.typ == evSW && (e.value == 0 || e.value == 1) })
	if err != nil {
		reportInputError(r, "hall-switch-event", err)
	} else if ok {
		r.Pass("hall-switch-event", "switch transition received; cover polarity not established")
	} else {
		r.Skip("hall-switch-event", "no operator switch transition observed")
	}
}

// Ranges are cached from checked EVIOCGABS; never reopen a grabbed node.
func axisSpan(c *Ctx, d *inputDev, axis int) (int32, int32, error) {
	if filepath.Clean(c.Root) != "/" {
		return 0, 0, errors.New("relocated root: device ioctls disabled")
	}
	v, ok := d.absMax[axis]
	if !ok || v[1] <= v[0] {
		return 0, 0, fmt.Errorf("%s axis %d has no validated range", d.name, axis)
	}
	return v[0], v[1], nil
}

type axisCoverage struct {
	lo, hi, min, max int32
	seen, invalid    bool
}

func (a *axisCoverage) observe(v int32) {
	if v < a.lo || v > a.hi {
		a.invalid = true
		return
	}
	if !a.seen {
		a.min, a.max, a.seen = v, v, true
		return
	}
	a.min, a.max = min(a.min, v), max(a.max, v)
}

func (a axisCoverage) fraction() (float64, bool) {
	if !a.seen || a.invalid || a.hi <= a.lo {
		return 0, false
	}
	return float64(int64(a.max)-int64(a.min)) / float64(int64(a.hi)-int64(a.lo)), true
}

func reportCoverage(r *Reporter, name string, x, y axisCoverage) bool {
	cx, okX := x.fraction()
	cy, okY := y.fraction()
	if !okX || !okY {
		r.Fail(name, "need both X and Y samples within validated bounds (X seen=%t invalid=%t; Y seen=%t invalid=%t)", x.seen, x.invalid, y.seen, y.invalid)
		return false
	}
	msg := fmt.Sprintf("X %d..%d of %d..%d (%.0f%%), Y %d..%d of %d..%d (%.0f%%)", x.min, x.max, x.lo, x.hi, cx*100, y.min, y.max, y.lo, y.hi, cy*100)
	if cx >= .97 && cy >= .97 {
		r.Pass(name, "%s; axis reach, not visual alignment", msg)
	} else {
		r.Warn(name, "%s; edges not fully swept", msg)
	}
	return true
}

// touchTracker starts with no trustworthy slot/contact state after queue draining.
// A BTN_TOUCH=0 state at SYN_REPORT establishes a neutral boundary. The first
// unchanged slot may never emit ABS_MT_SLOT; its IDs are deliberately ignored
// rather than guessed as slot zero, so this is a conservative contact lower bound.
// Sampling EVIOCGMTSLOTS separately would not provide an atomic snapshot with
// the asynchronously queued events, so it is not used to claim exact counts.
type touchTracker struct {
	minSlot, maxSlot                                  int32
	x, y                                              axisCoverage
	active                                            map[int32]int32
	slot                                              int32
	slotKnown, synced, touchKnown, touchDown, invalid bool
	peak, unknownIDs                                  int
}

func (t *touchTracker) observe(e event) {
	if e.dev != "ilitek_ts" {
		return
	}
	if e.typ == evKey && e.code == btnTouch {
		if e.value != 0 && e.value != 1 {
			t.invalid = true
			return
		}
		t.touchKnown, t.touchDown = true, e.value == 1
		return
	}
	if e.typ == evSyn && e.code == synReport {
		if t.touchKnown && !t.touchDown {
			t.synced = true
			t.active = map[int32]int32{}
			t.slotKnown = false
			return
		}
		if t.synced && t.touchKnown && t.touchDown {
			// Only completed frames establish simultaneous contacts. Intermediate
			// add/remove ordering within a frame must never inflate the peak.
			seen := map[int32]bool{}
			for _, id := range t.active {
				if seen[id] {
					t.invalid = true
					return
				}
				seen[id] = true
			}
			t.peak = max(t.peak, len(t.active))
		}
		return
	}
	if !t.synced || e.typ != evAbs {
		return
	}
	switch e.code {
	case absMTSlot:
		t.slot = e.value
		t.slotKnown = e.value >= t.minSlot && e.value <= t.maxSlot
		t.invalid = t.invalid || !t.slotKnown
	case absMTID:
		if e.value < -1 {
			t.invalid = true
			return
		}
		if !t.slotKnown {
			t.unknownIDs++
			return
		}
		if e.value == -1 {
			delete(t.active, t.slot)
		} else {
			t.active[t.slot] = e.value
		}
	case absMTX:
		t.x.observe(e.value)
	case absMTY:
		t.y.observe(e.value)
	}
}

func touchTest(c *Ctx, r *Reporter, s *session, devs map[string]*inputDev) {
	d := devs["ilitek_ts"]
	if d == nil {
		r.Skip("touch-events", "device absent")
		return
	}
	mnX, mxX, ex := axisSpan(c, d, absMTX)
	mnY, mxY, ey := axisSpan(c, d, absMTY)
	mnS, mxS, es := axisSpan(c, d, absMTSlot)
	if ex != nil || ey != nil || es != nil {
		r.Fail("touch-events", "axis bounds unavailable: X=%v Y=%v slot=%v", ex, ey, es)
		return
	}
	if err := s.drain(); err != nil {
		reportInputError(r, "touch-events", err)
		return
	}
	c.say("Touch (15 s): first touch and lift ALL fingers to establish a neutral frame; then sweep edges/corners and put 5+ fingers down together.")
	tracker := touchTracker{minSlot: mnS, maxSlot: mxS,
		x: axisCoverage{lo: mnX, hi: mxX}, y: axisCoverage{lo: mnY, hi: mxY}}
	_, err := s.until(15*time.Second, func(e event) bool {
		tracker.observe(e)
		return false
	})
	if err != nil {
		reportInputError(r, "touch-events", err)
		return
	}
	if tracker.invalid {
		r.Fail("touch-events", "out-of-bounds multitouch slot, invalid/duplicate tracking ID or BTN_TOUCH value")
		return
	}
	if !tracker.synced {
		r.Skip("touch-events", "no complete SYN_REPORT with BTN_TOUCH=0; initial contact/slot state remains unknown")
		return
	}
	r.Info("touch-contact-count", "contact lower bound from complete frames after neutral release; unchanged first slot may be omitted (%d unknown-slot IDs skipped)", tracker.unknownIDs)
	if !reportCoverage(r, "touch-coverage", tracker.x, tracker.y) {
		return
	}
	if tracker.peak >= 5 {
		r.Pass("touch-multitouch", "at least %d simultaneous contacts in a complete frame", tracker.peak)
	} else {
		r.Warn("touch-multitouch", "observed lower-bound peak %d (asked for 5+); unchanged first slot may be omitted", tracker.peak)
	}
}

// Draining leaves all key states unknown. Only explicit updates establish their
// states; contact evidence is committed at SYN_REPORT, never across unrelated
// pen/eraser frames or after a release in the same frame.
type penTipTracker struct {
	penKnown, touchKnown bool
	penDown, touchDown   bool
	observed             bool
}

func (p *penTipTracker) observe(e event) {
	if e.dev != "Wacom I2C Digitizer" {
		return
	}
	if e.typ == evKey && (e.value == 0 || e.value == 1) {
		switch e.code {
		case btnToolPen:
			p.penKnown, p.penDown = true, e.value == 1
		case btnTouch:
			p.touchKnown, p.touchDown = true, e.value == 1
		}
	}
	if e.typ == evSyn && e.code == synReport && p.penKnown && p.touchKnown && p.penDown && p.touchDown {
		p.observed = true
	}
}

func penTest(c *Ctx, r *Reporter, s *session, devs map[string]*inputDev) {
	d := devs["Wacom I2C Digitizer"]
	if d == nil {
		r.Skip("pen-events", "device absent")
		return
	}
	mnX, mxX, ex := axisSpan(c, d, absX)
	mnY, mxY, ey := axisSpan(c, d, absY)
	mnP, mxP, ep := axisSpan(c, d, absPressure)
	if ex != nil || ey != nil || ep != nil {
		r.Fail("pen-events", "axis bounds unavailable: X=%v Y=%v pressure=%v", ex, ey, ep)
		return
	}
	if err := s.drain(); err != nil {
		reportInputError(r, "pen-events", err)
		return
	}
	c.say("Pen (25 s): sweep edges/corners with tip, press hard once, press barrel button, then flip to eraser and back while hovering.")
	x, y := axisCoverage{lo: mnX, hi: mxX}, axisCoverage{lo: mnY, hi: mxY}
	var pmax int32
	var pressureSeen, pressureInvalid, barrel, eraser, flips bool
	var tip penTipTracker
	last := uint16(0)
	_, err := s.until(25*time.Second, func(e event) bool {
		if e.dev != "Wacom I2C Digitizer" {
			return false
		}
		tip.observe(e)
		switch {
		case e.typ == evAbs && e.code == absX:
			x.observe(e.value)
		case e.typ == evAbs && e.code == absY:
			y.observe(e.value)
		case e.typ == evAbs && e.code == absPressure:
			pressureSeen = true
			if e.value < mnP || e.value > mxP {
				pressureInvalid = true
			} else {
				pmax = max(pmax, e.value)
			}
		case e.typ == evKey && e.code == btnStylus && e.value == 1:
			barrel = true
		case e.typ == evKey && (e.code == btnToolPen || e.code == btnToolRubber) && e.value == 1:
			if e.code == btnToolRubber {
				eraser = true
			}
			flips = flips || (last != 0 && last != e.code)
			last = e.code
		}
		return false
	})
	if err != nil {
		reportInputError(r, "pen-events", err)
		return
	}
	if !reportCoverage(r, "pen-coverage", x, y) {
		return
	}
	r.Info("pen-alignment", "digitizer axis reach is not ink-under-nib alignment; verify in a drawing app")
	check := func(name string, ok bool, detail string) {
		if ok {
			r.Pass(name, "%s", detail)
		} else {
			r.Fail(name, "not observed")
		}
	}
	check("pen-tip", tip.observed, "BTN_TOOL_PEN=1 and BTN_TOUCH=1 in a complete frame")
	switch {
	case !pressureSeen || pressureInvalid:
		r.Fail("pen-pressure", "missing pressure samples or samples outside %d..%d", mnP, mxP)
	case int64(pmax)-int64(mnP) > (int64(mxP)-int64(mnP))/2:
		r.Pass("pen-pressure", "peak %d of %d..%d", pmax, mnP, mxP)
	default:
		r.Warn("pen-pressure", "peak %d of %d..%d (press harder to test upper range)", pmax, mnP, mxP)
	}
	check("pen-barrel", barrel, "barrel button observed")
	check("pen-eraser", eraser, "eraser tool observed")
	check("pen-flip", flips, "tool changed between pen and eraser; hover continuity not established")
}
