package partition

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func fakeSysfs(t *testing.T, parts map[string]struct {
	name    string
	sectors int64
},
) {
	t.Helper()
	root := t.TempDir()
	for dev, p := range parts {
		dir := filepath.Join(root, dev)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		uevent := "DEVTYPE=partition\nPARTNAME=" + p.name + "\n"
		if err := os.WriteFile(filepath.Join(dir, "uevent"), []byte(uevent), 0o644); err != nil {
			t.Fatal(err)
		}
		size := strconv.FormatInt(p.sectors, 10) + "\n"
		if err := os.WriteFile(filepath.Join(dir, "size"), []byte(size), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	old := SysBlock
	SysBlock = root
	t.Cleanup(func() { SysBlock = old })
}

type part = struct {
	name    string
	sectors int64
}

func TestResolvesUserdataByName(t *testing.T) {
	fakeSysfs(t, map[string]part{
		"sdc1":  {"misc", 1024},
		"sdc29": {"dtbo_a", 16384},
		"sdc57": {"userdata", MinUserdataSectors + 1},
	})
	got, err := ResolveUserdata()
	if err != nil {
		t.Fatal(err)
	}
	if got.Device != "/dev/sdc57" {
		t.Fatalf("resolved %s, want /dev/sdc57", got.Device)
	}
}

// A prefix match would hand back the wrong partition.
func TestRejectsAPrefixMatch(t *testing.T) {
	fakeSysfs(t, map[string]part{
		"sdc57": {"userdata_extra", MinUserdataSectors + 1},
	})
	if _, err := ResolveUserdata(); err == nil {
		t.Fatal("matched userdata_extra as userdata")
	}
}

// Two matches means the mapping is not what we think it is: refuse rather
// than pick one.
func TestRefusesAmbiguousMatches(t *testing.T) {
	fakeSysfs(t, map[string]part{
		"sdc57": {"userdata", MinUserdataSectors + 1},
		"sdd57": {"userdata", MinUserdataSectors + 1},
	})
	if _, err := ResolveUserdata(); err == nil {
		t.Fatal("accepted an ambiguous userdata match")
	}
}

// The size floor is what stops a moved mapping from handing back a small,
// boot-critical partition.
func TestRefusesAPartitionBelowTheSizeFloor(t *testing.T) {
	fakeSysfs(t, map[string]part{
		"sdc29": {"userdata", 16384},
	})
	if _, err := ResolveUserdata(); err == nil {
		t.Fatal("accepted a userdata partition far below the size floor")
	}
}

// ResolveNamed skips the floor: the read-only debug hasher needs the small
// boot partitions, and applies its own cap instead.
func TestResolveNamedHasNoSizeFloor(t *testing.T) {
	fakeSysfs(t, map[string]part{
		"sdc29": {"expdb", 16384},
	})
	got, err := ResolveNamed("expdb")
	if err != nil {
		t.Fatal(err)
	}
	if got.Device != "/dev/sdc29" || got.Bytes != 16384*512 {
		t.Fatalf("got %+v, want sdc29 at 16384 sectors", got)
	}
}

// DevDir is the hook the offline tests (and an unusual boot) use to point
// the device nodes somewhere else than /dev.
func TestDevDirOverride(t *testing.T) {
	fakeSysfs(t, map[string]part{
		"sdc29": {"expdb", 16384},
	})
	old := DevDir
	DevDir = "/tmp/fakedev"
	t.Cleanup(func() { DevDir = old })
	got, err := ResolveNamed("expdb")
	if err != nil {
		t.Fatal(err)
	}
	if got.Device != "/tmp/fakedev/sdc29" {
		t.Fatalf("resolved %s, want the DevDir override", got.Device)
	}
}

// Inventory lists every NAMED partition, sorted, and skips the whole-disk
// entries that carry no PARTNAME.
func TestInventoryListsNamedPartitionsSorted(t *testing.T) {
	fakeSysfs(t, map[string]part{
		"sda":   {"", 0}, // whole disk: no PARTNAME line
		"sdc57": {"userdata", MinUserdataSectors + 1},
		"sdc29": {"dtbo_a", 16384},
		"sdc1":  {"misc", 1024},
	})
	inv, err := Inventory()
	if err != nil {
		t.Fatal(err)
	}
	if len(inv) != 3 {
		t.Fatalf("got %d entries, want 3 (the disk itself is unnamed)", len(inv))
	}
	for i, want := range []string{"dtbo_a", "misc", "userdata"} {
		if inv[i].Name != want {
			t.Fatalf("entry %d is %s, want %s", i, inv[i].Name, want)
		}
	}
	if inv[2].Sectors != MinUserdataSectors+1 {
		t.Fatalf("userdata sectors = %d", inv[2].Sectors)
	}
}
