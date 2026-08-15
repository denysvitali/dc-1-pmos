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
