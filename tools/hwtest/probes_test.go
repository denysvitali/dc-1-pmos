package main

import (
	"bytes"
	"compress/gzip"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestUnknownLightSensorMustStayUnbound(t *testing.T) {
	c := fixture(t)
	const dev = "/sys/bus/i2c/devices/1-0049"
	put(t, c, dev+"/name", "guessed-light-sensor")
	if err := os.Symlink("/sys/bus/i2c/drivers/guessed-driver", filepath.Join(c.Root, dev, "driver")); err != nil {
		t.Fatal(err)
	}
	r := &Reporter{}
	checkI2C(c, r)
	for _, result := range r.results {
		if result.Name == "i2c-1-0049" && result.Status == Fail {
			return
		}
	}
	t.Fatal("bound unidentified part was not rejected")
}

func TestLoadTemperatureGuard(t *testing.T) {
	for _, temp := range []int64{-2147483648, -20001, 65000, 120000} {
		if loadTemperatureSafe(temp, nil) {
			t.Errorf("accepted unsafe telemetry %d", temp)
		}
	}
	if loadTemperatureSafe(30000, errors.New("unreadable")) || !loadTemperatureSafe(30000, nil) {
		t.Fatal("thermal guard did not distinguish valid reading")
	}
}

func TestRTCAdvanceUsesMeasuredInterval(t *testing.T) {
	for _, tc := range []struct {
		advance int64
		elapsed time.Duration
		want    bool
	}{
		{2, 2100 * time.Millisecond, true},
		{8, 8100 * time.Millisecond, true},
		{0, 2100 * time.Millisecond, false},
		{2, 8100 * time.Millisecond, false},
		{8, 2100 * time.Millisecond, false},
	} {
		if got := rtcAdvanceValid(tc.advance, tc.elapsed); got != tc.want {
			t.Errorf("advance=%d elapsed=%s: got %v want %v", tc.advance, tc.elapsed, got, tc.want)
		}
	}
}

func TestThermalInvalidTelemetry(t *testing.T) {
	for _, temp := range []string{"", "NaN", "-25000", "120000"} {
		c := fixture(t)
		put(t, c, "/sys/class/thermal/thermal_zone0/type", "test")
		put(t, c, "/sys/class/thermal/thermal_zone0/temp", temp)
		r := &Reporter{}
		checkThermal(c, r)
		for _, res := range r.results {
			if res.Status == Pass {
				t.Fatalf("%q passed: %+v", temp, res)
			}
		}
	}
}

func TestCoolingReadErrors(t *testing.T) {
	c := fixture(t)
	for _, n := range []string{"0", "1", "2"} {
		put(t, c, "/sys/class/thermal/cooling_device"+n+"/type", "test")
		put(t, c, "/sys/class/thermal/cooling_device"+n+"/max_state", "10")
	}
	r := &Reporter{}
	checkThermal(c, r)
	for _, res := range r.results {
		if res.Name == "cooling" && res.Status == Pass {
			t.Fatal(res)
		}
	}
}

func TestRunningKernelConfig(t *testing.T) {
	c := fixture(t)
	var b bytes.Buffer
	z := gzip.NewWriter(&b)
	for _, opt := range kconfig {
		z.Write([]byte("CONFIG_" + opt.name + "=y\n"))
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	put(t, c, "/proc/config.gz", "")
	if err := os.WriteFile(c.path("/proc/config.gz"), b.Bytes(), 0644); err != nil {
		t.Fatal(err)
	}
	put(t, c, "/proc/sys/kernel/unprivileged_bpf_disabled", "2")
	r := &Reporter{}
	checkKernelConfig(c, r)
	if len(r.results) != 2 {
		t.Fatal(r.results)
	}
	for _, res := range r.results {
		if res.Status != Pass {
			t.Fatal(res)
		}
	}
}

func TestMissingTelemetryCannotPass(t *testing.T) {
	for _, tc := range []struct {
		name string
		run  func(*Ctx, *Reporter)
	}{
		{"thermal", checkThermal}, {"gpu", checkGPUFreq}, {"sensors", checkSensors}, {"display", checkDisplay},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := &Reporter{}
			tc.run(fixture(t), r)
			for _, res := range r.results {
				if res.Status == Pass {
					t.Fatalf("missing telemetry passed: %+v", res)
				}
			}
		})
	}
}

func TestAccelScale(t *testing.T) {
	c := fixture(t)
	const dev = "/sys/bus/iio/devices/iio:device0"
	for _, a := range []string{"x", "y", "z"} {
		put(t, c, dev+"/in_accel_"+a+"_raw", "100")
	}
	for _, s := range []string{"NaN", "+Inf", "-1", "0", "bad"} {
		put(t, c, dev+"/in_accel_scale", s)
		if _, err := accelSample(c, dev); err == nil {
			t.Errorf("accepted scale %q", s)
		}
	}
	put(t, c, dev+"/in_accel_scale", "0.01")
	v, err := accelSample(c, dev)
	if err != nil || v != [3]float64{1, 1, 1} {
		t.Fatal(v, err)
	}
}

func TestGPUReadErrors(t *testing.T) {
	c := fixture(t)
	put(t, c, "/sys/class/devfreq/0.gpu/cur_freq", "390000000")
	r := &Reporter{}
	checkGPUFreq(c, r)
	for _, res := range r.results {
		if res.Status == Pass {
			t.Fatal(res)
		}
	}
}

func TestFrontlightReadErrors(t *testing.T) {
	c := fixture(t)
	for _, b := range []string{"white", "amber"} {
		put(t, c, "/sys/class/backlight/"+b+"/max_brightness", "255")
	}
	r := &Reporter{}
	checkFrontlight(c, r, c.glob("/sys/class/backlight/*"))
	for _, res := range r.results {
		if res.Status == Pass {
			t.Fatal(res)
		}
	}
}

func TestPoseAxisIndependentOfCalibration(t *testing.T) {
	for _, v := range [][3]float64{{1, -9, 2}, {10, -90, 20}} {
		if axis, ok := poseAxis(v); !ok || axis != "-y" {
			t.Fatalf("%v: axis=%q clear=%v", v, axis, ok)
		}
	}
	for _, v := range [][3]float64{{0, 0, 0}, {1, 1, 1}} {
		if _, ok := poseAxis(v); ok {
			t.Fatalf("accepted ambiguous pose %v", v)
		}
	}
}

func TestDominant(t *testing.T) {
	if dominant([3]float64{1, -9, 2}) != "-y" {
		t.Fatal("wrong axis")
	}
	got := keys(map[string]string{"+z": "flat", "-y": "up"})
	if len(got) != 2 || got[0] != "+z" || got[1] != "-y" {
		t.Fatal(got)
	}
}
