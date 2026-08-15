// Package rebootfastboot leaves the note LK reads on the way up, so the next
// boot lands in fastboot without anyone pressing a key.
//
// MECHANISM. On this SoC the note is the low nibble of WDT_NONRST_REG2
// (0x10007000 + 0x24), which survives a warm reset, and the value meaning
// fastboot is 3. LK's boot_mode_select tests in order, and every test RETURNS:
//
//  1. preloader boot mode in {1,4,7}                 -> that mode
//  2. latch + clear low nibble of 0x10007024, == 2   -> RECOVERY
//  3. misc BCB command == "boot-recovery"            -> RECOVERY
//  4. misc BCB command == "boot-fastboot"            -> RECOVERY
//  5. latched nibble == 3                            -> FASTBOOT
//  6. key id 1 held -> FACTORY;  7. key id 6 -> LK boot menu
//
// WHY NOT THE BCB. Both strings this LK matches resolve to RECOVERY (steps 3
// and 4), and both are tested BEFORE the nibble. So an armed BCB does not
// reach fastboot AND hides the nibble -- which is why this CLEARS a stale BCB
// rather than writing one.
//
// WHY NOT `reboot bootloader`. The stock DT advertises syscon-reboot-mode on
// this register and the kernel has CONFIG_SYSCON_REBOOT_MODE=y, but the jagar
// DT binds no reboot-mode node, so RESTART2 has nothing registered to honour
// it. [inferred from the DT; the nibble path is the one measured on hardware]
//
// Test hooks, same spirit as partlib.sh: DC1_SYSBLOCK overrides
// /sys/class/block, DC1_DEVDIR overrides /dev, DC1_MEMDEV overrides /dev/mem,
// DC1_MEMBASE overrides the mapped physical base.
package rebootfastboot

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
)

const (
	wdtBase          = 0x10007000
	wdtMapLen        = 0x1000
	wdtNonRST2       = 0x24 // survives a warm reset
	bootModeMask     = 0x0f
	bootModeFastboot = 0x03

	// Real misc is well under a megabyte. A big device under PARTNAME=misc
	// means the mapping is not what we think it is, and the next write would
	// land in something that matters. 16 MiB in 512-byte sectors.
	miscMaxSectors = 32768

	// bootloader_message: char command[32]; char status[32]. The A/B
	// bootloader_control lives at offset 2048 and is deliberately left alone.
	bcbClearBytes = 64
)

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// ResolveMisc finds the single partition named "misc", refusing anything that
// is not unique or is implausibly large. No hardcoded /dev/sdc1: a fixed node
// is exactly the mapping-moved hazard the size check exists to catch.
func ResolveMisc() (string, error) {
	sysblock := envOr("DC1_SYSBLOCK", "/sys/class/block")
	devdir := envOr("DC1_DEVDIR", "/dev")

	uevents, err := filepath.Glob(filepath.Join(sysblock, "*", "uevent"))
	if err != nil {
		return "", err
	}
	var found []string
	for _, u := range uevents {
		b, err := os.ReadFile(u)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			if strings.TrimRight(line, "\r") == "PARTNAME=misc" {
				found = append(found, filepath.Base(filepath.Dir(u)))
				break
			}
		}
	}
	if len(found) != 1 {
		return "", fmt.Errorf("expected exactly 1 PARTNAME=misc, found %d", len(found))
	}

	raw, err := os.ReadFile(filepath.Join(sysblock, found[0], "size"))
	if err != nil {
		return "", fmt.Errorf("cannot read the size of %s: %w", found[0], err)
	}
	sectors, err := strconv.ParseUint(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil {
		return "", fmt.Errorf("bad size for %s: %w", found[0], err)
	}
	if sectors > miscMaxSectors {
		return "", fmt.Errorf("misc (%s) is %d sectors, refusing (mapping moved?)",
			found[0], sectors)
	}
	return filepath.Join(devdir, found[0]), nil
}

// DisarmBCB clears a stale "boot-fastboot"/"boot-recovery" command, which on
// this LK means RECOVERY and is tested before the nibble. Anything else is
// left alone: those are the only two strings this LK matches.
func DisarmBCB(dev string, dryRun bool, out io.Writer) error {
	flags := os.O_RDWR | syscall.O_SYNC
	if dryRun {
		flags = os.O_RDONLY
	}
	f, err := os.OpenFile(dev, flags, 0)
	if err != nil {
		return fmt.Errorf("open %s: %w", dev, err)
	}
	defer f.Close()

	cmd := make([]byte, 32)
	if _, err := f.ReadAt(cmd, 0); err != nil {
		return fmt.Errorf("short read of %s: %w", dev, err)
	}
	fmt.Fprintf(out, "dc1-reboot-fastboot: misc BCB command: %q\n", printable(cmd))

	current := string(cmd[:clen(cmd)])
	if current != "boot-fastboot" && current != "boot-recovery" {
		return nil
	}
	if dryRun {
		fmt.Fprintf(out, "dc1-reboot-fastboot: BCB is armed and would divert LK "+
			"to recovery; would clear it\n")
		return nil
	}

	if _, err := f.WriteAt(make([]byte, bcbClearBytes), 0); err != nil {
		return fmt.Errorf("clearing the BCB failed: %w", err)
	}
	if err := f.Sync(); err != nil {
		return fmt.Errorf("sync: %w", err)
	}
	if _, err := f.ReadAt(cmd, 0); err != nil || cmd[0] != 0 {
		return errors.New("BCB did not read back clear; refusing to continue")
	}
	fmt.Fprintf(out, "dc1-reboot-fastboot: cleared the armed BCB (it means "+
		"RECOVERY on this LK, and hides the nibble)\n")
	return nil
}

// ArmNibble sets the boot-mode nibble to fastboot and proves it took. A
// register that does not read back is NOT rebooted on: a reboot then would
// simply return to Linux with the reason lost.
func ArmNibble(dryRun bool, out io.Writer) error {
	memdev := envOr("DC1_MEMDEV", "/dev/mem")
	base := uint64(wdtBase)
	if v := os.Getenv("DC1_MEMBASE"); v != "" {
		parsed, err := strconv.ParseUint(strings.TrimPrefix(v, "0x"), 16, 64)
		if err != nil {
			return fmt.Errorf("bad DC1_MEMBASE %q: %w", v, err)
		}
		base = parsed
	}

	flags := os.O_RDWR | syscall.O_SYNC
	prot := syscall.PROT_READ | syscall.PROT_WRITE
	if dryRun {
		flags = os.O_RDONLY
		prot = syscall.PROT_READ
	}
	f, err := os.OpenFile(memdev, flags, 0)
	if err != nil {
		return fmt.Errorf("open %s failed (CONFIG_DEVMEM?): %w", memdev, err)
	}
	defer f.Close()

	mem, err := syscall.Mmap(int(f.Fd()), int64(base), wdtMapLen, prot, syscall.MAP_SHARED)
	if err != nil {
		return fmt.Errorf("mmap %s at %#x failed: %w", memdev, base, err)
	}
	defer syscall.Munmap(mem)

	return armMapping(mem, base, dryRun, out)
}

// armMapping is the register write itself, split out from the mapping so it can
// be exercised without /dev/mem.
//
// There is deliberately no msync here. The C flushed with
// __sync_synchronize() (dc1-reboot-fastboot.c), a barrier, not a syscall; an
// earlier draft of this port used msync(MS_SYNC) instead, which ALWAYS fails
// with EINVAL on a MAP_SHARED mapping of an O_RDWR /dev/mem fd: mm/msync.c
// routes that case into vfs_fsync_range(), which returns -EINVAL when the file
// has no ->fsync, and drivers/char/mem.c's mem_fops has none. That turned the
// only route back to fastboot -- from the rescue shell, from the watchdog
// deadman, and from the installed system -- into a tool that wrote the
// register, reported "msync: invalid argument" and never rebooted. The offline
// tests could not see it because DC1_MEMDEV points at a regular file, where
// msync succeeds.
//
// The store and the read-back are atomic accesses because they must be real
// memory accesses: the read-back is the proof that the register took, and a
// plain load of a location the compiler just stored to may be folded into the
// stored value. LDAR/STLR on arm64, and same-address ordering makes the
// read-back observe the store on the Device-nGnRE mapping /dev/mem gives us
// here. Native-endian, like the C's volatile uint32_t store, and every target
// this builds for is little-endian.
func armMapping(mem []byte, base uint64, dryRun bool, out io.Writer) error {
	reg := register(mem[wdtNonRST2:])
	old := atomic.LoadUint32(reg)
	fmt.Fprintf(out, "dc1-reboot-fastboot: WDT_NONRST_REG2 (%#x) = 0x%08x, "+
		"boot mode nibble = %d\n", base+wdtNonRST2, old, old&bootModeMask)

	if dryRun {
		fmt.Fprintf(out, "dc1-reboot-fastboot: would set the nibble to %d (fastboot)\n",
			bootModeFastboot)
		return nil
	}

	want := (old &^ bootModeMask) | bootModeFastboot
	atomic.StoreUint32(reg, want)
	got := atomic.LoadUint32(reg)
	if got&bootModeMask != bootModeFastboot {
		return fmt.Errorf("wrote 0x%08x, read back 0x%08x -- register did not take, "+
			"NOT rebooting", want, got)
	}
	fmt.Fprintf(out, "dc1-reboot-fastboot: armed: 0x%08x -> 0x%08x (nibble %d = fastboot)\n",
		old, got, bootModeFastboot)
	return nil
}

func clen(b []byte) int {
	for i, c := range b {
		if c == 0 {
			return i
		}
	}
	return len(b)
}

func printable(b []byte) string {
	var sb strings.Builder
	for i := 0; i < len(b) && b[i] != 0; i++ {
		if b[i] >= 0x20 && b[i] < 0x7f {
			sb.WriteByte(b[i])
		} else {
			sb.WriteByte('.')
		}
	}
	return sb.String()
}

// Main is the `dc1-reboot-fastboot` entry point.
func Main(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("dc1-reboot-fastboot", flag.ContinueOnError)
	fs.SetOutput(stderr)
	dryRun := fs.Bool("n", false, "report the BCB and the nibble, change nothing")
	fs.BoolVar(dryRun, "dry-run", false, "alias for -n")
	noReboot := fs.Bool("no-reboot", false, "arm the nibble but do not reboot")
	force := fs.Bool("f", false, "reboot directly, for callers that are init or have none")
	fs.BoolVar(force, "force", false, "alias for -f")
	miscArg := fs.String("misc", "", "use DEV as the misc partition instead of resolving it")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	// A clear message beats an mmap failure. Skipped when the caller has
	// redirected the register file (the offline tests) -- there the kernel's
	// own permission check on the named file is the real gate.
	if !*dryRun && os.Geteuid() != 0 && os.Getenv("DC1_MEMDEV") == "" {
		fmt.Fprintln(stderr, "dc1-reboot-fastboot: must be root")
		return 1
	}

	// Step 1: make sure LK gets as far as the nibble. A BCB we cannot inspect
	// is not fatal -- it is normally clear -- but it is the first thing to
	// suspect if the device comes back to Linux instead of fastboot.
	misc := *miscArg
	if misc == "" {
		resolved, err := ResolveMisc()
		if err != nil {
			fmt.Fprintf(stderr, "dc1-reboot-fastboot: WARNING: could not check the "+
				"BCB (%v); if this boots back into Linux, a stale "+
				"\"boot-fastboot\"/\"boot-recovery\" there is why\n", err)
		} else {
			misc = resolved
		}
	}
	if misc != "" {
		fmt.Fprintf(stdout, "dc1-reboot-fastboot: misc = %s\n", misc)
		if err := DisarmBCB(misc, *dryRun, stdout); err != nil {
			fmt.Fprintf(stderr, "dc1-reboot-fastboot: %v\n", err)
			return 1
		}
	}

	// Step 2: leave the note LK reads on the way up.
	if err := ArmNibble(*dryRun, stdout); err != nil {
		fmt.Fprintf(stderr, "dc1-reboot-fastboot: %v\n", err)
		return 1
	}

	if *dryRun || *noReboot {
		return 0
	}

	syscall.Sync()
	fmt.Fprintln(stdout, "dc1-reboot-fastboot: rebooting into fastboot")

	// Ask the init system first so filesystems come down cleanly; -f is for
	// callers that ARE the init system, or have none.
	if !*force {
		_ = syscall.Exec("/sbin/reboot", []string{"reboot"}, os.Environ())
	}
	if err := syscall.Reboot(syscall.LINUX_REBOOT_CMD_RESTART); err != nil {
		fmt.Fprintf(stderr, "dc1-reboot-fastboot: reboot: %v\n", err)
		return 1
	}
	return 0
}
