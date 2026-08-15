package ask

import "github.com/denysvitali/dc-1-pmos/installer/gotools/internal/drm"

// drmFB paints through the shared DRM surface. This is the path that actually
// reaches the glass on this panel: /dev/fb0 and the LK scanout buffer are dead
// instruments (see fb.go's header), and only a DRM atomic commit lights the
// panel.
//
// dc1-ask and PID 1 hand the panel back and forth by DRM master: PID 1 drops
// master when it sees /tmp/ui-active, and dc1-ask's Acquire retries SET_MASTER
// on EBUSY until that happens, then modesets its own buffer. On close, the fd
// is released and PID 1 re-acquires and re-commits the status screen.
type drmFB struct {
	s *drm.Surface
	c *canvas
}

func openDRM() (*drmFB, error) {
	s, err := drm.Acquire()
	if err != nil {
		return nil, err
	}
	w, h := s.Size()
	return &drmFB{s: s, c: &canvas{w: w, h: h, stride: s.Stride(), pix: s.Shadow()}}, nil
}

func (d *drmFB) canvas() *canvas { return d.c }
func (d *drmFB) blit()           { _ = d.s.Blit() }
func (d *drmFB) close()          { _ = d.s.Close() }
