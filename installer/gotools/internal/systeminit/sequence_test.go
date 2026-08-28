package systeminit

import (
	"errors"
	"fmt"
	"io"
	"strings"
	"syscall"
	"testing"
	"time"
)

// errExeced stands in for a successful execve: the real one never returns, so
// the fake unwinds instead of letting boot() run on into its rollback path.
var errExeced = errors.New("fake: exec replaced the process")

type fakeOps struct {
	calls []string // every effect, in order -- the thing under test
	lines []string // what an operator would have seen

	stat     map[string]FileInfo
	mountErr map[string]error
	sysErr   map[string]error

	roots      []Candidate
	rootsFails int // ProbeRoots fails this many times before the partition appears
	probes     int

	execFails      bool
	rootIsSeparate bool
	rootHasInit    bool
	fsckRC         int
	armErr         error
	wdErr          error

	nextPid int
	pets    int
	armed   int
	slept   time.Duration
	now     time.Time
}

func newFake() *fakeOps {
	return &fakeOps{
		stat: map[string]FileInfo{
			"/":         {Dev: 1, Mode: 0o40755},
			rootMount:   {Dev: 1, Mode: 0o40755},
			busyboxPath: {Dev: 1, Mode: 0o100755},
		},
		mountErr:       map[string]error{},
		sysErr:         map[string]error{},
		roots:          []Candidate{{"/dev/sdc57", "ext4", "jagar-root"}},
		rootIsSeparate: true,
		rootHasInit:    true,
		nextPid:        100,
		now:            time.Unix(1_800_000_000, 0),
	}
}

func (f *fakeOps) record(format string, a ...any) {
	f.calls = append(f.calls, fmt.Sprintf(format, a...))
}

func (f *fakeOps) Say(line string) { f.lines = append(f.lines, strings.TrimSuffix(line, "\n")) }
func (f *fakeOps) OpenKmsg()       { f.record("openkmsg") }

func (f *fakeOps) Mkdir(path string, mode uint32) error {
	f.record("mkdir %s", path)
	return nil
}

func (f *fakeOps) Mount(source, target, fstype string, flags uintptr, data string) error {
	f.record("mount %s %s %s", source, target, fstype)
	if err := f.mountErr[target]; err != nil {
		return err
	}
	if target == rootMount {
		if f.rootIsSeparate {
			f.stat[rootMount] = FileInfo{Dev: 2, Mode: 0o40755}
		}
		if f.rootHasInit {
			f.stat[rootMount+"/sbin/init"] = FileInfo{Dev: 2, Mode: 0o100755}
		}
	}
	return nil
}

func (f *fakeOps) Unmount(target string) error {
	f.record("unmount %s", target)
	if target == rootMount {
		f.stat[rootMount] = FileInfo{Dev: 1, Mode: 0o40755}
		delete(f.stat, rootMount+"/sbin/init")
	}
	return nil
}

func (f *fakeOps) MoveMount(from, to string) error {
	f.record("movemount %s %s", from, to)
	return nil
}

func (f *fakeOps) Symlink(link, target string) error {
	f.record("symlink %s -> %s", link, target)
	return nil
}

func (f *fakeOps) WriteSys(path, value string) error {
	f.record("writesys %s=%s", path, strings.TrimSpace(value))
	return f.sysErr[path+"="+strings.TrimSpace(value)]
}

func (f *fakeOps) Touch(path string) error {
	f.record("touch %s", path)
	f.stat[path] = FileInfo{Dev: 1, Mode: 0o100644, MTime: f.now}
	return nil
}

func (f *fakeOps) Stat(path string) (FileInfo, error) {
	if fi, ok := f.stat[path]; ok {
		return fi, nil
	}
	return FileInfo{}, syscall.ENOENT
}

func (f *fakeOps) OpenRead(path string) (io.ReadCloser, error) {
	f.record("openread %s", path)
	return io.NopCloser(strings.NewReader("kmsg\n")), nil
}

func (f *fakeOps) OpenWrite(path string) (io.WriteCloser, error) {
	f.record("openwrite %s", path)
	if path == "/dev/watchdog" {
		if f.wdErr != nil {
			return nil, f.wdErr
		}
		return &fakeWatchdog{f}, nil
	}
	return nopWriteCloser{io.Discard}, nil
}

func (f *fakeOps) Spawn(path string, argv, extraEnv []string, tty string) (int, error) {
	f.record("spawn %s%s%s", strings.Join(argv, " "), envSuffix(extraEnv), ttySuffix(tty))
	f.nextPid++
	return f.nextPid, nil
}

func (f *fakeOps) Wait(pid int, block bool) (int, int, error) {
	if !block {
		return 0, 0, nil // tracked children still running; no strays
	}
	return pid, f.fsckRC, nil
}

func (f *fakeOps) Exec(path string, argv []string) error {
	f.record("exec %s %s", path, strings.Join(argv, " "))
	if f.execFails {
		return errors.New("exec: no such file")
	}
	panic(errExeced)
}

func (f *fakeOps) ProbeRoots() ([]Candidate, error) {
	f.record("proberoots")
	f.probes++
	if f.probes <= f.rootsFails {
		return nil, errors.New("expected exactly 1 PARTNAME=userdata, found 0")
	}
	return f.roots, nil
}

func (f *fakeOps) ArmFastboot() error {
	f.record("armfastboot")
	f.armed++
	return f.armErr
}

func (f *fakeOps) Now() time.Time { return f.now }

func (f *fakeOps) Sleep(d time.Duration) { f.slept += d }

func ttySuffix(tty string) string {
	if tty == "" {
		return ""
	}
	return " <" + tty
}

func envSuffix(env []string) string {
	if len(env) == 0 {
		return ""
	}
	return " [" + strings.Join(env, ",") + "]"
}

type nopWriteCloser struct{ io.Writer }

func (nopWriteCloser) Close() error { return nil }

type fakeWatchdog struct{ f *fakeOps }

func (w *fakeWatchdog) Write(p []byte) (int, error) { w.f.pets++; return len(p), nil }
func (w *fakeWatchdog) Close() error                { w.f.record("close /dev/watchdog"); return nil }

// runBoot drives the sequence to its end: either an exec (which in reality
// replaces the process) or a rescue shell.
func runBoot(t *testing.T, f *fakeOps) (execed bool) {
	t.Helper()
	defer func() {
		if r := recover(); r != nil {
			if r == errExeced {
				execed = true
				return
			}
			panic(r)
		}
	}()
	boot(f, Config{Self: "/bin/dc1tools", Once: true})
	return false
}

// indexOf returns the position of the first call containing want, or -1.
func indexOf(calls []string, want string) int {
	for i, c := range calls {
		if strings.Contains(c, want) {
			return i
		}
	}
	return -1
}

func mustOrder(t *testing.T, calls []string, steps ...string) {
	t.Helper()
	prev := -1
	for _, s := range steps {
		at := indexOf(calls, s)
		if at < 0 {
			t.Fatalf("step %q never happened:\n%s", s, strings.Join(calls, "\n"))
		}
		if at < prev {
			t.Fatalf("step %q happened out of order:\n%s", s, strings.Join(calls, "\n"))
		}
		prev = at
	}
}

// The ordering here is the part that was learned from failed boots, not from
// reading code: kernel filesystems, then the debug channel (so a hang after
// this point is visible from the host at all), then the watchdog owner, and
// only then anything that touches storage.
func TestBootOrder(t *testing.T) {
	f := newFake()
	if !runBoot(t, f) {
		t.Fatalf("a healthy boot did not reach switch_root:\n%s", strings.Join(f.calls, "\n"))
	}
	mustOrder(t, f.calls,
		"mount proc /proc proc",
		"mount devtmpfs /dev devtmpfs",
		"openkmsg",
		"mount configfs /sys/kernel/config configfs",
		"writesys "+gadgetRoot+"/UDC=musb-hdrc.4.auto",
		"spawn /bin/dc1tools system-init -helper kmsg",
		"spawn /bin/dc1tools system-init -helper shell",
		"spawn /bin/dc1tools system-init -helper watchdog",
		"proberoots",
		"mount /dev/sdc57 /mnt/root ext4",
		"movemount /dev /mnt/root/dev",
		"movemount /proc /mnt/root/proc",
		"movemount /sys /mnt/root/sys",
		"exec /bin/busybox switch_root /mnt/root /sbin/init",
	)
	// /dev/kmsg does not exist before devtmpfs is mounted, so a Say before
	// that is invisible; the log must not be opened earlier than it can be.
	if indexOf(f.calls, "openkmsg") < indexOf(f.calls, "mount devtmpfs") {
		t.Fatal("opened /dev/kmsg before devtmpfs was mounted")
	}
}

// The helpers are the only processes allowed to skip the PID 1 test, so PID 1
// has to mark them; without the marker they would refuse to start.
func TestHelpersAreMarkedByPID1(t *testing.T) {
	f := newFake()
	runBoot(t, f)
	for _, role := range []string{helperKmsg, helperShell, helperWatchdog} {
		at := indexOf(f.calls, "-helper "+role)
		if at < 0 {
			t.Fatalf("no %s helper", role)
		}
		if !strings.Contains(f.calls[at], "["+helperEnv+"=1]") {
			t.Errorf("%s helper spawned unmarked: %q", role, f.calls[at])
		}
	}
	// Nothing else gets the marker: an e2fsck or a shell that carried it
	// would be one more way to reach the helper paths by accident.
	for _, c := range f.calls {
		if strings.Contains(c, helperEnv) && !strings.Contains(c, "-helper ") {
			t.Errorf("marker leaked to %q", c)
		}
	}
}

// The watchdog owner must exist before anything that can hang, and long before
// the handoff: after switch_root nothing in this initramfs runs again.
func TestWatchdogPetterStartsBeforeAnyStorageWork(t *testing.T) {
	f := newFake()
	runBoot(t, f)
	wd := indexOf(f.calls, "-helper watchdog")
	if wd < 0 {
		t.Fatal("no watchdog petter was started")
	}
	for _, later := range []string{"proberoots", "mount /dev/sdc57", "exec /bin/busybox"} {
		if at := indexOf(f.calls, later); at >= 0 && at < wd {
			t.Fatalf("%q happened before the watchdog petter", later)
		}
	}
}

// Every refusal below must reach the rescue shell with the root partition
// untouched: no switch_root, and no write of any kind.
func TestSwitchRootNeverHappensWithoutAVerifiedMount(t *testing.T) {
	cases := []struct {
		name    string
		fake    func(*fakeOps)
		wantLog string
	}{
		{"userdata never appears", func(f *fakeOps) {
			f.rootsFails = rootWaitSeconds
		}, "userdata partition not found"},
		{"stock android is still there", func(f *fakeOps) {
			f.roots = []Candidate{{"/dev/sdc57", "", ""}}
		}, "not ext4"},
		{"someone else's ext4", func(f *fakeOps) {
			f.roots = []Candidate{{"/dev/sdc57", "ext4", "userdata"}}
		}, "not our filesystem"},
		{"the mount fails", func(f *fakeOps) {
			f.mountErr[rootMount] = syscall.EINVAL
		}, "mount of /dev/sdc57 failed"},
		{"the mount did not actually take", func(f *fakeOps) {
			f.rootIsSeparate = false
		}, "not a separate filesystem"},
		{"a rootfs with no init in it", func(f *fakeOps) {
			f.rootHasInit = false
		}, "no executable /sbin/init"},
		{"no busybox to switch_root with", func(f *fakeOps) {
			delete(f.stat, busyboxPath)
		}, "missing from initramfs"},
	}
	for _, c := range cases {
		f := newFake()
		c.fake(f)
		if runBoot(t, f) {
			t.Errorf("%s: reached switch_root anyway", c.name)
			continue
		}
		if at := indexOf(f.calls, "exec "); at >= 0 {
			t.Errorf("%s: exec'd %q", c.name, f.calls[at])
		}
		if !strings.Contains(strings.Join(f.lines, "\n"), c.wantLog) {
			t.Errorf("%s: nothing said about %q:\n%s", c.name, c.wantLog,
				strings.Join(f.lines, "\n"))
		}
		if indexOf(f.calls, "touch "+deadmanPath) < 0 {
			t.Errorf("%s: dropped to rescue without arming the deadman", c.name)
		}
	}
}

// A rootfs the mount check rejected must be unmounted again: leaving it
// mounted would make the rescue shell's view disagree with reality.
func TestRejectedRootIsUnmounted(t *testing.T) {
	for _, broken := range []func(*fakeOps){
		func(f *fakeOps) { f.rootIsSeparate = false },
		func(f *fakeOps) { f.rootHasInit = false },
	} {
		f := newFake()
		broken(f)
		runBoot(t, f)
		if indexOf(f.calls, "unmount "+rootMount) < 0 {
			t.Fatalf("left a rejected root mounted:\n%s", strings.Join(f.calls, "\n"))
		}
	}
}

// If the exec fails we are still PID 1 on the initramfs, but /dev /proc /sys
// have moved out from under us -- and the rescue shell needs them.
func TestFailedSwitchRootRollsTheKernelMountsBack(t *testing.T) {
	f := newFake()
	f.execFails = true
	if runBoot(t, f) {
		t.Fatal("a failing exec was reported as a handoff")
	}
	after := f.calls[indexOf(f.calls, "exec /bin/busybox"):]
	mustOrder(t, after,
		"movemount /mnt/root/sys /sys",
		"movemount /mnt/root/proc /proc",
		"movemount /mnt/root/dev /dev",
	)
	if !strings.Contains(strings.Join(f.lines, "\n"), "rolled back") {
		t.Fatal("rolled the mounts back without saying so")
	}
}

// The partition appears seconds after the kernel starts; one early ENOENT is
// not a failed boot.
func TestProbeIsRetriedWhileTheDeviceEnumerates(t *testing.T) {
	f := newFake()
	f.rootsFails = 12
	if !runBoot(t, f) {
		t.Fatalf("gave up on a partition that appeared at 13s:\n%s", strings.Join(f.lines, "\n"))
	}
	if f.probes != 13 {
		t.Fatalf("probed %d times, want 13", f.probes)
	}
	if !strings.Contains(strings.Join(f.lines, "\n"), "still waiting for userdata partition (10s)") {
		t.Fatalf("said nothing while waiting:\n%s", strings.Join(f.lines, "\n"))
	}
}

func TestFsckIsSkippedWhenItIsNotStaged(t *testing.T) {
	f := newFake()
	runBoot(t, f)
	if indexOf(f.calls, "e2fsck") >= 0 {
		t.Fatal("ran an e2fsck that is not in the image")
	}
	if !strings.Contains(strings.Join(f.lines, "\n"), "skipping fsck") {
		t.Fatal("skipped the fsck silently")
	}
}

// e2fsck exit 1 is "errors corrected", which is a boot; anything worse is a
// filesystem e2fsck refused, and mounting one of those is how a bad install
// becomes a corrupted one.
func TestFsckRunsWhenStaged(t *testing.T) {
	for rc, wantBoot := range map[int]bool{0: true, 1: true, 2: false, 8: false} {
		f := newFake()
		f.stat["/sbin/e2fsck"] = FileInfo{Dev: 1, Mode: 0o100755}
		f.fsckRC = rc
		if got := runBoot(t, f); got != wantBoot {
			t.Fatalf("rc=%d: reached switch_root = %v, want %v", rc, got, wantBoot)
		}
		if indexOf(f.calls, "spawn /sbin/e2fsck -p /dev/sdc57") < 0 {
			t.Fatalf("rc=%d: did not run e2fsck", rc)
		}
		if !wantBoot {
			if indexOf(f.calls, "mount /dev/sdc57") >= 0 {
				t.Errorf("rc=%d: mounted a filesystem e2fsck refused", rc)
			}
			if !strings.Contains(strings.Join(f.lines, "\n"), "uncorrectable errors") {
				t.Errorf("rc=%d: did not say why it refused", rc)
			}
		}
	}
}

// A gadget that cannot bind is survivable; a boot that stops because of one is
// not. It must still reach switch_root.
func TestGadgetFailureDoesNotStopTheBoot(t *testing.T) {
	f := newFake()
	for _, udc := range udcCandidates() {
		f.sysErr[gadgetRoot+"/UDC="+udc] = syscall.ENODEV
	}
	if !runBoot(t, f) {
		t.Fatal("a failed UDC bind stopped the boot")
	}
	if !strings.Contains(strings.Join(f.lines, "\n"), "UDC bind failed") {
		t.Fatal("failed to bind a UDC silently")
	}
}

func TestGadgetBindsTheFirstUDCThatAccepts(t *testing.T) {
	f := newFake()
	f.sysErr[gadgetRoot+"/UDC=musb-hdrc.4.auto"] = syscall.ENODEV
	runBoot(t, f)
	if indexOf(f.calls, "UDC=musb-hdrc.1.auto") < 0 {
		t.Fatal("did not fall through to the next UDC candidate")
	}
	if !strings.Contains(strings.Join(f.lines, "\n"), "bound UDC musb-hdrc.1.auto") {
		t.Fatal("did not report which UDC it bound")
	}
}

// Rescue is the terminal state: a shell on every console we can open, the
// deadman armed, and nothing written anywhere.
func TestRescueOffersAShellOnEveryConsole(t *testing.T) {
	f := newFake()
	rescue(f, Config{Once: true}, "boot.sh equivalent failed")
	for _, tty := range rescueConsoles {
		if indexOf(f.calls, "spawn /bin/busybox sh <"+tty) < 0 {
			t.Errorf("no rescue shell on %s:\n%s", tty, strings.Join(f.calls, "\n"))
		}
	}
	mustOrder(t, f.calls, "touch "+leasePath, "touch "+deadmanPath)
	for _, c := range f.calls {
		if strings.HasPrefix(c, "mount ") || strings.HasPrefix(c, "writesys ") {
			t.Errorf("rescue changed something: %q", c)
		}
	}
}

// The petter is a keep-alive until the rescue shell arms the deadman; after
// that it is a lease, and losing the operator must point the reset at LK
// fastboot BEFORE it stops petting -- the reset itself can run no code.
func TestPetterPetsUntilTheLeaseExpires(t *testing.T) {
	f := newFake()
	if rc := petter(f, Config{Once: true}); rc != 0 {
		t.Fatalf("petter returned %d", rc)
	}
	if f.pets != 1 {
		t.Fatalf("petted %d times, want 1", f.pets)
	}
	if f.armed != 0 {
		t.Fatal("armed fastboot while the boot was still healthy")
	}

	// Deadman armed, lease renewed just now: still ours to keep alive.
	f = newFake()
	f.stat[deadmanPath] = FileInfo{MTime: f.now}
	f.stat[leasePath] = FileInfo{MTime: f.now}
	petter(f, Config{Once: true})
	if f.pets != 1 || f.armed != 0 {
		t.Fatalf("pets=%d armed=%d: stopped petting on a fresh lease", f.pets, f.armed)
	}

	// Deadman armed, nobody has renewed the lease in an hour.
	f = newFake()
	f.stat[deadmanPath] = FileInfo{MTime: f.now}
	f.stat[leasePath] = FileInfo{MTime: f.now.Add(-time.Hour)}
	petter(f, Config{Once: true})
	if f.pets != 0 {
		t.Fatalf("kept petting past the lease (%d pets)", f.pets)
	}
	if f.armed != 1 {
		t.Fatal("stopped petting without pointing the reset at fastboot")
	}
	if indexOf(f.calls, "armfastboot") < 0 {
		t.Fatal("no arming call recorded")
	}
}

// No /dev/watchdog is a diagnosis, not a hang: say so and get out of the way.
func TestPetterWithoutAWatchdogSaysSo(t *testing.T) {
	f := newFake()
	f.wdErr = syscall.ENOENT
	if rc := petter(f, Config{Once: true}); rc != 0 {
		t.Fatalf("petter returned %d", rc)
	}
	if f.pets != 0 {
		t.Fatal("petted a watchdog it never opened")
	}
	if !strings.Contains(strings.Join(f.lines, "\n"), "no /dev/watchdog") {
		t.Fatal("failed to open /dev/watchdog silently")
	}
	if f.slept != 10*time.Second {
		t.Fatalf("retried for %v, want 10 attempts one second apart", f.slept)
	}
}

func TestKmsgStreamReopensBothEnds(t *testing.T) {
	f := newFake()
	streamKmsg(f, Config{Once: true})
	mustOrder(t, f.calls, "openwrite "+kmsgTTY, "openread /dev/kmsg")
}

func TestShellHelperRespawnsOnItsOwnTTY(t *testing.T) {
	f := newFake()
	respawnShell(f, Config{Once: true}, shellTTY)
	if indexOf(f.calls, "spawn /bin/busybox sh <"+shellTTY) < 0 {
		t.Fatalf("no shell on %s:\n%s", shellTTY, strings.Join(f.calls, "\n"))
	}
}

// A helper is a re-exec, not a fork: it starts with no /dev/kmsg, where the C's
// forked helpers inherited the g_kmsg fd main() opened before forking them
// (system/init.c:389 vs :404-406). Say's console list has no ttyGS0, and the
// ttyGS0 boot log the host reads as /dev/ttyACM0 is streamed FROM /dev/kmsg --
// so a helper that never opens it reports to nobody. The watchdog petter is the
// one that matters: "no /dev/watchdog", "pet failed" and "deadman lease
// expired" are the difference between a diagnosable reset and a mystery one.
func TestHelpersOpenKmsgBeforeSayingAnything(t *testing.T) {
	for _, helper := range []string{helperWatchdog, helperKmsg, helperShell} {
		f := newFake()
		f.wdErr = syscall.ENOENT // make the petter say something immediately
		cfg := Config{Helper: helper, Once: true, TTY: shellTTY}
		if rc := runHelper(f, cfg); rc != 0 {
			t.Fatalf("%s returned %d", helper, rc)
		}
		at := indexOf(f.calls, "openkmsg")
		if at < 0 {
			t.Fatalf("-helper %s never opened /dev/kmsg; its diagnostics reach "+
				"no channel the host can see:\n%s", helper, strings.Join(f.calls, "\n"))
		}
		if at != 0 {
			t.Fatalf("-helper %s did work before opening /dev/kmsg (openkmsg at %d):\n%s",
				helper, at, strings.Join(f.calls, "\n"))
		}
	}
}
