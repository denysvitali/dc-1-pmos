package ask

import "github.com/denysvitali/dc-1-pmos/installer/gotools/internal/drm"

// drmFB paints through a DRM surface dc1-ask acquires itself. This path is now
// used ONLY by the probe diagnostic, which needs a marker on screen and
// therefore modesets its own buffer -- a second modeset that does not reach
// this panel's glass (see internal/drm). The dialogs (menu/text/secret/info)
// no longer take this path: they run inside PID 1, drawing into its surface
// via screen.go/dialog.go.
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
