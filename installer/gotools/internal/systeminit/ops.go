package systeminit

import (
	"io"
	"os"
	"strings"
	"syscall"
	"time"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/partition"
	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/rebootfastboot"
)

// Ops is every effect this init has on the machine. Nothing else in the
// package touches a syscall, which is what lets the boot ORDER -- the part
// that was learned from failed boots, not from reading code -- be asserted
// against a fake instead of against a device that has no recovery channel.
type Ops interface {
	// Say broadcasts one already-formatted line to every text channel.
	Say(line string)
	// OpenKmsg starts including /dev/kmsg in Say. Only callable once
	// devtmpfs is up, which is why it is a step and not a constructor.
	OpenKmsg()

	Mkdir(path string, mode uint32) error
	Mount(source, target, fstype string, flags uintptr, data string) error
	Unmount(target string) error
	MoveMount(from, to string) error
	Symlink(link, target string) error
	// WriteSys writes an attribute; it never creates the file, because a
	// configfs attribute that does not exist means the gadget is not there.
	WriteSys(path, value string) error
	Touch(path string) error
	Stat(path string) (FileInfo, error)
	OpenRead(path string) (io.ReadCloser, error)
	OpenWrite(path string) (io.WriteCloser, error)

	// Spawn forks and execs a child with extraEnv added to its environment.
	// tty, when set, becomes its fds 0/1/2 in a new session. Wait reports one
	// child; block=false is a poll, and pid=-1 reaps whatever is ready.
	Spawn(path string, argv, extraEnv []string, tty string) (int, error)
	Wait(pid int, block bool) (wpid, status int, err error)
	// Exec replaces this process. On success it does not return.
	Exec(path string, argv []string) error

	// ProbeRoots resolves the install target and reports what filesystem it
	// carries. The error is the "not there yet" case worth retrying.
	ProbeRoots() ([]Candidate, error)
	// ArmFastboot points the pending watchdog reset at LK fastboot.
	ArmFastboot() error

	Now() time.Time
	Sleep(d time.Duration)
}

// FileInfo is the part of stat(2) this init makes decisions on.
type FileInfo struct {
	Dev   uint64
	Mode  uint32
	MTime time.Time
}

// Executable answers access(path, X_OK) closely enough for an initramfs that
// runs as root and stages its own files.
func (f FileInfo) Executable() bool { return f.Mode&0o111 != 0 }

// sysOps is the real machine.
type sysOps struct {
	stdout io.Writer
	stderr io.Writer
	kmsg   *os.File
}

// consoles is every text channel a failed boot might be watched on.
var consoles = []string{"/dev/tty0", "/dev/tty1", "/dev/console", "/dev/ttyS0"}

func (o *sysOps) Say(line string) {
	b := []byte(line)
	_, _ = o.stdout.Write(b)
	_, _ = o.stderr.Write(b)
	if o.kmsg != nil {
		_, _ = o.kmsg.Write(b)
	}
	for _, t := range consoles {
		f, err := os.OpenFile(t, os.O_WRONLY|syscall.O_NONBLOCK|syscall.O_NOCTTY, 0)
		if err != nil {
			continue
		}
		_, _ = f.Write(b)
		_ = f.Close()
	}
}

func (o *sysOps) OpenKmsg() {
	f, err := os.OpenFile("/dev/kmsg", os.O_WRONLY, 0)
	if err == nil {
		o.kmsg = f
	}
}

func (o *sysOps) Mkdir(path string, mode uint32) error { return syscall.Mkdir(path, mode) }

func (o *sysOps) Mount(source, target, fstype string, flags uintptr, data string) error {
	return syscall.Mount(source, target, fstype, flags, data)
}

func (o *sysOps) Unmount(target string) error { return syscall.Unmount(target, 0) }

func (o *sysOps) MoveMount(from, to string) error {
	return syscall.Mount(from, to, "", syscall.MS_MOVE, "")
}

func (o *sysOps) Symlink(link, target string) error { return os.Symlink(target, link) }

func (o *sysOps) WriteSys(path, value string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return err
	}
	_, err = f.WriteString(value)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

func (o *sysOps) Touch(path string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	_, err = f.WriteString("1\n")
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

func (o *sysOps) Stat(path string) (FileInfo, error) {
	var st syscall.Stat_t
	if err := syscall.Stat(path, &st); err != nil {
		return FileInfo{}, err
	}
	return FileInfo{
		Dev:   uint64(st.Dev),
		Mode:  uint32(st.Mode),
		MTime: time.Unix(st.Mtim.Sec, st.Mtim.Nsec),
	}, nil
}

func (o *sysOps) OpenRead(path string) (io.ReadCloser, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NOCTTY, 0)
}

func (o *sysOps) OpenWrite(path string) (io.WriteCloser, error) {
	return os.OpenFile(path, os.O_WRONLY|syscall.O_NOCTTY, 0)
}

func (o *sysOps) Spawn(path string, argv, extraEnv []string, tty string) (int, error) {
	attr := &syscall.ProcAttr{
		Env:   append(os.Environ(), extraEnv...),
		Files: []uintptr{0, 1, 2},
		Sys:   &syscall.SysProcAttr{},
	}
	if tty != "" {
		f, err := os.OpenFile(tty, os.O_RDWR|syscall.O_NOCTTY, 0)
		if err != nil {
			return 0, err
		}
		defer f.Close()
		fd := f.Fd()
		attr.Files = []uintptr{fd, fd, fd}
		attr.Sys.Setsid = true
	}
	return syscall.ForkExec(path, argv, attr)
}

func (o *sysOps) Wait(pid int, block bool) (int, int, error) {
	var ws syscall.WaitStatus
	var flags int
	if !block {
		flags = syscall.WNOHANG
	}
	for {
		wpid, err := syscall.Wait4(pid, &ws, flags, nil)
		if err == syscall.EINTR {
			continue
		}
		return wpid, ws.ExitStatus(), err
	}
}

func (o *sysOps) Exec(path string, argv []string) error {
	return syscall.Exec(path, argv, os.Environ())
}

func (o *sysOps) ProbeRoots() ([]Candidate, error) {
	// The same fail-closed PARTNAME resolution the installer writes through
	// (internal/partition, i.e. partlib.sh's rules): unique match, size floor,
	// so no boot-critical partition is reachable from here by construction.
	r, err := partition.ResolveUserdata()
	if err != nil {
		return nil, err
	}
	st, err := o.Stat(r.Device)
	if err != nil {
		return nil, err
	}
	if st.Mode&syscall.S_IFMT != syscall.S_IFBLK {
		return nil, &os.PathError{Op: "probe", Path: r.Device, Err: syscall.ENOTBLK}
	}
	f, err := os.Open(r.Device)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	// A short or failed read is NOT retried: the partition is there, it just
	// does not carry a filesystem we accept, which is the not-installed case.
	sb := make([]byte, SuperblockSize)
	cand := Candidate{Device: r.Device}
	if _, err := f.ReadAt(sb, SuperblockOffset); err == nil {
		cand.FSType, cand.Label = ProbeSuperblock(sb)
	}
	return []Candidate{cand}, nil
}

// ArmFastboot reuses the hardware-verified nibble write from
// dc1-reboot-fastboot. init.c had to keep its own copy inline because a forked
// child's exec path is not trustworthy after switch_root; here the petter is
// this same already-resident binary, so there is nothing to re-exec and no
// second implementation of the register write to keep alive.
func (o *sysOps) ArmFastboot() error {
	return rebootfastboot.ArmNibble(false, sayWriter{o})
}

func (o *sysOps) Now() time.Time { return time.Now() }

func (o *sysOps) Sleep(d time.Duration) { time.Sleep(d) }

// sayWriter routes another package's progress output onto the consoles.
type sayWriter struct{ o Ops }

func (w sayWriter) Write(p []byte) (int, error) {
	for _, l := range strings.Split(strings.TrimRight(string(p), "\n"), "\n") {
		if l != "" {
			w.o.Say(Line(l))
		}
	}
	return len(p), nil
}
