// Package bootctl decodes the A/B bootloader_control block.
//
// Why it exists: a kernel that dies AFTER LK hands off is, from LK's point of
// view, a successful boot -- LK loaded the image fine -- so LK never decrements
// the retry counter and never falls back. On 2026-08-03 that left the device
// cycling on a bad slot A for 8+ minutes with a known-good slot B right there.
//
// DELIBERATELY READ-ONLY. The struct layout is AOSP's, but this device's LK is
// the authority, so a dump must be cross-checked against
// `fastboot getvar slot-successful:a` before anyone trusts a write. A wrong CRC
// or wrong offset here would make BOTH slots unbootable, which is the exact
// failure this is meant to prevent. Mutation was retired on 2026-08-11: a
// caller-supplied slot letter is not running-image proof.
package bootctl

import (
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"strings"
)

const (
	// Offset of the control block inside misc.
	Offset = 2048
	// Magic is "BACB" little-endian.
	Magic = 0x42414342
	// Size of the packed struct on disk.
	Size = 32
)

// SlotMetadata is one slot's packed priority/tries/successful byte plus flags.
type SlotMetadata struct {
	PriorityTries uint8
	Flags         uint8
}

func (s SlotMetadata) Priority() int   { return int(s.PriorityTries & 0x0f) }
func (s SlotMetadata) Tries() int      { return int((s.PriorityTries >> 4) & 0x07) }
func (s SlotMetadata) Successful() int { return int((s.PriorityTries >> 7) & 0x01) }

// Control is the decoded bootloader_control block.
type Control struct {
	SlotSuffix [4]byte
	Magic      uint32
	Version    uint8
	Flags      uint8
	Reserved0  [2]byte
	Slots      [4]SlotMetadata
	Reserved1  [8]byte
	CRC32LE    uint32
}

// Parse decodes a control block from its 32 on-disk bytes.
func Parse(b []byte) (*Control, error) {
	if len(b) < Size {
		return nil, fmt.Errorf("bootloader_control is %d bytes, want %d", len(b), Size)
	}
	c := &Control{}
	copy(c.SlotSuffix[:], b[0:4])
	c.Magic = binary.LittleEndian.Uint32(b[4:8])
	c.Version = b[8]
	c.Flags = b[9]
	copy(c.Reserved0[:], b[10:12])
	for i := 0; i < 4; i++ {
		c.Slots[i] = SlotMetadata{PriorityTries: b[12+i*2], Flags: b[13+i*2]}
	}
	copy(c.Reserved1[:], b[20:28])
	c.CRC32LE = binary.LittleEndian.Uint32(b[28:32])
	return c, nil
}

// ComputedCRC is the CRC-32 over everything but the trailing CRC field. This
// is the standard zlib/ethernet polynomial, the same one the C version
// computed by hand.
func ComputedCRC(b []byte) uint32 {
	if len(b) < Size {
		return 0
	}
	return crc32.ChecksumIEEE(b[:Size-4])
}

// Dump renders the human-readable report, byte-for-byte the same shape the C
// implementation printed so existing recovery notes still read true.
func Dump(w io.Writer, raw []byte) error {
	c, err := Parse(raw)
	if err != nil {
		return err
	}
	magicNote := "(BAD MAGIC)"
	if c.Magic == Magic {
		magicNote = "(BACB ok)"
	}
	suffix := strings.TrimRight(string(c.SlotSuffix[:]), "\x00")
	fmt.Fprintf(w, "magic=0x%08x %s  version=%d  suffix=%s\n",
		c.Magic, magicNote, c.Version, suffix)

	want := ComputedCRC(raw)
	crcNote := "(match)"
	if c.CRC32LE != want {
		crcNote = "(MISMATCH -- layout is wrong, do NOT write)"
	}
	fmt.Fprintf(w, "crc stored=0x%08x computed=0x%08x %s\n", c.CRC32LE, want, crcNote)

	for i := 0; i < 2; i++ {
		fmt.Fprintf(w, "  slot %c: priority=%d tries_remaining=%d successful=%d\n",
			'a'+i, c.Slots[i].Priority(), c.Slots[i].Tries(), c.Slots[i].Successful())
	}
	return nil
}

// Read pulls the raw control block out of the misc partition.
func Read(dev string) ([]byte, error) {
	f, err := os.Open(dev)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	buf := make([]byte, Size)
	if _, err := f.ReadAt(buf, Offset); err != nil {
		return nil, fmt.Errorf("reading %s at %d: %w", dev, Offset, err)
	}
	return buf, nil
}

// Main is the `bootctl` entry point.
func Main(args []string, stdout, stderr io.Writer) int {
	dev := os.Getenv("DC1_MISC_DEV")
	if dev == "" {
		dev = "/dev/sdc1"
	}
	cmd := "dump"
	if len(args) > 0 {
		cmd = args[0]
	}

	raw, err := Read(dev)
	if err != nil {
		fmt.Fprintf(stderr, "bootctl: %v\n", err)
		return 1
	}
	if err := Dump(stdout, raw); err != nil {
		fmt.Fprintf(stderr, "bootctl: %v\n", err)
		return 1
	}
	if cmd == "dump" {
		return 0
	}
	fmt.Fprintf(stderr, "bootctl: REFUSING: mutation command %q is retired; "+
		"use host-side slot-guard.py with exact A/B image evidence\n", cmd)
	return 2
}

// writeFile is a tiny helper the tests use to lay down a fake misc device.
func writeFile(path string, b []byte) error { return os.WriteFile(path, b, 0o600) }
