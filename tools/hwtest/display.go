package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func init() {
	register(30, "display", "DSI/DRM state, GPU interfaces, frontlight readback", checkDisplay)
}

func checkDisplay(c *Ctx, r *Reporter) {
	conns := c.glob("/sys/class/drm/card*-DSI-*")
	if len(conns) == 0 {
		r.Fail("dsi", "no DSI connector registered")
	}
	bls := c.glob("/sys/class/backlight/*")
	for _, cn := range conns {
		name := filepath.Base(cn)
		st, err := c.read(cn + "/status")
		if err != nil {
			r.Fail(name, "status unreadable")
			continue
		}
		if st != "connected" {
			r.Fail(name, "status %q", st)
			continue
		}
		r.Pass(name, "connector reports connected")
		modes, err := c.read(cn + "/modes")
		if err != nil {
			r.Fail(name+"-mode", "modes unreadable")
		} else {
			found := false
			for _, m := range strings.Fields(modes) {
				if m == "1200x1600" {
					found = true
				}
			}
			if found {
				r.Pass(name+"-mode", "1200x1600 offered")
			} else {
				r.Fail(name+"-mode", "1200x1600 not offered")
			}
		}
		en, ee := c.read(cn + "/enabled")
		dpms, ed := c.read(cn + "/dpms")
		if ee != nil || ed != nil {
			r.Warn(name+"-state", "enabled/DPMS unreadable")
		} else {
			r.Info(name+"-state", "connector %s, DPMS %s; this does not establish panel emission", en, dpms)
		}
	}
	for _, card := range c.glob("/sys/class/drm/card[0-9]*") {
		if d := c.linkBase(card + "/device/driver"); d != "" {
			r.Info(filepath.Base(card), "driver %s", d)
		}
	}
	nodes := c.glob("/sys/class/drm/renderD*")
	if len(nodes) == 0 {
		r.Fail("render-node", "no DRM render node")
	}
	for _, node := range nodes {
		d := c.linkBase(node + "/device/driver")
		if d != "panfrost" {
			r.Fail("render-node", "%s driver %q, expected panfrost", filepath.Base(node), d)
			continue
		}
		r.Pass("render-node", "%s driven by panfrost", filepath.Base(node))
		if !filepathRootIsSlash(c) {
			r.Skip("render-open", "device opens disabled for fixtures")
			continue
		}
		f, err := os.OpenFile(c.path("/dev/dri/"+filepath.Base(node)), os.O_RDWR, 0)
		if err != nil {
			r.Skip("render-open", "%s", permHint(err))
		} else {
			f.Close()
			r.Pass("render-open", "node opens; no render workload submitted")
		}
	}
	checkGPUFreq(c, r)
	checkFrontlight(c, r, bls)
	r.Skip("gpu-render", "render node/state is not a GPU correctness or frame-pacing test")
}

func checkGPUFreq(c *Ctx, r *Reporter) {
	devs := c.glob("/sys/class/devfreq/*gpu*")
	if len(devs) == 0 {
		r.Fail("gpu-devfreq", "no GPU devfreq device")
		return
	}
	for _, d := range devs {
		cur, ec := c.readInt(d + "/cur_freq")
		mn, en := c.readInt(d + "/min_freq")
		mx, ex := c.readInt(d + "/max_freq")
		gov, eg := c.read(d + "/governor")
		avail, ea := c.read(d + "/available_frequencies")
		if ec != nil || en != nil || ex != nil || eg != nil || ea != nil || gov == "" {
			r.Fail("gpu-devfreq", "frequency telemetry unreadable or incomplete")
			continue
		}
		in := false
		valid := true
		for _, f := range strings.Fields(avail) {
			v, err := strconv.ParseInt(f, 10, 64)
			if err != nil || v <= 0 {
				valid = false
			}
			if v == cur {
				in = true
			}
		}
		if !valid || !in || mn < 0 || mx <= 0 || mn > mx {
			r.Fail("gpu-devfreq", "invalid OPP/window telemetry (current %d, min %d, max %d Hz)", cur, mn, mx)
			continue
		}
		r.Pass("gpu-devfreq", "current %d MHz is an advertised OPP; window %d-%d MHz, governor %s", cur/1e6, mn/1e6, mx/1e6, gov)
		if cur < mn || cur > mx {
			r.Warn("gpu-window", "current readback outside policy window; device may be idle or samples raced")
		}
	}
}

func checkFrontlight(c *Ctx, r *Reporter, bls []string) {
	if len(bls) < 2 {
		r.Fail("frontlight", "%d backlight devices, expected white and amber", len(bls))
	}
	for _, b := range bls {
		name := filepath.Base(b)
		cur, ec := c.readInt(b + "/brightness")
		mx, em := c.readInt(b + "/max_brightness")
		power, ep := c.readInt(b + "/bl_power")
		if ec != nil || em != nil || ep != nil {
			r.Fail(name, "brightness/max/bl_power unreadable")
			continue
		}
		if mx <= 0 || cur < 0 || cur > mx || power < 0 || power > 4 {
			r.Fail(name, "invalid brightness %d/%d, bl_power %d", cur, mx, power)
			continue
		}
		r.Pass(name, "brightness setting %d/%d, bl_power %d (not emitted-light measurement)", cur, mx, power)
		if actual, err := c.readInt(b + "/actual_brightness"); err == nil {
			r.Info(name+"-actual", "driver readback %d", actual)
		}
	}
	r.Skip("frontlight-sweep", "brightness has a live policy owner; no automatic writes")
	r.Skip("panel-visible", "no physical observation/TE measurement; DCS reads avoided because a timeout can wedge the panel")
}
