// Package drm acquires the DC-1 panel over DRM (a dumb buffer committed with
// the legacy SETCRTC ioctl) and holds DRM master for as long as the surface is
// alive. It is shared by two processes that never touch the panel at once:
//
//   - PID 1 (internal/installerinit), which owns the panel for the life of the
//     boot and paints the status screen, and
//   - dc1-ask (internal/ask), which takes the panel over while a prompt is on
//     screen and releases it when it exits.
//
// The handover is the one the C init never did: DRM allows one master per
// device (drm_auth.c: drm_setmaster_ioctl returns -EBUSY when dev->master is
// already set, -EINVAL when this file_priv already is master), and SETCRTC is
// a DRM_MASTER ioctl. So PID 1 drops master (DropMaster) while dc1-ask owns the
// panel, and re-acquires plus re-commits its buffer (Reacquire) afterwards.
//
// Only 32bpp XRGB8888 is handled; anything else and Acquire fails cleanly so
// the caller runs status-on-serial rather than paint garbage on a panel nobody
// can read. /dev/fb0 is NOT used: two maximally different framebuffers written
// through the fbdev emulation produced photographically identical panels -- an
// atomic commit is the ONLY channel that reaches the glass.
package drm

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
	"unsafe"
)

// cardNode is the only DRM node this panel exposes. Not exported: PID 1's gate
// (internal/installerinit/gate.go) waits for it with its own copy of the path,
// and nothing else needs it.
const cardNode = "/dev/dri/card0"

// The ioctl numbers are COMPUTED from the struct sizes, never written down.
//
// An ioctl encoding carries sizeof(arg) in bits 16..29, so a hardcoded number
// and a struct that disagree is an ABI break with no fixed symptom. That is
// not hypothetical -- the first draft of this file hardcoded ADDFB2 as
// 0xc06464b8, encoding 100 bytes, while drm_mode_fb_cmd2 is 104 (the
// [4]uint64 modifier forces 8-byte alignment padding after the three uint32
// arrays). The kernel accepts a short encoding silently (drm_ioctl zero-fills
// the tail), so the only way to know the encoding is right is to pin it --
// drm_test.go does that against the values the kernel headers produce.
const (
	iocNRBits   = 8
	iocTypeBits = 8
	iocSizeBits = 14

	iocNRShift   = 0
	iocTypeShift = iocNRShift + iocNRBits
	iocSizeShift = iocTypeShift + iocTypeBits
	iocDirShift  = iocSizeShift + iocSizeBits

	iocWrite = 1
	iocRead  = 2

	drmIoctlBase = 'd'
)

func ioc(dir, typ, nr, size uintptr) uintptr {
	return dir<<iocDirShift | size<<iocSizeShift | typ<<iocTypeShift | nr<<iocNRShift
}

// iowr is _IOWR: the direction every DRM mode ioctl here uses.
func iowr(nr, size uintptr) uintptr {
	return ioc(iocRead|iocWrite, drmIoctlBase, nr, size)
}

// ioNone is _IO: no argument payload (SET_MASTER, DROP_MASTER).
func ioNone(nr uintptr) uintptr { return ioc(0, drmIoctlBase, nr, 0) }

var (
	drmIoctlSetMaster    = ioNone(0x1e)
	drmIoctlDropMaster   = ioNone(0x1f)
	drmIoctlModeGetRes   = iowr(0xa0, unsafe.Sizeof(drmModeCardRes{}))
	drmIoctlModeGetConn  = iowr(0xa7, unsafe.Sizeof(drmModeGetConnector{}))
	drmIoctlModeCreateDumb = iowr(0xb2, unsafe.Sizeof(drmModeCreateDumb{}))
	drmIoctlModeAddFB2   = iowr(0xb8, unsafe.Sizeof(drmModeFBCmd2{}))
	drmIoctlModeMapDumb  = iowr(0xb3, unsafe.Sizeof(drmModeMapDumb{}))
	drmIoctlModeSetCRTC  = iowr(0xa2, unsafe.Sizeof(drmModeCRTC{}))
)

const (
	drmFormatXRGB8888 = 0x34325258 // 'XR24'
	drmModeConnected  = 1
)

type drmModeCardRes struct {
	FBIDPtr, CRTCIDPtr, ConnectorIDPtr, EncoderIDPtr     uint64
	CountFBs, CountCRTCs, CountConnectors, CountEncoders uint32
	MinWidth, MaxWidth, MinHeight, MaxHeight             uint32
}

type drmModeInfo struct {
	Clock                                  uint32
	HDisplay, HSyncStart, HSyncEnd, HTotal uint16
	HSkew                                  uint16
	VDisplay, VSyncStart, VSyncEnd, VTotal uint16
	VScan                                  uint16
	VRefresh                               uint32
	Flags, Type                            uint32
	Name                                   [32]byte
}

type drmModeGetConnector struct {
	EncodersPtr, ModesPtr, PropsPtr, PropValuesPtr uint64
	CountModes, CountProps, CountEncoders          uint32
	EncoderID, ConnectorID, ConnectorType          uint32
	ConnectorTypeID                                uint32
	Connection, MMWidth, MMHeight, Subpixel        uint32
	Pad                                            uint32
}

type drmModeCreateDumb struct {
	Height, Width, BPP, Flags uint32
	Handle, Pitch             uint32
	Size                      uint64
}

type drmModeFBCmd2 struct {
	FBID, Width, Height, PixelFormat, Flags uint32
	Handles                                 [4]uint32
	Pitches                                 [4]uint32
	Offsets                                 [4]uint32
	Modifier                                [4]uint64
}

type drmModeMapDumb struct {
	Handle, Pad uint32
	Offset      uint64
}

type drmModeCRTC struct {
	SetConnectorsPtr     uint64
	CountConnectors      uint32
	CRTCID, FBID         uint32
	X, Y                 uint32
	GammaSize, ModeValid uint32
	Mode                 drmModeInfo
}

func ioctl(fd uintptr, req uintptr, arg unsafe.Pointer) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, req, uintptr(arg))
	if errno != 0 {
		return errno
	}
	return nil
}

// Surface is an acquired panel. It owns the card0 file descriptor, the dumb
// buffer's mapped memory, and DRM master.
type Surface struct {
	f      *os.File
	mem    []byte
	shadow []byte
	w, h   int
	stride int

	// Remembered modeset parameters, so Reacquire can re-commit this buffer
	// after dc1-ask has pointed the scanout at its own.
	crtcID, connID, fbID uint32
	mode                 drmModeInfo
}

func (s *Surface) Size() (int, int) { return s.w, s.h }
func (s *Surface) Stride() int      { return s.stride }
func (s *Surface) How() string      { return "DRM dumb-buffer" }

// Shadow returns the shadow buffer. Nothing draws straight into the scanout:
// the user must never see a half-drawn screen.
func (s *Surface) Shadow() []byte { return s.shadow }

// Paint hands out the shadow buffer.
func (s *Surface) Paint(draw func(pix []byte, stride int)) {
	draw(s.shadow, s.stride)
}

// Blit puts the finished shadow on the panel in one copy.
func (s *Surface) Blit() error {
	copy(s.mem, s.shadow)
	return nil
}

// DropMaster releases DRM master so another process (dc1-ask) can modeset.
// It returns nil when already not master, since that is the state it was
// called to reach.
func (s *Surface) DropMaster() error {
	if err := ioctl(s.f.Fd(), drmIoctlDropMaster, unsafe.Pointer(nil)); err != nil && err != syscall.EINVAL {
		return err
	}
	return nil
}

// Reacquire takes DRM master back and re-commits this buffer to the scanout.
// Called after dc1-ask has released the panel.
func (s *Surface) Reacquire() error {
	if err := setMaster(s.f); err != nil {
		return err
	}
	return s.modeset()
}

func (s *Surface) modeset() error {
	set := drmModeCRTC{
		SetConnectorsPtr: uint64(uintptr(unsafe.Pointer(&s.connID))),
		CountConnectors:  1,
		CRTCID:           s.crtcID,
		FBID:             s.fbID,
		ModeValid:        1,
		Mode:             s.mode,
	}
	return ioctl(s.f.Fd(), drmIoctlModeSetCRTC, unsafe.Pointer(&set))
}

// Close unmaps the dumb buffer and closes the card, which releases DRM master.
func (s *Surface) Close() error {
	var err error
	if s.mem != nil {
		_ = syscall.Munmap(s.mem)
		s.mem = nil
	}
	if s.f != nil {
		err = s.f.Close()
		s.f = nil
	}
	return err
}

// Acquire opens the card, takes DRM master, allocates a dumb buffer and
// performs the first modeset -- which is the moment the panel lights.
func Acquire() (*Surface, error) {
	f, err := os.OpenFile(cardNode, os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("no %s: %w", cardNode, err)
	}
	fail := func(err error) (*Surface, error) {
		f.Close()
		return nil, err
	}

	if err := setMaster(f); err != nil {
		return fail(err)
	}

	// Two-pass GETRESOURCES: count, then fill.
	var res drmModeCardRes
	if err := ioctl(f.Fd(), drmIoctlModeGetRes, unsafe.Pointer(&res)); err != nil {
		return fail(fmt.Errorf("GETRESOURCES: %w", err))
	}
	if res.CountConnectors == 0 || res.CountCRTCs == 0 {
		return fail(errors.New("no DRM connector/crtc"))
	}
	if res.CountConnectors > 8 {
		res.CountConnectors = 8
	}
	if res.CountCRTCs > 8 {
		res.CountCRTCs = 8
	}
	var conns, crtcs [8]uint32
	res.ConnectorIDPtr = uint64(uintptr(unsafe.Pointer(&conns[0])))
	res.CRTCIDPtr = uint64(uintptr(unsafe.Pointer(&crtcs[0])))
	res.CountEncoders, res.CountFBs = 0, 0
	res.EncoderIDPtr, res.FBIDPtr = 0, 0
	if err := ioctl(f.Fd(), drmIoctlModeGetRes, unsafe.Pointer(&res)); err != nil {
		return fail(fmt.Errorf("GETRESOURCES (fill): %w", err))
	}
	crtcID := crtcs[0]

	// First connected connector, first mode.
	var mode drmModeInfo
	var connID uint32
	for i := 0; i < int(res.CountConnectors); i++ {
		var conn drmModeGetConnector
		conn.ConnectorID = conns[i]
		if err := ioctl(f.Fd(), drmIoctlModeGetConn, unsafe.Pointer(&conn)); err != nil {
			continue
		}
		if conn.CountModes == 0 {
			continue
		}
		if conn.CountModes > 8 {
			conn.CountModes = 8
		}
		var modes [8]drmModeInfo
		conn.ModesPtr = uint64(uintptr(unsafe.Pointer(&modes[0])))
		conn.CountProps, conn.CountEncoders = 0, 0
		conn.PropsPtr, conn.PropValuesPtr, conn.EncodersPtr = 0, 0, 0
		if err := ioctl(f.Fd(), drmIoctlModeGetConn, unsafe.Pointer(&conn)); err != nil {
			continue
		}
		if conn.Connection == drmModeConnected && conn.CountModes > 0 {
			connID = conns[i]
			mode = modes[0]
			break
		}
	}
	if connID == 0 {
		return fail(errors.New("no connected DRM connector"))
	}

	dumb := drmModeCreateDumb{
		Width:  uint32(mode.HDisplay),
		Height: uint32(mode.VDisplay),
		BPP:    32,
	}
	if err := ioctl(f.Fd(), drmIoctlModeCreateDumb, unsafe.Pointer(&dumb)); err != nil {
		return fail(fmt.Errorf("CREATE_DUMB 32bpp failed -- no display: %w", err))
	}

	fb := drmModeFBCmd2{
		Width:       uint32(mode.HDisplay),
		Height:      uint32(mode.VDisplay),
		PixelFormat: drmFormatXRGB8888,
	}
	fb.Handles[0] = dumb.Handle
	fb.Pitches[0] = dumb.Pitch
	if err := ioctl(f.Fd(), drmIoctlModeAddFB2, unsafe.Pointer(&fb)); err != nil {
		return fail(fmt.Errorf("ADDFB2: %w", err))
	}

	mreq := drmModeMapDumb{Handle: dumb.Handle}
	if err := ioctl(f.Fd(), drmIoctlModeMapDumb, unsafe.Pointer(&mreq)); err != nil {
		return fail(fmt.Errorf("MAP_DUMB: %w", err))
	}
	mem, err := syscall.Mmap(int(f.Fd()), int64(mreq.Offset), int(dumb.Size),
		syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		return fail(fmt.Errorf("dumb buffer mmap: %w", err))
	}

	s := &Surface{
		f:      f,
		mem:    mem,
		shadow: make([]byte, len(mem)),
		w:      int(mode.HDisplay),
		h:      int(mode.VDisplay),
		stride: int(dumb.Pitch),
		crtcID: crtcID,
		connID: connID,
		fbID:   fb.FBID,
		mode:   mode,
	}
	if err := s.modeset(); err != nil {
		s.Close()
		return nil, fmt.Errorf("SETCRTC failed -- panel stays dark: %w", err)
	}
	return s, nil
}

// setMaster takes DRM master, retrying briefly on EBUSY so dc1-ask can call it
// the moment PID 1's loop drops master (PID 1 polls /tmp/ui-active on a 1s
// tick, so a fresh dc1-ask can observe a short EBUSY window). EINVAL means
// this fd already is master; that is success, not an error.
func setMaster(f *os.File) error {
	deadline := time.Now().Add(5 * time.Second)
	for {
		err := ioctl(f.Fd(), drmIoctlSetMaster, unsafe.Pointer(nil))
		switch err {
		case nil, syscall.EINVAL:
			return nil
		case syscall.EBUSY:
			if time.Now().After(deadline) {
				return err
			}
			time.Sleep(100 * time.Millisecond)
		default:
			return err
		}
	}
}
