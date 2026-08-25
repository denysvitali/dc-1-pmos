package installerinit

import (
	"fmt"
	"io"
	"time"
)

// The display gate, as an ordered list of steps rather than a straight line of
// code, so the ORDER can be asserted in a test. That order is the part that
// cost boot cycles to learn, and it is not obvious from the outside:
//
//   - The DC-1 panel is held OFF at boot. The panel driver parks its probe
//     behind module parameters until something gates them on at runtime.
//     Opening them EARLY, during boot, does not boot at all -- LK falls back
//     to the other slot -- so this must stay a runtime step.
//   - /dev/fb0 does not reach the glass on this panel: two maximally different
//     framebuffers written through the fbdev emulation produced
//     photographically identical panels. Only a DRM atomic commit lights it.
//   - GCE/CMDQ is bound BEFORE the panel gate. Opening the panel first makes
//     GCE registration pull the whole dependent DRM chain in synchronously and
//     can wedge the interconnect.
//   - The kernel console is quieted before the display controller changes
//     owners, so a console cannot repaint the stale scanout underneath us.
//
// Nothing here touches storage: the gate is module parameters and
// deferred-probe pokes, and it resets on every reboot.
const (
	panelParams = "/sys/module/panel_novatek_nt36523/parameters"
	skipClient  = "/sys/module/mediatek_drm/parameters/jagar_skip_drm_client"
	gceParam    = "/sys/module/mtk_cmdq_mailbox/parameters/jagar_mt6789_probe_stage"
	dsiDevice   = "/sys/bus/mipi-dsi/devices/14013000.dsi.0"
	prodSeq     = "/sys/module/panel_novatek_nt36523/parameters/jagar_production_sequence"
	probeStage  = "/sys/module/panel_novatek_nt36523/parameters/jagar_probe_stage"
	cardNode    = "/dev/dri/card0"
	backlight   = "/sys/class/backlight/lcd-backlight/brightness"
)

// The GCE/CMDQ platform device is named 10228000.gce by the stock tree LK's
// FDT comes from and 10228000.mailbox by the mainline one; which one a unit
// shows depends on its stock-firmware vintage, not on anything we flash. Both
// name the same device, and the node exists before its driver probes, so
// resolving it here keeps one bad guess from failing the whole gate -- which,
// through acquireDisplay, failed the entire installer bring-up.
var gceCandidates = []string{"10228000.gce", "10228000.mailbox"}

func gceNode(ops Ops) string {
	for _, node := range gceCandidates {
		if ops.Exists("/sys/bus/platform/devices/" + node) {
			return node
		}
	}
	// Neither visible (or sysfs not populated yet): stay on the stock name
	// the C gate was proven with.
	return gceCandidates[0]
}

func gceDriverPath(node string) string {
	return "/sys/bus/platform/devices/" + node + "/driver"
}

// GateStep is one action in the sequence. Exactly one of Write/WaitFor is set.
type GateStep struct {
	// Why records what the step is for; it is printed on failure, so a boot
	// log says which stage of the gate died rather than just "gate failed".
	Why string

	Path  string
	Value string // for a write

	WaitFor time.Duration // for a wait; Path is what must appear

	// Optional means a failure is logged and stepped over. Used only where
	// the C also ignored the result.
	Optional bool

	// SkipIfExists short-circuits the step when Path is already there (the
	// GCE bind, which must not be repeated if the driver already bound).
	SkipIfExists string
}

// GateSequence is the gate in the order the C performed it, parameterized by
// the resolved GCE node name ("10228000.gce" or "10228000.mailbox"). Kept as
// data so a test can assert the order without a panel: get this wrong and the
// device does not boot, which is not a thing to discover on hardware.
func GateSequence(gce string) []GateStep {
	gceDriver := "/sys/bus/platform/devices/" + gce + "/driver"
	return []GateStep{
		{
			Why:  "tell mediatek-drm to skip its intermediate DRM client, so no fbdev helper performs the first modeset and the first real KMS client (us) gets the panel",
			Path: skipClient, Value: "Y\n",
		},
		{
			Why:  "bind GCE/CMDQ before the panel gate: opening the panel first pulls the dependent DRM chain in synchronously and can wedge the interconnect",
			Path: gceParam, Value: "4\n", SkipIfExists: gceDriver,
		},
		{
			Why:  "poke the deferred probe for GCE",
			Path: "/sys/bus/platform/drivers_probe", Value: gce + "\n",
			SkipIfExists: gceDriver,
		},
		{
			Why:  "GCE must actually bind before the panel is touched",
			Path: gceDriver, WaitFor: 5 * time.Second, SkipIfExists: gceDriver,
		},
		{
			Why:  "the DSI panel device has to enumerate before it can be gated on",
			Path: dsiDevice, WaitFor: 15 * time.Second,
		},
		{
			Why:  "quieten the kernel console before the display controller changes owners, so nothing repaints the stale scanout",
			Path: "/proc/sys/kernel/printk", Value: "1 4 1 7\n", Optional: true,
		},
		{
			Why:  "power the panel",
			Path: prodSeq, Value: "Y\n",
		},
		{
			Why:  "release the parked probe",
			Path: probeStage, Value: "3\n",
		},
		{
			Why:  "poke the deferred probe for the panel",
			Path: "/sys/bus/mipi-dsi/drivers_probe", Value: "14013000.dsi.0\n",
		},
		{
			Why:  "the DRM node is the proof the gate opened",
			Path: cardNode, WaitFor: 15 * time.Second,
		},
	}
}

// OpenGate runs GateSequence against ops. It returns an error naming the step
// that failed, because "gate failed" alone has cost debugging time before.
func OpenGate(ops Ops, log io.Writer) error {
	if !ops.Exists(panelParams) {
		return fmt.Errorf("no panel driver at %s (wrong kernel?)", panelParams)
	}
	gce := gceNode(ops)
	for _, step := range GateSequence(gce) {
		if step.SkipIfExists != "" && ops.Exists(step.SkipIfExists) {
			continue
		}
		var err error
		switch {
		case step.WaitFor > 0:
			err = ops.WaitFor(step.Path, step.WaitFor)
		default:
			err = ops.WriteFile(step.Path, step.Value)
		}
		if err == nil {
			continue
		}
		if step.Optional {
			fmt.Fprintf(log, "gate: skipped (%s): %v\n", step.Why, err)
			continue
		}
		return fmt.Errorf("%s: %w", step.Why, err)
	}
	return nil
}
