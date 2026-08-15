package pid1

import (
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Sending ourselves every signal in the list is the whole test: without Shield
// the Go runtime's handler routes them to dieFromSignal() and this test binary
// exits(2) instead of failing, which is exactly what PID 1 would do on the
// device -- "Kernel panic - not syncing: Attempted to kill init", on a board
// with no recovery channel that does not run a kernel.
func TestShieldedProcessSurvivesTheSignalsThatKillInit(t *testing.T) {
	Shield()
	self, err := os.FindProcess(os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	for _, sig := range fatal {
		if err := self.Signal(sig); err != nil {
			t.Fatalf("%v: %v", sig, err)
		}
		// Delivery is asynchronous; if it is going to kill us it does so here.
		time.Sleep(10 * time.Millisecond)
		t.Logf("survived %v", sig)
	}
}

// Shield must NOT leave these signals ignored, because SIG_IGN is inherited
// across execve while a handler is reset to SIG_DFL. PID 1 forks rc.sh, the
// debug shells and installd, and the system init execs the installed system's
// own init through switch_root: hand any of them a SIGTERM they cannot receive
// and `reboot` stops working on a device whose recovery story is a reboot.
func TestShieldLeavesChildrenTheirDefaultDispositions(t *testing.T) {
	Shield()
	ign, caught := dispositions(t)
	for _, sig := range fatal {
		bit := uint64(1) << (uint(sig.(syscall.Signal)) - 1)
		if ign&bit != 0 {
			t.Errorf("%v is SIG_IGN; every forked child would inherit that", sig)
		}
		if caught&bit == 0 {
			t.Errorf("%v is not caught, so nothing stops it killing PID 1", sig)
		}
	}
}

// dispositions reads SigIgn/SigCgt out of /proc/self/status -- the kernel's
// view, not the runtime's.
func dispositions(t *testing.T) (ign, caught uint64) {
	t.Helper()
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		t.Skipf("no /proc/self/status: %v", err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		v, err := strconv.ParseUint(f[1], 16, 64)
		if err != nil {
			continue
		}
		switch f[0] {
		case "SigIgn:":
			ign = v
		case "SigCgt:":
			caught = v
		}
	}
	if caught == 0 {
		t.Fatal("could not read SigCgt from /proc/self/status")
	}
	return ign, caught
}
