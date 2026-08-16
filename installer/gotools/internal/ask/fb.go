package ask

// Framebuffer access: fbdev if the driver bound, /dev/mem at the address LK
// left the panel scanning out of if it did not.
//
// UNPROVEN, and probably wrong. This two-step is carried over verbatim from
// src/ask.c, which never ran on the device. PID 1 does NOT use it and no
// longer claims to: init.c:246-250 records that two maximally different
// framebuffers written through the fbdev emulation produced photographically
// identical panels, and that only a DRM atomic commit reaches the glass, so
// init.c paints via fb_via_drm() alone. Both branches here are therefore
// suspect on this panel: fbdev is a dead instrument, and the LK scanout buffer
// stops being scanned out the moment PID 1's modeset lands.
//
// The repair -- give dc1-ask the DRM surface PID 1 has -- is now implemented:
// the dialogs run inside PID 1 and draw into its surface (see screen.go and
// dialog.go), never modesetting one of their own. These two branches remain
// only as the fallback for the probe diagnostic, and both are still suspect on
// this panel.

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

// Fallback geometry, measured from the live LK atag videolfb (see init.c).
const (
	fbPhys   = 0xfe8c1000
	fbLen    = 0x1650000
	fbW      = 1200
	fbH      = 1600
	fbStride = (1200 + 16) * 4 // the panel's line stride is 16 pixels wider
)

// Offsets into the two fb ioctl structs. fb_var_screeninfo is all __u32, so
// its offsets are fixed; fb_fix_screeninfo carries an unsigned long
// (smem_start) and everything after it shifts with the word size.
const (
	varXres        = 0
	varYres        = 4
	varBitsPerPix  = 24
	fixSmemLen     = 16 + wordSize
	fixLineLength  = 16 + wordSize + 24
	screeninfoSize = 256 // both structs are well under this
)

// framebuffer is the panel: the mapping, the shadow canvas painted into, and
// the file keeping the mapping alive.
type framebuffer struct {
	f   *os.File
	mem []byte
	c   *canvas
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// openFB maps the panel. DC1_FB overrides the fbdev node and DC1_MEMDEV the
// physical-memory fallback (tests).
func openFB() (*framebuffer, error) {
	if fb, err := openFbdev(envOr("DC1_FB", "/dev/fb0")); err == nil {
		return fb, nil
	}
	return openDevmem(envOr("DC1_MEMDEV", "/dev/mem"))
}

func openFbdev(path string) (*framebuffer, error) {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	var vinfo, finfo [screeninfoSize]byte
	if err := ioctl(f.Fd(), fbioGetVScreenInfo, vinfo[:]); err != nil {
		f.Close()
		return nil, err
	}
	if err := ioctl(f.Fd(), fbioGetFScreenInfo, finfo[:]); err != nil {
		f.Close()
		return nil, err
	}
	w := int(le32(vinfo[varXres:]))
	h := int(le32(vinfo[varYres:]))
	bpp := int(le32(vinfo[varBitsPerPix:]))
	stride := int(le32(finfo[fixLineLength:]))
	if stride == 0 {
		stride = w * 4
	}
	if bpp == 0 {
		bpp = 32
	}
	length := int(le32(finfo[fixSmemLen:]))
	if length == 0 {
		length = stride * h
	}
	fb, err := mapFB(f, 0, length, w, h, stride, bpp)
	if err != nil {
		f.Close()
		return nil, err
	}
	return fb, nil
}

func openDevmem(path string) (*framebuffer, error) {
	f, err := os.OpenFile(path, os.O_RDWR|syscall.O_SYNC, 0)
	if err != nil {
		return nil, err
	}
	fb, err := mapFB(f, fbPhys, fbLen, fbW, fbH, fbStride, 32)
	if err != nil {
		f.Close()
		return nil, err
	}
	return fb, nil
}

// mapFB maps length bytes at off and allocates the shadow buffer. A panel
// this tool cannot paint correctly is refused rather than painted wrong:
// every drawing routine here assumes 32bpp little-endian pixels.
func mapFB(f *os.File, off int64, length, w, h, stride, bpp int) (*framebuffer, error) {
	if bpp != 32 || w <= 0 || h <= 0 || stride < w*4 {
		return nil, fmt.Errorf("unusable framebuffer: %dx%d, %d bpp, stride %d",
			w, h, bpp, stride)
	}
	if stride*h > length {
		return nil, errors.New("framebuffer mapping is shorter than one screen")
	}
	mem, err := syscall.Mmap(int(f.Fd()), off, length,
		syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_SHARED)
	if err != nil {
		return nil, err
	}
	return &framebuffer{f: f, mem: mem, c: newCanvas(w, h, stride)}, nil
}

// blit puts the finished screen on the panel in one copy, so nothing
// half-drawn is ever visible.
func (fb *framebuffer) blit() { copy(fb.mem, fb.c.pix) }

func (fb *framebuffer) canvas() *canvas { return fb.c }

func (fb *framebuffer) close() {
	syscall.Munmap(fb.mem)
	fb.f.Close()
}
