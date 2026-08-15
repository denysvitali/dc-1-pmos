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
	"strconv"
	"strings"
)

// SysBlock is the sysfs root; overridable for tests.
var SysBlock = "/sys/class/block"

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
		Device:  "/dev/" + dev,
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
