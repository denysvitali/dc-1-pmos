package ask

import (
	"fmt"
	"io"
	"strconv"
)

// touchprobe measures the raw touch mapping WITHOUT rendering anything, so it
// does not need the panel or DRM master at all. This is the decisive test for
// touch.go's "inverted on both axes" hypothesis, and it is deliberately free of
// the display path: rendering a marker needs a second DRM modeset, which this
// panel cannot do (see internal/drm -- only the one-time boot handoff lights
// it). Reading evdev only needs the touchscreen node.
//
//	dc1-ask touchprobe [N]   -- read N taps (default 4), print raw (x,y) each
func touchprobe(args []string, stdout, stderr io.Writer) int {
	n := 4
	if len(args) > 0 {
		v, err := strconv.Atoi(args[0])
		if err != nil || v < 1 {
			fmt.Fprintln(stderr, "dc1-ask: touchprobe [N] (N taps, default 4)")
			return 2
		}
		n = v
	}

	t, err := openTouch()
	if err != nil {
		fmt.Fprintln(stderr, "dc1-ask: no touchscreen: "+err.Error())
		return 2
	}
	defer t.close()

	fmt.Fprintf(stdout, "TOUCHPROBE axes_x=(%d,%d) axes_y=(%d,%d) taps=%d\n",
		t.minX, t.maxX, t.minY, t.maxY, n)

	for i := 0; i < n; i++ {
		x, y, err := t.rawTap()
		if err != nil {
			fmt.Fprintln(stderr, "dc1-ask: tap read failed: "+err.Error())
			return 2
		}
		fmt.Fprintf(stdout, "TOUCHPROBE tap=%d raw_x=%d raw_y=%d\n", i+1, x, y)
	}
	return 0
}
