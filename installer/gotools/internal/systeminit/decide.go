package systeminit

import (
	"bytes"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"time"
)

// Broadcast formatting, from init.c's say(): one line goes to stdout, stderr,
// /dev/kmsg and every console we can open, so one rendering covers all four.
// The 512-byte line buffer and the 16-byte headroom are kept because the
// consoles are the only place a failed boot is visible, and a line that a tty
// truncates mid-word is a line an operator misreads.
const (
	logPrefix = "[dc1-boot] "
	lineMax   = 512
	msgMax    = lineMax - 16
)

// Line renders one broadcast line exactly as init.c's say() did.
func Line(msg string) string {
	if len(msg) > msgMax {
		msg = msg[:msgMax]
	}
	return logPrefix + msg + "\n"
}

// Deadman lease. A watchdog that is petted unconditionally is not a watchdog,
// it is a keep-alive: it holds a dead board alive instead of resetting it, and
// -- worse -- it defeats the A/B recovery LK already implements, because a
// board that never resets is never retried and never falls back to the other
// slot. A failed boot must therefore stop being petted.
//
// Petting is unconditional only while the boot is still making progress. Once
// we drop to the rescue shell, the petter switches to a lease: it keeps the
// board alive only while someone demonstrably still has it, and the lease is
// renewed from outside (`touch /tmp/wd-lease` over the debug shell). Walk away
// -- or lose the cable -- and the board arms the fastboot boot mode and stops
// petting, so the watchdog reset lands in LK fastboot (a recoverable state you
// can re-flash from) instead of rebooting the same slot or sitting dark.
const (
	deadmanPath  = "/tmp/wd-deadman"
	leasePath    = "/tmp/wd-lease"
	leaseSeconds = 1800 // ~30 min; petting is manual in rescue
)

// LeaseFresh reports whether the rescue-shell lease still holds the board
// alive. haveLease is whether the lease file exists at all; now is zero when
// there is no usable clock, which fails towards staying alive rather than
// resetting a board someone may be actively debugging.
func LeaseFresh(haveLease bool, mtime, now time.Time) bool {
	if !haveLease {
		return false
	}
	if now.IsZero() {
		return true
	}
	if now.Before(mtime) {
		return true
	}
	return now.Sub(mtime) <= leaseSeconds*time.Second
}

// Root selection. The label is load-bearing: only the filesystem the installer
// wrote (and hash-verified) carries it. Anything else -- stock Android f2fs, a
// wiped partition, a half-install (the installer holds the superblock back
// until the hash matched) -- must fail here, read-only.
const (
	rootFSType = "ext4"
	rootLabel  = "jagar-root"
	rootMount  = "/mnt/root"
)

// Candidate is one probed partition: what the resolver found, and what its
// superblock says it is.
type Candidate struct {
	Device string
	FSType string
	Label  string
}

// SelectRoot picks the one filesystem worth mounting, or explains why none is.
// Never falls back to "the only ext4 we found": an unlabelled ext4 on userdata
// is exactly the half-installed case this gate exists to catch.
func SelectRoot(cands []Candidate) (string, error) {
	var match []Candidate
	for _, c := range cands {
		if c.FSType == rootFSType && c.Label == rootLabel {
			match = append(match, c)
		}
	}
	switch {
	case len(match) == 1:
		return match[0].Device, nil
	case len(match) > 1:
		return "", fmt.Errorf("%d filesystems are labelled %s; refusing to guess",
			len(match), rootLabel)
	case len(cands) == 0:
		return "", errors.New("no partition to probe")
	case len(cands) == 1 && cands[0].FSType != rootFSType:
		return "", fmt.Errorf("%s is %s, not ext4 (not installed? run the installer)",
			cands[0].Device, describeFS(cands[0].FSType))
	case len(cands) == 1:
		return "", fmt.Errorf("%s is ext4 but labelled %q, not %q (not our filesystem; refusing)",
			cands[0].Device, cands[0].Label, rootLabel)
	}
	return "", fmt.Errorf("none of %d candidates is ext4 labelled %s", len(cands), rootLabel)
}

func describeFS(t string) string {
	if t == "" {
		return "not a recognised ext filesystem"
	}
	return t
}

// ext superblock layout: the 1024 bytes at offset 1024. Every offset below was
// read back out of real `mke2fs -t ext2/ext3/ext4` images rather than recalled,
// and the feature words in the table test are those measured images'.
//
// This replaces boot.sh's `blkid | grep TYPE=/LABEL=`. Not for elegance: the
// SYSTEM image never runs `busybox --install`, so every applet the boot path
// shells out to is one more thing that can be missing -- and a missing one
// fails SILENTLY (that exact class of bug, a missing `dirname`, once left the
// device dark on every boot). Reading the superblock ourselves removes the
// dependency instead of adding a staging check for it.
const (
	// SuperblockOffset is where the primary ext superblock starts.
	SuperblockOffset = 1024
	// SuperblockSize is how much of it we need.
	SuperblockSize = 1024

	sbMagic           = 0x38
	sbFeatureCompat   = 0x5c
	sbFeatureIncompat = 0x60
	sbVolumeName      = 0x78
	sbVolumeNameLen   = 16

	extMagic             = 0xef53
	featCompatHasJournal = 0x0004
	featIncompatExtents  = 0x0040
	featIncompat64Bit    = 0x0080
)

// ProbeSuperblock reports the type and label blkid would report for sb, the
// SuperblockSize bytes at SuperblockOffset. An empty type means "not ext at
// all", which is the stock-Android and freshly-wiped cases.
func ProbeSuperblock(sb []byte) (fstype, label string) {
	if len(sb) < SuperblockSize {
		return "", ""
	}
	if binary.LittleEndian.Uint16(sb[sbMagic:]) != extMagic {
		return "", ""
	}
	compat := binary.LittleEndian.Uint32(sb[sbFeatureCompat:])
	incompat := binary.LittleEndian.Uint32(sb[sbFeatureIncompat:])
	switch {
	case incompat&(featIncompatExtents|featIncompat64Bit) != 0:
		fstype = rootFSType
	case compat&featCompatHasJournal != 0:
		fstype = "ext3"
	default:
		fstype = "ext2"
	}
	raw := sb[sbVolumeName : sbVolumeName+sbVolumeNameLen]
	if i := bytes.IndexByte(raw, 0); i >= 0 {
		raw = raw[:i]
	}
	return fstype, string(raw)
}

// UFS probes seconds after the gadget-less kernel starts, so the userdata
// partition (and its uevent) appears late. Retry the whole resolution rather
// than failing on one early ENOENT.
const rootWaitSeconds = 60

// WaitingNotice is the occasional "still waiting" line, at the same marks
// boot.sh used: often enough to show progress, rarely enough to stay readable.
func WaitingNotice(second int) (string, bool) {
	switch second {
	case 10, 30, 50:
		return fmt.Sprintf("still waiting for userdata partition (%ds)", second), true
	}
	return "", false
}

// e2fsck is optional: the default initramfs has only busybox. Skipping is
// acceptable because the filesystem was SHA-256-verified at install time and
// ext4 journals recover ordinary unclean shutdowns; stage e2fsck into the
// image to enable this.
var fsckPaths = []string{"/sbin/e2fsck", "/usr/sbin/e2fsck", "/bin/e2fsck"}

// FsckAcceptable maps an e2fsck exit code to a verdict: 0 and 1 (errors
// corrected) are success, >=2 is not.
func FsckAcceptable(rc int) bool { return rc >= 0 && rc <= 1 }

// The MUSB UDC name candidates match the installer initramfs; the first one
// that accepts the write wins.
func udcCandidates() []string {
	return []string{"musb-hdrc.1.auto", "musb-hdrc.0.auto", "11201000.usb", "11200000.usb"}
}

// gadgetStep is one configfs operation. Kept as data so the whole gadget shape
// can be asserted in a table test instead of only on a device.
type gadgetStep struct {
	Kind  string // "mkdir", "write" or "symlink"
	Path  string
	Value string // written value, or symlink target
}

// gadgetSteps is the CDC-ACM composite gadget, minus the root mkdir the caller
// does (its failure means there is no configfs at all). Mirrors the installer
// initramfs gadget() minus ECM -- a serial stream and a shell are all a
// diagnosable boot needs.
func gadgetSteps(g string) []gadgetStep {
	return []gadgetStep{
		{"write", g + "/idVendor", "0x18d1\n"},
		{"write", g + "/idProduct", "0x4ee7\n"},
		{"mkdir", g + "/strings/0x409", ""},
		{"write", g + "/strings/0x409/manufacturer", "daylight\n"},
		{"write", g + "/strings/0x409/product", "dc1-system\n"},
		{"write", g + "/strings/0x409/serialnumber", "dc1-system\n"},
		{"mkdir", g + "/configs/c.1", ""},
		{"mkdir", g + "/configs/c.1/strings/0x409", ""},
		{"write", g + "/configs/c.1/strings/0x409/configuration", "acm\n"},
		{"mkdir", g + "/functions/acm.0", ""},
		{"mkdir", g + "/functions/acm.1", ""},
		{"symlink", g + "/configs/c.1/acm.0", g + "/functions/acm.0"},
		{"symlink", g + "/configs/c.1/acm.1", g + "/functions/acm.1"},
	}
}

// Config is the parsed command line.
type Config struct {
	Helper string // "" for init itself; otherwise the child role
	TTY    string // console for Helper == "shell"
	DryRun bool   // print the plan, touch nothing
	Once   bool   // run each endless loop a single pass and return (tests)
	Self   string // path to re-exec for helper children
}

// Helper roles. In C these were plain fork()s of PID 1; Go cannot fork without
// exec, so each one is a re-exec of this same binary. See spawnHelper.
const (
	helperWatchdog = "watchdog"
	helperKmsg     = "kmsg"
	helperShell    = "shell"

	// helperEnv is set by PID 1 on the children it spawns, and only on those.
	helperEnv = "DC1_SYSTEM_INIT_HELPER"
)

// initAllowed and helperAllowed are the "are we really who we say we are"
// gates. Everything past them is destructive on a live host -- mounting over
// /proc, opening the host's watchdog, moving kernel filesystems -- and
// `dc1tools system-init` is exactly the sort of thing that gets typed by
// accident.
func initAllowed(pid int) bool { return pid == 1 }

// A helper is legitimately not PID 1, so it proves its parentage instead: PID
// 1 spawned it AND marked it. The marker matters on its own, because every
// daemonized process on a normal host is reparented to PID 1 too.
func helperAllowed(ppid int, marker string) bool { return ppid == 1 && marker == "1" }

// ParseArgs is the whole command line, kept pure so the roles and their
// argument requirements are table-testable.
func ParseArgs(args []string, out io.Writer) (Config, error) {
	fs := flag.NewFlagSet("system-init", flag.ContinueOnError)
	fs.SetOutput(out)
	var cfg Config
	fs.StringVar(&cfg.Helper, "helper", "", "child role: watchdog, kmsg or shell (spawned by PID 1)")
	fs.StringVar(&cfg.TTY, "tty", "", "console for -helper shell")
	fs.BoolVar(&cfg.DryRun, "n", false, "print what booting would do, change nothing")
	fs.BoolVar(&cfg.DryRun, "dry-run", false, "alias for -n")
	fs.BoolVar(&cfg.Once, "once", false, "run each endless loop a single pass and return (tests)")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}
	switch cfg.Helper {
	case "", helperWatchdog, helperKmsg:
	case helperShell:
		if cfg.TTY == "" {
			return Config{}, errors.New("-helper shell needs -tty")
		}
	default:
		return Config{}, fmt.Errorf("unknown -helper %q", cfg.Helper)
	}
	if cfg.TTY != "" && cfg.Helper != helperShell {
		return Config{}, errors.New("-tty only applies to -helper shell")
	}
	return cfg, nil
}

// selfPath is the binary a helper child re-execs.
//
// On the device the fallback is ALWAYS what gets used, not an edge case:
// os.Executable() is readlink("/proc/self/exe") on Linux, Main resolves it
// before boot() mounts /proc, so it always fails with ENOENT. /bin/dc1tools is
// therefore a hardcoded path, and it is load-bearing -- build.sh:412 stages the
// binary there. Move it and the watchdog petter stops starting.
func selfPath(exe string, err error) string {
	if err != nil || exe == "" {
		return "/bin/dc1tools"
	}
	return exe
}

// Plan is what a real boot would do, in order. Printed instead of acting when
// this is not PID 1, so the refusal is still useful output.
func Plan() []string {
	return []string{
		"mount proc on /proc, sysfs on /sys, devtmpfs on /dev",
		"mount configfs and bring up the CDC-ACM debug gadget (ttyGS0 log, ttyGS1 shell)",
		"spawn the watchdog petter: sole owner of /dev/watchdog, survives switch_root",
		"resolve userdata by GPT PARTNAME, then require ext4 labelled " + rootLabel,
		"run e2fsck -p if it is staged (exit 0 or 1 is success)",
		"mount that device at " + rootMount + " and require an executable /sbin/init in it",
		"move /dev /proc /sys into it, then exec busybox switch_root " + rootMount + " /sbin/init",
		"on ANY failure: write nothing, arm the deadman lease, rescue shells on tty1/ttyS0/console",
	}
}
