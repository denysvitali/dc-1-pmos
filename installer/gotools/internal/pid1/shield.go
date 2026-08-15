// Package pid1 holds the one safety invariant both of this repo's inits need
// and neither can be tested for on a device that has no recovery channel: PID
// 1 must not be killable, and must not make its children unkillable either.
package pid1

import (
	"os"
	"os/signal"
	"syscall"
)

// fatal is every signal whose default action would end this process and, on
// PID 1, take the kernel with it: "Kernel panic - not syncing: Attempted to
// kill init". SIGPIPE is here for the same reason -- fds 1/2 of both inits are
// a VT and a USB gadget, either of which can go away mid-write.
var fatal = []os.Signal{
	syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP,
	syscall.SIGQUIT, syscall.SIGPIPE,
}

// Shield makes this process survive the signals that would otherwise kill it.
//
// The kernel discards these signals when they are sent to an init only while
// their disposition is still SIG_DFL (kernel/signal.c, sig_task_ignored()).
// The C inits installed nothing and were immune by construction. The Go
// runtime installs a handler for every signal during schedinit, which makes a
// Go init killable, and runtime.dieFromSignal() ends in exit(2) -- a kernel
// panic on the device, i.e. exactly the wedged state that needs a physical
// power-button press to leave. Busybox `reboot` without -f signals PID 1, so
// an operator in the rescue shell -- the only place a failed boot is
// driveable -- is one command away from that.
//
// signal.Notify, NOT signal.Ignore: SIG_IGN survives execve, so ignoring here
// would hand every forked child (rc.sh, installd, the debug shells) and, after
// switch_root, the installed system's real init a set of signals it cannot
// receive. Handlers are reset to SIG_DFL by execve, so with Notify the
// children keep the dispositions the C gave them. The signals are drained and
// dropped, which is what the kernel used to do for us.
func Shield() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, fatal...)
	go func() {
		for range ch {
		}
	}()
}
