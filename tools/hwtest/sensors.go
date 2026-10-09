package main

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"
)

func accelDevice(c *Ctx) string {
	for _, d := range c.glob("/sys/bus/iio/devices/iio:device*") {
		if n, _ := c.read(d + "/name"); n == "mc3416" {
			return d
		}
	}
	return ""
}

func accelSample(c *Ctx, dev string) ([3]float64, error) {
	var v [3]float64
	scale, err := strconv.ParseFloat(readOr(c, dev+"/in_accel_scale", "0"), 64)
	if err != nil || scale <= 0 || math.IsNaN(scale) || math.IsInf(scale, 0) {
		return v, fmt.Errorf("bad in_accel_scale")
	}
	for i, a := range []string{"x", "y", "z"} {
		raw, err := c.readInt(dev + "/in_accel_" + a + "_raw")
		if err != nil {
			return v, err
		}
		v[i] = float64(raw) * scale
		if math.IsNaN(v[i]) || math.IsInf(v[i], 0) {
			return v, fmt.Errorf("nonfinite acceleration")
		}
	}
	return v, nil
}

func readOr(c *Ctx, p, def string) string {
	if s, err := c.read(p); err == nil {
		return s
	}
	return def
}

func norm(v [3]float64) float64 { return math.Sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]) }

// dominant names the axis carrying most of gravity, e.g. "+y".
func dominant(v [3]float64) string {
	best := 0
	for i := range v {
		if math.Abs(v[i]) > math.Abs(v[best]) {
			best = i
		}
	}
	sign := "+"
	if v[best] < 0 {
		sign = "-"
	}
	return sign + string("xyz"[best])
}

func poseAxis(v [3]float64) (string, bool) {
	g := norm(v)
	if g <= 0 || math.IsNaN(g) || math.IsInf(g, 0) {
		return "", false
	}
	largest := math.Max(math.Abs(v[0]), math.Max(math.Abs(v[1]), math.Abs(v[2])))
	return dominant(v), largest/g >= .8
}

func checkSensors(c *Ctx, r *Reporter) {
	dev := accelDevice(c)
	if dev == "" {
		r.Fail("accelerometer", "mc3416 IIO device absent")
	} else {
		s, err := accelSample(c, dev)
		if err != nil {
			r.Fail("accelerometer", "%v", err)
		} else if g := norm(s); g < 8.3 || g > 11.3 {
			r.Warn("accelerometer", "|a| = %.2f m/s^2, expected about 9.81 if stationary (%.2f,%.2f,%.2f); motion or calibration can explain this", g, s[0], s[1], s[2])
		} else {
			r.Pass("accelerometer", "|a| = %.2f m/s^2 (%.2f, %.2f, %.2f)", g, s[0], s[1], s[2])
		}
		if mm, err := c.read(dev + "/in_mount_matrix"); err == nil {
			r.Info("mount-matrix", "%s", strings.ReplaceAll(mm, "\n", " "))
		}
		if err == nil && c.Interactive {
			poseTest(c, r, dev)
		} else if !c.Interactive {
			r.Skip("poses", "needs -interactive")
		}
	}

	var ok, bad int
	for _, a := range c.glob("/sys/bus/iio/devices/iio:device*/in_voltage*_input") {
		if _, err := c.readInt(a); err != nil {
			bad++
		} else {
			ok++
		}
	}
	if ok+bad == 0 {
		r.Warn("adc", "no auxadc channels")
	} else if bad > 0 {
		r.Warn("adc", "%d/%d channels readable", ok, ok+bad)
	} else {
		r.Pass("adc", "%d auxadc channels readable", ok)
	}

	checkI2C(c, r)
}

func poseTest(c *Ctx, r *Reporter, dev string) {
	poses := []string{
		"upright portrait (the side with the buttons up)",
		"rotated a quarter turn clockwise (landscape)",
		"upside down portrait",
		"rotated a quarter turn counter-clockwise (landscape)",
		"flat on a table, screen up",
	}
	got := map[string]string{}
	for _, p := range poses {
		if !c.wait("Hold the tablet " + p + " and keep it still") {
			r.Skip("poses", "operator input ended")
			return
		}
		if !c.paused(700 * time.Millisecond) {
			r.Skip("poses", "interrupted")
			return
		}
		var sum [3]float64
		const n = 10
		for i := 0; i < n; i++ {
			s, err := accelSample(c, dev)
			if err != nil {
				r.Fail("poses", "%v", err)
				return
			}
			for j := range sum {
				sum[j] += s[j] / n
			}
			if !c.paused(50 * time.Millisecond) {
				r.Skip("poses", "interrupted")
				return
			}
		}
		axis, clear := poseAxis(sum)
		if !clear {
			r.Fail("poses", "no clear nonzero gravity axis in %q; hold an axis-aligned stationary pose", p)
			return
		}
		r.Info("pose", "%s -> gravity on %s (%.1f, %.1f, %.1f)", p, axis, sum[0], sum[1], sum[2])
		if prev, dup := got[axis]; dup {
			r.Fail("poses", "%q and %q both read gravity on %s: poses not distinguishable", prev, p, axis)
			return
		}
		got[axis] = p
		if g := norm(sum); g < 8.3 || g > 11.3 {
			r.Warn("pose-magnitude", "|a| = %.2f in %q; magnitude calibration is not established, direction test continues", g, p)
		}
	}
	r.Pass("poses", "5 poses give 5 distinct gravity axes %v (compare with the mount matrix and GNOME's rotation separately)", keys(got))
}

func keys(m map[string]string) []string {
	var k []string
	for a := range m {
		k = append(k, a)
	}
	sort.Strings(k)
	return k
}

// Parts that must stay unbound until separately validated (see CLAUDE.md).
var mustStayUnbound = []string{"rt9471", "bq78z100", "bq27"}

func checkI2C(c *Ctx, r *Reporter) {
	var bound []string
	var unbound []string
	for _, d := range c.glob("/sys/bus/i2c/devices/[0-9]*-00*") {
		id := d[strings.LastIndex(d, "/")+1:]
		name, _ := c.read(d + "/name")
		drv := c.linkBase(d + "/driver")
		if id == "1-0049" && drv != "" {
			r.Fail("i2c-"+id, "unidentified ambient-light/proximity part is bound to %s; it must remain unbound", drv)
		}
		lname := strings.ToLower(name)
		for _, bad := range mustStayUnbound {
			if strings.Contains(lname, bad) && drv != "" {
				r.Fail("i2c-"+id, "%s is bound to %s; it must stay disabled until validated", name, drv)
			}
		}
		if drv == "" {
			unbound = append(unbound, id+":"+name)
		} else {
			bound = append(bound, id+":"+name+"->"+drv)
		}
	}
	r.Info("i2c-bound", "%d clients: %s", len(bound), strings.Join(bound, ", "))
	if len(unbound) > 0 {
		r.Info("i2c-unbound", "%s", strings.Join(unbound, ", "))
	}
	r.Skip("light-sensor", "no ambient-light protocol probe implemented; I2C enumeration does not prove lux/proximity sensing")
}
