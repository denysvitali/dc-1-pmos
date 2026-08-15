package ask

// The two ioctl families this tool needs, and the ABI sizes that go with
// them. Confined to this file so the rest of the package stays free of
// unsafe, the same way internal/rebootfastboot does it.

import (
	"syscall"
	"unsafe"
)

// _IOC from asm-generic/ioctl.h, which is what arm64 uses.
const (
	iocRead      = 2
	iocNRBits    = 8
	iocTypeBits  = 8
	iocSizeBits  = 14
	iocNRShift   = 0
	iocTypeShift = iocNRShift + iocNRBits
	iocSizeShift = iocTypeShift + iocTypeBits
	iocDirShift  = iocSizeShift + iocSizeBits
)

func ioc(dir, typ, nr, size uintptr) uintptr {
	return dir<<iocDirShift | typ<<iocTypeShift | nr<<iocNRShift | size<<iocSizeShift
}

// EVIOCGBIT(EV_ABS, len): which absolute axes the device reports.
func eviocgbit(ev, length int) uintptr {
	return ioc(iocRead, 'E', uintptr(0x20+ev), uintptr(length))
}

// EVIOCGABS(axis): struct input_absinfo for one axis.
func eviocgabs(axis int) uintptr {
	return ioc(iocRead, 'E', uintptr(0x40+axis), absinfoSize)
}

// linux/fb.h.
const (
	fbioGetVScreenInfo = 0x4600
	fbioGetFScreenInfo = 0x4602
)

const (
	// struct input_absinfo: six __s32, on every architecture.
	absinfoSize = 24

	// struct input_event is a struct timeval followed by __u16 type,
	// __u16 code, __s32 value. Go's syscall.Timeval mirrors the kernel's
	// per architecture, so take the size from it rather than assuming 64-bit.
	timevalSize = int(unsafe.Sizeof(syscall.Timeval{}))
	eventSize   = timevalSize + 8

	// sizeof(long): struct fb_fix_screeninfo carries an unsigned long, so
	// the offsets after it depend on the word size.
	wordSize = int(unsafe.Sizeof(uintptr(0)))
)

func ioctl(fd, req uintptr, buf []byte) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, req,
		uintptr(unsafe.Pointer(&buf[0])))
	if errno != 0 {
		return errno
	}
	return nil
}
