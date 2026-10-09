package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const storageBytes = 1 << 20
const storageWorkerEnv = "DC1_HWTEST_STORAGE_WORKER"
const storageTmpfile = 0x400000 | syscall.O_DIRECTORY

var errStorageUnavailable = errors.New("storage preflight unavailable")

func storageWorkerExitCode(err error) int {
	if err == nil {
		return 0
	}
	if errors.Is(err, errStorageUnavailable) {
		return 2
	}
	return 1
}

func init() {
	// A separate process bounds even a stalled filesystem syscall. The worker
	// uses an unnamed private regular file so timeout/SIGKILL cannot leave a
	// named file behind; the last close releases its space.
	if storageWorkerRequested(os.Args, os.Getenv(storageWorkerEnv)) {
		if err := storageRoundTrip(); err != nil {
			// Do not emit paths, mount sources or arbitrary syscall error text.
			fmt.Fprintln(os.Stdout, "storage round trip unavailable or failed")
			os.Exit(storageWorkerExitCode(err))
		}
		fmt.Fprintln(os.Stdout, "OK")
		os.Exit(0)
	}
	register(80, "storage", "root filesystem and MMC evidence; -active for a bounded temporary-file round trip", checkStorage)
}

func storageWorkerRequested(args []string, marker string) bool {
	return marker == "roundtrip-v1" && len(args) == 2 && args[1] == "--dc1-storage-worker"
}

type storageMount struct {
	fs       string
	writable bool
}

func storageRootMount(s string) (storageMount, bool) {
	var result storageMount
	found := false
	for _, line := range strings.Split(s, "\n") {
		parts := strings.SplitN(line, " - ", 2)
		if len(parts) != 2 {
			continue
		}
		left, right := strings.Fields(parts[0]), strings.Fields(parts[1])
		if len(left) < 6 || len(right) < 3 || left[4] != "/" {
			continue
		}
		result = storageMount{fs: right[0], writable: storageOption(left[5], "rw") && storageOption(right[2], "rw")}
		found = true
	}
	return result, found
}

func storageOption(options, want string) bool {
	for _, option := range strings.Split(options, ",") {
		if option == want {
			return true
		}
	}
	return false
}

func checkStorage(c *Ctx, r *Reporter) {
	mounts, err := c.read("/proc/self/mountinfo")
	m, ok := storageRootMount(mounts)
	if err != nil || !ok {
		r.Skip("root mount", "root mount information unavailable")
	} else {
		if m.fs == "ext4" {
			r.Pass("root filesystem", "root is ext4; this does not verify the root label or boot partition mapping")
		} else {
			r.Warn("root filesystem", "root is not the expected ext4 filesystem (mount source omitted)")
		}
		if m.writable {
			r.Pass("root mount mode", "root mount reports read-write")
		} else {
			r.Warn("root mount mode", "root mount reports read-only")
		}
	}
	if filepath.Clean(c.Root) == "/" {
		var st syscall.Statfs_t
		if err := syscall.Statfs("/", &st); err != nil {
			r.Skip("root free space", "filesystem space unavailable")
		} else {
			r.Info("root free space", "%d MiB available to this user", storageFreeBytes(st)/(1<<20))
		}
	} else {
		r.Skip("root free space", "fixture mode: host filesystem space is not device evidence")
	}
	if hosts := c.glob("/sys/class/mmc_host/mmc*"); len(hosts) > 0 {
		r.Pass("MMC hosts", "%d host(s) registered; registration does not prove card I/O", len(hosts))
	} else {
		r.Skip("MMC hosts", "no MMC hosts visible")
	}
	cards := 0
	for _, block := range c.glob("/sys/class/block/mmcblk*") {
		name := filepath.Base(block)
		if strings.Contains(strings.TrimPrefix(name, "mmcblk"), "p") || strings.Contains(name, "boot") || strings.Contains(name, "rpmb") {
			continue
		}
		if n, err := c.readInt(block + "/size"); err == nil && n > 0 {
			cards++
		}
	}
	if cards > 0 {
		r.Pass("MMC media", "%d whole MMC block device(s) report nonzero capacity; no mount or read/write test performed", cards)
	} else {
		r.Skip("MMC media", "no whole MMC media with readable nonzero capacity; insert a card to test enumeration")
	}
	if !c.Active {
		r.Skip("root file round trip", "requires -active; no block devices are opened")
	} else if filepath.Clean(c.Root) != "/" {
		r.Skip("root file round trip", "disabled for fixtures")
	} else if !ok || m.fs != "ext4" || !m.writable {
		r.Skip("root file round trip", "requires a verified read-write ext4 root mount")
	} else {
		storageActive(c, r)
	}
}

func storageFreeBytes(st syscall.Statfs_t) uint64 {
	if st.Bsize <= 0 {
		return 0
	}
	blockSize := uint64(st.Bsize)
	if st.Bavail > ^uint64(0)/blockSize {
		return ^uint64(0)
	}
	return st.Bavail * blockSize
}

func storageActive(c *Ctx, r *Reporter) {
	parent := c.Cancel
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, 8*time.Second)
	defer cancel()
	executable, err := os.Executable()
	if err != nil {
		r.Skip("root file round trip", "cannot locate bounded worker executable")
		return
	}
	cmd := exec.CommandContext(ctx, executable, "--dc1-storage-worker")
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, storageWorkerEnv+"=") {
			cmd.Env = append(cmd.Env, entry)
		}
	}
	cmd.Env = append(cmd.Env, storageWorkerEnv+"=roundtrip-v1")
	cmd.WaitDelay = time.Second
	var output bytes.Buffer
	cmd.Stdout = &output
	// Worker emits only one fixed short line and no errors/identifiers.
	if err := cmd.Start(); err != nil {
		r.Skip("root file round trip", "cannot start bounded worker")
		return
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	// Wait stays in a reaper goroutine: SIGKILL cannot immediately stop a
	// task in uninterruptible filesystem I/O, so never Wait synchronously
	// after the deadline. Kernel recovery is needed to release its fd/space.
	select {
	case <-ctx.Done():
		r.Warn("root file round trip", "worker cancelled or exceeded 8 seconds; uninterruptible kernel I/O may delay termination and space release, but no named file remains")
		return
	case err := <-done:
		if err != nil {
			var exit *exec.ExitError
			if errors.As(err, &exit) && exit.ExitCode() == 2 {
				r.Skip("root file round trip", "preflight or unnamed-file creation unavailable (space, permission, unsupported filesystem)")
			} else {
				r.Fail("root file round trip", "bounded worker failed its write, sync, read-back digest or close; no raw error output retained")
			}
			return
		}
	}
	if strings.TrimSpace(output.String()) != "OK" {
		r.Fail("root file round trip", "unexpected worker result")
		return
	}
	r.Pass("root file round trip", "1 MiB unnamed private regular file on root filesystem: sync, read-back SHA-256 match, close/remove; cancellation-safe cleanup (not a durability or block-device test)")
}

func storageRoundTrip() error {
	root, err := os.Open("/")
	if err != nil {
		return errStorageUnavailable
	}
	defer root.Close()
	rootInfo, err := root.Stat()
	if err != nil {
		return errStorageUnavailable
	}
	rootDev := rootInfo.Sys().(*syscall.Stat_t).Dev
	for _, path := range []string{"/var/tmp", "/var/cache", "/"} {
		dir, err := os.Open(path)
		if err != nil {
			continue
		}
		err = storageInDirectory(dir, rootDev)
		dir.Close()
		if err == nil {
			return nil
		}
		if !errors.Is(err, errStorageUnavailable) {
			return err
		}
	}
	return errStorageUnavailable
}

func storageInDirectory(dir *os.File, rootDev uint64) error {
	info, err := dir.Stat()
	if err != nil {
		return errStorageUnavailable
	}
	if !info.IsDir() || info.Sys().(*syscall.Stat_t).Dev != rootDev {
		return errStorageUnavailable
	}
	var fs syscall.Statfs_t
	if err := syscall.Fstatfs(int(dir.Fd()), &fs); err != nil {
		return errStorageUnavailable
	}
	// Require ext4 (not tmpfs), rw, and leave at least 16 MiB free.
	if fs.Type != 0xef53 || fs.Flags&1 != 0 || storageFreeBytes(fs) < storageBytes+(16<<20) {
		return errStorageUnavailable
	}
	// O_TMPFILE creates an already-unlinked regular file, avoiding the
	// create/unlink cancellation window. Unsupported filesystems safely skip.
	fd, err := syscall.Openat(int(dir.Fd()), ".", syscall.O_RDWR|syscall.O_CLOEXEC|storageTmpfile, 0600)
	if err != nil {
		return errStorageUnavailable
	}
	f := os.NewFile(uintptr(fd), "private storage test")
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || !fi.Mode().IsRegular() {
		return errors.New("not a regular file")
	}
	data := make([]byte, storageBytes)
	for i := range data {
		data[i] = byte((i*131 + i/251) & 255)
	}
	want := sha256.Sum256(data)
	if n, err := f.Write(data); err != nil || n != len(data) {
		return errors.New("short or failed write")
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	got := sha256.New()
	n, err := io.Copy(got, io.LimitReader(f, storageBytes+1))
	if err != nil || n != storageBytes || !bytes.Equal(got.Sum(nil), want[:]) {
		return errors.New("read-back mismatch")
	}
	return f.Close()
}
