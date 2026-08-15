package ask

import (
	"fmt"
	"io"
)

// probe is a diagnostic mode, not part of the install flow. It paints a bright
// marker at each scanout corner in turn and reports the RAW touch coordinates
// of the next tap, so the raw->scanout mapping can be measured instead of
// guessed. touch.go's tap() header documents why: the raw touch frame is
// believed inverted on both axes relative to the untransformed scanout dc1-ask
// paints into, and the decisive test is to touch a marker at a known scanout
// corner and read what raw position arrives.
//
//	dc1-ask probe [tl|tr|bl|br]   -- one named corner, or all four in order
func probe(args []string, stdout, stderr io.Writer) int {
	s, err := openSurface()
	if err != nil {
		fmt.Fprintln(stderr, "dc1-ask: no display")
		return 2
	}
	defer s.close()

	t, err := openTouch()
	if err != nil {
		fmt.Fprintln(stderr, "dc1-ask: no touchscreen")
		return 2
	}
	defer t.close()

	c := s.canvas()
	const block = 220
	corners := []struct {
		name   string
		mx, my int
	}{
		{"tl", 0, 0},
		{"tr", c.w - block, 0},
		{"bl", 0, c.h - block},
		{"br", c.w - block, c.h - block},
	}

	if len(args) > 0 {
		one := corners[:0]
		for _, cn := range corners {
			if cn.name == args[0] {
				one = append(one, cn)
			}
		}
		if len(one) == 0 {
			fmt.Fprintln(stderr, "dc1-ask: unknown corner "+args[0])
			return 2
		}
		corners = one
	}

	fmt.Fprintf(stdout, "PROBE scan=%dx%d axes_x=(%d,%d) axes_y=(%d,%d)\n",
		c.w, c.h, t.minX, t.maxX, t.minY, t.maxY)

	for i, cn := range corners {
		c.fillRect(0, 0, c.w, c.h, cBG)
		c.fillRect(cn.mx, cn.my, block, block, cFG)
		c.drawText(c.w/2-40, c.h/2-60, 12, cAccent, fmt.Sprintf("%d", i+1))
		s.blit()

		x, y, err := t.rawTap()
		if err != nil {
			fmt.Fprintln(stderr, "dc1-ask: tap read failed: "+err.Error())
			return 2
		}
		fmt.Fprintf(stdout, "PROBE corner=%s marker=(%d,%d) raw_x=%d raw_y=%d\n",
			cn.name, cn.mx, cn.my, x, y)
	}

	// Black the panel before handing back to PID 1, so the status screen
	// re-appears cleanly when it re-acquires master.
	c.fillRect(0, 0, c.w, c.h, cBG)
	s.blit()
	return 0
}
