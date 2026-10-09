package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func ipFixture(t *testing.T) *Ctx {
	t.Helper()
	return &Ctx{Root: t.TempDir(), Cancel: context.Background(), Out: io.Discard}
}

func ipPut(t *testing.T, c *Ctx, p, s string) {
	t.Helper()
	path := c.path(p)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(s), 0644); err != nil {
		t.Fatal(err)
	}
}

func ipHas(r *Reporter, name string, status Status) bool {
	for _, res := range r.results {
		if res.Name == name && res.Status == status {
			return true
		}
	}
	return false
}

func ipGoodPower(t *testing.T, c *Ctx) {
	t.Helper()
	for p, s := range map[string]string{
		"/sys/class/power_supply/mt6358-fg/voltage_now": "3900000",
		"/sys/class/power_supply/mt6358-fg/capacity":    "55",
		"/sys/class/power_supply/mt6358-fg/current_now": "-150000",
		"/sys/class/power_supply/mt6358-fg/status":      "Discharging",
		"/sys/class/power_supply/mt6375-charger/online": "0",
		"/sys/class/power_supply/mt6375-charger/status": "Not charging",
		"/sys/class/typec/port0/data_role":              "host [device]",
		"/sys/class/typec/port0/power_role":             "source [sink]",
		"/sys/class/typec/port0/power_operation_mode":   "default",
		"/sys/power/state":                              "freeze mem",
		"/sys/power/mem_sleep":                          "[s2idle]",
	} {
		ipPut(t, c, p, s)
	}
}

func TestPowerRequiredAttributesNeverPassOnReadError(t *testing.T) {
	cases := []struct{ p, result string }{
		{"/sys/class/power_supply/mt6358-fg/voltage_now", "fuel-gauge"},
		{"/sys/class/power_supply/mt6358-fg/capacity", "fuel-gauge"},
		{"/sys/class/power_supply/mt6358-fg/current_now", "fuel-gauge"},
		{"/sys/class/power_supply/mt6358-fg/status", "fuel-gauge"},
		{"/sys/class/power_supply/mt6375-charger/online", "charger"},
		{"/sys/class/power_supply/mt6375-charger/status", "charger"},
		{"/sys/class/typec/port0/data_role", "typec"},
		{"/sys/class/typec/port0/power_role", "typec"},
		{"/sys/class/typec/port0/power_operation_mode", "typec"},
		{"/sys/power/state", "suspend-state"},
		{"/sys/power/mem_sleep", "suspend-state"},
	}
	for _, tc := range cases {
		for _, value := range []string{"missing", "", "garbage"} {
			t.Run(tc.p+"/"+value, func(t *testing.T) {
				c := ipFixture(t)
				ipGoodPower(t, c)
				if value == "missing" {
					if err := os.Remove(c.path(tc.p)); err != nil {
						t.Fatal(err)
					}
				} else {
					ipPut(t, c, tc.p, value)
				}
				r := &Reporter{}
				checkPower(c, r)
				if ipHas(r, tc.result, Pass) {
					t.Fatalf("bad %s produced PASS: %+v", tc.p, r.results)
				}
				if !ipHas(r, tc.result, Fail) {
					t.Fatalf("bad %s not failed: %+v", tc.p, r.results)
				}
			})
		}
	}
}

func TestPowerValidFixtureAndInvalidValues(t *testing.T) {
	c := ipFixture(t)
	ipGoodPower(t, c)
	r := &Reporter{}
	checkPower(c, r)
	for _, name := range []string{"fuel-gauge", "gauge-sign", "charger", "typec", "suspend-state"} {
		if !ipHas(r, name, Pass) {
			t.Fatalf("valid %s not passed: %+v", name, r.results)
		}
	}
	for _, tc := range []struct{ p, value, name string }{
		{"/sys/class/power_supply/mt6375-charger/online", "2", "charger"},
		{"/sys/class/power_supply/mt6358-fg/capacity", "101", "fuel-gauge"},
		{"/sys/class/power_supply/mt6358-fg/voltage_now", "2999999", "fuel-gauge"},
		{"/sys/power/state", "notfreeze", "suspend-state"},
		{"/sys/power/mem_sleep", "junk [s2idle]", "suspend-state"},
		{"/sys/class/typec/port0/data_role", "junk [device]", "typec"},
	} {
		t.Run(tc.name+tc.value, func(t *testing.T) {
			c := ipFixture(t)
			ipGoodPower(t, c)
			ipPut(t, c, tc.p, tc.value)
			r := &Reporter{}
			checkPower(c, r)
			if ipHas(r, tc.name, Pass) || !ipHas(r, tc.name, Fail) {
				t.Fatalf("invalid value passed: %+v", r.results)
			}
		})
	}
}

func TestChargerSourceReadsNegotiatedCeilings(t *testing.T) {
	c := ipFixture(t)
	ipGoodPower(t, c)
	ipPut(t, c, "/sys/class/power_supply/mt6375-charger/online", "1")
	ipPut(t, c, "/sys/class/power_supply/mt6375-charger/status", "Charging")
	ipPut(t, c, "/sys/class/power_supply/tcpm-source-psy-mt6375-tcpc/voltage_max", "12000000")
	ipPut(t, c, "/sys/class/power_supply/tcpm-source-psy-mt6375-tcpc/current_max", "3000000")
	ipPut(t, c, "/sys/class/power_supply/tcpm-source-psy-mt6375-tcpc/usb_type", "C [PD]")
	r := &Reporter{}
	checkCharger(c, r, "/sys/class/power_supply/", "Charging")
	if !ipHas(r, "source-voltage_max", Info) || !ipHas(r, "source-current_max", Info) {
		t.Fatalf("negotiated ceilings unavailable: %+v", r.results)
	}
	for _, res := range r.results {
		if res.Status == Fail {
			t.Fatalf("valid source failed: %+v", res)
		}
	}
	ipPut(t, c, "/sys/class/power_supply/tcpm-source-psy-mt6375-tcpc/current_max", "broken")
	r = &Reporter{}
	checkCharger(c, r, "/sys/class/power_supply/", "Charging")
	if !ipHas(r, "source-current_max", Fail) || ipHas(r, "source-current_max", Info) {
		t.Fatalf("broken source current silently accepted: %+v", r.results)
	}
}

func TestGaugeSignUnknownOrZeroNeverPasses(t *testing.T) {
	for _, tc := range []struct{ status, current string }{{"Unknown", "1000"}, {"Full", "0"}, {"Charging", "0"}} {
		c := ipFixture(t)
		ipGoodPower(t, c)
		ipPut(t, c, "/sys/class/power_supply/mt6358-fg/status", tc.status)
		ipPut(t, c, "/sys/class/power_supply/mt6358-fg/current_now", tc.current)
		r := &Reporter{}
		checkPower(c, r)
		if ipHas(r, "gauge-sign", Pass) {
			t.Fatalf("ambiguous sign passed: %+v", r.results)
		}
	}
}

func TestRTCFixtureSkipsTickAndReadsErrors(t *testing.T) {
	c := ipFixture(t)
	for _, d := range []string{"rtc0", "rtc1"} {
		ipPut(t, c, "/sys/class/rtc/"+d+"/name", "fixture-rtc")
		ipPut(t, c, "/sys/class/rtc/"+d+"/since_epoch", "1700000000")
	}
	start := time.Now()
	r := &Reporter{}
	checkRTC(c, r)
	if time.Since(start) >= time.Second {
		t.Fatal("relocated RTC test waited for ticking")
	}
	for _, d := range []string{"rtc0", "rtc1"} {
		if ipHas(r, d, Pass) || !ipHas(r, d+"-tick", Skip) {
			t.Fatalf("fixture claims hardware RTC: %+v", r.results)
		}
	}
	ipPut(t, c, "/sys/class/rtc/rtc0/since_epoch", "broken")
	r = &Reporter{}
	checkRTC(c, r)
	if !ipHas(r, "rtc0", Fail) {
		t.Fatalf("bad RTC read ignored: %+v", r.results)
	}
}

func TestSuspendStatsRequiresBothCounters(t *testing.T) {
	c := ipFixture(t)
	ipGoodPower(t, c)
	ipPut(t, c, "/sys/power/suspend_stats/success", "4")
	r := &Reporter{}
	checkSuspend(c, r)
	if !ipHas(r, "suspend-stats", Fail) || ipHas(r, "suspend-stats", Info) {
		t.Fatalf("missing fail counter ignored: %+v", r.results)
	}
}

func TestInputRelocatedRootDisablesIOEvenWithFlags(t *testing.T) {
	c := ipFixture(t)
	c.Interactive = true
	ipPut(t, c, "/sys/class/input/input0/name", "ilitek_ts")
	ipPut(t, c, "/sys/class/input/input0/event0/fixture", "")
	ipPut(t, c, "/sys/class/input/input0/capabilities/abs", "260800000000000")
	devs := inputDevices(c)
	if _, err := openSession(c, devs, true); err == nil {
		t.Fatal("relocated session opened devices")
	}
	r := &Reporter{}
	checkInput(c, r)
	if !ipHas(r, "events", Skip) || !ipHas(r, "ilitek_ts-axes", Skip) {
		t.Fatalf("relocation skips missing: %+v", r.results)
	}
}

func TestInputSessionNeverOpensUnrelatedDevices(t *testing.T) {
	// An unrelated device points at a path that must never be opened or grabbed.
	c := &Ctx{Root: "/", Cancel: context.Background()}
	_, err := openSession(c, map[string]*inputDev{
		"USB keyboard": {name: "USB keyboard", event: "/dev/this-unrelated-device-must-not-be-opened"},
	}, true)
	if err == nil || err.Error() != "no board input event nodes" {
		t.Fatalf("unrelated input attempted: %v", err)
	}
}

func TestPowerPauseCancellationIsImmediate(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	c := &Ctx{Cancel: ctx}
	start := time.Now()
	if c.paused(2100*time.Millisecond) || time.Since(start) > time.Second {
		t.Fatal("RTC sampling wait did not respect cancellation")
	}
}

func TestInputAmbiguousBoardNameRejected(t *testing.T) {
	c := ipFixture(t)
	for _, id := range []string{"0", "1"} {
		ipPut(t, c, "/sys/class/input/input"+id+"/name", "ilitek_ts")
		ipPut(t, c, "/sys/class/input/input"+id+"/event"+id+"/fixture", "")
	}
	if d := inputDevices(c)["ilitek_ts"]; d == nil || d.problem == "" {
		t.Fatal("ambiguous device accepted")
	}
}

func TestCoverageRequiresBothAxesAndBounds(t *testing.T) {
	for _, tc := range []struct {
		name   string
		xs, ys []int32
		want   Status
	}{
		{"full", []int32{0, 100}, []int32{0, 100}, Pass},
		{"one-axis", []int32{0, 100}, nil, Fail},
		{"beyond-max", []int32{0, 100, 101}, []int32{0, 100}, Fail},
		{"below-min", []int32{-1, 100}, []int32{0, 100}, Fail},
		{"partial", []int32{20, 80}, []int32{0, 100}, Warn},
	} {
		t.Run(tc.name, func(t *testing.T) {
			x, y := axisCoverage{lo: 0, hi: 100}, axisCoverage{lo: 0, hi: 100}
			for _, v := range tc.xs {
				x.observe(v)
			}
			for _, v := range tc.ys {
				y.observe(v)
			}
			r := &Reporter{}
			reportCoverage(r, "coverage", x, y)
			if !ipHas(r, "coverage", tc.want) {
				t.Fatalf("unexpected result: %+v", r.results)
			}
		})
	}
	// Difference arithmetic must not overflow when axes span signed int32.
	a := axisCoverage{lo: -2147483648, hi: 2147483647}
	a.observe(a.lo)
	a.observe(a.hi)
	if f, ok := a.fraction(); !ok || f != 1 {
		t.Fatalf("full signed range: %f %t", f, ok)
	}
}

func ipPen(typ, code uint16, value int32) event {
	return event{dev: "Wacom I2C Digitizer", typ: typ, code: code, value: value}
}

func TestPenEraserContactThenPenHoverDoesNotProveTip(t *testing.T) {
	var p penTipTracker
	for _, e := range []event{
		ipPen(evKey, btnToolPen, 0), ipPen(evKey, btnToolRubber, 1),
		ipPen(evKey, btnTouch, 1), ipPen(evSyn, synReport, 0),
		ipPen(evKey, btnTouch, 0), ipPen(evKey, btnToolRubber, 0),
		ipPen(evKey, btnToolPen, 1), ipPen(evSyn, synReport, 0),
	} {
		p.observe(e)
	}
	if p.observed {
		t.Fatal("eraser contact then pen hover falsely proved pen tip")
	}
	p.observe(ipPen(evKey, btnTouch, 1))
	if p.observed {
		t.Fatal("uncommitted contact falsely proved tip")
	}
	p.observe(ipPen(evSyn, synReport, 0))
	if !p.observed {
		t.Fatal("real committed pen contact not recognized")
	}
}

func TestPenTipUnknownAndReleasedStatesAreConservative(t *testing.T) {
	for _, tc := range []struct {
		name   string
		events []event
	}{
		{"unknown-tool", []event{ipPen(evKey, btnTouch, 1), ipPen(evSyn, synReport, 0)}},
		{"unknown-contact", []event{ipPen(evKey, btnToolPen, 1), ipPen(evSyn, synReport, 0)}},
		{"contact-released", []event{ipPen(evKey, btnToolPen, 1), ipPen(evKey, btnTouch, 1), ipPen(evKey, btnTouch, 0), ipPen(evSyn, synReport, 0)}},
		{"tool-released", []event{ipPen(evKey, btnTouch, 1), ipPen(evKey, btnToolPen, 1), ipPen(evKey, btnToolPen, 0), ipPen(evSyn, synReport, 0)}},
		{"other-device", []event{ipTouch(evKey, btnTouch, 1), ipPen(evKey, btnToolPen, 1), ipPen(evSyn, synReport, 0)}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var p penTipTracker
			for _, e := range tc.events {
				p.observe(e)
			}
			if p.observed {
				t.Fatalf("unknown/released state proved tip: %+v", p)
			}
		})
	}
}

func ipTouch(typ, code uint16, value int32) event {
	return event{dev: "ilitek_ts", typ: typ, code: code, value: value}
}

func ipTouchTracker() *touchTracker {
	return &touchTracker{minSlot: 0, maxSlot: 9,
		x: axisCoverage{lo: 0, hi: 100}, y: axisCoverage{lo: 0, hi: 100}}
}

func ipTouchNeutral(tr *touchTracker) {
	tr.observe(ipTouch(evKey, btnTouch, 0))
	tr.observe(ipTouch(evSyn, synReport, 0))
}

func TestTouchRequiresCompleteNeutralBoundary(t *testing.T) {
	tr := ipTouchTracker()
	// Events surviving a drain are not enough to infer pre-existing contacts.
	tr.observe(ipTouch(evAbs, absMTSlot, 3))
	tr.observe(ipTouch(evAbs, absMTID, 20))
	tr.observe(ipTouch(evAbs, absMTX, 100))
	tr.observe(ipTouch(evKey, btnTouch, 1))
	tr.observe(ipTouch(evSyn, synReport, 0))
	if tr.synced || tr.peak != 0 || tr.x.seen {
		t.Fatalf("unsynchronized state accepted: %+v", tr)
	}
	tr.observe(ipTouch(evKey, btnTouch, 0))
	if tr.synced {
		t.Fatal("neutral event synchronized before SYN_REPORT")
	}
	tr.observe(ipTouch(evKey, btnTouch, 1))
	tr.observe(ipTouch(evSyn, synReport, 0))
	if tr.synced {
		t.Fatal("transient BTN_TOUCH=0 was not neutral at frame end")
	}
	ipTouchNeutral(tr)
	if !tr.synced || tr.slotKnown || len(tr.active) != 0 {
		t.Fatalf("bad neutral boundary: %+v", tr)
	}
}

func TestTouchUnknownSlotNeverCreatesGhostContact(t *testing.T) {
	tr := ipTouchTracker()
	ipTouchNeutral(tr)
	tr.observe(ipTouch(evKey, btnTouch, 1))
	// Current kernel slot may be 7, not zero; no explicit slot survived draining.
	tr.observe(ipTouch(evAbs, absMTID, 30))
	tr.observe(ipTouch(evSyn, synReport, 0))
	if tr.peak != 0 || len(tr.active) != 0 || tr.unknownIDs != 1 {
		t.Fatalf("unknown ID assigned to slot zero: %+v", tr)
	}
	tr.observe(ipTouch(evAbs, absMTSlot, 7))
	tr.observe(ipTouch(evAbs, absMTID, -1))
	tr.observe(ipTouch(evSyn, synReport, 0))
	if tr.peak != 0 || len(tr.active) != 0 {
		t.Fatalf("ghost contact survived true slot release: %+v", tr)
	}
	tr.observe(ipTouch(evAbs, absMTSlot, 4))
	tr.observe(ipTouch(evAbs, absMTID, 31))
	tr.observe(ipTouch(evSyn, synReport, 0))
	if tr.peak != 1 {
		t.Fatalf("explicit slot did not count: %+v", tr)
	}
	ipTouchNeutral(tr)
	if tr.slotKnown || len(tr.active) != 0 {
		t.Fatalf("neutral release retained stale state: %+v", tr)
	}
	tr.observe(ipTouch(evKey, btnTouch, 1))
	tr.observe(ipTouch(evAbs, absMTID, 32))
	tr.observe(ipTouch(evSyn, synReport, 0))
	if len(tr.active) != 0 || tr.peak != 1 {
		t.Fatalf("neutral boundary inferred previous slot: %+v", tr)
	}
}

func TestTouchPeakCountsOnlyCompleteFrames(t *testing.T) {
	tr := ipTouchTracker()
	ipTouchNeutral(tr)
	tr.observe(ipTouch(evKey, btnTouch, 1))
	for slot := int32(0); slot < 4; slot++ {
		tr.observe(ipTouch(evAbs, absMTSlot, slot))
		tr.observe(ipTouch(evAbs, absMTID, 40+slot))
	}
	if tr.peak != 0 {
		t.Fatal("partial frame established contact peak")
	}
	tr.observe(ipTouch(evSyn, synReport, 0))
	if tr.peak != 4 {
		t.Fatalf("four-contact frame not counted: %+v", tr)
	}
	// Add new contact before retiring old contact in the same frame: never five.
	tr.observe(ipTouch(evAbs, absMTSlot, 4))
	tr.observe(ipTouch(evAbs, absMTID, 44))
	if tr.peak != 4 {
		t.Fatal("transient five-contact intermediate state counted")
	}
	tr.observe(ipTouch(evAbs, absMTSlot, 0))
	tr.observe(ipTouch(evAbs, absMTID, -1))
	tr.observe(ipTouch(evSyn, synReport, 0))
	if tr.peak != 4 {
		t.Fatalf("replacement frame falsely established five: %+v", tr)
	}
	tr.observe(ipTouch(evAbs, absMTSlot, 5))
	tr.observe(ipTouch(evAbs, absMTID, 45))
	if tr.peak != 4 {
		t.Fatal("trailing incomplete frame counted")
	}
	tr.observe(ipTouch(evSyn, synReport, 0))
	if tr.peak != 5 {
		t.Fatalf("genuine complete five-contact frame omitted: %+v", tr)
	}
}

func TestTouchDuplicateTrackingIDsInvalidateCommittedFrame(t *testing.T) {
	tr := ipTouchTracker()
	ipTouchNeutral(tr)
	tr.observe(ipTouch(evKey, btnTouch, 1))
	for slot := int32(0); slot < 5; slot++ {
		tr.observe(ipTouch(evAbs, absMTSlot, slot))
		tr.observe(ipTouch(evAbs, absMTID, 50))
	}
	if tr.invalid {
		t.Fatal("duplicate intermediate states must be checked at frame commit")
	}
	tr.observe(ipTouch(evSyn, synReport, 0))
	if !tr.invalid || tr.peak >= 5 {
		t.Fatalf("five slots with one tracking ID accepted: %+v", tr)
	}
}

func TestTouchTrackingIDTransferWithinFrameIsValid(t *testing.T) {
	tr := ipTouchTracker()
	ipTouchNeutral(tr)
	tr.observe(ipTouch(evKey, btnTouch, 1))
	tr.observe(ipTouch(evAbs, absMTSlot, 0))
	tr.observe(ipTouch(evAbs, absMTID, 50))
	tr.observe(ipTouch(evSyn, synReport, 0))
	tr.observe(ipTouch(evAbs, absMTSlot, 1))
	tr.observe(ipTouch(evAbs, absMTID, 50))
	tr.observe(ipTouch(evAbs, absMTSlot, 0))
	tr.observe(ipTouch(evAbs, absMTID, -1))
	tr.observe(ipTouch(evSyn, synReport, 0))
	if tr.invalid || tr.peak != 1 || tr.active[1] != 50 {
		t.Fatalf("transient duplicate before retirement rejected or ID lost: %+v", tr)
	}
}

func TestTouchInvalidSlotsAndIDsFailTracking(t *testing.T) {
	for _, bad := range []event{ipTouch(evAbs, absMTSlot, -1), ipTouch(evAbs, absMTSlot, 10), ipTouch(evAbs, absMTID, -2)} {
		tr := ipTouchTracker()
		ipTouchNeutral(tr)
		tr.observe(bad)
		if !tr.invalid {
			t.Fatalf("invalid event accepted: %+v", bad)
		}
	}
}

func ipEventBytes(typ, code uint16, value int32) []byte {
	b := make([]byte, 24)
	binary.LittleEndian.PutUint16(b[16:18], typ)
	binary.LittleEndian.PutUint16(b[18:20], code)
	binary.LittleEndian.PutUint32(b[20:24], uint32(value))
	return b
}

func ipPipeReader(t *testing.T) (*session, int) {
	t.Helper()
	var fds [2]int
	if err := syscall.Pipe2(fds[:], syscall.O_NONBLOCK|syscall.O_CLOEXEC); err != nil {
		t.Fatal(err)
	}
	s := newInputSession(context.Background())
	s.fds = []int{fds[0]}
	s.wg.Add(1)
	go s.readEvents("fixture", fds[0])
	t.Cleanup(func() { s.close(); _ = syscall.Close(fds[1]) })
	return s, fds[1]
}

func TestInputReaderRawNonblockingCleanup(t *testing.T) {
	s, w := ipPipeReader(t)
	if _, err := syscall.Write(w, ipEventBytes(evKey, keyPower, 1)); err != nil {
		t.Fatal(err)
	}
	ok, err := s.until(time.Second, func(e event) bool { return e.typ == evKey && e.code == keyPower && e.value == 1 })
	if err != nil || !ok {
		t.Fatalf("event not decoded: %t %v", ok, err)
	}
	done := make(chan struct{})
	go func() { s.close(); s.close(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("idle nonblocking reader cleanup hung")
	}
}

func TestInputReaderErrorsInvalidateSession(t *testing.T) {
	for _, tc := range []struct {
		name     string
		b        []byte
		fragment string
	}{
		{"syn-dropped", ipEventBytes(evSyn, synDropped, 0), "SYN_DROPPED"},
		{"drop-after-key", append(ipEventBytes(evKey, keyPower, 1), ipEventBytes(evSyn, synDropped, 0)...), "SYN_DROPPED"},
		{"truncated", []byte{0}, "truncated"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, w := ipPipeReader(t)
			if _, err := syscall.Write(w, tc.b); err != nil {
				t.Fatal(err)
			}
			ok, err := s.until(time.Second, func(event) bool { return true })
			if ok || err == nil || !strings.Contains(err.Error(), tc.fragment) {
				t.Fatalf("lost stream accepted: %t %v", ok, err)
			}
			if err := s.drain(); err == nil {
				t.Fatal("drain forgot sticky stream error")
			}
		})
	}
}

func TestInputReaderEOFAndQueueOverflowInvalidateSession(t *testing.T) {
	t.Run("eof", func(t *testing.T) {
		var fds [2]int
		if err := syscall.Pipe2(fds[:], syscall.O_NONBLOCK|syscall.O_CLOEXEC); err != nil {
			t.Fatal(err)
		}
		s := newInputSession(context.Background())
		s.fds = []int{fds[0]}
		s.wg.Add(1)
		go s.readEvents("fixture", fds[0])
		defer s.close()
		if err := syscall.Close(fds[1]); err != nil {
			t.Fatal(err)
		}
		if ok, err := s.until(time.Second, func(event) bool { return true }); ok || err == nil || !strings.Contains(err.Error(), "ended") {
			t.Fatalf("EOF silently ignored: %t %v", ok, err)
		}
	})
	t.Run("overflow", func(t *testing.T) {
		var fds [2]int
		if err := syscall.Pipe2(fds[:], syscall.O_NONBLOCK|syscall.O_CLOEXEC); err != nil {
			t.Fatal(err)
		}
		s := newInputSession(context.Background())
		s.fds = []int{fds[0]}
		for i := 0; i < cap(s.ch); i++ {
			s.ch <- event{}
		}
		if _, err := syscall.Write(fds[1], ipEventBytes(evKey, keyPower, 1)); err != nil {
			t.Fatal(err)
		}
		s.wg.Add(1)
		go s.readEvents("fixture", fds[0])
		defer s.close()
		defer syscall.Close(fds[1])
		select {
		case err := <-s.errCh:
			if !strings.Contains(err.Error(), "overflow") {
				t.Fatal(err)
			}
		case <-time.After(time.Second):
			t.Fatal("queue overflow not surfaced")
		}
	})
}

func TestInputSessionCancellationAndDeadline(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	s := newInputSession(ctx)
	defer s.close()
	cancel()
	if ok, err := s.until(time.Second, func(event) bool { return true }); ok || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel ignored: %t %v", ok, err)
	}
	s2 := newInputSession(context.Background())
	defer s2.close()
	producerDone := make(chan struct{})
	go func() {
		defer close(producerDone)
		for {
			select {
			case s2.ch <- event{}:
			case <-s2.ctx.Done():
				return
			}
		}
	}()
	start := time.Now()
	if ok, err := s2.until(20*time.Millisecond, func(event) bool { return false }); ok || err != nil {
		t.Fatalf("deadline result: %t %v", ok, err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("continuous event stream starved deadline")
	}
	s2.close()
	<-producerDone
}
