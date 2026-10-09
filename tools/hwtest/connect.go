package main

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

func init() {
	register(60, "wifi", "MT7902 Wi-Fi link and optional explicit-target reachability", checkWiFi)
	register(65, "bluetooth", "MT7902 Bluetooth controller (no discovery or pairing)", checkBluetooth)
	register(70, "usb", "UDC, configfs gadget, Type-C role, host device count", checkUSB)
}

// Connectivity checks never print addresses, SSIDs, BSSIDs or USB peer names.
// A relocated root must not query live interfaces, open sockets or wait for USB.
func filepathRootIsSlash(c *Ctx) bool { return c.Root == "" || filepath.Clean(c.Root) == "/" }

func connectivityPresent(c *Ctx, r *Reporter, name, path string) bool {
	resolved, err := c.readPath(path)
	if err == nil {
		_, err = os.Stat(resolved)
	}
	if err == nil {
		return true
	}
	if errors.Is(err, os.ErrNotExist) {
		r.Fail(name, "required interface missing")
	} else if errors.Is(err, os.ErrPermission) {
		r.Skip(name, "interface inspection denied")
	} else {
		r.Warn(name, "could not inspect interface")
	}
	return false
}

func connectivityRead(c *Ctx, r *Reporter, name, path string) (string, bool) {
	v, err := c.read(path)
	if err != nil {
		if errors.Is(err, os.ErrPermission) {
			r.Skip(name, "read permission denied")
		} else {
			r.Fail(name, "could not read %s", path)
		}
		return "", false
	}
	return v, true
}

func connectivityCounter(c *Ctx, r *Reporter, name, path string) (int64, bool) {
	v, err := c.readInt(path)
	if err != nil || v < 0 {
		if errors.Is(err, os.ErrPermission) {
			r.Skip(name, "read permission denied")
		} else {
			r.Fail(name, "could not read a nonnegative counter from %s", path)
		}
		return 0, false
	}
	return v, true
}

// Require a literal IP and numeric port: resolving hostnames could send DNS
// traffic outside the socket's wlan0 binding. No gateway or public-IP fallback.
func wifiNetworkTarget(target string) (string, error) {
	host, port, err := net.SplitHostPort(target)
	if err != nil || net.ParseIP(host) == nil {
		return "", errors.New("network target must be a literal IP:port (IPv6 in brackets); DNS is not used")
	}
	for _, digit := range port {
		if digit < '0' || digit > '9' {
			return "", errors.New("network target must use a numeric TCP port from 1 to 65535")
		}
	}
	p, err := strconv.Atoi(port)
	if err != nil || p < 1 || p > 65535 {
		return "", errors.New("network target must use a numeric TCP port from 1 to 65535")
	}
	return net.JoinHostPort(host, strconv.Itoa(p)), nil
}

func wifiDial(ctx context.Context, target string) error {
	d := net.Dialer{
		Timeout: 2 * time.Second,
		Control: func(_, _ string, raw syscall.RawConn) error {
			var bindErr error
			if err := raw.Control(func(fd uintptr) {
				bindErr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, "wlan0")
			}); err != nil {
				return err
			}
			return bindErr // Never connect if interface binding fails.
		},
	}
	conn, err := d.DialContext(ctx, "tcp", target)
	if err != nil {
		return err
	}
	return conn.Close() // The probe sends no application payload.
}

func checkWiFi(c *Ctx, r *Reporter) {
	const wl = "/sys/class/net/wlan0"
	if !connectivityPresent(c, r, "wlan0", wl) {
		return
	}
	driver, err := os.Readlink(c.path(wl + "/device/driver"))
	if err != nil {
		if errors.Is(err, os.ErrPermission) {
			r.Skip("driver", "driver inspection denied")
		} else {
			r.Warn("driver", "could not read driver symlink")
		}
	} else if filepath.Base(driver) != "mt7921s" {
		r.Fail("driver", "wlan0 is not bound to mt7921s")
	} else {
		r.Pass("driver", "mt7921s")
	}
	op, readable := connectivityRead(c, r, "link", wl+"/operstate")
	up := readable && op == "up"
	if readable {
		if up {
			r.Pass("link", "operstate up (does not prove peer reachability)")
		} else if op == "unknown" || op == "notpresent" || op == "down" || op == "lowerlayerdown" || op == "testing" || op == "dormant" {
			r.Warn("link", "interface is not operationally up")
		} else {
			r.Fail("link", "unrecognized operstate value")
		}
	}
	if filepathRootIsSlash(c) {
		ifc, err := net.InterfaceByName("wlan0")
		if err != nil {
			r.Warn("addresses", "could not inspect wlan0 addresses")
		} else if as, err := ifc.Addrs(); err != nil {
			r.Warn("addresses", "could not read wlan0 addresses")
		} else {
			v4, v6 := 0, 0
			for _, a := range as {
				ip, _, err := net.ParseCIDR(a.String())
				if err != nil {
					continue
				}
				if ip.To4() != nil {
					v4++
				} else if ip.To16() != nil {
					v6++
				}
			}
			r.Info("addresses", "%d IPv4 and %d IPv6 address(es) assigned; identifiers omitted", v4, v6)
		}
	} else {
		r.Skip("addresses", "live interface inspection disabled for a relocated root")
	}
	for _, n := range []string{"rx_bytes", "tx_bytes", "rx_errors", "tx_errors"} {
		if v, ok := connectivityCounter(c, r, n, wl+"/statistics/"+n); ok {
			r.Info(n, "%d since boot", v)
		}
	}
	if c.NetworkTarget == "" {
		r.Skip("reachability", "requires an explicit -network-target; -active never probes the network")
		return
	}
	if !filepathRootIsSlash(c) {
		r.Skip("reachability", "network probes disabled for a relocated root")
		return
	}
	target, err := wifiNetworkTarget(c.NetworkTarget)
	if err != nil {
		r.Skip("reachability", "%s", err)
		return
	}
	if !up {
		r.Skip("reachability", "wlan0 link is unavailable")
		return
	}
	ctx := c.Cancel
	if ctx == nil {
		ctx = context.Background()
	}
	err = wifiDial(ctx, target)
	switch {
	case err == nil:
		r.Pass("reachability", "explicit TCP target accepted a connection via wlan0 (no payload)")
	case errors.Is(err, syscall.EPERM), errors.Is(err, syscall.EACCES):
		r.Skip("reachability", "insufficient privilege to bind the probe to wlan0; no unbound retry")
	case errors.Is(err, context.Canceled):
		r.Skip("reachability", "probe cancelled")
	case errors.Is(err, syscall.ECONNREFUSED):
		r.Pass("reachability", "TCP refusal received via wlan0; service availability not established")
	default:
		// net.OpError includes the target: do not copy it into public reports.
		r.Warn("reachability", "explicit TCP probe via wlan0 did not complete within its limit or encountered a socket error")
	}
}

// hciDevInfo mirrors struct hci_dev_info; the controller address is inspected
// only for an all-zero value and is never included in results.
type hciDevInfo struct {
	DevID  uint16
	Name   [8]byte
	Bdaddr [6]byte
	Flags  uint32
	Rest   [72]byte
}

func hciInfo(id int) (hciDevInfo, error) {
	var di hciDevInfo
	fd, err := syscall.Socket(31, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, 1) // AF_BLUETOOTH, BTPROTO_HCI
	if err != nil {
		return di, err
	}
	defer syscall.Close(fd)
	di.DevID = uint16(id)
	if err := ioctl(uintptr(fd), 0x800448d3, unsafe.Pointer(&di)); err != nil { // HCIGETDEVINFO (read-only)
		return di, err
	}
	return di, nil
}

func checkBluetooth(c *Ctx, r *Reporter) {
	const hci = "/sys/class/bluetooth/hci0"
	if !connectivityPresent(c, r, "hci0", hci) {
		return
	}
	target, err := os.Readlink(c.path(hci))
	if err != nil {
		r.Warn("transport", "could not read controller symlink")
	} else if strings.Contains(target, "mmc") {
		r.Pass("transport", "controller sits on the SDIO bus")
	} else {
		r.Warn("transport", "controller symlink does not identify an SDIO transport")
	}
	found := false
	for _, rf := range c.glob("/sys/class/rfkill/rfkill*") {
		t, ok := connectivityRead(c, r, "rfkill-type", rf+"/type")
		if !ok || t != "bluetooth" {
			continue
		}
		found = true
		soft, softOK := connectivityCounter(c, r, "rfkill-soft", rf+"/soft")
		hard, hardOK := connectivityCounter(c, r, "rfkill-hard", rf+"/hard")
		if !softOK || !hardOK {
			continue
		}
		if soft > 1 || hard > 1 {
			r.Fail("rfkill", "invalid block-state value")
		} else if soft != 0 || hard != 0 {
			r.Warn("rfkill", "blocked (soft=%d hard=%d); blocking does not establish a malfunction", soft, hard)
		} else {
			r.Pass("rfkill", "not blocked")
		}
	}
	if !found {
		r.Fail("rfkill", "no readable Bluetooth rfkill entry")
	}
	if !filepathRootIsSlash(c) {
		r.Skip("hci-state", "live controller ioctl disabled for a relocated root")
	} else if di, err := hciInfo(0); err != nil {
		if errors.Is(err, syscall.EPERM) || errors.Is(err, syscall.EACCES) {
			r.Skip("hci-state", "permission denied for read-only controller ioctl")
		} else {
			r.Warn("hci-state", "read-only controller ioctl failed")
		}
	} else {
		up, running := di.Flags&1 != 0, di.Flags&4 != 0
		switch {
		case !up || !running:
			r.Warn("hci-state", "UP=%v RUNNING=%v; administratively down or setup incomplete (not malfunction proof)", up, running)
		case di.Bdaddr == [6]byte{}:
			r.Fail("hci-state", "controller address is unset (possible firmware setup failure)")
		default:
			r.Pass("hci-state", "UP and RUNNING; controller address set (identifier omitted)")
		}
	}
	r.Skip("discovery", "not performed: read-only checks never change Bluetooth discovery state")
	r.Skip("pairing", "pairing and A2DP require a separately authorized peer test")
}

func checkUSB(c *Ctx, r *Reporter) {
	udc := c.glob("/sys/class/udc/*")
	if len(udc) == 0 {
		r.Fail("udc", "no UDC registered")
	} else if st, ok := connectivityRead(c, r, "udc", udc[0]+"/state"); ok {
		if knownUDCState(st) {
			r.Info("udc", "state %s", st)
		} else {
			r.Fail("udc", "unrecognized UDC state")
		}
	}
	// Shallow reads only. Never unbind or recursively walk configfs.
	const g = "/sys/kernel/config/usb_gadget/g1"
	resolved, inspectErr := c.readPath(g)
	if inspectErr == nil {
		_, inspectErr = os.Stat(resolved)
	}
	if inspectErr != nil {
		if errors.Is(inspectErr, os.ErrPermission) {
			r.Skip("gadget", "gadget inspection denied")
		} else {
			r.Warn("gadget", "g1 unavailable (configfs unmounted or gadget not created)")
		}
	} else if u, ok := connectivityRead(c, r, "gadget", g+"/UDC"); ok {
		if u == "" {
			r.Fail("gadget", "g1 exists but is unbound: it must stay bound, including in host mode")
		} else {
			r.Pass("gadget", "g1 bound (including in host mode)")
		}
	}
	if car, ok := connectivityRead(c, r, "usb0", "/sys/class/net/usb0/carrier"); ok {
		switch car {
		case "0":
			r.Info("usb0", "present, no carrier")
		case "1":
			r.Info("usb0", "present, carrier detected")
		default:
			r.Fail("usb0", "unrecognized carrier value")
		}
	}
	if dr, ok := connectivityRead(c, r, "data-role", "/sys/class/typec/port0/data_role"); ok {
		switch {
		case dr == "host", strings.Contains(dr, "[host]"):
			r.Info("data-role", "host")
		case dr == "device", strings.Contains(dr, "[device]"):
			r.Info("data-role", "device")
		default:
			r.Fail("data-role", "active role unavailable")
		}
	}
	count := 0
	for _, d := range c.glob("/sys/bus/usb/devices/[0-9]*-[0-9]*") {
		if !strings.Contains(filepath.Base(d), ":") {
			count++
		}
	}
	r.Info("usb-devices", "%d enumerated device(s); peer identifiers omitted", count)
	if !c.Interactive {
		r.Skip("host-link", "requires -interactive (plug a PC to observe ECM)")
		return
	}
	if !filepathRootIsSlash(c) {
		r.Skip("host-link", "interactive wait disabled for a relocated root")
		return
	}
	if len(udc) == 0 {
		r.Skip("host-link", "no UDC to observe")
		return
	}
	if c.Cancel != nil && c.Cancel.Err() != nil {
		r.Skip("host-link", "interactive wait cancelled")
		return
	}
	c.say("Connect the tablet to a PC with a USB data cable now (45 s, Ctrl-C cancels)...")
	waitUSBHost(c, r, udc[0]+"/state", "/sys/class/net/usb0/carrier", 45*time.Second)
}

// waitUSBHost only observes existing interfaces. Keeping the wait separate lets
// fixtures exercise timeout and cancellation without opening live devices.
func waitUSBHost(c *Ctx, r *Reporter, statePath, carrierPath string, timeout time.Duration) {
	ctx := c.Cancel
	if ctx == nil {
		ctx = context.Background()
	}
	if ctx.Err() != nil {
		r.Skip("host-link", "interactive wait cancelled")
		return
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			r.Skip("host-link", "interactive wait cancelled")
			return
		}
		st, stateOK := connectivityRead(c, r, "host-link-state", statePath)
		car, carrierOK := connectivityRead(c, r, "host-link-carrier", carrierPath)
		if !stateOK || !carrierOK {
			r.Skip("host-link", "cannot observe UDC state and ECM carrier")
			return
		}
		if !knownUDCState(st) || (car != "0" && car != "1") {
			r.Fail("host-link", "invalid UDC state or carrier value; link not established")
			return
		}
		if st == "configured" && car == "1" {
			r.Pass("host-link", "host configured the gadget and ECM has carrier; SSH still needs an independent PC-side test")
			return
		}
		delay := time.Until(deadline)
		if delay > 500*time.Millisecond {
			delay = 500 * time.Millisecond
		}
		if !c.paused(delay) {
			r.Skip("host-link", "interactive wait cancelled")
			return
		}
	}
	r.Fail("host-link", "no configured gadget with ECM carrier observed within %s", timeout)
}

func knownUDCState(s string) bool {
	switch s {
	case "not attached", "attached", "powered", "reconnecting", "unauthenticated", "default", "addressed", "configured", "suspended":
		return true
	default:
		return false
	}
}
