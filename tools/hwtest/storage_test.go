package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
)

func storageAudioFixture(t *testing.T) *Ctx {
	t.Helper()
	return &Ctx{Root: t.TempDir(), Cancel: context.Background(), In: bufio.NewReader(strings.NewReader("")), Out: io.Discard}
}

func storageAudioPut(t *testing.T, c *Ctx, path, data string) {
	t.Helper()
	name := filepath.Join(c.Root, path)
	if err := os.MkdirAll(filepath.Dir(name), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(name, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}

func storageAudioResult(t *testing.T, r *Reporter, name string) Result {
	t.Helper()
	for _, result := range r.results {
		if result.Name == name {
			return result
		}
	}
	t.Fatalf("missing result %q: %+v", name, r.results)
	return Result{}
}

func TestStorageTmpfileFlags(t *testing.T) {
	want := 0x410000
	if runtime.GOARCH == "arm64" {
		want = 0x404000
	}
	if storageTmpfile != want {
		t.Fatalf("O_TMPFILE on %s: %#x, want %#x", runtime.GOARCH, storageTmpfile, want)
	}
}

func TestStorageWorkerFailureClassification(t *testing.T) {
	for _, test := range []struct {
		err  error
		want int
	}{
		{nil, 0},
		{errStorageUnavailable, 2},
		{fmt.Errorf("preflight: %w", errStorageUnavailable), 2},
		{errors.New("write failed"), 1},
		{errors.New("sync failed"), 1},
		{errors.New("read-back mismatch"), 1},
	} {
		if got := storageWorkerExitCode(test.err); got != test.want {
			t.Errorf("worker exit %d, want %d", got, test.want)
		}
	}
}

func TestStorageWorkerGuard(t *testing.T) {
	for _, test := range []struct {
		args   []string
		marker string
		want   bool
	}{
		{[]string{"hwtest", "--dc1-storage-worker"}, "roundtrip-v1", true},
		{[]string{"hwtest"}, "roundtrip-v1", false},
		{[]string{"hwtest", "-active"}, "roundtrip-v1", false},
		{[]string{"hwtest", "--dc1-storage-worker", "-active"}, "roundtrip-v1", false},
		{[]string{"hwtest", "--dc1-storage-worker"}, "", false},
		{[]string{"hwtest", "--dc1-storage-worker"}, "unexpected", false},
	} {
		if got := storageWorkerRequested(test.args, test.marker); got != test.want {
			t.Errorf("worker guard got %v, want %v", got, test.want)
		}
	}
}

func TestStorageRootMount(t *testing.T) {
	for _, test := range []struct {
		line            string
		found, writable bool
		fs              string
	}{
		{"31 1 8:1 / / rw,relatime - ext4 /dev/private-identifier rw", true, true, "ext4"},
		{"31 1 8:1 / / ro,relatime - ext4 /dev/private-identifier rw", true, false, "ext4"},
		{"31 1 8:1 / / rw,relatime - ext4 /dev/private-identifier ro", true, false, "ext4"},
		{"31 1 0:4 / / rw - tmpfs tmpfs rw", true, true, "tmpfs"},
		{"31 1 8:1 / /var/tmp rw - ext4 secret rw", false, false, ""},
		{"malformed", false, false, ""},
	} {
		got, ok := storageRootMount(test.line)
		if ok != test.found || got.fs != test.fs || got.writable != test.writable {
			t.Errorf("mount parse: got %+v %v, want %+v", got, ok, test)
		}
	}
}

func TestStoragePassiveAndFixtureActive(t *testing.T) {
	c := storageAudioFixture(t)
	c.Active = true // defense in depth beyond CLI fixture guard
	storageAudioPut(t, c, "/proc/self/mountinfo", "31 1 8:1 / / rw - ext4 /dev/PRIVATE_IDENTIFIER rw")
	storageAudioPut(t, c, "/sys/class/mmc_host/mmc0/present", "1")
	storageAudioPut(t, c, "/sys/class/block/mmcblk0/size", "249737216")
	storageAudioPut(t, c, "/sys/class/block/mmcblk0p1/size", "249735000")
	storageAudioPut(t, c, "/sys/class/block/mmcblk0boot0/size", "4096")
	r := &Reporter{group: "storage"}
	checkStorage(c, r)
	for _, name := range []string{"root filesystem", "root mount mode", "MMC hosts", "MMC media"} {
		if result := storageAudioResult(t, r, name); result.Status != Pass {
			t.Errorf("%s: %+v", name, result)
		}
	}
	if got := storageAudioResult(t, r, "MMC media"); !strings.Contains(got.Detail, "1 whole") {
		t.Errorf("partitions counted: %+v", got)
	}
	for _, name := range []string{"root free space", "root file round trip"} {
		if result := storageAudioResult(t, r, name); result.Status != Skip {
			t.Errorf("fixture performed host action: %+v", result)
		}
	}
	for _, result := range r.results {
		if strings.Contains(result.Detail, "PRIVATE_IDENTIFIER") {
			t.Fatal("mount identifier leaked")
		}
	}
}

func TestStorageMissingEvidence(t *testing.T) {
	c := storageAudioFixture(t)
	r := &Reporter{group: "storage"}
	checkStorage(c, r)
	for _, result := range r.results {
		if result.Status == Pass {
			t.Errorf("missing evidence passed: %+v", result)
		}
	}
}

func TestStorageFreeBytes(t *testing.T) {
	if got := storageFreeBytes(syscall.Statfs_t{Bsize: 4096, Bavail: 100}); got != 409600 {
		t.Fatal(got)
	}
	if got := storageFreeBytes(syscall.Statfs_t{Bsize: 0, Bavail: 100}); got != 0 {
		t.Fatal(got)
	}
	if got := storageFreeBytes(syscall.Statfs_t{Bsize: 4096, Bavail: ^uint64(0)}); got != ^uint64(0) {
		t.Fatal(got)
	}
}

func TestStorageRejectsDifferentFilesystem(t *testing.T) {
	c := storageAudioFixture(t)
	dir, err := os.Open(c.Root)
	if err != nil {
		t.Fatal(err)
	}
	defer dir.Close()
	info, err := dir.Stat()
	if err != nil {
		t.Fatal(err)
	}
	wrongDev := info.Sys().(*syscall.Stat_t).Dev + 1
	if err := storageInDirectory(dir, wrongDev); err == nil {
		t.Fatal("accepted directory outside root filesystem")
	}
	files, err := os.ReadDir(c.Root)
	if err != nil || len(files) != 0 {
		t.Fatalf("unexpected writes: %v %v", files, err)
	}
}

func TestStorageAudioRegistration(t *testing.T) {
	for name, order := range map[string]int{"storage": 80, "audio": 90} {
		found := false
		for _, g := range groups {
			if g.name == name {
				found = true
				if g.order != order {
					t.Errorf("%s order %d", name, g.order)
				}
			}
		}
		if !found {
			t.Errorf("%s group missing", name)
		}
	}
}
