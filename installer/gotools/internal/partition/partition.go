// Package partition resolves the install target by GPT partition NAME.
//
// Never by a hardcoded /dev/sdX: the enumeration order is not stable, and the
// partitions this device cannot survive losing (preloader, lk, dtbo,
// vendor_boot) sit on the same disk. Resolving by name, requiring the match to
// be unique, and enforcing a size floor makes those unreachable by
// construction rather than by care.
package partition

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// SysBlock is the sysfs root; overridable for tests.
var SysBlock = "/sys/class/block"

// DevDir is where partition device nodes appear once devtmpfs is mounted;
// overridable for tests.
var DevDir = "/dev"

// MinUserdataSectors is the floor for the userdata partition (32 GiB in
// 512-byte sectors). A match far below this means the name mapping moved and
// the resolver is about to hand back something important.
const MinUserdataSectors = 32 * 1024 * 1024 * 1024 / 512

// Resolved is a partition that passed every check.
type Resolved struct {
	Device  string
	Sectors int64
	Bytes   int64
}

// ResolveUserdata finds the single partition named "userdata".
func ResolveUserdata() (*Resolved, error) {
	return resolveNamed("userdata", MinUserdataSectors)
}

// ResolveNamed finds the single partition named name with NO size floor.
// Callers must apply their own sanity bound: userdata's floor is what keeps
// the install writer away from the small authenticated partitions, and a
// reader that skips that floor takes responsibility for one of its own --
// e.g. the debug hasher's max-bytes cap.
func ResolveNamed(name string) (*Resolved, error) {
	return resolveNamed(name, 0)
}

func resolveNamed(name string, minSectors int64) (*Resolved, error) {
	uevents, err := filepath.Glob(filepath.Join(SysBlock, "*", "uevent"))
	if err != nil {
		return nil, err
	}
	var matches []string
	for _, u := range uevents {
		data, err := os.ReadFile(u)
		if err != nil {
			continue
		}
		if !hasPartName(string(data), name) {
			continue
		}
		matches = append(matches, filepath.Base(filepath.Dir(u)))
	}
	if len(matches) != 1 {
		return nil, fmt.Errorf("expected exactly 1 PARTNAME=%s, found %d", name, len(matches))
	}

	dev := matches[0]
	raw, err := os.ReadFile(filepath.Join(SysBlock, dev, "size"))
	if err != nil {
		return nil, fmt.Errorf("reading size of %s: %w", dev, err)
	}
	sectors, err := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
	if err != nil {
		return nil, fmt.Errorf("bad size for %s: %w", dev, err)
	}
	if sectors < minSectors {
		return nil, fmt.Errorf("%s (%s) is only %d sectors; refusing (mapping moved?)",
			name, dev, sectors)
	}
	return &Resolved{
		Device:  DevDir + "/" + dev,
		Sectors: sectors,
		Bytes:   sectors * 512,
	}, nil
}

// hasPartName requires a whole-line, exact match: a prefix test would accept
// "userdata_extra" and hand back the wrong partition.
func hasPartName(uevent, name string) bool {
	want := "PARTNAME=" + name
	for _, line := range strings.Split(uevent, "\n") {
		if strings.TrimRight(line, "\r") == want {
			return true
		}
	}
	return false
}

// partName extracts the PARTNAME value from a uevent body, "" if none.
func partName(uevent string) string {
	for _, line := range strings.Split(uevent, "\n") {
		line = strings.TrimRight(line, "\r")
		if v, ok := strings.CutPrefix(line, "PARTNAME="); ok {
			return v
		}
	}
	return ""
}

// Entry is one block device carrying a GPT partition name. Read-only facts;
// the device path is what /dev/<node> will be once devtmpfs is mounted.
type Entry struct {
	Name    string
	Device  string
	Sectors int64
}

// Inventory lists every sysfs block entry that carries a PARTNAME, sorted by
// name. It reads only uevent+size files -- never opens device nodes -- so it
// is safe on any boot state, including one where resolving would fail because
// a name appears twice or zero times.
func Inventory() ([]Entry, error) {
	uevents, err := filepath.Glob(filepath.Join(SysBlock, "*", "uevent"))
	if err != nil {
		return nil, err
	}
	var out []Entry
	for _, u := range uevents {
		data, err := os.ReadFile(u)
		if err != nil {
			continue
		}
		name := partName(string(data))
		if name == "" {
			continue
		}
		dev := filepath.Base(filepath.Dir(u))
		e := Entry{Name: name, Device: DevDir + "/" + dev}
		if raw, err := os.ReadFile(filepath.Join(SysBlock, dev, "size")); err == nil {
			if s, err := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64); err == nil {
				e.Sectors = s
			}
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}
