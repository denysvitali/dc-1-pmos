package debugtools

import (
	"bytes"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/partition"
)

// fakeDevice lays down a regular file to stand in for a partition node and
// returns its path. Content lands at `at`; when total is given the file is
// truncated to it, so reads through the hole-y middle return zeros -- how
// the LK/expdb tests fake multi-GB devices without disk cost.
func fakeDevice(t *testing.T, dir, name string, content []byte, at int64, total ...int64) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.WriteAt(content, at); err != nil {
		t.Fatal(err)
	}
	if len(total) > 0 && total[0] > 0 {
		if err := f.Truncate(total[0]); err != nil {
			t.Fatal(err)
		}
	}
	return f.Name()
}

// fakeSysfs points the partition package at a temp sysfs tree plus a
// SEPARATE temp device directory -- on the real device /sys/class/block and
// /dev are different filesystems, and a name collision here would be exactly
// the kind of mistake the tests exist to catch.
func fakeSysfs(t *testing.T, parts map[string]string, sectors map[string]int64) {
	t.Helper()
	root := t.TempDir()
	for dev, name := range parts {
		d := filepath.Join(root, dev)
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		body := "DEVTYPE=partition\n"
		if name != "" {
			body += "PARTNAME=" + name + "\n"
		}
		if err := os.WriteFile(filepath.Join(d, "uevent"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "size"),
			[]byte(strconv.FormatInt(sectors[dev], 10)+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	oldBlock, oldDev := partition.SysBlock, partition.DevDir
	partition.SysBlock, partition.DevDir = root, t.TempDir()
	t.Cleanup(func() { partition.SysBlock, partition.DevDir = oldBlock, oldDev })
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func testEnv(t *testing.T) env {
	t.Helper()
	return env{
		sysBlock:  partition.SysBlock,
		devDir:    t.TempDir(), // where fake device nodes go in these tests
		devMem:    filepath.Join(t.TempDir(), "mem"),
		pstoreDir: filepath.Join(t.TempDir(), "pstore"),
		outDir:    filepath.Join(t.TempDir(), "debug"),
		cmdline:   filepath.Join(t.TempDir(), "cmdline"),
		meminfo:   filepath.Join(t.TempDir(), "meminfo"),
		uptime:    filepath.Join(t.TempDir(), "uptime"),
		osrelease: filepath.Join(t.TempDir(), "osrelease"),
	}
}

// ----------------------------------------------------------------------- info

func TestInfoReportShowsSlotAndOmitsSerial(t *testing.T) {
	fakeSysfs(t, map[string]string{"sdc29": "expdb"}, map[string]int64{"sdc29": 16384})
	e := testEnv(t)
	writeFile(t, e.cmdline,
		"console=tty0 androidboot.slot_suffix=_a androidboot.serialno=TOPSECRET bootopt=64B3M2")
	writeFile(t, e.osrelease, "6.12.34-dc1\n")
	writeFile(t, e.meminfo, "MemTotal:        2048000 kB\nMemFree:         1024000 kB\n")
	writeFile(t, e.uptime, "1234.56 0.00\n")

	rep, _ := infoReport(e)
	if !strings.Contains(rep, "slot:    _a") {
		t.Fatalf("report missing slot:\n%s", rep)
	}
	if strings.Contains(rep, "TOPSECRET") || strings.Contains(rep, "serial") {
		t.Fatalf("report leaked the serial number:\n%s", rep)
	}
	if !strings.Contains(rep, "kernel:  6.12.34-dc1") ||
		!strings.Contains(rep, "mem:     2000 MiB total, 1000 MiB free") ||
		!strings.Contains(rep, "uptime:  1234 s") {
		t.Fatalf("kernel/mem/uptime sections wrong:\n%s", rep)
	}
	if !strings.Contains(rep, "expdb") || !strings.Contains(rep, "(1 partitions)") {
		t.Fatalf("inventory missing:\n%s", rep)
	}
}

func TestInfoReportDegradesWithoutAnyFiles(t *testing.T) {
	fakeSysfs(t, nil, nil)
	e := testEnv(t)
	rep, ok := infoReport(e)
	if ok {
		t.Fatal("empty environment reported as complete")
	}
	for _, want := range []string{"unknown (no build stamp)", "slot:    unknown", "(none found)"} {
		if !strings.Contains(rep, want) {
			t.Fatalf("degraded report missing %q:\n%s", want, rep)
		}
	}
}

func TestCmdlineValueIsWholeToken(t *testing.T) {
	got := cmdlineValue("a=1 ab=2 abc=3", "ab")
	if got != "2" {
		t.Fatalf("cmdlineValue matched %q, want 2", got)
	}
}

// ----------------------------------------------------------------------- hash

func TestHashReportDigestsMatchContent(t *testing.T) {
	content := []byte("dc1 bootloader control block, twice over: 0123456789abcdef")
	fakeSysfs(t,
		map[string]string{"sdc5": "boot_a", "sdc6": "boot_b"},
		map[string]int64{"sdc5": int64(len(content)) / 512, "sdc6": 8},
	)
	e := testEnv(t)
	// The "device nodes" live where fakeSysfs pointed DevDir.
	fakeDevice(t, partition.DevDir, "sdc5", content, 0)
	// boot_b exists as a hole-y file: reads back zeros.
	fakeDevice(t, partition.DevDir, "sdc6", nil, 0, 8*512)

	rep, ok := hashReport(e, []string{"boot_a", "boot_b"})
	if !ok {
		t.Fatalf("hash run not ok:\n%s", rep)
	}
	want5 := md5.Sum(content)
	want256 := sha256.Sum256(content)
	if !strings.Contains(rep, hex.EncodeToString(want5[:])) ||
		!strings.Contains(rep, hex.EncodeToString(want256[:])) {
		t.Fatalf("boot_a digests wrong:\n%s", rep)
	}
	zeros := make([]byte, 8*512)
	wantz := sha256.Sum256(zeros)
	if !strings.Contains(rep, hex.EncodeToString(wantz[:])) {
		t.Fatalf("sparse boot_b digest wrong:\n%s", rep)
	}
	saved, err := os.ReadFile(filepath.Join(e.outDir, "partition-hashes.txt"))
	if err != nil || !bytes.Contains(saved, []byte(hex.EncodeToString(want5[:]))) {
		t.Fatalf("saved report missing digests: %v", err)
	}
}

func TestHashReportSkipsOversizeAndMissing(t *testing.T) {
	fakeSysfs(t,
		map[string]string{"sdc57": "userdata", "sdc5": "boot_a"},
		map[string]int64{
			"sdc57": (maxHashBytes / 512) + 100, // just over the cap
			"sdc5":  16,
		})
	e := testEnv(t)
	fakeDevice(t, partition.DevDir, "sdc5", []byte("tiny"), 0)

	// Cap-skip alone is a successful observation: userdata was NOT read.
	rep, ok := hashReport(e, []string{"userdata"})
	if !ok || !strings.Contains(rep, "skipped") || !strings.Contains(rep, "cap") {
		t.Fatalf("oversize partition not skipped cleanly (ok=%v):\n%s", ok, rep)
	}
	if strings.Contains(rep, "md5:") {
		t.Fatalf("oversize partition was hashed anyway:\n%s", rep)
	}

	// A name that resolves to nothing IS a failure of the requested set,
	// reported inline while the rest still hashes.
	rep, ok = hashReport(e, []string{"boot_a", "lk"})
	if ok {
		t.Fatal("a not-found partition must fail the run")
	}
	if !strings.Contains(rep, "lk: not found") || strings.Count(rep, "md5:") != 1 {
		t.Fatalf("mixed run wrong:\n%s", rep)
	}

	// The same shape through Main exits nonzero because lk was missing.
	var out bytes.Buffer
	rc := Main([]string{"hash", "userdata", "lk"}, &out, &out)
	if rc != 1 {
		t.Fatalf("Main(hash with a missing partition) = %d, want 1", rc)
	}
}

// ----------------------------------------------------------------------- logs

func TestPrintableTextBreaksOnBinaryRuns(t *testing.T) {
	in := []byte("\x01LK said:\x00\x00\x00hello world\x01\x02again\nend\x7f")
	got := printableText(in)
	want := "LK said:\nhello world\nagain\nend"
	if got != want {
		t.Fatalf("printableText:\n got %q\nwant %q", got, want)
	}
}

func TestTailLinesKeepsTheRequestedCount(t *testing.T) {
	s := strings.Repeat("x\n", 30) + "last" // 31 lines
	got := tailLines(s, 15)
	lines := strings.Split(got, "\n")
	if len(lines) != 15 || lines[len(lines)-1] != "last" {
		t.Fatalf("tailLines kept %d lines, want 15 ending in last: %q",
			len(lines), got)
	}
}

func TestCollectLKReadsTheRing(t *testing.T) {
	e := testEnv(t)
	ring := "LK log line one\r\n" + strings.Repeat("\x00", 32) + "second line"
	mem := fakeDevice(t, e.devDir, "mem", []byte(ring), lkBase,
		lkBase+lkPages*pageSz)
	if err := os.MkdirAll(e.outDir, 0o755); err != nil {
		t.Fatal(err)
	}

	raw, err := readLKRing(mem)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != lkPages*pageSz {
		t.Fatalf("ring read is %d bytes, want %d", len(raw), lkPages*pageSz)
	}
	rep, err := saveLK(e.outDir, raw)
	if err != nil {
		t.Fatal(err)
	}
	saved, err := os.ReadFile(filepath.Join(e.outDir, "lk-log.bin"))
	if err != nil || len(saved) != lkPages*pageSz {
		t.Fatalf("raw ring file is %d bytes (%v), want %d",
			len(saved), err, lkPages*pageSz)
	}
	txt, err := os.ReadFile(filepath.Join(e.outDir, "lk-log.txt"))
	if err != nil || !strings.Contains(string(txt), "second line") {
		t.Fatalf("text view wrong (%v):\n%s", err, txt)
	}
	if !strings.Contains(rep, "last lines:") {
		t.Fatalf("report lacks tail:\n%s", rep)
	}

	// A missing memory device fails cleanly rather than panicking.
	if _, err := readLKRing(filepath.Join(e.devDir, "absent")); err == nil {
		t.Fatal("readLKRing succeeded without the mem device")
	}
}

// The on-screen LK viewer pages exactly lkViewLines lines of the ring tail,
// no matter how much printable text the 256 KiB ring carries.
func TestLKViewTailIsBounded(t *testing.T) {
	var b strings.Builder
	for i := 0; i < lkViewLines*3; i++ {
		fmt.Fprintf(&b, "line %d\n", i)
	}
	view := tailLines(printableText([]byte(b.String())), lkViewLines)
	lines := strings.Split(view, "\n")
	if len(lines) != lkViewLines {
		t.Fatalf("viewer window is %d lines, want %d", len(lines), lkViewLines)
	}
	if lines[len(lines)-1] != fmt.Sprintf("line %d", lkViewLines*3-1) {
		t.Fatalf("window does not end at the newest line: %q", lines[len(lines)-1])
	}
}

func TestTruncateLineClamps(t *testing.T) {
	if got := truncateLine("short", 60); got != "short" {
		t.Fatalf("truncateLine altered a short line: %q", got)
	}
	got := truncateLine(strings.Repeat("x", 100), 60)
	if len(got) != 63 || !strings.HasSuffix(got, "...") {
		t.Fatalf("truncateLine produced %d chars: %q", len(got), got)
	}
}

func TestCollectExpdbHonoursTheCap(t *testing.T) {
	// 17 MiB of sparse content: over the cap, so only the first expdbReadCap
	// bytes may be read.
	fakeSysfs(t, map[string]string{"sdc40": "expdb"},
		map[string]int64{"sdc40": (expdbReadCap + (1 << 20)) / 512})
	e := testEnv(t)
	fakeDevice(t, partition.DevDir, "sdc40",
		[]byte("persisted failed-slot log"), 0, expdbReadCap+(1<<20))
	if err := os.MkdirAll(e.outDir, 0o755); err != nil {
		t.Fatal(err)
	}

	rep, err := collectExpdb(e.outDir)
	if err != nil {
		t.Fatal(err)
	}
	bin, err := os.Stat(filepath.Join(e.outDir, "expdb.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if bin.Size() != expdbReadCap {
		t.Fatalf("expdb.bin is %d bytes, want the %d cap", bin.Size(), expdbReadCap)
	}
	if !strings.Contains(rep, "truncated at") {
		t.Fatalf("truncation note missing:\n%s", rep)
	}
}

func TestCollectPstoreCopiesWithoutDeleting(t *testing.T) {
	e := testEnv(t)
	src := e.pstoreDir // never the default path, so no mount is attempted
	if err := os.MkdirAll(src, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(src, "dmesg-ramoops-0"), "panic text")
	writeFile(t, filepath.Join(src, "pmsg-ramoops-0"), "userspace msg")
	if err := os.MkdirAll(filepath.Join(src, "subdir"), 0o755); err != nil {
		t.Fatal(err)
	}

	rep, err := collectPstore(src, e.outDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"dmesg-ramoops-0", "pmsg-ramoops-0"} {
		got, err := os.ReadFile(filepath.Join(e.outDir, "pstore", n))
		if err != nil {
			t.Fatalf("copy of %s missing: %v", n, err)
		}
		want, _ := os.ReadFile(filepath.Join(src, n))
		if !bytes.Equal(got, want) {
			t.Fatalf("%s copy differs from source", n)
		}
	}
	if !strings.Contains(rep, "2 records") {
		t.Fatalf("record count wrong:\n%s", rep)
	}
}

func TestCollectPstoreEmptyIsNotAnError(t *testing.T) {
	e := testEnv(t)
	if err := os.MkdirAll(e.pstoreDir, 0o755); err != nil {
		t.Fatal(err)
	}
	rep, err := collectPstore(e.pstoreDir, e.outDir)
	if err != nil {
		t.Fatalf("empty pstore returned an error: %v", err)
	}
	if !strings.Contains(rep, "unverified on this hardware") {
		t.Fatalf("empty pstore lacks the caveat:\n%s", rep)
	}
}

func TestLogsCollectContinuesPastFailures(t *testing.T) {
	fakeSysfs(t, map[string]string{"sdc40": "expdb"},
		map[string]int64{"sdc40": 512})
	e := testEnv(t)
	fakeDevice(t, partition.DevDir, "sdc40", []byte("expdb content here"), 0)
	if err := os.MkdirAll(e.pstoreDir, 0o755); err != nil {
		t.Fatal(err)
	}

	oldKmsg := kmsgReadAll
	kmsgReadAll = func() ([]byte, error) { return []byte("<3>fake kernel line\n"), nil }
	t.Cleanup(func() { kmsgReadAll = oldKmsg })

	// No devmem file: the lk collector must fail while the others succeed.
	rep, anyOK := logsCollect(e, "all")
	if !anyOK {
		t.Fatalf("all-fail exit despite dmesg/pstore/expdb success:\n%s", rep)
	}
	if !strings.Contains(rep, "logs saved under") ||
		!strings.Contains(rep, "172.16.42.1") {
		t.Fatalf("summary lines missing:\n%s", rep)
	}
	if _, err := os.Stat(filepath.Join(e.outDir, "dmesg.txt")); err != nil {
		t.Fatalf("dmesg.txt not written: %v", err)
	}

	// Everything unavailable -> reported, anyOK false.
	e2 := testEnv(t)
	kmsgReadAll = func() ([]byte, error) { return nil, os.ErrNotExist }
	rep2, anyOK2 := logsCollect(e2, "all")
	if anyOK2 {
		t.Fatalf("reported success with nothing collected:\n%s", rep2)
	}

	// An unknown single source is an error, not silent success.
	if _, ok := logsCollect(e, "nope"); ok {
		t.Fatal("unknown log source accepted")
	}
}

// ------------------------------------------------------------------ main wiring

// Main threads the DC1_* hooks into the collectors; prove the whole CLI path
// against fakes, including that `version` prints the stamp variable. Sysfs
// and devices get separate directories, like they have on the device.
func TestMainSubcommands(t *testing.T) {
	root := t.TempDir()
	block := filepath.Join(root, "block")
	dev := filepath.Join(root, "dev")
	for _, d := range []string{filepath.Join(block, "sdc5"), dev} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, filepath.Join(block, "sdc5", "uevent"), "PARTNAME=misc\n")
	writeFile(t, filepath.Join(block, "sdc5", "size"), "512\n")
	writeFile(t, filepath.Join(dev, "sdc5"), "misc partition bytes")

	t.Setenv("DC1_SYSBLOCK", block)
	t.Setenv("DC1_DEVDIR", dev)
	t.Setenv("DC1_DEBUG_DIR", filepath.Join(root, "out"))
	t.Setenv("DC1_CMDLINE", filepath.Join(root, "cmdline"))
	t.Setenv("DC1_DEVMEM", filepath.Join(dev, "mem"))
	t.Setenv("DC1_PSTORE_DIR", filepath.Join(root, "pstore"))

	var out bytes.Buffer
	Version = "abc1234-test"
	if rc := Main([]string{"version"}, &out, &out); rc != 0 || out.String() != "abc1234-test\n" {
		t.Fatalf("version: rc=%d out=%q", rc, out.String())
	}
	out.Reset()
	if rc := Main([]string{"info"}, &out, &out); rc != 0 ||
		!strings.Contains(out.String(), "version: abc1234-test") {
		t.Fatalf("info via Main:\n%s", out.String())
	}
	out.Reset()
	if rc := Main([]string{"hash", "misc"}, &out, &out); rc != 0 {
		t.Fatalf("hash misc: rc=%d\n%s", rc, out.String())
	}
	want := sha256.Sum256([]byte("misc partition bytes"))
	if !strings.Contains(out.String(), hex.EncodeToString(want[:])) {
		t.Fatalf("hash misc digests wrong:\n%s", out.String())
	}
	out.Reset()
	if rc := Main([]string{"nonsense"}, &out, &out); rc != 2 {
		t.Fatalf("unknown command rc=%d, want 2", rc)
	}
}
