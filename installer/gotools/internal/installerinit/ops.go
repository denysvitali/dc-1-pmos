package installerinit

import (
	"errors"
	"os"
	"syscall"
	"time"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/drm"
)

// Ops is every effect PID 1 has on the world. Behind an interface so the boot
// sequence can be asserted against a recording fake: this code mounts over the
// running system and never returns, so there is no other way to test the
// ordering that matters.
type Ops interface {
	Mkdir(path string, mode os.FileMode) error
	Mount(source, target, fstype string, flags uintptr, data string) error
	// WriteFile writes an attribute that must already exist. It never
	// creates: a sysfs/configfs attribute that is not there means the driver
	// is not there, and creating a plain file in its place would hide that.
	WriteFile(path, value string) error
	// CreateFile writes a plain file, creating it if needed. /tmp is empty on
	// an initramfs boot, so anything under it needs this and not WriteFile.
	CreateFile(path, value string) error
	ReadFile(path string) (string, error)
	Exists(path string) bool
	WaitFor(path string, within time.Duration) error
	Symlink(oldname, newname string) error

	// OpenKmsg returns the writer progress goes to, or nil if there is none.
	OpenKmsg() *os.File
	// Broadcast puts one already-formatted line on every text console that
	// exists, each opened and closed per line.
	Broadcast(line string)
	// GrabTTY dups the console onto 0/1/2 so writes and kernel messages
	// coexist.
	GrabTTY(path string) error

	// Spawn starts the second stage without waiting for it.
	Spawn(argv []string) (int, error)
	// Reap collects finished children; PID 1 is everything's parent.
	Reap()

	Sleep(d time.Duration)

	// Display acquires the panel and returns a surface to paint on, or an
	// error if the device must run status-on-serial-only.
	Display() (Surface, error)
}

// Surface is an acquired panel: a shadow buffer plus the blit that puts it on
// the glass. It also satisfies ask.Surface (Size/Stride/Shadow/Blit), so PID 1
// can host the touch UI in-process: the dialogs draw into THIS buffer and
// blit, never modeset one of their own (a second modeset blackens this panel).
type Surface interface {
	Size() (w, h int)
	Stride() int
	// Shadow is the buffer the dialog engine draws into; Paint wraps the
	// status painter's use of the same buffer.
	Shadow() []byte
	// Paint hands the caller the shadow buffer to draw into.
	Paint(func(pix []byte, stride int))
	Blit() error
	How() string
	// DebugLine is the black-panel root-cause probe (see drm.Surface).
	DebugLine() string
}

type sysOps struct{}

// SysOps is the real implementation.
func SysOps() Ops { return sysOps{} }

func (sysOps) Mkdir(path string, mode os.FileMode) error {
	if err := os.Mkdir(path, mode); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	return nil
}

func (sysOps) Mount(source, target, fstype string, flags uintptr, data string) error {
	return syscall.Mount(source, target, fstype, flags, data)
}

func (sysOps) WriteFile(path, value string) error {
	return write(path, value, os.O_WRONLY|os.O_TRUNC, 0)
}

func (sysOps) CreateFile(path, value string) error {
	return write(path, value, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
}

func write(path, value string, flag int, mode os.FileMode) error {
	f, err := os.OpenFile(path, flag, mode)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(value)
	return err
}

func (sysOps) ReadFile(path string) (string, error) {
	b, err := os.ReadFile(path)
	return string(b), err
}

func (sysOps) Exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (o sysOps) WaitFor(path string, within time.Duration) error {
	deadline := time.Now().Add(within)
	for {
		if o.Exists(path) {
			return nil
		}
		if time.Now().After(deadline) {
			return errors.New("did not appear: " + path)
		}
		time.Sleep(time.Second)
	}
}

func (sysOps) Symlink(oldname, newname string) error {
	err := os.Symlink(oldname, newname)
	if err != nil && errors.Is(err, os.ErrExist) {
		return nil
	}
	return err
}

func (sysOps) OpenKmsg() *os.File {
	f, err := os.OpenFile("/dev/kmsg", os.O_WRONLY, 0)
	if err != nil {
		return nil
	}
	return f
}

// consoles is every text channel this initramfs might be watched on. ttyGS0 is
// the load-bearing one: it is the USB serial the host sees as /dev/ttyACM0,
// and it is the ONLY channel that carries a failure once the panel is dark and
// rc.sh -- which is what streams kmsg to the gadget -- has failed to start.
var consoles = []string{"/dev/tty0", "/dev/tty1", "/dev/console",
	"/dev/ttyS0", "/dev/ttyGS0"}

// Broadcast reproduces init.c's say(): open, write, close, per line and per
// node, best effort.
//
// It MUST use raw syscall writes, not os.File.Write. os.File.Write on a
// non-blocking fd that returns EAGAIN parks the goroutine in netpoll waiting
// for writability -- and a gadget serial (ttyGS0) nobody is draining never
// becomes writable, so PID 1 would hang here on the first status line emitted
// after the gadget comes up, before the paint loop ever runs. init.c used
// unchecked write(2), which returns EAGAIN and moves on. This reproduces that.
func (sysOps) Broadcast(line string) {
	b := []byte(line)
	for _, t := range consoles {
		fd, err := syscall.Open(t, syscall.O_WRONLY|syscall.O_NONBLOCK|syscall.O_NOCTTY, 0)
		if err != nil {
			continue
		}
		_, _ = syscall.Write(fd, b)
		_ = syscall.Close(fd)
	}
}

func (sysOps) GrabTTY(path string) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	// Dup3 rather than Dup2: arm64 has no dup2 syscall, so Go does not
	// expose syscall.Dup2 there. Dup3 with flags 0 is the same thing.
	fd := int(f.Fd())
	for _, target := range []int{0, 1, 2} {
		if fd == target {
			continue
		}
		if err := syscall.Dup3(fd, target, 0); err != nil {
			return err
		}
	}
	return nil
}

func (sysOps) Spawn(argv []string) (int, error) {
	return syscall.ForkExec(argv[0], argv, &syscall.ProcAttr{
		Files: []uintptr{0, 1, 2},
	})
}

// Reap drains every finished child. PID 1 inherits the orphans of the whole
// system, so this runs on every tick rather than per-child.
func (sysOps) Reap() {
	var status syscall.WaitStatus
	for {
		pid, err := syscall.Wait4(-1, &status, syscall.WNOHANG, nil)
		if pid <= 0 || err != nil {
			return
		}
	}
}

func (sysOps) Sleep(d time.Duration) { time.Sleep(d) }

func (o sysOps) Display() (Surface, error) { return drm.Acquire() }
