package imagewrite

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"testing"
)

// dribbleReader hands back awkward, varying read sizes, the way a socket
// does. The shell implementation this package replaces was correct against a
// regular file and wrong against exactly this: its splitter over-read the
// pipe and threw the remainder away, so the body write started mid-image.
type dribbleReader struct {
	data []byte
	pos  int
	rng  *rand.Rand
}

func (d *dribbleReader) Read(p []byte) (int, error) {
	if d.pos >= len(d.data) {
		return 0, io.EOF
	}
	// 1..7001 bytes per read, so the 1 MiB boundary lands mid-read.
	n := d.rng.Intn(7000) + 1
	if n > len(p) {
		n = len(p)
	}
	if remaining := len(d.data) - d.pos; n > remaining {
		n = remaining
	}
	copy(p, d.data[d.pos:d.pos+n])
	d.pos += n
	return n, nil
}

func testImage(t *testing.T, size int) []byte {
	t.Helper()
	img := make([]byte, size)
	rng := rand.New(rand.NewSource(1))
	if _, err := rng.Read(img); err != nil {
		t.Fatal(err)
	}
	return img
}

func newTarget(t *testing.T, size int) *os.File {
	t.Helper()
	path := filepath.Join(t.TempDir(), "target.img")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(int64(size)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

func sum(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// The regression test for the bug that shipped: fed through a reader that
// returns awkward sizes, every byte must still land at the right offset.
func TestWriteIsByteExactFromADribblingReader(t *testing.T) {
	const size = 3 * MiB
	img := testImage(t, size)
	dst := newTarget(t, size)

	src := &dribbleReader{data: img, rng: rand.New(rand.NewSource(2))}
	res, err := Write(dst, src, size, sum(img), nil)
	if err != nil {
		t.Fatalf("Write: %v", err)
	}
	if res.Bytes != size {
		t.Fatalf("wrote %d bytes, want %d", res.Bytes, size)
	}

	got := make([]byte, size)
	if _, err := dst.ReadAt(got, 0); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, img) {
		for i := range got {
			if got[i] != img[i] {
				t.Fatalf("target differs from the image at byte %d "+
					"(the over-read regression shifts everything after the superblock)", i)
			}
		}
	}
}

// The superblock must be written LAST: until the transfer verifies, the first
// MiB must not contain the image's superblock, or an aborted install leaves a
// mountable filesystem behind.
func TestSuperblockIsHeldBackUntilTheTransferVerifies(t *testing.T) {
	const size = 3 * MiB
	img := testImage(t, size)
	dst := newTarget(t, size)

	// Truncated source: the body ends early, so the write must fail.
	src := bytes.NewReader(img[:size-4096])
	if _, err := Write(dst, src, size, sum(img), nil); err == nil {
		t.Fatal("accepted a short image")
	}

	first := make([]byte, MiB)
	if _, err := dst.ReadAt(first, 0); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, make([]byte, MiB)) {
		t.Fatal("superblock survived a failed transfer; the partition is mountable")
	}
}

func TestWriteRejectsASHAMismatch(t *testing.T) {
	const size = 3 * MiB
	img := testImage(t, size)
	dst := newTarget(t, size)

	wrong := sum([]byte("not the image"))
	if _, err := Write(dst, bytes.NewReader(img), size, wrong, nil); err == nil {
		t.Fatal("accepted an image whose digest did not match")
	}
	first := make([]byte, MiB)
	if _, err := dst.ReadAt(first, 0); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, make([]byte, MiB)) {
		t.Fatal("superblock written despite a digest mismatch")
	}
}

// A device that silently drops writes past some offset (which is what the
// shipped bug looked like from the outside) must be caught by the read-back,
// not reported as a successful install.
type lyingTarget struct {
	f     *os.File
	after int64
}

func (l *lyingTarget) WriteAt(p []byte, off int64) (int, error) {
	if off >= l.after {
		return len(p), nil // pretend
	}
	// A write straddling the boundary is truncated, and the caller is still
	// told every byte landed -- the shape of a device that quietly stops
	// accepting data partway through a large transfer.
	if end := off + int64(len(p)); end > l.after {
		keep := l.after - off
		if _, err := l.f.WriteAt(p[:keep], off); err != nil {
			return 0, err
		}
		return len(p), nil
	}
	return l.f.WriteAt(p, off)
}
func (l *lyingTarget) ReadAt(p []byte, off int64) (int, error) { return l.f.ReadAt(p, off) }
func (l *lyingTarget) Sync() error                             { return l.f.Sync() }

func TestReadBackCatchesADeviceThatDropsWrites(t *testing.T) {
	const size = 3 * MiB
	img := testImage(t, size)
	dst := &lyingTarget{f: newTarget(t, size), after: 2 * MiB}

	_, err := Write(dst, bytes.NewReader(img), size, sum(img), nil)
	if err == nil {
		t.Fatal("reported success for a device that dropped writes")
	}
}
