package main

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func connectFixture(t *testing.T) *Ctx {
	t.Helper()
	return &Ctx{Root: t.TempDir(), Cancel: context.Background(), Out: io.Discard}
}

func connectFixtureFile(t *testing.T, c *Ctx, path, value string) {
	t.Helper()
	p := c.path(path)
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(value), 0644); err != nil {
		t.Fatal(err)
	}
}

func connectFixtureLink(t *testing.T, c *Ctx, path, target string) {
	t.Helper()
	p := c.path(path)
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, p); err != nil {
		t.Fatal(err)
	}
}

func connectResult(t *testing.T, r *Reporter, name string, status Status) {
	t.Helper()
	for _, result := range r.results {
		if result.Name == name && result.Status == status {
			return
		}
	}
	t.Fatalf("missing %s %s in %#v", status, name, r.results)
}

func TestWiFiNetworkTarget(t *testing.T) {
	for _, s := range []string{"192.0.2.1:443", "[2001:db8::1]:443"} {
		if _, err := wifiNetworkTarget(s); err != nil {
			t.Errorf("valid numeric target rejected: %v", err)
		}
	}
	for _, s := range []string{"", "example.com:443", "192.0.2.1:http", "192.0.2.1:+443", "192.0.2.1:-443", "192.0.2.1:0", "192.0.2.1:65536", "[fe80::1%wlan0]:443", "192.0.2.1"} {
		if _, err := wifiNetworkTarget(s); err == nil {
			t.Errorf("unsafe or invalid target accepted: %q", s)
		}
	}
}

func TestWiFiActiveRemainsPassive(t *testing.T) {
	c := connectFixture(t)
	c.Active = true
	connectFixtureFile(t, c, "/sys/class/net/wlan0/operstate", "up")
	connectFixtureLink(t, c, "/sys/class/net/wlan0/device/driver", "/drivers/mt7921s")
	for _, n := range []string{"rx_bytes", "tx_bytes", "rx_errors", "tx_errors"} {
		connectFixtureFile(t, c, "/sys/class/net/wlan0/statistics/"+n, "0")
	}
	r := &Reporter{}
	checkWiFi(c, r)
	connectResult(t, r, "reachability", Skip)
	connectResult(t, r, "addresses", Skip)
	connectResult(t, r, "driver", Pass)
	c.NetworkTarget = "192.0.2.1:443"
	r = &Reporter{}
	checkWiFi(c, r)
	connectResult(t, r, "reachability", Skip)
}

func TestWiFiReadErrorsNotZeroCounters(t *testing.T) {
	c := connectFixture(t)
	connectFixtureFile(t, c, "/sys/class/net/wlan0/statistics/rx_bytes", "not an integer")
	r := &Reporter{}
	checkWiFi(c, r)
	connectResult(t, r, "link", Fail)
	connectResult(t, r, "rx_bytes", Fail)
	connectResult(t, r, "tx_bytes", Fail)
	for _, result := range r.results {
		if result.Name == "rx_bytes" && result.Status == Info {
			t.Fatal("invalid counter reported as measured data")
		}
	}
}

func TestBluetoothActiveDoesNotDiscover(t *testing.T) {
	c := connectFixture(t)
	c.Active = true
	connectFixtureFile(t, c, "/sys/devices/mmc/controller/present", "1")
	connectFixtureLink(t, c, "/sys/class/bluetooth/hci0", c.path("/sys/devices/mmc/controller"))
	connectFixtureFile(t, c, "/sys/class/rfkill/rfkill0/type", "bluetooth")
	connectFixtureFile(t, c, "/sys/class/rfkill/rfkill0/soft", "garbled")
	connectFixtureFile(t, c, "/sys/class/rfkill/rfkill0/hard", "0")
	r := &Reporter{}
	checkBluetooth(c, r)
	connectResult(t, r, "discovery", Skip)
	connectResult(t, r, "hci-state", Skip)
	connectResult(t, r, "rfkill-soft", Fail)
	for _, result := range r.results {
		if result.Name == "rfkill" && result.Status == Pass {
			t.Fatal("unreadable rfkill state was reported as unblocked")
		}
	}
}

func TestBluetoothBlockedIsWarning(t *testing.T) {
	for _, states := range [][2]string{{"1", "0"}, {"0", "1"}} {
		c := connectFixture(t)
		connectFixtureFile(t, c, "/sys/devices/mmc/controller/present", "1")
		connectFixtureLink(t, c, "/sys/class/bluetooth/hci0", c.path("/sys/devices/mmc/controller"))
		connectFixtureFile(t, c, "/sys/class/rfkill/rfkill0/type", "bluetooth")
		connectFixtureFile(t, c, "/sys/class/rfkill/rfkill0/soft", states[0])
		connectFixtureFile(t, c, "/sys/class/rfkill/rfkill0/hard", states[1])
		r := &Reporter{}
		checkBluetooth(c, r)
		connectResult(t, r, "rfkill", Warn)
		for _, result := range r.results {
			if result.Status == Fail {
				t.Fatalf("administrative blocking reported as failure: %#v", result)
			}
		}
	}
}

func TestUSBPeerIdentifiersOmitted(t *testing.T) {
	c := connectFixture(t)
	connectFixtureFile(t, c, "/sys/class/udc/controller/state", "configured")
	connectFixtureFile(t, c, "/sys/kernel/config/usb_gadget/g1/UDC", "controller")
	connectFixtureFile(t, c, "/sys/class/net/usb0/carrier", "1")
	connectFixtureFile(t, c, "/sys/class/typec/port0/data_role", "host [device]")
	connectFixtureFile(t, c, "/sys/bus/usb/devices/1-1/product", "PRIVATE-PEER-NAME")
	connectFixtureFile(t, c, "/sys/bus/usb/devices/1-1/serial", "PRIVATE-SERIAL")
	r := &Reporter{}
	checkUSB(c, r)
	connectResult(t, r, "gadget", Pass)
	connectResult(t, r, "host-link", Skip)
	for _, result := range r.results {
		if strings.Contains(result.Detail, "PRIVATE") || strings.Contains(result.Detail, "1-1") {
			t.Fatalf("peer identifier leaked: %#v", result)
		}
	}
}

func TestUSBUnreadableStateNotPass(t *testing.T) {
	c := connectFixture(t)
	connectFixtureFile(t, c, "/sys/kernel/config/usb_gadget/g1/other", "1")
	r := &Reporter{}
	checkUSB(c, r)
	connectResult(t, r, "gadget", Fail)
	connectResult(t, r, "usb0", Fail)
}

func TestUSBWaitCancelled(t *testing.T) {
	c := connectFixture(t)
	connectFixtureFile(t, c, "/state", "not attached")
	connectFixtureFile(t, c, "/carrier", "0")
	ctx, cancel := context.WithCancel(context.Background())
	c.Cancel = ctx
	defer cancel()
	timer := time.AfterFunc(20*time.Millisecond, cancel)
	defer timer.Stop()
	r := &Reporter{}
	start := time.Now()
	waitUSBHost(c, r, "/state", "/carrier", 45*time.Second)
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("cancellation took %s", elapsed)
	}
	connectResult(t, r, "host-link", Skip)
}

func TestUSBWaitMissingOrInvalidRead(t *testing.T) {
	for _, state := range []string{"", "invalid"} {
		c := connectFixture(t)
		if state != "" {
			connectFixtureFile(t, c, "/state", state)
		}
		connectFixtureFile(t, c, "/carrier", "1")
		r := &Reporter{}
		waitUSBHost(c, r, "/state", "/carrier", time.Second)
		for _, result := range r.results {
			if result.Name == "host-link" && result.Status == Pass {
				t.Fatal("missing or invalid read reported as a configured link")
			}
		}
	}
}
