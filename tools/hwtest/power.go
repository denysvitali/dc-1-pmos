package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func init() {
	register(50, "power", "fuel gauge, charger, Type-C/PD, RTC, suspend plumbing, watchdog", checkPower)
}

// Required attributes never turn an unreadable or empty value into a zero-value PASS.
func powerText(c *Ctx, r *Reporter, name, path string) (string, bool) {
	v, err := c.read(path)
	if err != nil {
		r.Fail(name, "read %s: %v", path, err)
		return "", false
	}
	if v == "" {
		r.Fail(name, "%s is empty", path)
		return "", false
	}
	return v, true
}

func powerInt(c *Ctx, r *Reporter, name, path string) (int64, bool) {
	v, err := c.readInt(path)
	if err != nil {
		r.Fail(name, "read %s: %v", path, err)
		return 0, false
	}
	return v, true
}

func powerStatus(c *Ctx, r *Reporter, name, path string) (string, bool) {
	v, ok := powerText(c, r, name, path)
	if !ok {
		return "", false
	}
	switch v {
	case "Charging", "Discharging", "Not charging", "Full", "Unknown":
		return v, true
	default:
		r.Fail(name, "invalid power-supply status %q at %s", v, path)
		return "", false
	}
}

func checkPower(c *Ctx, r *Reporter) {
	ps := "/sys/class/power_supply/"
	var status string
	if !c.exists(ps + "mt6358-fg") {
		r.Fail("fuel-gauge", "mt6358-fg missing")
	} else {
		uv, okV := powerInt(c, r, "fuel-gauge", ps+"mt6358-fg/voltage_now")
		capacity, okC := powerInt(c, r, "fuel-gauge", ps+"mt6358-fg/capacity")
		ua, okA := powerInt(c, r, "fuel-gauge", ps+"mt6358-fg/current_now")
		st, okS := powerStatus(c, r, "fuel-gauge", ps+"mt6358-fg/status")
		if okS {
			status = st
		}
		if okV && okC && okA && okS {
			v := float64(uv) / 1e6
			switch {
			case uv < 3000000 || uv > 4450000:
				r.Fail("fuel-gauge", "%.3f V is outside the cell range", v)
			case capacity < 0 || capacity > 100:
				r.Fail("fuel-gauge", "capacity %d%% is outside 0..100", capacity)
			case st == "Unknown":
				r.Warn("fuel-gauge", "%.3f V, %d%%, %d mA; status Unknown", v, capacity, ua/1000)
			default:
				r.Pass("fuel-gauge", "readable telemetry: %.3f V, %d%%, %d mA, %s (not pack protection validation)", v, capacity, ua/1000, st)
			}
			if capacity == 0 || (capacity == 100 && st == "Discharging" && v < 4.0) {
				r.Warn("gauge-plausible", "capacity %d%% at %.2f V looks stale", capacity, v)
			}
		}
		if okA && okS {
			switch {
			case st != "Charging" && st != "Discharging":
				r.Skip("gauge-sign", "status %s does not establish a current direction", st)
			case ua == 0:
				r.Warn("gauge-sign", "zero current does not establish the %s direction", st)
			case st == "Charging" && ua < 0, st == "Discharging" && ua > 0:
				r.Warn("gauge-sign", "status %s but current %d mA has the wrong sign", st, ua/1000)
			default:
				r.Pass("gauge-sign", "current sign consistent with %s", st)
			}
		}
	}
	checkCharger(c, r, ps, status)
	checkTypeC(c, r)
	checkRTC(c, r)
	checkSuspend(c, r)
	checkWatchdog(c, r)
}

func checkCharger(c *Ctx, r *Reporter, ps, battStatus string) {
	if !c.exists(ps + "mt6375-charger") {
		r.Fail("charger", "mt6375-charger missing")
		return
	}
	on, okOn := powerInt(c, r, "charger", ps+"mt6375-charger/online")
	st, okS := powerStatus(c, r, "charger", ps+"mt6375-charger/status")
	if okOn && on != 0 && on != 1 {
		r.Fail("charger", "online=%d is not boolean", on)
		okOn = false
	}
	if !okOn || !okS {
		return
	}
	switch {
	case on == 0 && (st == "Charging" || battStatus == "Charging"):
		r.Fail("charger", "no input online but status Charging (charger %q, gauge %q)", st, battStatus)
	case battStatus == "" || battStatus == "Unknown" || st == "Unknown":
		r.Warn("charger", "online=%d, charger %q, gauge %q; consistency unavailable", on, st, battStatus)
	case on == 1 && battStatus == "Discharging":
		r.Warn("charger", "input online but pack discharging (charger %q)", st)
	default:
		r.Pass("charger", "online=%d, charger %q, gauge %q; status consistency only, not charge/protection proof", on, st, battStatus)
	}
	if on == 1 {
		// TCPM exposes negotiated ceilings, not measured input voltage/current.
		for _, f := range []string{"voltage_max", "current_max"} {
			if v, ok := powerInt(c, r, "source-"+f, ps+"tcpm-source-psy-mt6375-tcpc/"+f); ok {
				if v < 0 {
					r.Fail("source-"+f, "negative source telemetry %d", v)
				} else {
					r.Info("source-"+f, "%d (kernel power-supply units)", v)
				}
			}
		}
		if v, ok := powerText(c, r, "source-usb_type", ps+"tcpm-source-psy-mt6375-tcpc/usb_type"); ok {
			r.Info("source-usb_type", "%s; advertised/selected types, not physical charging proof", v)
		}
	}
}

// Writable enum attributes may list choices with the active choice in brackets.
func selectedPowerRole(v string, allowed ...string) bool {
	valid := func(s string) bool {
		for _, a := range allowed {
			if s == a {
				return true
			}
		}
		return false
	}
	if !strings.ContainsAny(v, "[]") {
		return valid(v)
	}
	if strings.Count(v, "[") != 1 || strings.Count(v, "]") != 1 {
		return false
	}
	selected := false
	for _, field := range strings.Fields(v) {
		if strings.HasPrefix(field, "[") && strings.HasSuffix(field, "]") {
			if !valid(field[1 : len(field)-1]) {
				return false
			}
			selected = true
		} else if !valid(field) {
			return false
		}
	}
	return selected
}

func checkTypeC(c *Ctx, r *Reporter) {
	p := "/sys/class/typec/port0"
	if !c.exists(p) {
		r.Fail("typec", "port0 missing")
		return
	}
	dr, okD := powerText(c, r, "typec", p+"/data_role")
	pr, okP := powerText(c, r, "typec", p+"/power_role")
	op, okO := powerText(c, r, "typec", p+"/power_operation_mode")
	if okD && !selectedPowerRole(dr, "host", "device") {
		r.Fail("typec", "unrecognized data role %q", dr)
		okD = false
	}
	if okP && !selectedPowerRole(pr, "source", "sink") {
		r.Fail("typec", "unrecognized power role %q", pr)
		okP = false
	}
	if okO && !selectedPowerRole(op, "default", "1.5A", "3.0A", "usb_power_delivery") {
		r.Fail("typec", "unrecognized operation mode %q", op)
		okO = false
	}
	if okD && okP && okO {
		r.Pass("typec", "readable role telemetry: data %s, power %s, mode %s", dr, pr, op)
	}
	if c.exists(p + "-partner") {
		r.Info("typec-partner", "a partner is registered")
	}
	if c.exists("/sys/class/usb_power_delivery/pd0") {
		r.Pass("pd", "pd0 registered; no contract or electrical validation implied")
	} else {
		r.Warn("pd", "no usb_power_delivery device")
	}
}

func rtcSeconds(c *Ctx, rtc string) (int64, error) { return c.readInt(rtc + "/since_epoch") }

func rtcAdvanceValid(advance int64, elapsed time.Duration) bool {
	delta := float64(advance) - elapsed.Seconds()
	return advance > 0 && delta >= -1.5 && delta <= 1.5
}

func checkRTC(c *Ctx, r *Reporter) {
	rtcs := c.glob("/sys/class/rtc/rtc*")
	if len(rtcs) < 2 {
		r.Warn("rtc", "%d RTC devices, expected PMIC plus s35390a", len(rtcs))
	}
	first := map[string]int64{}
	sampled := map[string]time.Time{}
	names := map[string]string{}
	for _, d := range rtcs {
		short := filepath.Base(d)
		name, ok := powerText(c, r, short, d+"/name")
		t, err := rtcSeconds(c, d)
		if err != nil {
			r.Fail(short, "read since_epoch: %v", err)
			continue
		}
		if t < 0 {
			r.Fail(short, "negative since_epoch %d", t)
			continue
		}
		if !ok {
			continue
		}
		first[d], names[d] = t, name
		sampled[d] = time.Now()
		if alarm, err := c.read(d + "/wakealarm"); err == nil {
			r.Info(short+"-alarm", "wakealarm interface readable (%q); not modified or tested", alarm)
		} else {
			r.Skip(short+"-alarm", "wakealarm unavailable: %v; not modified", err)
		}
	}
	if filepath.Clean(c.Root) != "/" {
		for _, d := range rtcs {
			if t, ok := first[d]; ok {
				r.Info(filepath.Base(d)+"-sample", "%s since_epoch=%d (fixture)", names[d], t)
				r.Skip(filepath.Base(d)+"-tick", "relocated root: static fixture cannot establish RTC ticking or system-time skew")
			}
		}
		return
	}
	if len(first) == 0 {
		return
	}
	if !c.paused(2100 * time.Millisecond) {
		r.Skip("rtc-tick", "cancelled before the second sample")
		return
	}
	for _, d := range rtcs {
		t0, ok := first[d]
		if !ok {
			continue
		}
		short := filepath.Base(d)
		t1, err := rtcSeconds(c, d)
		if err != nil {
			r.Fail(short, "second since_epoch read: %v", err)
			continue
		}
		if t1 < 0 {
			r.Fail(short, "negative second since_epoch %d", t1)
			continue
		}
		now := time.Now()
		elapsed := now.Sub(sampled[d])
		wallElapsed := float64(now.UnixNano()-sampled[d].UnixNano()) / 1e9
		adv, skew := t1-t0, t1-now.Unix()
		switch {
		case wallElapsed-elapsed.Seconds() > 2 || elapsed.Seconds()-wallElapsed > 2:
			r.Warn(short, "%s tick comparison inconclusive: suspend or system-clock adjustment between samples", names[d])
		case !rtcAdvanceValid(adv, elapsed):
			r.Fail(short, "%s advanced %d s in %.2f s measured interval", names[d], adv, elapsed.Seconds())
		case skew > 60 || skew < -60:
			r.Warn(short, "%s ticks but is %d s from system time", names[d], skew)
		default:
			r.Pass(short, "%s ticks, within %d s of system time; alarm/wake not tested", names[d], skew)
		}
	}
}

func checkSuspend(c *Ctx, r *Reporter) {
	st, okS := powerText(c, r, "suspend-state", "/sys/power/state")
	ms, okM := powerText(c, r, "suspend-state", "/sys/power/mem_sleep")
	if okM && !selectedPowerRole(ms, "s2idle", "shallow", "deep") {
		r.Fail("suspend-state", "unrecognized mem_sleep %q", ms)
		okM = false
	}
	if okS && okM {
		found := false
		for _, s := range strings.Fields(st) {
			found = found || s == "freeze"
		}
		if found {
			r.Pass("suspend-state", "freeze offered; states %q, mem_sleep %q; no suspend/resume proof", st, ms)
		} else {
			r.Fail("suspend-state", "freeze not offered (%q)", st)
		}
	}
	p := "/sys/power/suspend_stats/"
	if !c.exists(p) {
		r.Skip("suspend-stats", "suspend statistics interface absent")
	} else {
		ok, okSuccess := powerInt(c, r, "suspend-stats", p+"success")
		fail, okFail := powerInt(c, r, "suspend-stats", p+"fail")
		if okSuccess && okFail {
			if ok < 0 || fail < 0 {
				r.Fail("suspend-stats", "negative counters: success=%d fail=%d", ok, fail)
			} else {
				r.Info("suspend-stats", "%d successful, %d failed suspends since boot", ok, fail)
			}
		}
	}
	r.Skip("suspend-cycle", "never run automatically: a failed resume removes the recovery channel; use docs/hw/suspend.md")
}

func checkWatchdog(c *Ctx, r *Reporter) {
	wd := c.glob("/sys/class/watchdog/watchdog*")
	if len(wd) == 0 {
		r.Fail("watchdog", "no watchdog device registered")
		return
	}
	holders := map[string]bool{}
	for _, fd := range c.glob("/proc/[0-9]*/fd/*") {
		t := c.linkTarget(fd)
		if t != "/dev/watchdog" && !strings.HasPrefix(t, "/dev/watchdog") {
			continue
		}
		// Accept only watchdog or watchdogN, not unrelated similarly named paths.
		suffix := strings.TrimPrefix(t, "/dev/watchdog")
		valid := true
		for _, b := range suffix {
			valid = valid && b >= '0' && b <= '9'
		}
		if !valid {
			continue
		}
		parts := strings.Split(fd, "/")
		comm, err := c.read("/proc/" + parts[2] + "/comm")
		if err != nil || comm == "" {
			r.Warn("watchdog-holder", "PID %s has %s open, but process name unavailable", parts[2], t)
			continue
		}
		holders[comm] = true
	}
	var names []string
	for h := range holders {
		names = append(names, h)
	}
	sort.Strings(names)
	if len(names) > 0 {
		r.Pass("watchdog", "%d registered device(s); a watchdog descriptor held by %s; pinging/recovery not proven and device never opened", len(wd), strings.Join(names, ","))
	} else if filepath.Clean(c.Root) != "/" || os.Geteuid() != 0 {
		r.Skip("watchdog", "%d registered device(s); fixture or restricted /proc cannot establish holders; device never opened", len(wd))
	} else {
		r.Warn("watchdog", "%d registered device(s); no visible holder (restricted/racing /proc is possible); device never opened", len(wd))
	}
}
