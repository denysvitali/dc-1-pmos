package installerinit

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

// fakeOps records every effect in order. The ordering is the whole point: this
// code mounts over the running system and never returns, so a recorded call
// log is the only way to assert the sequence that boot correctness depends on.
type fakeOps struct {
	calls    []string
	consoles []string
	present  map[string]bool
	files    map[string]string

	failWrite  map[string]bool
	failWait   map[string]bool
	display    Surface
	displayErr error
	spawnErr   error

	ticks int
	stop  func()
}

func newFake() *fakeOps {
	return &fakeOps{
		present:   map[string]bool{},
		files:     map[string]string{},
		failWrite: map[string]bool{},
		failWait:  map[string]bool{},
	}
}

func (f *fakeOps) log(format string, a ...any) {
	f.calls = append(f.calls, fmt.Sprintf(format, a...))
}

func (f *fakeOps) Mkdir(path string, _ os.FileMode) error {
	f.log("mkdir %s", path)
	f.present[path] = true
	return nil
}

func (f *fakeOps) Mount(source, target, fstype string, _ uintptr, _ string) error {
	f.log("mount %s on %s (%s)", source, target, fstype)
	return nil
}

func (f *fakeOps) WriteFile(path, value string) error {
	if f.failWrite[path] {
		f.log("write %s FAILED", path)
		return errors.New("write refused")
	}
	// Faithful to the real one, which has no O_CREATE: sysfs and configfs
	// attributes always exist, /tmp is an empty tmpfs on an initramfs boot.
	if strings.HasPrefix(path, "/tmp/") && !f.present[path] {
		f.log("write %s ENOENT", path)
		return os.ErrNotExist
	}
	f.log("write %s=%s", path, strings.TrimSpace(value))
	f.files[path] = value
	return nil
}

func (f *fakeOps) CreateFile(path, value string) error {
	if f.failWrite[path] {
		f.log("create %s FAILED", path)
		return errors.New("write refused")
	}
	f.log("create %s=%s", path, strings.TrimSpace(value))
	f.present[path] = true
	f.files[path] = value
	return nil
}

func (f *fakeOps) Broadcast(line string) {
	f.consoles = append(f.consoles, strings.TrimSuffix(line, "\n"))
}

func (f *fakeOps) ReadFile(path string) (string, error) {
	v, ok := f.files[path]
	if !ok {
		return "", os.ErrNotExist
	}
	return v, nil
}

func (f *fakeOps) Exists(path string) bool { return f.present[path] }

func (f *fakeOps) WaitFor(path string, _ time.Duration) error {
	if f.failWait[path] {
		f.log("wait %s TIMEOUT", path)
		return errors.New("did not appear")
	}
	f.log("wait %s", path)
	f.present[path] = true
	return nil
}

func (f *fakeOps) Symlink(oldname, newname string) error {
	f.log("symlink %s -> %s", newname, oldname)
	return nil
}

func (f *fakeOps) OpenKmsg() *os.File { return nil }

func (f *fakeOps) GrabTTY(path string) error {
	f.log("grabtty %s", path)
	return nil
}

func (f *fakeOps) Spawn(argv []string) (int, error) {
	if f.spawnErr != nil {
		f.log("spawn %s FAILED", strings.Join(argv, " "))
		return 0, f.spawnErr
	}
	f.log("spawn %s", strings.Join(argv, " "))
	return 4242, nil
}

func (f *fakeOps) Reap() { f.log("reap") }

// Sleep is where the loop is cut short: PID 1 never returns on the device, so
// the test stops it after a fixed number of ticks.
func (f *fakeOps) Sleep(time.Duration) {
	f.ticks--
	if f.ticks <= 0 && f.stop != nil {
		f.stop()
	}
}

func (f *fakeOps) Display() (Surface, error) {
	f.log("display")
	if f.displayErr != nil {
		return nil, f.displayErr
	}
	return f.display, nil
}

// gateReady marks every path the gate waits on as already present, so the
// happy path does not depend on WaitFor side effects.
func (f *fakeOps) gateReady() {
	f.present[panelParams] = true
	f.present["/etc/rc.sh"] = true
	f.present["/bin/busybox"] = true
	f.present["/sys/class/udc"] = true
}

func indexOf(t *testing.T, calls []string, substr string) int {
	t.Helper()
	for i, c := range calls {
		if strings.Contains(c, substr) {
			return i
		}
	}
	t.Fatalf("call not found: %q in\n%s", substr, strings.Join(calls, "\n"))
	return -1
}

// THE ordering fact: rc.sh must start before the display gate runs. LK arms a
// ~31 s watchdog this kernel does not auto-pet, rc.sh's first job is to pet
// it, and the gate can spend ~35 s waiting. Get this backwards and the device
// resets itself mid-boot.
func TestSecondStageStartsBeforeTheDisplayGate(t *testing.T) {
	f := newFake()
	f.gateReady()
	f.ticks = 1
	done := make(chan struct{})
	f.stop = func() { panic(errStop) }

	go func() {
		defer func() { recover(); close(done) }()
		Run(f, io.Discard)
	}()
	<-done

	rc := indexOf(t, f.calls, "spawn /bin/busybox sh /etc/rc.sh")
	gate := indexOf(t, f.calls, "write "+skipClient)
	if rc > gate {
		t.Fatalf("display gate ran before rc.sh (rc at %d, gate at %d):\n%s",
			rc, gate, strings.Join(f.calls, "\n"))
	}
}

// devtmpfs is not auto-mounted on an initramfs boot, and /dev/kmsg and
// /dev/dri/card0 do not exist until it is. Everything that touches /dev must
// come after the mount.
func TestDevtmpfsIsMountedBeforeAnythingUsesDev(t *testing.T) {
	f := newFake()
	f.gateReady()
	f.ticks = 1
	done := make(chan struct{})
	f.stop = func() { panic(errStop) }
	go func() {
		defer func() { recover(); close(done) }()
		Run(f, io.Discard)
	}()
	<-done

	mount := indexOf(t, f.calls, "mount devtmpfs on /dev")
	tty := indexOf(t, f.calls, "grabtty /dev/tty1")
	if mount > tty {
		t.Fatal("grabbed /dev/tty1 before devtmpfs was mounted")
	}
}

var errStop = errors.New("stop")

// The gate order is the thing that cost boot cycles. GCE binds before the
// panel is touched; opening the panel first can wedge the interconnect.
func TestGateBindsGCEBeforeTouchingThePanel(t *testing.T) {
	f := newFake()
	f.present[panelParams] = true
	if err := OpenGate(f, io.Discard); err != nil {
		t.Fatal(err)
	}
	gce := indexOf(t, f.calls, "write "+gceParam)
	prod := indexOf(t, f.calls, "write "+prodSeq)
	if gce > prod {
		t.Fatalf("panel was powered before GCE bound:\n%s", strings.Join(f.calls, "\n"))
	}
	// And the console is quieted before the panel changes owners.
	printk := indexOf(t, f.calls, "write /proc/sys/kernel/printk")
	if printk > prod {
		t.Fatal("console was still loud when the display controller changed owners")
	}
}

func TestGateUsesMainlineGCEPlatformDeviceName(t *testing.T) {
	f := newFake()
	f.present[panelParams] = true
	f.present[mainlineGCEDevice] = true
	if err := OpenGate(f, io.Discard); err != nil {
		t.Fatal(err)
	}
	probe := indexOf(t, f.calls, "write /sys/bus/platform/drivers_probe="+mainlineGCEName)
	wait := indexOf(t, f.calls, "wait "+mainlineGCEDevice+"/driver")
	if probe > wait {
		t.Fatalf("waited for mainline GCE before probing it:\n%s", strings.Join(f.calls, "\n"))
	}
	for _, call := range f.calls {
		if strings.Contains(call, "drivers_probe="+stockGCEName) {
			t.Fatalf("used stock GCE name on the mainline tree:\n%s", strings.Join(f.calls, "\n"))
		}
	}
}

// A gate failure must name the step, because "gate failed" alone has cost
// debugging time.
func TestGateFailureNamesTheStep(t *testing.T) {
	f := newFake()
	f.present[panelParams] = true
	f.failWait[dsiDevice] = true
	err := OpenGate(f, io.Discard)
	if err == nil {
		t.Fatal("gate reported success with no DSI device")
	}
	if !strings.Contains(err.Error(), "DSI") {
		t.Fatalf("error does not name the failing step: %v", err)
	}
}

// No panel driver at all is a clear, early refusal rather than a pile of
// failing writes.
func TestGateRefusesWithoutThePanelDriver(t *testing.T) {
	f := newFake()
	if err := OpenGate(f, io.Discard); err == nil {
		t.Fatal("gate proceeded without a panel driver")
	}
	if len(f.calls) != 0 {
		t.Fatalf("gate wrote something before checking for the driver: %v", f.calls)
	}
}

// The optional step is skipped, not fatal: the C ignored its result too.
func TestGateStepsOverAnOptionalFailure(t *testing.T) {
	f := newFake()
	f.present[panelParams] = true
	f.failWrite["/proc/sys/kernel/printk"] = true
	if err := OpenGate(f, io.Discard); err != nil {
		t.Fatalf("an optional step failure was treated as fatal: %v", err)
	}
}

// The GCE steps are skipped when the driver is already bound; repeating the
// bind is not harmless.
func TestGateSkipsGCEWhenAlreadyBound(t *testing.T) {
	f := newFake()
	f.present[panelParams] = true
	f.present[gceDriver] = true
	if err := OpenGate(f, io.Discard); err != nil {
		t.Fatal(err)
	}
	for _, c := range f.calls {
		if strings.Contains(c, gceParam) {
			t.Fatalf("re-bound GCE that was already bound:\n%s", strings.Join(f.calls, "\n"))
		}
	}
}

func TestGadgetUsesTheMACTheHostInstallerLooksFor(t *testing.T) {
	f := newFake()
	f.present["/sys/class/udc"] = true
	if err := Gadget(f, io.Discard); err != nil {
		t.Fatal(err)
	}
	var sawHost bool
	for _, c := range f.calls {
		if strings.Contains(c, "host_addr="+HostMAC) {
			sawHost = true
		}
	}
	if !sawHost {
		t.Fatalf("host MAC %s never written; dc1-install.sh finds the link by it", HostMAC)
	}
}

// Every candidate refusing is an error, not a silent success -- but it is a
// recoverable one, because rc.sh retries with the real name.
func TestGadgetReportsWhenNoUDCBinds(t *testing.T) {
	f := newFake()
	f.present["/sys/class/udc"] = true
	for _, udc := range UDCCandidates() {
		_ = udc
		f.failWrite[gadgetRoot+"/UDC"] = true
	}
	if err := Gadget(f, io.Discard); err == nil {
		t.Fatal("reported a bound gadget when every UDC candidate failed")
	}
}

func TestStatusLines(t *testing.T) {
	cases := map[string]struct {
		in   string
		want []string
	}{
		"blank falls back":  {"", []string{DefaultStatus}},
		"newlines only":     {"\n\n", []string{DefaultStatus}},
		"trailing newline":  {"WRITING\n", []string{"WRITING"}},
		"blanks dropped":    {"A\n\nB\n", []string{"A", "B"}},
		"capped at the max": {strings.Repeat("X\n", 20), nil},
	}
	for name, tc := range cases {
		got := StatusLines(tc.in)
		if tc.want == nil {
			if len(got) != maxStatusLines {
				t.Errorf("%s: %d lines, want the %d cap", name, len(got), maxStatusLines)
			}
			continue
		}
		if strings.Join(got, "|") != strings.Join(tc.want, "|") {
			t.Errorf("%s: got %v, want %v", name, got, tc.want)
		}
	}
}

// PID 1 must never panic: a panic here is a dead device. Unknown bytes render
// blank rather than indexing off the end of the font.
func TestPaintSurvivesEveryByte(t *testing.T) {
	const w, h, stride = 64, 64, 64 * 4
	pix := make([]byte, stride*h)
	var all []byte
	for b := 0; b < 256; b++ {
		all = append(all, byte(b))
	}
	PaintStatus(pix, stride, w, h, []string{string(all)}, 12345, -1)
}

// Painting must stay inside the buffer whatever the geometry says.
func TestPaintClipsToTheBuffer(t *testing.T) {
	const w, h, stride = 16, 16, 16 * 4
	pix := make([]byte, stride*h)
	guard := make([]byte, len(pix))
	copy(guard, pix)
	PaintStatus(pix, stride, w, h, []string{"A VERY LONG STATUS LINE INDEED"}, 1, -1)
	if len(pix) != len(guard) {
		t.Fatal("buffer was resized")
	}
}

func TestMainRefusesUnlessPID1(t *testing.T) {
	var out, errb strings.Builder
	rc := Main(nil, &out, &errb)
	if rc != 1 {
		t.Fatalf("rc = %d, want 1", rc)
	}
	if !strings.Contains(errb.String(), "not 1") {
		t.Fatalf("stderr = %q", errb.String())
	}
	// The refusal has to say what it WOULD do, or it is just a wall.
	if !strings.Contains(errb.String(), "rc.sh") {
		t.Fatal("refusal did not describe the plan")
	}
}

func TestDryRunPrintsThePlanAndExitsZero(t *testing.T) {
	var out, errb strings.Builder
	if rc := Main([]string{"-n"}, &out, &errb); rc != 0 {
		t.Fatalf("rc = %d, want 0", rc)
	}
	if !strings.Contains(out.String(), "devtmpfs") {
		t.Fatalf("plan missing the mounts:\n%s", out.String())
	}
}

func TestMainRejectsUnknownArguments(t *testing.T) {
	var out, errb strings.Builder
	if rc := Main([]string{"--wat"}, &out, &errb); rc != 2 {
		t.Fatalf("rc = %d, want 2", rc)
	}
}

// runOnce drives Run to the point where the fake stops it, the way the
// ordering tests above do.
func runOnce(f *fakeOps) {
	f.ticks = 1
	f.stop = func() { panic(errStop) }
	done := make(chan struct{})
	go func() {
		defer func() { recover(); close(done) }()
		Run(f, io.Discard)
	}()
	<-done
}

// /tmp is an empty tmpfs on an initramfs boot and nothing stages the status
// file, so an open without O_CREAT fails with ENOENT every single boot: no
// STARTING on the panel and a false "cannot write" line at the exact moment an
// operator is scanning the log for real errors. init.c:575 used
// O_WRONLY|O_CREAT|O_TRUNC here and O_WRONLY|O_TRUNC for sysfs attributes; the
// distinction is deliberate and has to survive.
func TestInitialStatusIsCreatedNotJustTruncated(t *testing.T) {
	f := newFake()
	f.gateReady()
	runOnce(f)

	if got := f.files[StatusFile]; strings.TrimSpace(got) != "STARTING" {
		t.Fatalf("%s = %q, want STARTING -- the first status never reached the panel:\n%s",
			StatusFile, got, strings.Join(f.calls, "\n"))
	}
	for _, c := range f.calls {
		if strings.Contains(c, "cannot write") || strings.Contains(c, "ENOENT") {
			t.Fatalf("status write failed: %q", c)
		}
	}
}

// A sysfs/configfs attribute must still NOT be created: a plain file where the
// kernel should have exposed an attribute hides a missing driver behind a
// successful write.
func TestSysfsWritesStillNeverCreate(t *testing.T) {
	dir := t.TempDir()
	o := SysOps()
	path := dir + "/attribute-that-does-not-exist"
	if err := o.WriteFile(path, "1\n"); err == nil {
		t.Fatal("WriteFile created a missing file; a missing attribute must stay an error")
	}
	if err := o.CreateFile(path, "STARTING\n"); err != nil {
		t.Fatalf("CreateFile: %v", err)
	}
	b, err := os.ReadFile(path)
	if err != nil || string(b) != "STARTING\n" {
		t.Fatalf("CreateFile wrote %q, %v", b, err)
	}
}

// The failure that has to reach the host: rc.sh cannot start, so the kmsg
// streamer that feeds ttyGS0 never runs either. init.c's say() wrote every
// console node itself, ttyGS0 included, which is why the reason appeared on
// /dev/ttyACM0 anyway. Without that fan-out the operator gets a device that
// shows a status screen, does nothing, and says why on no channel at all.
func TestBootFailuresReachTheConsolesNotJustKmsg(t *testing.T) {
	f := newFake()
	f.gateReady()
	f.present["/etc/rc.sh"] = false // busybox is there, rc.sh is not
	runOnce(f)

	var saw bool
	for _, l := range f.consoles {
		if strings.Contains(l, "no installer daemon") {
			saw = true
		}
	}
	if !saw {
		t.Fatalf("the rc.sh failure never reached a console; consoles saw:\n%s",
			strings.Join(f.consoles, "\n"))
	}
}

// ttyGS0 is the one that matters: it is the host's /dev/ttyACM0, and it is the
// only channel left once the panel is dark and rc.sh (which streams kmsg to
// the gadget) has failed.
func TestConsoleListCarriesTheUSBSerial(t *testing.T) {
	var saw bool
	for _, c := range consoles {
		if c == "/dev/ttyGS0" {
			saw = true
		}
	}
	if !saw {
		t.Fatalf("consoles = %v, missing /dev/ttyGS0", consoles)
	}
}

// A dead channel must not take the live ones with it. io.MultiWriter returns
// on the first error, and on this device the first writer is a VT that the
// panel gate has just told the kernel not to drive.
func TestOneDeadChannelDoesNotSilenceTheRest(t *testing.T) {
	f := newFake()
	p := &progress{ops: f, w: []io.Writer{deadWriter{}, &strings.Builder{}}}
	live := p.w[1].(*strings.Builder)
	if _, err := p.Write([]byte("init: something went wrong\n")); err != nil {
		t.Fatalf("progress.Write reported %v; PID 1 has nowhere to report it to", err)
	}
	if !strings.Contains(live.String(), "something went wrong") {
		t.Fatal("a failing first writer swallowed the line")
	}
	if len(f.consoles) != 1 {
		t.Fatalf("consoles saw %v", f.consoles)
	}
}

type deadWriter struct{}

func (deadWriter) Write([]byte) (int, error) { return 0, errors.New("ENXIO") }
