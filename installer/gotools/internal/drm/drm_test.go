package drm

import (
	"testing"
	"unsafe"
)

// These values were produced by compiling a C program against the kernel UAPI
// headers this project vendors (installer/src/uapi/drm/*, the same headers the
// C init compiled against) and printing the real DRM_IOCTL_* macros and
// sizeof/offsetof. They are the ABI; if a Go struct here drifts, the derived
// ioctl encoding changes and these fail.
//
// This is not belt-and-braces. The first draft of drm.go hardcoded ADDFB2 as
// 0xc06464b8 -- a size of 100 where drm_mode_fb_cmd2 is 104, because the
// [4]uint64 modifier array forces 8-byte alignment padding. That one would in
// fact have WORKED: drm_ioctl() dispatches on _IOC_NR, copies in_size bytes
// and zero-fills the tail, and the four bytes lost were modifier[3]. Which is
// the point -- a wrong size is silent here, not an EINVAL, so the only way to
// know the encodings are right is to pin them against the headers.
func TestIoctlEncodingsMatchTheKernelHeaders(t *testing.T) {
	cases := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"SET_MASTER", drmIoctlSetMaster, 0x641e},
		{"DROP_MASTER", drmIoctlDropMaster, 0x641f},
		{"MODE_GETRESOURCES", drmIoctlModeGetRes, 0xc04064a0},
		{"MODE_GETCONNECTOR", drmIoctlModeGetConn, 0xc05064a7},
		{"MODE_CREATE_DUMB", drmIoctlModeCreateDumb, 0xc02064b2},
		{"MODE_ADDFB2", drmIoctlModeAddFB2, 0xc06864b8},
		{"MODE_MAP_DUMB", drmIoctlModeMapDumb, 0xc01064b3},
		{"MODE_SETCRTC", drmIoctlModeSetCRTC, 0xc06864a2},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s = %#x, kernel headers say %#x", c.name, c.got, c.want)
		}
	}
}

func TestStructSizesMatchTheKernelABI(t *testing.T) {
	cases := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"drm_mode_card_res", unsafe.Sizeof(drmModeCardRes{}), 64},
		{"drm_mode_get_connector", unsafe.Sizeof(drmModeGetConnector{}), 80},
		{"drm_mode_create_dumb", unsafe.Sizeof(drmModeCreateDumb{}), 32},
		{"drm_mode_fb_cmd2", unsafe.Sizeof(drmModeFBCmd2{}), 104},
		{"drm_mode_map_dumb", unsafe.Sizeof(drmModeMapDumb{}), 16},
		{"drm_mode_crtc", unsafe.Sizeof(drmModeCRTC{}), 104},
		{"drm_mode_modeinfo", unsafe.Sizeof(drmModeInfo{}), 68},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("sizeof(%s) = %d, kernel ABI says %d", c.name, c.got, c.want)
		}
	}
}

// Sizes alone do not pin the LAYOUT: two different field orders can share a
// size and still put the wrong value in the wrong place, which an ioctl
// accepts silently. These are the fields the code actually reads or writes.
func TestStructOffsetsMatchTheKernelABI(t *testing.T) {
	var res drmModeCardRes
	var conn drmModeGetConnector
	var dumb drmModeCreateDumb
	var crtc drmModeCRTC

	cases := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"card_res.connector_id_ptr", unsafe.Offsetof(res.ConnectorIDPtr), 16},
		{"card_res.count_crtcs", unsafe.Offsetof(res.CountCRTCs), 36},
		{"card_res.count_connectors", unsafe.Offsetof(res.CountConnectors), 40},
		{"get_connector.modes_ptr", unsafe.Offsetof(conn.ModesPtr), 8},
		{"get_connector.count_modes", unsafe.Offsetof(conn.CountModes), 32},
		{"get_connector.connector_id", unsafe.Offsetof(conn.ConnectorID), 48},
		{"get_connector.connection", unsafe.Offsetof(conn.Connection), 60},
		{"create_dumb.handle", unsafe.Offsetof(dumb.Handle), 16},
		{"create_dumb.pitch", unsafe.Offsetof(dumb.Pitch), 20},
		{"create_dumb.size", unsafe.Offsetof(dumb.Size), 24},
		{"crtc.set_connectors_ptr", unsafe.Offsetof(crtc.SetConnectorsPtr), 0},
		{"crtc.crtc_id", unsafe.Offsetof(crtc.CRTCID), 12},
		{"crtc.fb_id", unsafe.Offsetof(crtc.FBID), 16},
		{"crtc.mode_valid", unsafe.Offsetof(crtc.ModeValid), 32},
		{"crtc.mode", unsafe.Offsetof(crtc.Mode), 36},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("offsetof(%s) = %d, kernel ABI says %d", c.name, c.got, c.want)
		}
	}
}

// The modeset parameters must survive into the Surface so Reacquire can
// re-commit the same buffer. A modeset with a zeroed crtc/fb/mode would be
// accepted by the ioctl and simply point the scanout at nothing -- silent, so
// assert the fields the re-commit path reads are the ones Acquire set.
func TestSurfaceRemembersModesetParameters(t *testing.T) {
	s := &Surface{
		crtcID: 0x1234,
		connID: 0x5678,
		fbID:   0x9abc,
		mode:   drmModeInfo{HDisplay: 1200, VDisplay: 1600},
	}
	if s.crtcID == 0 || s.connID == 0 || s.fbID == 0 {
		t.Fatalf("modeset params not set: crtc=%x conn=%x fb=%x", s.crtcID, s.connID, s.fbID)
	}
}

// Blit rotates the shadow 180 degrees into the scanout: logical (x,y) must
// land at scanout (w-1-x, h-1-y). This is the hardware-measured panel
// orientation -- a straight copy would leave every screen upside-down.
func TestBlitRotates180(t *testing.T) {
	// 2x2 logical pixels, stride 8 bytes, each pixel one distinguishable u32.
	px := func(b byte) []byte { return []byte{0, 0, 0, b} }
	var shadow []byte
	shadow = append(shadow, px(0xAA)...) // logical (0,0)
	shadow = append(shadow, px(0xBB)...) // logical (1,0)
	shadow = append(shadow, px(0xCC)...) // logical (0,1)
	shadow = append(shadow, px(0xDD)...) // logical (1,1)

	s := &Surface{w: 2, h: 2, stride: 8, shadow: shadow, mem: make([]byte, 16)}
	if err := s.Blit(); err != nil {
		t.Fatalf("Blit: %v", err)
	}

	// After a 180 rotation, scanout (0,0) == logical (1,1) == 0xDD, etc.
	want := append(px(0xDD), append(px(0xCC), append(px(0xBB), px(0xAA)...)...)...)
	for i := range want {
		if s.mem[i] != want[i] {
			t.Fatalf("mem[%d] = %#x, want %#x (full: % x vs % x)",
				i, s.mem[i], want[i], s.mem, want)
		}
	}
}
