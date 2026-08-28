package installerinit

import (
	"errors"
	"fmt"
	"io"
	"path"
)

// The composite USB gadget: two CDC-ACM serial functions (ttyGS0 = one-way
// kmsg stream, ttyGS1 = interactive shell) plus CDC-ECM ethernet (usb0, the
// installer transfer channel).
//
// ECM rather than RNDIS: the host side is Linux (cdc_ether) and RNDIS is
// deprecated. The MACs are fixed so the host does not see a new interface
// every boot -- the host installer finds the link by the host-side MAC
// 02:1a:11:00:00:01, so changing it breaks dc1-install.sh.
const (
	gadgetRoot = "/sys/kernel/config/usb_gadget/g1"
	HostMAC    = "02:1a:11:00:00:01"
	DeviceMAC  = "02:1a:11:00:00:02"
)

// UDCCandidates are the names the MTU3 driver actually registers on this SoC.
// rc.sh retries with the real name from /sys/class/udc if every guess misses,
// so a failure here is not final.
func UDCCandidates() []string {
	return []string{
		"musb-hdrc.4.auto",
		"musb-hdrc.1.auto",
		"musb-hdrc.0.auto",
		"11201000.usb",
		"11200000.usb",
	}
}

// gadgetNode is one configfs entry: a directory, a file write, or a link.
type gadgetNode struct {
	Dir   string // relative to gadgetRoot
	File  string // relative to gadgetRoot
	Value string
	Link  string // symlink target, relative to gadgetRoot
	As    string // symlink name, relative to gadgetRoot
}

// GadgetNodes is the configfs shape as data, so the test can assert it without
// a configfs mount. Order matters: configfs requires the directory before its
// attributes, and every function before the config links to it.
func GadgetNodes() []gadgetNode {
	return []gadgetNode{
		{File: "idVendor", Value: "0x18d1\n"},
		{File: "idProduct", Value: "0x4ee7\n"},
		{Dir: "strings/0x409"},
		{File: "strings/0x409/manufacturer", Value: "daylight\n"},
		{File: "strings/0x409/product", Value: "dc1-installer\n"},
		{File: "strings/0x409/serialnumber", Value: "dc1-installer\n"},
		{Dir: "configs/c.1"},
		{Dir: "configs/c.1/strings/0x409"},
		{File: "configs/c.1/strings/0x409/configuration", Value: "acm+ecm\n"},
		{Dir: "functions/acm.0"},
		{Dir: "functions/acm.1"},
		{Dir: "functions/ecm.0"},
		{File: "functions/ecm.0/dev_addr", Value: DeviceMAC + "\n"},
		{File: "functions/ecm.0/host_addr", Value: HostMAC + "\n"},
		{Link: "functions/acm.0", As: "configs/c.1/acm.0"},
		{Link: "functions/acm.1", As: "configs/c.1/acm.1"},
		{Link: "functions/ecm.0", As: "configs/c.1/ecm.0"},
	}
}

// Gadget brings the gadget up and binds it to a UDC.
func Gadget(ops Ops, log io.Writer) error {
	if err := ops.Mkdir(gadgetRoot, 0o755); err != nil {
		return fmt.Errorf("no configfs usb_gadget (USB_CONFIGFS=m, module not loaded?): %w", err)
	}
	for _, n := range GadgetNodes() {
		var err error
		switch {
		case n.Dir != "":
			err = ops.Mkdir(path.Join(gadgetRoot, n.Dir), 0o755)
		case n.Link != "":
			err = ops.Symlink(path.Join(gadgetRoot, n.Link), path.Join(gadgetRoot, n.As))
		default:
			err = ops.WriteFile(path.Join(gadgetRoot, n.File), n.Value)
		}
		if err != nil {
			// Individually non-fatal, exactly as in the C: a partially
			// built gadget can still bind, and rc.sh gets another go.
			fmt.Fprintf(log, "gadget: %v\n", err)
		}
	}

	if !ops.Exists("/sys/class/udc") {
		return errors.New("no /sys/class/udc -- MTU3 did not register a UDC")
	}
	for _, udc := range UDCCandidates() {
		if err := ops.WriteFile(path.Join(gadgetRoot, "UDC"), udc); err == nil {
			fmt.Fprintf(log, "gadget: bound UDC %s\n", udc)
			return nil
		}
	}
	return errors.New("UDC bind failed for every candidate")
}
