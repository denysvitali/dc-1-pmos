package rebootfastboot

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"unsafe"
)

func fakeSysfs(t *testing.T, parts map[string]struct {
	name    string
	sectors int64
},
) string {
	t.Helper()
	sys := t.TempDir()
	dev := t.TempDir()
	for node, p := range parts {
		dir := filepath.Join(sys, node)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "uevent"),
			[]byte("DEVTYPE=partition\nPARTNAME="+p.name+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "size"),
			[]byte(strconv.FormatInt(p.sectors, 10)+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dev, node), make([]byte, 4096), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("DC1_SYSBLOCK", sys)
	t.Setenv("DC1_DEVDIR", dev)
	return dev
}

type part = struct {
	name    string
	sectors int64
}

func TestResolvesMiscByName(t *testing.T) {
	dev := fakeSysfs(t, map[string]part{
		"sdc1":  {"misc", 1024},
		"sdc57": {"userdata", 200000000},
	})
	got, err := ResolveMisc()
	if err != nil {
		t.Fatal(err)
	}
	if got != filepath.Join(dev, "sdc1") {
		t.Fatalf("resolved %s", got)
	}
}

// A big device under PARTNAME=misc means the mapping moved, and the next write
// would land in something that matters.
func TestRefusesAnImplausiblyLargeMisc(t *testing.T) {
	fakeSysfs(t, map[string]part{"sdc1": {"misc", miscMaxSectors + 1}})
	if _, err := ResolveMisc(); err == nil {
		t.Fatal("accepted a misc partition past the size ceiling")
	}
}

func TestRefusesAmbiguousMisc(t *testing.T) {
	fakeSysfs(t, map[string]part{
		"sdc1": {"misc", 1024},
		"sdd1": {"misc", 1024},
	})
	if _, err := ResolveMisc(); err == nil {
		t.Fatal("accepted an ambiguous misc match")
	}
}

func writeBCB(t *testing.T, path, command string) {
	t.Helper()
	buf := make([]byte, 4096)
	copy(buf, command)
	if err := os.WriteFile(path, buf, 0o600); err != nil {
		t.Fatal(err)
	}
}

// An armed BCB means RECOVERY on this LK and is tested BEFORE the nibble, so
// leaving it would send the device to recovery and hide the nibble entirely.
func TestDisarmClearsAnArmedBCB(t *testing.T) {
	for _, cmd := range []string{"boot-fastboot", "boot-recovery"} {
		path := filepath.Join(t.TempDir(), "misc")
		writeBCB(t, path, cmd)
		var out bytes.Buffer
		if err := DisarmBCB(path, false, &out); err != nil {
			t.Fatalf("%s: %v", cmd, err)
		}
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if got[0] != 0 {
			t.Fatalf("%s: BCB not cleared", cmd)
		}
	}
}

// Anything else is not a string this LK matches, so it must be left alone
// rather than "helpfully" wiped.
func TestDisarmLeavesAnUnrelatedBCBAlone(t *testing.T) {
	path := filepath.Join(t.TempDir(), "misc")
	writeBCB(t, path, "something-else")
	var out bytes.Buffer
	if err := DisarmBCB(path, false, &out); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(got), "something-else") {
		t.Fatal("clobbered a BCB command this LK does not match")
	}
}

func TestDisarmDryRunChangesNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "misc")
	writeBCB(t, path, "boot-fastboot")
	var out bytes.Buffer
	if err := DisarmBCB(path, true, &out); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(got), "boot-fastboot") {
		t.Fatal("dry run modified the BCB")
	}
	if !strings.Contains(out.String(), "would clear it") {
		t.Fatalf("dry run did not report intent:\n%s", out.String())
	}
}

// The register file stands in for /dev/mem: the nibble must land in the low
// four bits of the word at 0x24 and leave every other bit untouched.
func TestArmNibbleSetsOnlyTheLowNibble(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mem")
	reg := make([]byte, wdtMapLen)
	binary.LittleEndian.PutUint32(reg[wdtNonRST2:], 0x38002070) // field 7, nibble 0
	if err := os.WriteFile(path, reg, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DC1_MEMDEV", path)
	t.Setenv("DC1_MEMBASE", "0")

	var out bytes.Buffer
	if err := ArmNibble(false, &out); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	word := binary.LittleEndian.Uint32(got[wdtNonRST2:])
	if word&bootModeMask != bootModeFastboot {
		t.Fatalf("nibble = %d, want %d", word&bootModeMask, bootModeFastboot)
	}
	// Everything above the nibble must be preserved: those bits are the
	// preloader's boot-mode field and clobbering them changes LK's decision.
	if word&^bootModeMask != 0x38002070&^uint32(bootModeMask) {
		t.Fatalf("clobbered bits outside the nibble: 0x%08x", word)
	}
}

func TestArmNibbleDryRunChangesNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "mem")
	reg := make([]byte, wdtMapLen)
	binary.LittleEndian.PutUint32(reg[wdtNonRST2:], 0x38002070)
	if err := os.WriteFile(path, reg, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DC1_MEMDEV", path)
	t.Setenv("DC1_MEMBASE", "0")

	var out bytes.Buffer
	if err := ArmNibble(true, &out); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if binary.LittleEndian.Uint32(got[wdtNonRST2:]) != 0x38002070 {
		t.Fatal("dry run wrote to the register")
	}
}

// msyncRefuses reports whether the kernel refuses to msync(MS_SYNC) this
// mapping -- the property the fixture below needs, asserted rather than
// assumed.
func msyncRefuses(b []byte) error {
	_, _, errno := syscall.Syscall(syscall.SYS_MSYNC,
		uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)), syscall.MS_SYNC)
	if errno == 0 {
		return nil
	}
	return errno
}

// Arming must not be conditional on the mapping being syncable.
//
// WDT_NONRST_REG2 is reached through /dev/mem, and msync(MS_SYNC) on a
// MAP_SHARED mapping of an O_RDWR /dev/mem fd ALWAYS fails with EINVAL:
// mm/msync.c routes that case into vfs_fsync_range(), which returns -EINVAL
// when the file has no ->fsync, and drivers/char/mem.c's mem_fops has none. An
// earlier draft of this port synced between the store and the read-back, so on
// hardware dc1-reboot-fastboot wrote the nibble, reported "msync: invalid
// argument" and never rebooted -- taking out the only route back to fastboot
// from the rescue shell, the watchdog deadman and the installed system. The
// other tests here cannot see it: they point DC1_MEMDEV at a regular file,
// which msync is happy to flush.
//
// The fixture is an off-page-boundary slice, which the kernel refuses for a
// different reason (offset_in_page(start), mm/msync.c) but refuses just the
// same, so it reproduces the failure without needing /dev/mem.
func TestArmingDoesNotDependOnSyncingTheMapping(t *testing.T) {
	backing := make([]byte, wdtMapLen+64)
	mem := backing[8 : 8+wdtMapLen] // never page-aligned, still 4-byte aligned
	mem[wdtNonRST2] = 0xa5

	if err := msyncRefuses(mem); err == nil {
		t.Fatal("the fixture is syncable, so it no longer stands in for /dev/mem")
	}

	var out strings.Builder
	if err := armMapping(mem, wdtBase, false, &out); err != nil {
		t.Fatalf("arming failed on a mapping the kernel will not sync: %v\n"+
			"on the device this is every /dev/mem mapping, i.e. no reboot at all", err)
	}
	if got := mem[wdtNonRST2] & bootModeMask; got != bootModeFastboot {
		t.Fatalf("nibble = %d, want %d", got, bootModeFastboot)
	}
	if got := mem[wdtNonRST2] &^ bootModeMask; got != 0xa0 {
		t.Fatalf("clobbered the high nibble: 0x%02x, want 0xa0", got)
	}
	if !strings.Contains(out.String(), "armed:") {
		t.Fatalf("no arming line reported:\n%s", out.String())
	}
}
