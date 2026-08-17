// Package systeminit is the Go port of installer/src/system/init.c -- PID 1 of
// the DC-1 SYSTEM boot initramfs (the one inside jagar-boot.img, i.e. what
// boots the installed postmarketOS).
//
// NOT YET /init. installer/build.sh still stages the C binary, and this is
// deliberate: the device's only recovery channel runs through boot_a, so an
// unbooted Go PID 1 shipped as /init could cost the way back. This applet
// exists so the port can be exercised and reviewed first; wiring it as /init
// is a separate change, after a Go init has demonstrably booted on hardware.
//
// Job, in order, all fail-closed:
//
//  1. mount proc / sysfs / devtmpfs (devtmpfs is NOT auto-mounted on an
//     initramfs boot)
//  2. bring up a CDC-ACM gadget and a log+shell on it, BEFORE anything can
//     hang, so a hang is observable from the host
//  3. start a watchdog petter that keeps /dev/watchdog open and petted ACROSS
//     the switch_root, forever
//  4. resolve userdata by GPT PARTNAME, require ext4 labelled jagar-root,
//     optional fsck, mount at /mnt/root
//  5. verify, move /dev /proc /sys into the new root, and exec busybox
//     switch_root /mnt/root /sbin/init
//
// ANY failure drops to a rescue shell on the consoles instead of writing
// anything. The petter keeps running in rescue so the operator has more than
// one watchdog period to type.
//
// TWO DIFFERENCES FROM THE C, both forced:
//
//   - The C forked its watchdog petter and debug channels; Go cannot fork
//     without exec, so each is a re-exec of this same binary in a helper role
//     (-helper watchdog|kmsg|shell). They are all started BEFORE switch_root,
//     which is what makes them survive it: a running process keeps its mapped
//     binary even though the initramfs it came from is gone.
//   - Step 4 was /etc/boot.sh. It is in-process here, over
//     internal/partition (the same rules as partlib.sh) plus a direct read of
//     the ext superblock, so the boot path no longer depends on which busybox
//     applets happened to be staged. boot.sh remains the shipped
//     implementation until this one boots.
package systeminit

import (
	"fmt"
	"io"
	"os"
	"time"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/pid1"
)

const (
	busyboxPath = "/bin/busybox"
	gadgetRoot  = "/sys/kernel/config/usb_gadget/g1"
	kmsgTTY     = "/dev/ttyGS0"
	shellTTY    = "/dev/ttyGS1"
)

// rescueConsoles are where a rescue shell is offered. Not ttyGS1: the debug
// channel already carries one, and it is respawned independently.
var rescueConsoles = []string{"/dev/tty1", "/dev/ttyS0", "/dev/console"}

// kernelMounts are moved into the new root, in this order, and rolled back in
// reverse if the handoff fails.
var kernelMounts = []string{"/dev", "/proc", "/sys"}

func say(o Ops, format string, a ...any) { o.Say(Line(fmt.Sprintf(format, a...))) }

// Main is the `system-init` applet entry point.
func Main(args []string, stdout, stderr io.Writer) int {
	cfg, err := ParseArgs(args, stderr)
	if err != nil {
		fmt.Fprintf(stderr, "system-init: %v\n", err)
		return 2
	}
	cfg.Self = selfPath(os.Executable())
	o := &sysOps{stdout: stdout, stderr: stderr}

	if cfg.DryRun {
		fmt.Fprintln(stdout, "system-init: would, in order:")
		for i, step := range Plan() {
			fmt.Fprintf(stdout, "  %d. %s\n", i+1, step)
		}
		return 0
	}

	// Refuse to act unless we genuinely are what we claim to be.
	if cfg.Helper == "" && !initAllowed(os.Getpid()) {
		fmt.Fprintf(stderr, "system-init: refusing to run: PID %d, not 1.\n", os.Getpid())
		fmt.Fprintln(stderr, "As PID 1 it would, in order:")
		for i, step := range Plan() {
			fmt.Fprintf(stderr, "  %d. %s\n", i+1, step)
		}
		fmt.Fprintln(stderr, "Run with -n for the same list as a normal exit.")
		return 1
	}
	if cfg.Helper != "" && !helperAllowed(os.Getppid(), os.Getenv(helperEnv)) {
		fmt.Fprintf(stderr, "system-init: -helper %s is spawned by PID 1, "+
			"not run by hand (parent is PID %d)\n", cfg.Helper, os.Getppid())
		return 1
	}

	if cfg.Helper != "" {
		return runHelper(o, cfg)
	}

	// A Go PID 1 is killable where the C one was not; see pid1.Shield. Only on
	// the init path: the helpers are ordinary children and the C's were
	// killable too.
	pid1.Shield()
	return boot(o, cfg)
}

// runHelper dispatches a helper child, with /dev/kmsg opened FIRST.
//
// The C opened g_kmsg in main() before forking any helper (system/init.c:389
// vs :404), so every forked helper inherited the fd and its say() reached the
// ring buffer. Go cannot fork, so the helper re-execs this binary and starts
// with no kmsg at all -- and the console list Say writes to has no ttyGS0,
// while the ttyGS0 boot log is fed FROM /dev/kmsg. Without this the watchdog
// petter's diagnostics ("no /dev/watchdog", "deadman lease expired", "pet
// failed") reach no channel the host can see, on a device whose only real
// observation channel is /dev/ttyACM0, and they are missing from dmesg on the
// installed system too.
func runHelper(o Ops, cfg Config) int {
	o.OpenKmsg()
	switch cfg.Helper {
	case helperWatchdog:
		return petter(o, cfg)
	case helperKmsg:
		return streamKmsg(o, cfg)
	case helperShell:
		return respawnShell(o, cfg, cfg.TTY)
	}
	return 2
}

// boot is the sequence. It returns only when it has failed; on success it has
// exec'd switch_root and this process no longer exists.
func boot(o Ops, cfg Config) int {
	say(o, "init: system initramfs starting")

	for _, d := range []string{"/proc", "/sys", "/dev", "/tmp", "/mnt", rootMount} {
		_ = o.Mkdir(d, 0o755)
	}
	_ = o.Mount("proc", "/proc", "proc", 0, "")
	_ = o.Mount("sysfs", "/sys", "sysfs", 0, "")
	_ = o.Mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755")

	// Only now is there a /dev/kmsg to say things into.
	o.OpenKmsg()
	say(o, "init: proc/sys/dev mounted")

	// USB debug channel: configfs + ACM gadget + log/shell, BEFORE the rootfs
	// hunt, so a hang there is observable from the host (/dev/ttyACM0 log,
	// /dev/ttyACM1 shell). This is what makes a boot failure diagnosable: the
	// rescue shell below writes only to tty1/ttyS0, which are not reachable
	// over USB.
	_ = o.Mkdir("/sys/kernel/config", 0o755)
	_ = o.Mount("configfs", "/sys/kernel/config", "configfs", 0, "")
	gadget(o)
	spawnHelper(o, cfg, helperKmsg)
	spawnHelper(o, cfg, helperShell)

	// After the gadget, as in the C: the petter's own diagnostics are worth
	// nothing if there is no channel to read them on, and LK's timer is ~31s
	// against configfs writes that take milliseconds.
	spawnHelper(o, cfg, helperWatchdog)

	if st, err := o.Stat(busyboxPath); err != nil || !st.Executable() {
		return rescue(o, cfg, busyboxPath+" missing from initramfs")
	}

	dev, err := findRoot(o)
	if err != nil {
		return rescue(o, cfg, err.Error())
	}
	if err := mountRoot(o, dev); err != nil {
		return rescue(o, cfg, err.Error())
	}

	say(o, "init: switching root from verified device %s", dev)
	moved := 0
	for _, m := range kernelMounts {
		if err := o.MoveMount(m, rootMount+m); err != nil {
			say(o, "init: moving %s into the new root failed: %v", m, err)
			break
		}
		moved++
	}
	if moved == len(kernelMounts) {
		// switch_root only works from PID 1, which is why the pivot lives
		// here and not in a script: a background exec would replace only the
		// script -- a bug the bring-up initramfs actually hit.
		if err := o.Exec(busyboxPath, []string{"switch_root", rootMount, "/sbin/init"}); err != nil {
			say(o, "init: switch_root exec FAILED: %v", err)
		}
	}
	for moved > 0 {
		moved--
		m := kernelMounts[moved]
		_ = o.MoveMount(rootMount+m, m)
	}
	return rescue(o, cfg, "switch_root failed; kernel filesystems rolled back")
}

// findRoot waits for the partition to appear, then decides once. The wait is
// only for the partition: a device that is present but carries the wrong
// filesystem is not going to become right by waiting, and retrying that would
// only delay the rescue shell by a minute.
func findRoot(o Ops) (string, error) {
	var cands []Candidate
	for second := 1; ; second++ {
		var err error
		if cands, err = o.ProbeRoots(); err == nil {
			break
		}
		if second >= rootWaitSeconds {
			return "", fmt.Errorf("userdata partition not found after %ds: %v", second, err)
		}
		if msg, ok := WaitingNotice(second); ok {
			say(o, "%s", msg)
		}
		o.Sleep(time.Second)
	}
	dev, err := SelectRoot(cands)
	if err != nil {
		return "", err
	}
	say(o, "init: userdata resolved: %s (ext4, labelled %s)", dev, rootLabel)
	return dev, nil
}

// mountRoot fscks (if it can), mounts, and proves the result is a filesystem
// worth handing control to. Writes nothing on any failing path.
func mountRoot(o Ops, dev string) error {
	if err := fsck(o, dev); err != nil {
		return err
	}
	if err := o.Mount(dev, rootMount, rootFSType, 0, ""); err != nil {
		return fmt.Errorf("mount of %s failed: %v", dev, err)
	}

	// A successful mount(2) of a device that turned out to be nothing would
	// still leave /mnt/root on the initramfs' own filesystem; compare st_dev
	// rather than trusting the return value alone.
	oldRoot, err1 := o.Stat("/")
	newRoot, err2 := o.Stat(rootMount)
	if err1 != nil || err2 != nil || oldRoot.Dev == newRoot.Dev {
		_ = o.Unmount(rootMount)
		return fmt.Errorf("%s is not a separate filesystem", rootMount)
	}
	if st, err := o.Stat(rootMount + "/sbin/init"); err != nil || !st.Executable() {
		_ = o.Unmount(rootMount)
		return fmt.Errorf("no executable /sbin/init in %s", dev)
	}
	return nil
}

// fsck runs e2fsck -p when it is staged, and is otherwise a documented no-op:
// the filesystem was SHA-256-verified at install time and ext4 journals
// recover ordinary unclean shutdowns. An e2fsck that ran and found something
// it could not correct IS fatal, as it is in boot.sh: mounting a filesystem
// e2fsck refused is how a bad install becomes a corrupted one.
func fsck(o Ops, dev string) error {
	bin := ""
	for _, p := range fsckPaths {
		if st, err := o.Stat(p); err == nil && st.Executable() {
			bin = p
			break
		}
	}
	if bin == "" {
		say(o, "init: e2fsck not in initramfs; skipping fsck "+
			"(ext4 journal + install-time hash verification)")
		return nil
	}
	pid, err := o.Spawn(bin, []string{bin, "-p", dev}, nil, "")
	if err == nil {
		var rc int
		if _, rc, err = o.Wait(pid, true); err == nil {
			if !FsckAcceptable(rc) {
				return fmt.Errorf("e2fsck found uncorrectable errors (rc=%d)", rc)
			}
			say(o, "init: e2fsck clean (rc=%d)", rc)
			return nil
		}
	}
	// Could not run it at all, which is the same position as not staging it.
	say(o, "init: could not run %s (%v); continuing without a fsck", bin, err)
	return nil
}

// gadget brings up the CDC-ACM composite gadget over configfs. Fails silently:
// no debug channel is bad, but it is not a reason not to boot.
func gadget(o Ops) {
	if err := o.Mkdir(gadgetRoot, 0o755); err != nil && !os.IsExist(err) {
		say(o, "gadget: no configfs usb_gadget")
		return
	}
	for _, s := range gadgetSteps(gadgetRoot) {
		switch s.Kind {
		case "mkdir":
			_ = o.Mkdir(s.Path, 0o755)
		case "write":
			_ = o.WriteSys(s.Path, s.Value)
		case "symlink":
			_ = o.Symlink(s.Path, s.Value)
		}
	}
	for _, udc := range udcCandidates() {
		if err := o.WriteSys(gadgetRoot+"/UDC", udc); err == nil {
			say(o, "gadget: bound UDC %s", udc)
			return
		}
	}
	say(o, "gadget: UDC bind failed")
}

// spawnHelper re-execs this binary in a helper role. See the package comment:
// these replace init.c's fork()s, and they must be started before switch_root
// because that is what makes them outlive the initramfs they came from.
//
// OWED BEFORE THIS BECOMES /init: the C now signals its kmsg and shell helpers
// to exit at the systemd handoff (init.c stop_debug_channels), and this port
// does not. Outliving switch_root is the point of these helpers, but the shell
// one must not outlive the boot: it has a tty on stdin, so busybox ash treats
// it as interactive and sets SIGTERM to SIG_IGN, and systemd-shutdown then
// waits the full DefaultTimeoutStopSec on every reboot before escalating to
// SIGKILL -- 90s of a panel frozen on the last compositor frame, measured on
// hardware 2026-08-17. dc1-debug-shell.service re-provides both channels, so
// there is nothing to lose by exiting.
func spawnHelper(o Ops, cfg Config, role string) {
	argv := []string{cfg.Self, "system-init", "-helper", role}
	if role == helperShell {
		// The helper opens its own tty, and reopens it: the gadget can
		// re-enumerate underneath it at any time.
		argv = append(argv, "-tty", shellTTY)
	}
	if _, err := o.Spawn(cfg.Self, argv, []string{helperEnv + "=1"}, ""); err != nil {
		say(o, "init: could not start the %s helper: %v", role, err)
	}
}

// petter is the sole owner of /dev/watchdog. It holds the fd open forever --
// including across switch_root -- because /dev/watchdog is single-open, so
// handing over to an in-rootfs watchdog daemon would need a close-and-reopen
// gap, and whether this driver honours magic-close (vs nowayout) has never
// been measured. Cost of that choice: a userspace-only hang does not
// auto-reset (a kernel hang still does, because the petter dies with it).
//
// Pet interval 10s against LK's ~31s timer.
func petter(o Ops, cfg Config) int {
	var w io.WriteCloser
	for i := 0; i < 10 && w == nil; i++ {
		var err error
		if w, err = o.OpenWrite("/dev/watchdog"); err != nil {
			w = nil
			o.Sleep(time.Second)
		}
	}
	if w == nil {
		say(o, "watchdog: no /dev/watchdog -- if LK armed its timer, the board resets")
		return 0
	}
	defer w.Close()
	say(o, "watchdog: petter running (sole owner, survives switch_root)")

	for {
		if _, err := o.Stat(deadmanPath); err == nil && !leaseHolds(o) {
			say(o, "watchdog: deadman lease expired -- arming fastboot and ceasing "+
				"to pet; the reset will land in LK fastboot")
			// Point the reset at fastboot, then stop petting. The hardware
			// reset itself can run no code, so this MUST happen before the
			// petting stops. Best-effort: a plain reset is the safe failure
			// mode.
			if err := o.ArmFastboot(); err != nil {
				say(o, "watchdog: %v -- the reset will be a plain one", err)
			}
			// Do not exit: exiting is indistinguishable from a crash, and
			// staying parked keeps the fd owned so nothing else re-arms it
			// before the reset lands.
			for {
				o.Sleep(time.Hour)
				if cfg.Once {
					return 0
				}
			}
		}
		if _, err := w.Write([]byte("a")); err != nil {
			say(o, "watchdog: pet failed: %v", err)
		}
		if cfg.Once {
			return 0
		}
		o.Sleep(10 * time.Second)
	}
}

func leaseHolds(o Ops) bool {
	st, err := o.Stat(leasePath)
	return LeaseFresh(err == nil, st.MTime, o.Now())
}

// streamKmsg is the one-way boot log on ttyGS0. It reopens on error, forever:
// the gadget can be torn down and rebound underneath us (adding a function
// re-enumerates the device), which invalidates the old fd, and a one-shot
// streamer would go silent for the rest of the boot.
func streamKmsg(o Ops, cfg Config) int {
	for {
		out, err := o.OpenWrite(kmsgTTY)
		if err == nil {
			var k io.ReadCloser
			if k, err = o.OpenRead("/dev/kmsg"); err == nil {
				_, _ = io.Copy(out, k)
				_ = k.Close()
			}
			_ = out.Close()
		}
		if cfg.Once {
			return 0
		}
		o.Sleep(time.Second)
	}
}

// respawnShell keeps an interactive root shell on tty. RESPAWN, like the
// installer's rc.sh does: this shell is the only interactive way into a failed
// boot, and losing it permanently (as a one-shot exec does the moment the
// gadget re-enumerates) strands the device with no way to drive it.
func respawnShell(o Ops, cfg Config, tty string) int {
	for {
		pid, err := o.Spawn(busyboxPath, []string{busyboxPath, "sh"}, nil, tty)
		if err == nil {
			_, _, _ = o.Wait(pid, true)
		}
		if cfg.Once {
			return 0
		}
		o.Sleep(time.Second)
	}
}

// rescue is the terminal state: shells on every plausible console, the deadman
// armed, and nothing written to any partition. Never returns on a real boot.
func rescue(o Ops, cfg Config, why string) int {
	say(o, "RESCUE SHELL: %s", why)
	say(o, "nothing was written; fix the problem or reflash from fastboot")

	// Arm the deadman. From here the board stays alive only while someone
	// renews the lease; otherwise it resets, which is what lets LK retry the
	// slot and eventually fall back. Seed the lease once so an operator who is
	// already attached has the full window to notice and take over.
	_ = o.Touch(leasePath)
	_ = o.Touch(deadmanPath)
	say(o, "watchdog: deadman armed -- renew with: touch %s (else the board resets)", leasePath)

	kid := make([]int, len(rescueConsoles))
	for {
		for i, tty := range rescueConsoles {
			if kid[i] > 0 {
				if wpid, _, err := o.Wait(kid[i], false); err == nil && wpid == 0 {
					continue // still running
				}
				kid[i] = 0
			}
			pid, err := o.Spawn(busyboxPath, []string{busyboxPath, "sh"}, nil, tty)
			if err != nil {
				continue
			}
			kid[i] = pid
		}
		// Reap strays: as PID 1 we inherit every orphan on the system.
		for {
			if wpid, _, err := o.Wait(-1, false); err != nil || wpid <= 0 {
				break
			}
		}
		if cfg.Once {
			return 1
		}
		o.Sleep(2 * time.Second)
	}
}
