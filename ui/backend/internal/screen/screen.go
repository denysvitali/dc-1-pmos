// Package screen captures what is actually on the panel.
//
// It exists because this device is developed at the end of a USB cable: the
// panel is the only output that matters and, until now, the only way to read
// it was to photograph it. A capture endpoint turns "does onboarding look
// right" from a question someone has to be in the room to answer into one the
// build can answer.
//
// Capture goes through the compositor (wlr-screencopy), not through DRM. A
// DRM read-back would need to be master, and sway holds that for the life of
// the session; wlr-screencopy is the protocol wlroots exposes for exactly
// this, and it returns the composited output rather than one client's buffer.
package screen

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Capturer returns the current panel contents as an encoded image.
type Capturer interface {
	// Capture returns PNG bytes. It never returns a partial image with a nil
	// error: a caller that gets no error may render what it gets.
	Capture(ctx context.Context) ([]byte, error)
}

// Grim captures with grim(1), the wlroots screenshot tool.
//
// dc1-backend runs as root from OpenRC and therefore starts with none of the
// session's environment; grim needs to find the compositor socket, which is
// discovered here rather than inherited. Discovery is done per call, so a
// session that restarts (a crash, or the reboot at the end of onboarding)
// does not leave the endpoint permanently pointed at a dead socket.
type Grim struct {
	// Root is the rootfs prefix, "/" in production.
	Root string
	// Bin is the tool to run; empty means "grim".
	Bin string
}

// Capture shells out to grim and returns the PNG on stdout.
func (g Grim) Capture(ctx context.Context) ([]byte, error) {
	runtime, display, err := g.session()
	if err != nil {
		return nil, err
	}
	bin := g.Bin
	if bin == "" {
		bin = "grim"
	}
	cmd := exec.CommandContext(ctx, bin, "-t", "png", "-")
	// Minimal and fixed, like cmdrunner's: nothing here is a secret, and
	// nothing here is caller-supplied.
	cmd.Env = []string{
		"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
		"LC_ALL=C",
		"XDG_RUNTIME_DIR=" + runtime,
		"WAYLAND_DISPLAY=" + display,
	}
	var out, errBuf bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s: %w%s", bin, err, excerpt(errBuf.String()))
	}
	if !bytes.HasPrefix(out.Bytes(), pngMagic) {
		// grim exiting 0 without a PNG has happened often enough in other
		// people's bug reports to be worth refusing here rather than
		// handing the caller something it will try to decode.
		return nil, fmt.Errorf("%s produced %d bytes that are not a PNG",
			bin, out.Len())
	}
	return out.Bytes(), nil
}

var pngMagic = []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

// session finds the compositor: the newest wayland-N socket under any
// /run/user/UID. There is exactly one graphical session on this device, so
// there is no ambiguity to resolve -- but if that ever stops being true, the
// choice is made explicit and deterministic here rather than by whichever
// entry readdir happened to return first.
func (g Grim) session() (runtime, display string, err error) {
	root := g.Root
	if root == "" {
		root = "/"
	}
	base := filepath.Join(root, "run/user")
	users, err := os.ReadDir(base)
	if err != nil {
		return "", "", fmt.Errorf("no session directory (%s): %w", base, err)
	}
	var found []string
	for _, u := range users {
		if !u.IsDir() {
			continue
		}
		dir := filepath.Join(base, u.Name())
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			name := e.Name()
			// wayland-1 is the socket; wayland-1.lock is not.
			if strings.HasPrefix(name, "wayland-") && !strings.HasSuffix(name, ".lock") {
				found = append(found, filepath.Join(dir, name))
			}
		}
	}
	if len(found) == 0 {
		return "", "", fmt.Errorf("no wayland socket under %s: the compositor is not running", base)
	}
	sort.Strings(found)
	pick := found[len(found)-1]
	return filepath.Dir(pick), filepath.Base(pick), nil
}

func excerpt(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if len(s) > 200 {
		s = s[:200] + "..."
	}
	return ": " + strings.ReplaceAll(s, "\n", "; ")
}
