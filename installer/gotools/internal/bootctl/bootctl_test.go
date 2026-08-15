package bootctl

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"strings"
	"testing"
)

// realBlock is the control block read off this device on 2026-08-14: suffix
// "_a", magic BACB, version 1, nb_slot 2, slot A priority 15, slot B priority
// 14, both successful. Pinning the real bytes is what makes this a decoder
// test rather than a test of my own encoder.
func realBlock() []byte {
	b := make([]byte, Size)
	copy(b[0:4], []byte{'_', 'a', 0, 0})
	copy(b[4:8], []byte{0x42, 0x43, 0x41, 0x42}) // "BCAB" on the wire
	b[8] = 1                                     // version
	b[9] = 2                                     // nb_slot=2
	b[12], b[13] = 0x8f, 0x00                    // slot a
	b[14], b[15] = 0x8e, 0x00                    // slot b
	binary.LittleEndian.PutUint32(b[28:32], crc32.ChecksumIEEE(b[:Size-4]))
	return b
}

func TestParsesTheRealControlBlock(t *testing.T) {
	c, err := Parse(realBlock())
	if err != nil {
		t.Fatal(err)
	}
	if c.Magic != Magic {
		t.Fatalf("magic = %#x, want %#x", c.Magic, Magic)
	}
	if got := strings.TrimRight(string(c.SlotSuffix[:]), "\x00"); got != "_a" {
		t.Fatalf("suffix = %q, want _a", got)
	}
	if c.Version != 1 {
		t.Fatalf("version = %d, want 1", c.Version)
	}
	// The packed byte is the whole point: priority in the low nibble, tries
	// in the next three bits, successful in the top bit.
	if p, tr, s := c.Slots[0].Priority(), c.Slots[0].Tries(), c.Slots[0].Successful(); p != 15 || tr != 0 || s != 1 {
		t.Fatalf("slot a = prio %d tries %d successful %d, want 15/0/1", p, tr, s)
	}
	if p, tr, s := c.Slots[1].Priority(), c.Slots[1].Tries(), c.Slots[1].Successful(); p != 14 || tr != 0 || s != 1 {
		t.Fatalf("slot b = prio %d tries %d successful %d, want 14/0/1", p, tr, s)
	}
}

// The C version computed CRC-32 by hand with polynomial 0xedb88320, init
// 0xffffffff, final complement. That is exactly crc32.ChecksumIEEE; if it ever
// stops being, a dump would report MISMATCH on a healthy device and send
// someone chasing a layout problem that is not there.
func TestCRCMatchesTheStoredValue(t *testing.T) {
	raw := realBlock()
	c, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got := ComputedCRC(raw); got != c.CRC32LE {
		t.Fatalf("computed CRC %#x, stored %#x", got, c.CRC32LE)
	}
}

func TestDumpReportsAMismatchedCRCLoudly(t *testing.T) {
	raw := realBlock()
	raw[28] ^= 0xff // corrupt the stored CRC
	var out bytes.Buffer
	if err := Dump(&out, raw); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "do NOT write") {
		t.Fatalf("a corrupt CRC did not produce the warning:\n%s", out.String())
	}
}

func TestDumpFlagsBadMagic(t *testing.T) {
	raw := realBlock()
	raw[4] ^= 0xff
	var out bytes.Buffer
	if err := Dump(&out, raw); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "BAD MAGIC") {
		t.Fatalf("bad magic not reported:\n%s", out.String())
	}
}

// Mutation is retired; anything but `dump` must refuse rather than act.
func TestMutationIsRefused(t *testing.T) {
	dir := t.TempDir()
	dev := dir + "/misc"
	blob := make([]byte, Offset+Size)
	copy(blob[Offset:], realBlock())
	if err := writeFile(dev, blob); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DC1_MISC_DEV", dev)

	var out, errb bytes.Buffer
	if rc := Main([]string{"set-active"}, &out, &errb); rc != 2 {
		t.Fatalf("rc = %d, want 2", rc)
	}
	if !strings.Contains(errb.String(), "REFUSING") {
		t.Fatalf("stderr = %q", errb.String())
	}
}

func TestDumpSucceeds(t *testing.T) {
	dir := t.TempDir()
	dev := dir + "/misc"
	blob := make([]byte, Offset+Size)
	copy(blob[Offset:], realBlock())
	if err := writeFile(dev, blob); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DC1_MISC_DEV", dev)

	var out, errb bytes.Buffer
	if rc := Main([]string{"dump"}, &out, &errb); rc != 0 {
		t.Fatalf("rc = %d, want 0 (stderr %q)", rc, errb.String())
	}
	for _, want := range []string{"BACB ok", "(match)", "slot a:", "slot b:"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("dump missing %q:\n%s", want, out.String())
		}
	}
}
