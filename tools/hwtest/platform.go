package main

import (
	"bufio"
	"compress/gzip"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func init() {
	register(10, "platform", "device tree, kernel, CPUs, memory, kernel config, log health", checkPlatform)
	register(20, "thermal", "LVTS and NTC zones, cooling devices", checkThermal)
}

func checkPlatform(c *Ctx, r *Reporter) {
	if m, err := c.read("/proc/device-tree/model"); err != nil {
		r.Fail("model", "cannot read device-tree model: %v", err)
	} else if strings.Contains(m, "DC-1") {
		r.Pass("model", "%q", m)
	} else {
		r.Fail("model", "%q does not identify a DC-1", m)
	}

	rel, _ := c.read("/proc/sys/kernel/osrelease")
	r.Info("kernel", "%s", rel)
	if rel != "" {
		if c.exists("/lib/modules/" + rel) {
			r.Pass("modules", "/lib/modules/%s present", rel)
		} else {
			r.Fail("modules", "/lib/modules/%s missing: running kernel has no matching modules", rel)
		}
	}

	if on, err := c.read("/sys/devices/system/cpu/online"); err != nil {
		r.Skip("cpus", "%v", err)
	} else if on == "0-7" {
		r.Pass("cpus", "all 8 CPUs online")
	} else {
		r.Fail("cpus", "online=%q, expected 0-7", on)
	}

	checkCPUFreq(c, r)

	if kb := memKB(c, "MemTotal"); kb == 0 {
		r.Skip("memory", "cannot read /proc/meminfo")
	} else if kb >= 7_000_000 {
		r.Pass("memory", "%.1f GiB total", float64(kb)/1048576)
	} else {
		r.Warn("memory", "%.1f GiB total, expected about 8 GiB", float64(kb)/1048576)
	}

	checkKernelConfig(c, r)
	checkHealth(c, r)
}

func memKB(c *Ctx, key string) int64 {
	p, err := c.readPath("/proc/meminfo")
	if err != nil {
		return 0
	}
	f, err := os.Open(p)
	if err != nil {
		return 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var k string
		var v int64
		if n, _ := fmt.Sscanf(sc.Text(), "%s %d", &k, &v); n == 2 && k == key+":" {
			return v
		}
	}
	return 0
}

func checkCPUFreq(c *Ctx, r *Reporter) {
	pol := c.glob("/sys/devices/system/cpu/cpufreq/policy*")
	if len(pol) != 2 {
		r.Fail("cpufreq", "found %d cpufreq policies, expected 2", len(pol))
		return
	}
	baseline := map[string]int64{}
	peak := map[string]int64{}
	for _, p := range pol {
		cpus, err := c.read(p + "/related_cpus")
		lo, elo := c.readInt(p + "/cpuinfo_min_freq")
		hi, ehi := c.readInt(p + "/cpuinfo_max_freq")
		cur, ecur := c.readInt(p + "/scaling_cur_freq")
		gov, egov := c.read(p + "/scaling_governor")
		name := filepath.Base(p)
		if err != nil || elo != nil || ehi != nil || ecur != nil || egov != nil || cpus == "" || gov == "" {
			r.Fail(name, "unreadable frequency policy")
			continue
		}
		if hi <= lo || cur < lo || cur > hi {
			r.Fail(name, "cpus [%s] range %d-%d kHz, current %d", cpus, lo, hi, cur)
			continue
		}
		baseline[p], peak[p] = cur, cur
		r.Pass(name, "cpus [%s] %d-%d MHz, now %d MHz, governor %s", cpus, lo/1000, hi/1000, cur/1000, gov)
	}
	if !c.Active || !filepathRootIsSlash(c) {
		r.Skip("dvfs-load", "needs -active on the live root (3 s bounded CPU load)")
		return
	}
	// Refuse stimulus if thermal telemetry is missing, invalid or already hot.
	zones := c.glob("/sys/class/thermal/thermal_zone*")
	if len(zones) == 0 {
		r.Skip("dvfs-load", "no thermal telemetry")
		return
	}
	for _, z := range zones {
		t, err := c.readInt(z + "/temp")
		if err != nil || t < -20000 || t >= 60000 {
			r.Skip("dvfs-load", "thermal telemetry unavailable or >=60 C")
			return
		}
	}
	stop := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var x uint64 = 1
			for {
				select {
				case <-stop:
					loadSink.Add(x)
					return
				default:
					for j := 0; j < 10000; j++ {
						x = x*3 + uint64(j)
					}
				}
			}
		}()
	}
	defer func() { close(stop); wg.Wait() }()
	for i := 0; i < 10; i++ {
		if !c.paused(300 * time.Millisecond) {
			r.Skip("dvfs-load", "interrupted")
			return
		}
		for _, z := range zones {
			t, err := c.readInt(z + "/temp")
			if !loadTemperatureSafe(t, err) {
				r.Warn("dvfs-load", "aborted: temperature unreadable, invalid or >=65 C")
				return
			}
		}
		for p := range baseline {
			if f, err := c.readInt(p + "/scaling_cur_freq"); err == nil {
				peak[p] = max(peak[p], f)
			}
		}
	}
	for _, p := range pol {
		before, ok := baseline[p]
		if !ok {
			continue
		}
		if peak[p] > before {
			r.Pass(filepath.Base(p)+"-load", "same-cluster frequency rose %d -> %d MHz", before/1000, peak[p]/1000)
		} else {
			r.Info(filepath.Base(p)+"-load", "peak %d MHz, baseline %d MHz; no transition observed (possibly already boosted)", peak[p]/1000, before/1000)
		}
	}
}

func loadTemperatureSafe(t int64, err error) bool {
	return err == nil && t >= -20000 && t < 65000
}

var loadSink atomic.Uint64

// Required options: built in (y) or built in / module (ym).
var kconfig = []struct {
	name string
	ym   bool
}{
	{"HIGH_RES_TIMERS", false}, {"BINFMT_SCRIPT", false}, {"EPOLL", false},
	{"SIGNALFD", false}, {"TIMERFD", false}, {"EVENTFD", false},
	{"FUSE_FS", false}, {"SECURITYFS", false}, {"DEBUG_INFO_BTF", false},
	{"INPUT_UINPUT", true}, {"UHID", true}, {"BT_RFCOMM", true}, {"BT_BNEP", true},
	{"SECURITY_LANDLOCK", true}, {"BPF_LSM", true},
}

func checkKernelConfig(c *Ctx, r *Reporter) {
	defer func() {
		v, err := c.readInt("/proc/sys/kernel/unprivileged_bpf_disabled")
		if err != nil {
			r.Skip("bpf-unpriv", "policy unreadable")
			return
		}
		if v == 1 || v == 2 {
			r.Pass("bpf-unpriv", "unprivileged BPF disabled (%d)", v)
		} else if v == 0 {
			r.Fail("bpf-unpriv", "unprivileged BPF is enabled")
		} else {
			r.Fail("bpf-unpriv", "invalid policy %d", v)
		}
	}()
	p, err := c.readPath("/proc/config.gz")
	if err != nil {
		r.Skip("kconfig", "config unavailable: %v", err)
		return
	}
	f, err := os.Open(p)
	if err != nil {
		r.Skip("kconfig", "/proc/config.gz unavailable: %v", err)
		return
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		r.Fail("kconfig", "bad /proc/config.gz: %v", err)
		return
	}
	defer zr.Close()
	cfg := map[string]string{}
	sc := bufio.NewScanner(zr)
	sc.Buffer(make([]byte, 1<<16), 1<<20)
	for sc.Scan() {
		if k, v, ok := strings.Cut(sc.Text(), "="); ok && strings.HasPrefix(k, "CONFIG_") {
			cfg[strings.TrimPrefix(k, "CONFIG_")] = v
		}
	}
	if err := sc.Err(); err != nil {
		r.Fail("kconfig", "read config: %v", err)
		return
	}
	var bad []string
	for _, o := range kconfig {
		v := cfg[o.name]
		if v == "y" || (o.ym && v == "m") {
			continue
		}
		bad = append(bad, fmt.Sprintf("%s=%q", o.name, v))
	}
	if len(bad) > 0 {
		r.Fail("kconfig", "contract options wrong: %s", strings.Join(bad, ", "))
	} else {
		r.Pass("kconfig", "%d contract options present in the running kernel", len(kconfig))
	}
}

func checkHealth(c *Ctx, r *Reporter) {
	if out, err := c.run(5*time.Second, "dmesg"); err != nil {
		r.Skip("dmesg", "kernel log unavailable; no raw log is included")
	} else {
		// Report only signature counts; kernel logs can contain device identifiers.
		for _, sig := range []string{"Oops", "Call trace", "Kernel panic", "BUG:", "WARNING: CPU", "timeout", "failed"} {
			if n := strings.Count(out, sig); n > 0 {
				if sig == "timeout" || sig == "failed" {
					r.Warn("dmesg", "%d occurrences of %q (not necessarily current faults)", n, sig)
				} else {
					r.Fail("dmesg-crash", "%d occurrences of %q", n, sig)
				}
			}
		}
		r.Info("dmesg", "signature scan is not a complete kernel health check")
	}
	if !c.have("systemctl") {
		r.Skip("systemd", "systemctl unavailable")
		return
	}
	out, err := c.run(10*time.Second, "systemctl", "--failed", "--no-legend", "--plain")
	if err != nil {
		r.Skip("systemd", "failed-unit query did not complete")
		return
	}
	if l := nonEmpty(out); len(l) == 0 {
		r.Pass("systemd", "no failed units reported")
	} else {
		r.Warn("systemd", "%d failed units reported; inspect systemctl --failed locally", len(l))
	}
}

func nonEmpty(s string) []string {
	var o []string
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			o = append(o, l)
		}
	}
	return o
}

func checkThermal(c *Ctx, r *Reporter) {
	zones := c.glob("/sys/class/thermal/thermal_zone*")
	if len(zones) < 15 {
		r.Warn("zones", "%d thermal zones, expected 15 (13 LVTS + 2 NTC)", len(zones))
	} else {
		r.Pass("zones", "%d thermal zones", len(zones))
	}
	var hot = -100.0
	var hotName string
	var badRead []string
	for _, z := range zones {
		var typ string
		if t, err := c.read(z + "/type"); err != nil || t == "" {
			r.Fail(filepath.Base(z), "zone type unreadable")
			continue
		} else {
			typ = t
		}
		t, err := c.readInt(z + "/temp")
		if err != nil {
			badRead = append(badRead, typ)
			continue
		}
		deg := float64(t) / 1000
		if deg < -20 || deg > 105 {
			r.Fail(typ, "implausible reading %.1f C", deg)
			continue
		}
		if deg > hot {
			hot, hotName = deg, typ
		}
	}
	if len(badRead) > 0 {
		r.Fail("readable", "unreadable zones: %s", strings.Join(badRead, ", "))
	}
	switch {
	case hotName == "":
		r.Fail("hottest", "no readable thermal zones")
	case hot > 80:
		r.Fail("hottest", "%s at %.1f C", hotName, hot)
	case hot > 60:
		r.Warn("hottest", "%s at %.1f C", hotName, hot)
	default:
		r.Pass("hottest", "%s at %.1f C", hotName, hot)
	}
	cd := c.glob("/sys/class/thermal/cooling_device*")
	var parts []string
	valid := true
	for _, d := range cd {
		t, et := c.read(d + "/type")
		cur, ec := c.readInt(d + "/cur_state")
		mx, em := c.readInt(d + "/max_state")
		if et != nil || ec != nil || em != nil || t == "" || cur < 0 || mx <= 0 || cur > mx {
			r.Fail(filepath.Base(d), "invalid or unreadable cooling state")
			valid = false
			continue
		}
		parts = append(parts, fmt.Sprintf("%s %d/%d", t, cur, mx))
	}
	if len(cd) < 3 {
		r.Warn("cooling", "%d cooling devices (%s), expected cpu0, cpu6 and gpu", len(cd), strings.Join(parts, "; "))
	} else if valid {
		r.Pass("cooling", "%s (readback, not a thermal throttling test)", strings.Join(parts, "; "))
	}
}
