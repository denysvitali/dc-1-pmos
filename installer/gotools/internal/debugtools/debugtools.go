// Package debugtools is dc1-debug: the on-device debugging toolkit.
//
// Screen-first: `dc1-debug menu` drives PID 1's dialog server -- the same
// on-panel screens tui.sh uses -- so device info, partition checksums, and
// log collection are reachable from the touchscreen with no keyboard. The
// same collectors are plain subcommands (`info`, `hash`, `logs`) for the USB
// shells, which stay the fallback when the panel is dark.
//
// READ-ONLY BY CONSTRUCTION. Nothing here opens a partition for writing,
// selects a slot, or writes /dev/mem; the only writes are regular files
// under /tmp/debug (a tmpfs -- lost on reboot, which is also the privacy
// story: nothing collected persists a boot unless the user copies it off).
// Hashing streams each partition once through md5+sha256 in a single read
// pass and refuses anything above maxHashBytes, so a typo'd name cannot
// turn into an hour-long read of userdata.
package debugtools

import (
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"unsafe"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/ask"
	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/partition"
)

// Version is stamped at build time by installer/build.sh with
// -ldflags -X (git short SHA, -dirty when the tree was not clean). It is the
// answer to "what is on this device", so the default is a loud unknown.
var Version = "unknown"

const (
	// maxHashBytes caps one partition read: the default hash set is all
	// small, and anything bigger (userdata is >=32 GiB) is a mistake.
	maxHashBytes = 256 << 20

	// expdbReadCap bounds the expdb dump. The partition holds the failed
	// slot's persisted LK log; its layout is undocumented, so the text
	// view is a best-effort printable filter, not a parser.
	expdbReadCap = 16 << 20

	// LK's current-boot log ring: physical 0x7ffbf000, 256 KiB (64 pages).
	// Readable because CONFIG_STRICT_DEVMEM is off; the DT keeps the region
	// mapped (log_store@7ffbf000). The ring is reset before LK falls back,
	// so it shows the boot that SUCCEEDED; the failed slot is in expdb.
	lkBase  = 0x7ffbf000
	lkPages = 64
	pageSz  = 4096

	// defaultHashNames is the hash set: every partition that decides
	// whether this device boots, none of them user data.
	defaultHashNames = "boot_a boot_b lk dtbo misc expdb"

	// menuLinesPerPage is the info-screen chunk size. PID 1's infoLayout
	// fits ~19 lines above the OK button on the 1200x1600 panel; 12 keeps
	// a comfortable margin and a visible title.
	menuLinesPerPage = 12

	// lkViewLines is how much of the LK ring tail the on-screen viewer
	// pages through: 5 pages of OK taps. LK's interesting decisions (slot
	// selection, fallback) are at the END of the ring; the full 256 KiB is
	// always saved to /tmp/debug by Collect logs.
	lkViewLines = 60
)

// env is every filesystem location the toolkit touches, hookable for the
// offline tests (DC1_* variables, same convention as the shell scripts and
// bootctl's DC1_MISC_DEV).
type env struct {
	sysBlock  string
	devDir    string
	devMem    string
	pstoreDir string
	outDir    string
	cmdline   string
	meminfo   string
	uptime    string
	osrelease string
}

func envFromOs() env {
	return env{
		sysBlock:  getenv("DC1_SYSBLOCK", "/sys/class/block"),
		devDir:    getenv("DC1_DEVDIR", "/dev"),
		devMem:    getenv("DC1_DEVMEM", "/dev/mem"),
		pstoreDir: getenv("DC1_PSTORE_DIR", "/sys/fs/pstore"),
		outDir:    getenv("DC1_DEBUG_DIR", "/tmp/debug"),
		cmdline:   getenv("DC1_CMDLINE", "/proc/cmdline"),
		meminfo:   getenv("DC1_MEMINFO", "/proc/meminfo"),
		uptime:    getenv("DC1_UPTIME", "/proc/uptime"),
		osrelease: getenv("DC1_OSRELEASE", "/proc/sys/kernel/osrelease"),
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// Main is the `dc1-debug` applet entry point.
func Main(args []string, stdout, stderr io.Writer) int {
	e := envFromOs()
	partition.SysBlock = e.sysBlock
	partition.DevDir = e.devDir

	cmd := "menu"
	var rest []string
	if len(args) > 0 {
		cmd = args[0]
		rest = args[1:]
	}

	switch cmd {
	case "menu":
		return menuMain(e, stderr)
	case "info":
		rep, _ := infoReport(e)
		fmt.Fprint(stdout, rep)
		return 0
	case "hash":
		names := strings.Fields(defaultHashNames)
		if len(rest) > 0 {
			names = rest
		}
		rep, ok := hashReport(e, names)
		fmt.Fprint(stdout, rep)
		if !ok {
			return 1
		}
		return 0
	case "logs":
		which := "all"
		if len(rest) > 0 {
			which = rest[0]
		}
		rep, anyOK := logsCollect(e, which)
		fmt.Fprint(stdout, rep)
		if !anyOK {
			return 1
		}
		return 0
	case "version":
		fmt.Fprintln(stdout, Version)
		return 0
	case "-h", "--help", "help":
		fmt.Fprint(stdout, usage)
		return 0
	}
	fmt.Fprintf(stderr, "dc1-debug: unknown command %q\n%s", cmd, usage)
	return 2
}

const usage = `usage: dc1-debug [command]

commands:
  menu                on-screen debug menu (default; needs the touch UI)
  info                device + installer report
  hash [PART...]      md5+sha256 of partitions (default: ` + defaultHashNames + `)
  logs [all|dmesg|lk|pstore|expdb]
                      collect logs under ` + "/tmp/debug" + `
  version             print the installer version this image was built from

Everything here is read-only on partitions and memory. Files land in
/tmp/debug (RAM); nothing is flashed, nothing selects a slot.
`

// ----------------------------------------------------------------- device info

// infoReport renders the on-screen device report. It degrades gracefully:
// every section independently falls back to "unknown", because this is the
// tool the user reaches for when things are already broken. The kernel
// command line is filtered through a whitelist -- the serial number lives
// there too, and serials must never reach a screen the user may photograph
// for a bug report.
func infoReport(e env) (string, bool) {
	var b strings.Builder
	fmt.Fprintln(&b, "DC-1 INSTALLER DEBUG")

	if Version == "unknown" {
		fmt.Fprintln(&b, "version: unknown (no build stamp)")
	} else {
		fmt.Fprintf(&b, "version: %s\n", Version)
	}
	fmt.Fprintf(&b, "kernel:  %s\n", oneLine(e.osrelease, "unknown"))

	cmd := readFile(e.cmdline)
	if slot := cmdlineValue(cmd, "androidboot.slot_suffix"); slot != "" {
		fmt.Fprintf(&b, "slot:    %s\n", slot)
	} else {
		fmt.Fprintln(&b, "slot:    unknown")
	}
	if reason := cmdlineValue(cmd, "androidboot.bootreason"); reason != "" {
		fmt.Fprintf(&b, "bootreason: %s\n", reason)
	}

	total, free := meminfoMiB(e.meminfo)
	if total > 0 {
		fmt.Fprintf(&b, "mem:     %d MiB total, %d MiB free\n", total, free)
	}
	if up, ok := uptimeSeconds(e.uptime); ok {
		fmt.Fprintf(&b, "uptime:  %d s\n", up)
	}

	fmt.Fprintln(&b, "")
	fmt.Fprintln(&b, "partitions (MiB):")
	inv, err := partition.Inventory()
	if err != nil || len(inv) == 0 {
		fmt.Fprintln(&b, "  (none found)")
		return b.String(), false
	}
	for _, p := range inv {
		fmt.Fprintf(&b, "  %-16s %-8s %6d\n", p.Name, p.Device, p.Sectors*512>>20)
	}
	fmt.Fprintf(&b, "  (%d partitions)\n", len(inv))
	return b.String(), true
}

// cmdlineValue returns the value of KEY=VALUE from a kernel command line.
// Only ever called with whitelisted keys by the callers.
func cmdlineValue(cmdline, key string) string {
	for _, tok := range strings.Fields(cmdline) {
		if v, ok := strings.CutPrefix(tok, key+"="); ok {
			return v
		}
	}
	return ""
}

func meminfoMiB(path string) (total, free int64) {
	for _, line := range strings.Split(readFile(path), "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		f := strings.Fields(v)
		if len(f) == 0 || f[len(f)-1] != "kB" {
			continue
		}
		n, err := strconv.ParseInt(f[0], 10, 64)
		if err != nil {
			continue
		}
		switch strings.TrimSpace(k) {
		case "MemTotal":
			total = n >> 10
		case "MemFree":
			free = n >> 10
		}
	}
	return total, free
}

func uptimeSeconds(path string) (int64, bool) {
	f, _, ok := strings.Cut(readFile(path), " ")
	if !ok {
		return 0, false
	}
	n, err := strconv.ParseFloat(f, 64)
	if err != nil {
		return 0, false
	}
	return int64(n), true
}

// -------------------------------------------------------------------- hashing

// hashReport hashes each named partition with md5 and sha256 in ONE read
// pass, prints a screen-sized report, and appends it to
// <outDir>/partition-hashes.txt. Read-only: the only per-partition syscall
// is a sequential ReadAt/Read stream. A name that resolves to nothing is
// reported and skipped; one over the cap is reported as skipped; the exit
// contract (ok) is false only when something asked-for was not hashable.
func hashReport(e env, names []string) (string, bool) {
	var b strings.Builder
	fmt.Fprintln(&b, "PARTITION CHECKSUMS (read-only)")

	ok := true
	type line struct{ name, dev, mib, md5, sha string }
	var lines []line
	for _, name := range names {
		r, err := partition.ResolveNamed(name)
		if err != nil {
			fmt.Fprintf(&b, "%s: not found (%v)\n", name, err)
			ok = false
			continue
		}
		if r.Bytes > maxHashBytes {
			fmt.Fprintf(&b, "%s: skipped (%d bytes exceeds %d MiB cap)\n",
				name, r.Bytes, maxHashBytes>>20)
			continue
		}
		d5, d256, err := hashDev(r.Device)
		if err != nil {
			fmt.Fprintf(&b, "%s: read failed (%v)\n", name, err)
			ok = false
			continue
		}
		lines = append(lines, line{name, r.Device,
			strconv.FormatInt(r.Bytes>>20, 10), d5, d256})
	}
	for _, l := range lines {
		fmt.Fprintf(&b, "%s (%s, %s MiB)\n", l.name, l.dev, l.mib)
		fmt.Fprintf(&b, "  md5:    %s\n", l.md5)
		fmt.Fprintf(&b, "  sha256: %s\n", l.sha)
	}

	if dir, err := mkdirOut(e.outDir); err == nil {
		path := filepath.Join(dir, "partition-hashes.txt")
		body := b.String()
		if werr := os.WriteFile(path, []byte(body), 0o644); werr == nil {
			fmt.Fprintf(&b, "saved: %s\n", path)
		}
	}
	return b.String(), ok
}

// hashDev streams DEV once through both digests. This is the whole
// write-safety story for the hash tool: the file is opened O_RDONLY and
// nothing but Read is ever called on the handle.
func hashDev(dev string) (string, string, error) {
	f, err := os.Open(dev)
	if err != nil {
		return "", "", err
	}
	defer f.Close()
	var h5, h256 hash.Hash = md5.New(), sha256.New()
	if _, err := io.Copy(io.MultiWriter(h5, h256), f); err != nil {
		return "", "", err
	}
	return hex.EncodeToString(h5.Sum(nil)), hex.EncodeToString(h256.Sum(nil)), nil
}

// ----------------------------------------------------------------- log sources

// logsCollect runs the requested collectors into <outDir>. `all` continues
// past individual failures and reports them inline; anyOK is false only when
// nothing at all could be collected.
func logsCollect(e env, which string) (string, bool) {
	var b strings.Builder
	fmt.Fprintln(&b, "LOG COLLECTION (read-only)")
	dir, err := mkdirOut(e.outDir)
	if err != nil {
		fmt.Fprintf(&b, "cannot create %s: %v\n", e.outDir, err)
		return b.String(), false
	}

	anyOK := false
	run := func(name string, fn func() (string, error)) {
		if which != "all" && which != name {
			return
		}
		rep, err := fn()
		fmt.Fprintln(&b, rep)
		if err != nil {
			fmt.Fprintf(&b, "  (%s failed: %v)\n", name, err)
			return
		}
		anyOK = true
	}

	run("dmesg", func() (string, error) { return collectDmesg(dir) })
	run("lk", func() (string, error) {
		raw, err := readLKRing(e.devMem)
		if err != nil {
			return "", err
		}
		return saveLK(dir, raw)
	})
	run("pstore", func() (string, error) { return collectPstore(e.pstoreDir, dir) })
	run("expdb", func() (string, error) { return collectExpdb(dir) })

	if which != "all" && which != "" {
		// A single unknown source name should not look like success.
		switch which {
		case "dmesg", "lk", "pstore", "expdb":
		default:
			fmt.Fprintf(&b, "unknown log source %q\n", which)
			return b.String(), false
		}
	}
	if which == "all" {
		fmt.Fprintf(&b, "logs saved under %s (RAM -- lost on reboot)\n", dir)
		fmt.Fprintf(&b, "fetch over USB: scp from 172.16.42.1\n")
	}
	return b.String(), anyOK
}

// collectDmesg snapshots the kernel log. klogctl(3) READ_ALL is
// non-destructive (it does not consume the ring). There is deliberately no
// /dev/kmsg fallback: a char-device read that never returns EAGAIN would
// hang the collector mid-dialog, and syslog(2) covers the case this tool
// actually runs in -- root inside the installer initramfs.
func collectDmesg(dir string) (string, error) {
	data, err := kmsgReadAll()
	path := filepath.Join(dir, "dmesg.txt")
	if err == nil {
		werr := os.WriteFile(path, data, 0o644)
		if werr == nil {
			lines := strings.Count(strings.TrimSpace(string(data)), "\n") + 1
			return fmt.Sprintf("dmesg: %d lines -> %s", lines, path), nil
		}
		err = werr
	}
	return "dmesg: unavailable", err
}

// kmsgReadAll is a var so tests can stub the kernel log.
var kmsgReadAll = func() ([]byte, error) {
	buf := make([]byte, 1<<20)
	n, _, errno := syscall.Syscall(syscall.SYS_SYSLOG, 3, /* READ_ALL */
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if errno != 0 {
		return nil, fmt.Errorf("syslog(2) READ_ALL: %v", errno)
	}
	return buf[:int(n)], nil
}

// readLKRing reads the LK current-boot ring (lkPages pages at physical
// lkBase) through /dev/mem. Strictly read-only: the handle is only ever
// ReadAt-ed.
func readLKRing(devMem string) ([]byte, error) {
	f, err := os.Open(devMem)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", devMem, err)
	}
	defer f.Close()
	raw := make([]byte, lkPages*pageSz)
	if _, err := f.ReadAt(raw, lkBase); err != nil {
		return nil, fmt.Errorf("read %s at %#x: %w", devMem, lkBase, err)
	}
	return raw, nil
}

// saveLK persists the ring as collected by `logs`: raw bytes plus a
// printable-text view, and a short report carrying the tail.
func saveLK(dir string, raw []byte) (string, error) {
	binPath := filepath.Join(dir, "lk-log.bin")
	txtPath := filepath.Join(dir, "lk-log.txt")
	if err := os.WriteFile(binPath, raw, 0o644); err != nil {
		return "", err
	}
	txt := printableText(raw)
	if err := os.WriteFile(txtPath, []byte(txt), 0o644); err != nil {
		return "", err
	}
	return fmt.Sprintf("lk log: %d bytes -> %s\nlast lines:\n%s",
		len(raw), binPath, tailLines(txt, 15)), nil
}

// printableText keeps ASCII printable runs and turns every run of binary
// bytes into one line break, so NUL-padded LK records become lines instead
// of one 256 KiB paragraph. Binary runs produce a SEPARATOR, not padding:
// no break is emitted before the first printable byte or after the last.
func printableText(b []byte) string {
	var out []byte
	brk := false
	for _, c := range b {
		switch {
		case c == '\n':
			out = append(out, '\n')
			brk = false
		case c >= 0x20 && c <= 0x7e:
			if brk && len(out) > 0 {
				out = append(out, '\n')
			}
			out = append(out, c)
			brk = false
		default:
			brk = true
		}
	}
	return string(out)
}

func tailLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// truncateLine clamps a one-line message (typically an error string) so it
// cannot blow out an info screen.
func truncateLine(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

// collectPstore copies every pstore record to <dir>/pstore/. The kernel
// builds pstore/ramoops in (geometry comes from LK's command line) but
// nothing mounts it, so this mounts it on first use -- only at the real
// path, never at a redirected test path. Capture is UNVERIFIED ON
// HARDWARE: an empty result is the expected outcome until measured, not a
// fault, and is reported as such rather than as an error.
func collectPstore(pstoreDir, dir string) (string, error) {
	if entries, _ := os.ReadDir(pstoreDir); len(entries) == 0 &&
		pstoreDir == "/sys/fs/pstore" {
		_ = syscall.Mount("pstore", pstoreDir, "pstore", 0, "")
	}
	entries, err := os.ReadDir(pstoreDir)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", pstoreDir, err)
	}
	outDir := filepath.Join(dir, "pstore")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return "", err
	}
	var names []string
	for _, en := range entries {
		if !en.Type().IsRegular() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(pstoreDir, en.Name()))
		if err != nil {
			continue
		}
		if err := os.WriteFile(filepath.Join(outDir, en.Name()), data, 0o644); err != nil {
			continue
		}
		names = append(names, en.Name())
	}
	if len(names) == 0 {
		return "pstore: no records (capture is unverified on this hardware)", nil
	}
	sort.Strings(names)
	return fmt.Sprintf("pstore: %d records -> %s (%s)",
		len(names), outDir, strings.Join(names, ", ")), nil
}

// collectExpdb dumps the head of the expdb partition -- where LK persists a
// FAILED slot's log. The layout is undocumented, so like the LK ring this is
// a raw copy plus a printable view; the tail is what usually carries the
// interesting lines.
func collectExpdb(dir string) (string, error) {
	r, err := partition.ResolveNamed("expdb")
	if err != nil {
		return "", err
	}
	n := r.Bytes
	truncated := false
	if n > expdbReadCap {
		n = expdbReadCap
		truncated = true
	}
	f, err := os.Open(r.Device)
	if err != nil {
		return "", err
	}
	defer f.Close()
	raw := make([]byte, n)
	if _, err := io.ReadFull(f, raw); err != nil {
		return "", err
	}
	binPath := filepath.Join(dir, "expdb.bin")
	txtPath := filepath.Join(dir, "expdb.txt")
	if err := os.WriteFile(binPath, raw, 0o644); err != nil {
		return "", err
	}
	txt := printableText(raw)
	if err := os.WriteFile(txtPath, []byte(txt), 0o644); err != nil {
		return "", err
	}
	note := ""
	if truncated {
		note = fmt.Sprintf(" (truncated at %d of %d bytes)", n, r.Bytes)
	}
	return fmt.Sprintf("expdb: %d bytes%s -> %s\nlast lines:\n%s",
		n, note, binPath, tailLines(txt, 15)), nil
}

// ------------------------------------------------------------------ utilities

func readFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

func oneLine(path, def string) string {
	s := strings.TrimSpace(readFile(path))
	if s == "" {
		return def
	}
	return strings.SplitN(s, "\n", 2)[0]
}

func mkdirOut(dir string) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

// ------------------------------------------------------------------- the menu

// menuMain is the screen-first interface: a loop of dc1-ask dialogs served
// by PID 1, so the whole toolkit runs from the touchscreen. Every dialog is
// one ask.Forward request; RC 2 anywhere (UI gone) unwinds to exit 2, which
// tui.sh already treats as "fall back to USB".
func menuMain(e env, stderr io.Writer) int {
	for {
		resp, ok := ask.Forward([]string{"menu", "DC-1 DEBUG",
			"Device info", "Partition checksums", "Collect logs",
			"LK boot log", "Back"})
		if !ok || resp.RC == 2 {
			fmt.Fprintln(stderr, "dc1-debug: no display")
			return 2
		}
		if resp.RC != 0 {
			return 1
		}
		switch strings.TrimSpace(resp.Out) {
		case "0":
			rep, _ := infoReport(e)
			if !showPages("DEVICE INFO", rep, stderr) {
				return 2
			}
		case "1":
			resp, ok := ask.Forward([]string{"menu", "PARTITION CHECKSUMS",
				"Hash boot_a boot_b lk dtbo misc expdb",
				"(read-only; nothing is flashed)", "Back"})
			if !ok || resp.RC == 2 {
				fmt.Fprintln(stderr, "dc1-debug: no display")
				return 2
			}
			if strings.TrimSpace(resp.Out) == "0" {
				rep, hashOK := hashReport(e, strings.Fields(defaultHashNames))
				if !showPages("PARTITION CHECKSUMS", rep, stderr) {
					return 2
				}
				if !hashOK {
					_ = showInfo("SOME PARTITIONS MISSING", []string{
						"Not every requested partition", "could be read.",
						"Details are on the previous screen."}, stderr)
				}
			}
		case "2":
			resp, ok := ask.Forward([]string{"menu", "COLLECT LOGS",
				"Collect dmesg, LK log, pstore,",
				"expdb into /tmp/debug", "Back"})
			if !ok || resp.RC == 2 {
				fmt.Fprintln(stderr, "dc1-debug: no display")
				return 2
			}
			if strings.TrimSpace(resp.Out) == "0" {
				rep, _ := logsCollect(e, "all")
				if !showPages("LOGS COLLECTED", rep, stderr) {
					return 2
				}
			}
		case "3":
			// On-panel LK log viewer: one read of the ring, saved in the
			// same format Collect logs uses, then the tail paged on the
			// screen. The tail is where LK records slot selection and any
			// fallback decision.
			raw, err := readLKRing(e.devMem)
			if err != nil {
				if !showInfo("LK LOG UNAVAILABLE", []string{
					"Could not read the current-boot",
					"ring via /dev/mem.",
					"",
					truncateLine(err.Error(), 60)}, stderr) {
					return 2
				}
				continue
			}
			if dir, derr := mkdirOut(e.outDir); derr == nil {
				_, _ = saveLK(dir, raw)
			}
			view := tailLines(printableText(raw), lkViewLines) +
				"\n\nfull ring: /tmp/debug/lk-log.txt" +
				"\n(refresh the saved copy: Collect logs)"
			if !showPages("LK BOOT LOG", view, stderr) {
				return 2
			}
		default:
			return 0
		}
	}
}

// showInfo paints one info screen; false means the UI went away.
func showInfo(title string, lines []string, stderr io.Writer) bool {
	args := append([]string{"info", title}, lines...)
	resp, ok := ask.Forward(args)
	return ok && resp.RC != 2
}

// showPages paginates a report over the panel: infoLayout fits ~19 lines
// per screen and callers pass pre-split lines, so long output is chunked
// here. Each chunk needs one OK tap; the title shows the page counter.
func showPages(title, report string, stderr io.Writer) bool {
	lines := strings.Split(strings.TrimRight(report, "\n"), "\n")
	pages := (len(lines) + menuLinesPerPage - 1) / menuLinesPerPage
	if pages == 0 {
		pages = 1
	}
	for p := 0; p < pages; p++ {
		end := (p + 1) * menuLinesPerPage
		if end > len(lines) {
			end = len(lines)
		}
		chunk := lines[p*menuLinesPerPage : end]
		t := fmt.Sprintf("%s (%d/%d)", title, p+1, pages)
		if !showInfo(t, chunk, stderr) {
			return false
		}
	}
	return true
}
