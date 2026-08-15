// Package imagewrite owns the byte-critical part of an install: streaming a
// raw ext4 image onto the target partition, and proving afterwards that the
// bytes on the device are the bytes that were sent.
//
// This replaces a busybox shell pipeline
// (head -c | tee | dd) that silently corrupted every install: busybox
// `head -c` discards whatever it over-read past its byte count, so the body
// write began 1023 bytes into the image (measured on hardware) and every byte
// after the superblock landed shifted. The shell's SHA-256 check could not see
// it, because it hashed the `tee` branch -- what ARRIVED -- rather than what
// was written. Here the split is exact by construction (io.ReadFull), and the
// device is read back and hashed before the install is called a success.
//
// Fail-closed ordering, unchanged from the shell version it replaces:
//
//   - the first MiB (superblock) is held back in memory and written LAST, so
//     an aborted or corrupt transfer never leaves a mountable filesystem
//     labelled jagar-root behind;
//   - the target is resolved by GPT partition name by the caller, never a
//     hardcoded device node;
//   - any failure scrubs the first MiB, so nothing half-written is mountable.
package imagewrite

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"syscall"
)

// MiB is the held-back superblock window.
const MiB = 1 << 20

// Progress reports a stage to the caller (which relays it to the host).
type Progress func(state string)

// Target is the destination being written. *os.File satisfies it; the tests
// use a plain file, production uses the partition's block device.
type Target interface {
	io.WriterAt
	io.ReaderAt
	Sync() error
}

// Result carries what was actually written.
type Result struct {
	Bytes  int64
	SHA256 string
}

// Write streams exactly size bytes from src onto dst.
//
// The returned Result reflects the bytes that landed on the device: Write
// reads them back and hashes them, and returns an error if they differ from
// what was received. wantSHA is the digest the host declared; an empty string
// skips the transfer check (the network install has no independent digest for
// the decompressed stream) but never skips the read-back check.
func Write(dst Target, src io.Reader, size int64, wantSHA string, report Progress) (*Result, error) {
	if size < MiB {
		return nil, fmt.Errorf("image is %d bytes, smaller than the %d-byte superblock window", size, MiB)
	}
	if report == nil {
		report = func(string) {}
	}

	// Scrub the superblock first: from here until commit, the partition holds
	// nothing mountable.
	if err := scrub(dst); err != nil {
		return nil, fmt.Errorf("scrubbing the superblock: %w", err)
	}

	hasher := sha256.New()
	limited := io.LimitReader(src, size)
	hashed := io.TeeReader(limited, hasher)

	// Exactly one MiB, held back. io.ReadFull is the whole fix: it consumes
	// precisely this many bytes and not one more, whatever sizes the
	// underlying reads happen to return.
	first := make([]byte, MiB)
	if _, err := io.ReadFull(hashed, first); err != nil {
		return nil, fmt.Errorf("reading the superblock window: %w", err)
	}

	report("RECEIVING IMAGE")
	bodyLen := size - MiB
	written, err := copyAt(dst, hashed, MiB, bodyLen)
	if err != nil {
		_ = scrub(dst)
		return nil, fmt.Errorf("writing the image body: %w", err)
	}
	if written != bodyLen {
		_ = scrub(dst)
		return nil, fmt.Errorf("short image: got %d body bytes, want %d", written, bodyLen)
	}

	got := hex.EncodeToString(hasher.Sum(nil))
	if wantSHA != "" && got != wantSHA {
		_ = scrub(dst)
		return nil, fmt.Errorf("sha256 mismatch: got %s, want %s (short or corrupt transfer)", got, wantSHA)
	}
	report("SHA-256 VERIFIED")

	// Only now does the filesystem become mountable.
	if _, err := dst.WriteAt(first, 0); err != nil {
		_ = scrub(dst)
		return nil, fmt.Errorf("writing the verified superblock: %w", err)
	}
	if err := dst.Sync(); err != nil {
		_ = scrub(dst)
		return nil, fmt.Errorf("sync: %w", err)
	}
	// The block layer buffers the writes above. On the DC-1's UFS, the per-fd
	// fsync alone does NOT durably land the superblock -- a mount immediately
	// after read stale bytes ("Invalid argument"/"Data consistency error",
	// ext4 magic gone), while the read-back below still "passed" because it
	// was reading the page cache, not the disk. A global sync forces the
	// whole device's dirty pages out before anything else reads them.
	syscall.Sync()

	// Read the image back OFF the device -- from DISK, not the page cache we
	// just wrote. Drop the cache first so the hash proves what actually
	// landed: a cached read-back passes even when the flush was lost, which
	// is exactly the false "verified" that has cost re-installs on hardware.
	report("VERIFYING WRITTEN IMAGE")
	dropCaches()
	back, err := readBackSHA(dst, size)
	if err != nil {
		_ = scrub(dst)
		return nil, fmt.Errorf("reading the image back: %w", err)
	}
	if back != got {
		_ = scrub(dst)
		return nil, fmt.Errorf("read-back mismatch: device has %s, image is %s", back, got)
	}

	return &Result{Bytes: size, SHA256: got}, nil
}

// Scrub zeroes the first MiB, leaving nothing mountable behind. Exported so
// the caller can reject a session that failed outside Write.
func Scrub(dst Target) error { return scrub(dst) }

// dropCaches drops the page cache so a subsequent read hits the block device
// instead of the pages Write just dirtied. Best-effort: on a non-Linux host
// (or a missing /proc) it is a no-op and the read-back degrades to the old
// cache-backed check, not an error.
func dropCaches() {
	_ = os.WriteFile("/proc/sys/vm/drop_caches", []byte("3\n"), 0o644)
}

func scrub(dst Target) error {
	zero := make([]byte, MiB)
	if _, err := dst.WriteAt(zero, 0); err != nil {
		return err
	}
	return dst.Sync()
}

// copyAt writes exactly want bytes from src at the given offset.
func copyAt(dst io.WriterAt, src io.Reader, offset, want int64) (int64, error) {
	buf := make([]byte, 4<<20)
	var done int64
	for done < want {
		chunk := int64(len(buf))
		if remaining := want - done; remaining < chunk {
			chunk = remaining
		}
		n, err := io.ReadFull(src, buf[:chunk])
		if n > 0 {
			if _, werr := dst.WriteAt(buf[:n], offset+done); werr != nil {
				return done, werr
			}
			done += int64(n)
		}
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return done, nil
			}
			return done, err
		}
	}
	return done, nil
}

func readBackSHA(dst io.ReaderAt, size int64) (string, error) {
	hasher := sha256.New()
	buf := make([]byte, 4<<20)
	var done int64
	for done < size {
		chunk := int64(len(buf))
		if remaining := size - done; remaining < chunk {
			chunk = remaining
		}
		n, err := dst.ReadAt(buf[:chunk], done)
		if n > 0 {
			hasher.Write(buf[:n])
			done += int64(n)
		}
		if err != nil {
			if errors.Is(err, io.EOF) && done == size {
				break
			}
			return "", err
		}
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

// OpenTarget opens a block device (or, in tests, a regular file) for the
// read/write access Write needs.
func OpenTarget(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDWR, 0)
}
