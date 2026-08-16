// Package installerinit is PID 1 of the DC-1 "installation mode" initramfs.
//
// Single purpose: bring the device to a state where the host-side installer
// (installer/host/dc1-install.sh) can reach it over the USB cable fastboot
// already used, and show the user what is happening on the panel.
//
// It does four things and then loops forever:
//
//  1. mount proc / sysfs / devtmpfs / configfs
//  2. bring up the USB gadget (2x CDC-ACM serial + CDC-ECM ethernet)
//  3. start /etc/rc.sh (busybox second stage: network, shells, installd)
//  4. paint a status screen from /tmp/installer-status
//
// Hardware facts encoded here cost boot cycles to learn; do not re-derive
// them:
//
//   - devtmpfs is NOT auto-mounted on an initramfs boot. devtmpfs_mount() is
//     only called from prepare_namespace(), which the kernel skips when it
//     runs rdinit. /init must mount it or /dev/kmsg and /dev/dri/card0 never
//     appear at all.
//   - the panel is dark at boot and only lights via a DRM atomic commit after
//     the runtime gate is opened (see gate.go). /dev/fb0 and the LK scanout
//     buffer are dead instruments on this panel.
//   - rc.sh is started BEFORE the display is acquired. LK arms a ~31 s
//     hardware watchdog that this kernel does not auto-pet, and rc.sh's first
//     job is to pet it; the gate can spend ~35 s on its GCE/DSI/card0 waits in
//     a pathological case. Acquiring the display first can therefore reset the
//     device. The panel is dark until the gate returns anyway, so waiting
//     costs nothing.
//
// If PID 1 exits the kernel panics, so Run never returns on the device.
package installerinit

import (
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/ask"
	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/pid1"
)

// StatusFile is written by rc.sh and installd as the install progresses; PID 1
// only renders it.
const StatusFile = "/tmp/installer-status"

// DefaultStatus is shown when nothing has written a status yet.
const DefaultStatus = "WAITING FOR HOST"

// Config is the parsed command line.
type Config struct {
	DryRun bool
}

// Main is the `system-init`-style applet entry point for dc1-installer-init.
func Main(args []string, stdout, stderr io.Writer) int {
	var cfg Config
	for _, a := range args {
		switch a {
		case "-n", "--dry-run":
			cfg.DryRun = true
		default:
			fmt.Fprintf(stderr, "dc1-installer-init: unknown argument %q\n", a)
			return 2
		}
	}

	if cfg.DryRun {
		for i, step := range Plan() {
			fmt.Fprintf(stdout, "%d. %s\n", i+1, step)
		}
		return 0
	}

	// Refuse anywhere but PID 1: every mount below is unconditional, it
	// mounts over the running system, and the loop never exits.
	if os.Getpid() != 1 {
		fmt.Fprintf(stderr, "dc1-installer-init: refusing to run: PID %d, not 1.\n", os.Getpid())
		fmt.Fprintln(stderr, "This mounts devtmpfs/proc/sys over the running system and never returns.")
		fmt.Fprintln(stderr, "As PID 1 it would, in order:")
		for i, step := range Plan() {
			fmt.Fprintf(stderr, "  %d. %s\n", i+1, step)
		}
		fmt.Fprintln(stderr, "Run with -n for the same list as a normal exit.")
		return 1
	}

	// A Go PID 1 is killable where the C one was not; see pid1.Shield.
	pid1.Shield()

	Run(SysOps(), stderr)
	return 0 // unreachable on the device
}

// Plan is the boot sequence in words. It is the refusal message and the
// dry-run output, so the ordering is reviewable without reading the code.
func Plan() []string {
	return []string{
		"mount proc on /proc, sysfs on /sys, devtmpfs on /dev, configfs on /sys/kernel/config",
		"open /dev/kmsg and take /dev/tty1 as the console",
		"bring up the CDC-ACM + CDC-ECM USB gadget (ttyGS0 log, ttyGS1 shell, usb0 transfer)",
		"write the initial " + StatusFile,
		"start /etc/rc.sh in the background (it pets the watchdog, which must happen before the display gate)",
		"open the display gate and acquire the panel over DRM (up to ~35 s in the worst case)",
		"loop forever: repaint the status screen, heartbeat to kmsg, reap children",
	}
}

// progress is where every line PID 1 emits goes: its own fds, /dev/kmsg once
// there is one, and every console node, each written independently.
//
// NOT io.MultiWriter: that stops at the first writer that errors, so a dark VT
// or a gadget with no host would silently take the rest of the channels with
// it. init.c's say() wrote each channel with its own unchecked write(2) for
// exactly this reason -- the whole point of the fan-out is that a boot failure
// is legible on whatever channel happens to be alive.
type progress struct {
	ops Ops
	w   []io.Writer
}

func (p *progress) Write(b []byte) (int, error) {
	for _, w := range p.w {
		_, _ = w.Write(b)
	}
	p.ops.Broadcast(string(b))
	return len(b), nil
}

// Run is the boot sequence. It never returns.
func Run(ops Ops, log io.Writer) {
	out := &progress{ops: ops, w: []io.Writer{log}}
	say := func(format string, a ...any) {
		fmt.Fprintf(out, "[dc1-installer] "+format+"\n", a...)
	}

	say("init: entered userspace (installation mode)")
	mountAll(ops)

	if kmsg := ops.OpenKmsg(); kmsg != nil {
		// Everything after this point is visible in dmesg, which is what
		// the USB serial log actually carries.
		out.w = append(out.w, kmsg)
	}
	say("init: proc/sys/dev/configfs mounted")

	// A controlling tty, so our writes and kernel messages coexist.
	_ = ops.GrabTTY("/dev/tty1")

	if err := Gadget(ops, out); err != nil {
		// Not fatal: rc.sh retries the UDC bind with the real name from
		// /sys/class/udc once any staged gadget modules are loaded.
		say("gadget: %v (rc.sh retries)", err)
	}

	// CreateFile, not WriteFile: /tmp is an empty tmpfs at this point and
	// nothing stages the status file, so an O_WRONLY|O_TRUNC open would fail
	// with ENOENT every boot -- a false error line where an operator is
	// scanning for real ones, and no STARTING on the panel.
	if err := ops.CreateFile(StatusFile, "STARTING\n"); err != nil {
		say("init: cannot write %s: %v", StatusFile, err)
	}

	// Second stage first -- see the package comment: rc.sh pets the watchdog
	// and the display gate can outlast it.
	startSecondStage(ops, say)

	surface, err := acquireDisplay(ops, out)
	if err != nil {
		say("fb: no display (%v) -- status only on serial/kmsg", err)
	} else {
		say("fb: acquired via %s", surface.How())
	}

	// paintMu serialises the two things that draw into the one surface: the
	// status painter in loop() and a touch dialog served by the dialog server.
	// A dialog holds it for its whole lifetime, so a TryLock failure in loop()
	// means "a prompt is on screen, do not repaint over it".
	var paintMu sync.Mutex

	if surface != nil {
		run := func(args []string) ask.DialogResponse {
			scr, err := ask.NewScreen(surface)
			if err != nil {
				return ask.DialogResponse{RC: 2, Err: "dc1-ask: no touchscreen"}
			}
			defer scr.Close()
			paintMu.Lock()
			rc, outS, errS := scr.Run(args)
			paintMu.Unlock()
			return ask.DialogResponse{RC: rc, Out: outS, Err: errS}
		}
		go serveDialogs(ask.DialogSocket, run, out)
	}

	loop(ops, surface, &paintMu, out)
}

func mountAll(ops Ops) {
	for _, d := range []string{"/proc", "/sys", "/dev", "/tmp"} {
		_ = ops.Mkdir(d, 0o755)
	}
	_ = ops.Mount("proc", "/proc", "proc", 0, "")
	_ = ops.Mount("sysfs", "/sys", "sysfs", 0, "")
	_ = ops.Mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755")
	_ = ops.Mkdir("/sys/kernel/config", 0o755)
	_ = ops.Mount("configfs", "/sys/kernel/config", "configfs", 0, "")
}

func startSecondStage(ops Ops, say func(string, ...any)) {
	if !ops.Exists("/etc/rc.sh") || !ops.Exists("/bin/busybox") {
		say("init: /etc/rc.sh or /bin/busybox missing -- no installer daemon")
		return
	}
	if _, err := ops.Spawn([]string{"/bin/busybox", "sh", "/etc/rc.sh"}); err != nil {
		say("init: rc.sh spawn FAILED: %v", err)
	}
}

func acquireDisplay(ops Ops, log io.Writer) (Surface, error) {
	if err := OpenGate(ops, log); err != nil {
		return nil, err
	}
	surface, err := ops.Display()
	if err != nil {
		return nil, err
	}
	// The frontlight comes up at 0, so a committed frame is invisible until
	// the white channel is raised.
	_ = ops.WriteFile(backlight, "10\n")
	return surface, nil
}

// loop repaints, heartbeats and reaps forever.
func loop(ops Ops, surface Surface, paintMu *sync.Mutex, log io.Writer) {
	for tick := uint64(0); ; tick++ {
		status, err := ops.ReadFile(StatusFile)
		if err != nil || strings.TrimSpace(status) == "" {
			status = DefaultStatus
		}

		// The touch UI (ask.Screen, run in-process by the dialog server) draws
		// into this same surface. It holds paintMu for the whole time a dialog
		// is up, so a TryLock failure means a prompt is on screen and the
		// status screen must not repaint over it. No DRM master handover: the
		// dialog blits into the buffer already committed, it never modesets.
		if surface != nil && paintMu.TryLock() {
			w, h := surface.Size()
			lines := StatusLines(status)
			surface.Paint(func(pix []byte, stride int) {
				PaintStatus(pix, stride, w, h, lines, tick)
			})
			_ = surface.Blit()
			paintMu.Unlock()
			if tick == 0 {
				fmt.Fprintf(log, "[dc1-installer] DIAG %s\n", surface.DebugLine())
			}
		}

		if tick%15 == 0 {
			fmt.Fprintf(log, "[dc1-installer] tick=%d\n", tick)
		}
		ops.Reap()
		ops.Sleep(time.Second)
	}
}
