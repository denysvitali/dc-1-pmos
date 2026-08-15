package installerinit

import (
	"errors"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// DRM, by raw ioctl against the kernel UAPI. Only 32bpp XRGB8888 is handled;
// anything else and we give up cleanly and run status-on-serial rather than
// paint garbage on a panel nobody can read.
//
// The legacy SETCRTC ioctl is used deliberately: the kernel routes it through
// the atomic path internally, and an atomic commit is the ONLY channel that
// reaches the glass on this panel. /dev/fb0 does not -- two maximally
// different framebuffers written through the fbdev emulation produced
// photographically identical panels.
//
// The 1200x1600 buffer is 7.68 MB of contiguous coherent memory, satisfied by
// the postmarketOS kernel's CMA pool (CREATE_DUMB 32bpp verified on the
// installer kernel, 2026-08-14). If a future config regresses, CREATE_DUMB
// fails and the caller falls back to serial-only status.

const (
	drmIoctlSetMaster      = 0x641e
	drmIoctlModeGetRes     = 0xc04064a0
	drmIoctlModeGetConn    = 0xc05064a7
	drmIoctlModeCreateDumb = 0xc02064b2
	drmIoctlModeAddFB2     = 0xc06464b8
	drmIoctlModeMapDumb    = 0xc01064b3
	drmIoctlModeSetCRTC    = 0xc06864a2

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

type drmSurface struct {
	f      *os.File
	mem    []byte
	shadow []byte
	w, h   int
	stride int
}

func (s *drmSurface) Size() (int, int) { return s.w, s.h }
func (s *drmSurface) How() string      { return "DRM dumb-buffer" }

// Paint hands out the shadow buffer. Nothing draws straight into the scanout:
// the user must never see a half-drawn screen.
func (s *drmSurface) Paint(draw func(pix []byte, stride int)) {
	draw(s.shadow, s.stride)
}

func (s *drmSurface) Blit() error {
	copy(s.mem, s.shadow)
	return nil
}

// acquireDRM opens the card, finds a connected connector, allocates a dumb
// buffer and performs the first modeset -- which is the moment the panel
// lights.
func acquireDRM(ops Ops) (Surface, error) {
	f, err := os.OpenFile(cardNode, os.O_RDWR, 0)
	if err != nil {
		return nil, fmt.Errorf("no %s: %w", cardNode, err)
	}
	fd := f.Fd()

	// Fails harmlessly when we already own it.
	_ = ioctl(fd, drmIoctlSetMaster, unsafe.Pointer(nil))

	// Two-pass GETRESOURCES: count, then fill.
	var res drmModeCardRes
	if err := ioctl(fd, drmIoctlModeGetRes, unsafe.Pointer(&res)); err != nil {
		f.Close()
		return nil, fmt.Errorf("GETRESOURCES: %w", err)
	}
	if res.CountConnectors == 0 || res.CountCRTCs == 0 {
		f.Close()
		return nil, errors.New("no DRM connector/crtc")
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
	if err := ioctl(fd, drmIoctlModeGetRes, unsafe.Pointer(&res)); err != nil {
		f.Close()
		return nil, fmt.Errorf("GETRESOURCES (fill): %w", err)
	}
	crtcID := crtcs[0]

	// First connected connector, first mode.
	var mode drmModeInfo
	var connID uint32
	for i := 0; i < int(res.CountConnectors); i++ {
		var conn drmModeGetConnector
		conn.ConnectorID = conns[i]
		if err := ioctl(fd, drmIoctlModeGetConn, unsafe.Pointer(&conn)); err != nil {
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
		if err := ioctl(fd, drmIoctlModeGetConn, unsafe.Pointer(&conn)); err != nil {
			continue
		}
		if conn.Connection == drmModeConnected && conn.CountModes > 0 {
			connID = conns[i]
			mode = modes[0]
			break
		}
	}
	if connID == 0 {
		f.Close()
		return nil, errors.New("no connected DRM connector")
	}

	dumb := drmModeCreateDumb{
		Width:  uint32(mode.HDisplay),
		Height: uint32(mode.VDisplay),
		BPP:    32,
	}
	if err := ioctl(fd, drmIoctlModeCreateDumb, unsafe.Pointer(&dumb)); err != nil {
		f.Close()
		return nil, fmt.Errorf("CREATE_DUMB 32bpp failed -- no display: %w", err)
	}

	fb := drmModeFBCmd2{
		Width:       uint32(mode.HDisplay),
		Height:      uint32(mode.VDisplay),
		PixelFormat: drmFormatXRGB8888,
	}
	fb.Handles[0] = dumb.Handle
	fb.Pitches[0] = dumb.Pitch
	if err := ioctl(fd, drmIoctlModeAddFB2, unsafe.Pointer(&fb)); err != nil {
		f.Close()
		return nil, fmt.Errorf("ADDFB2: %w", err)
	}

	mreq := drmModeMapDumb{Handle: dumb.Handle}
	if err := ioctl(fd, drmIoctlModeMapDumb, unsafe.Pointer(&mreq)); err != nil {
		f.Close()
		return nil, fmt.Errorf("MAP_DUMB: %w", err)
	}
	mem, err := syscall.Mmap(int(fd), int64(mreq.Offset), int(dumb.Size),
		syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		f.Close()
		return nil, fmt.Errorf("dumb buffer mmap: %w", err)
	}

	// The first modeset: the scanout switches to our buffer and the panel
	// lights. It was held dark until exactly this point.
	set := drmModeCRTC{
		SetConnectorsPtr: uint64(uintptr(unsafe.Pointer(&connID))),
		CountConnectors:  1,
		CRTCID:           crtcID,
		FBID:             fb.FBID,
		ModeValid:        1,
		Mode:             mode,
	}
	if err := ioctl(fd, drmIoctlModeSetCRTC, unsafe.Pointer(&set)); err != nil {
		_ = syscall.Munmap(mem)
		f.Close()
		return nil, fmt.Errorf("SETCRTC failed -- panel stays dark: %w", err)
	}

	return &drmSurface{
		f:      f, // held for our lifetime; PID 1 never exits
		mem:    mem,
		shadow: make([]byte, len(mem)),
		w:      int(mode.HDisplay),
		h:      int(mode.VDisplay),
		stride: int(dumb.Pitch),
	}, nil
}
