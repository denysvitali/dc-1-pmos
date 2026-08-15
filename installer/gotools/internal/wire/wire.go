// Package wire parses the DC1-INSTALL-V1 header.
//
// The wire format is unchanged from the shell implementation it replaces, so
// the host script (installer/host/dc1-install.sh) needs no modification:
//
//	DC1-INSTALL-V1\n
//	size=<decimal bytes of the raw image>\n
//	sha256=<64 hex digits>\n
//	[answers=<base64> | unprovisioned=1]\n
//	\n
//	<size bytes of raw ext4 image>
package wire

import (
	"bufio"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Magic is the first line of every session.
const Magic = "DC1-INSTALL-V1"

// MinImageBytes rejects an obviously bogus size before anything destructive
// happens. The real rootfs is ~1.5 GiB; 8 MiB is a floor, not a target.
const MinImageBytes = 8 << 20

// Header is one parsed session header.
type Header struct {
	Size          int64
	SHA256        string
	Answers       []byte // decoded; nil for an unprovisioned install
	Unprovisioned bool
}

// ParseHeader reads header lines up to the blank separator. The reader is
// left positioned at the first byte of the image body.
//
// A bufio.Reader is required rather than an io.Reader: the caller must reuse
// the SAME reader for the body, because bufio will have buffered past the
// blank line. Handing the raw connection to the body reader instead would
// silently drop those buffered bytes -- the exact class of bug (a mid-stream
// byte offset) that made the shell implementation corrupt every install.
func ParseHeader(r *bufio.Reader) (*Header, error) {
	magic, err := r.ReadString('\n')
	if err != nil {
		return nil, fmt.Errorf("reading magic: %w", err)
	}
	if strings.TrimRight(magic, "\r\n") != Magic {
		return nil, fmt.Errorf("bad magic: %q", strings.TrimRight(magic, "\r\n"))
	}

	h := &Header{}
	var sawSize, sawSHA bool
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, fmt.Errorf("reading header: %w", err)
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return nil, fmt.Errorf("malformed header line: %q", line)
		}
		switch key {
		case "size":
			n, err := strconv.ParseInt(value, 10, 64)
			if err != nil {
				return nil, fmt.Errorf("bad size: %q", value)
			}
			h.Size, sawSize = n, true
		case "sha256":
			if len(value) != 64 || strings.TrimLeft(value, "0123456789abcdef") != "" {
				return nil, fmt.Errorf("bad sha256: %q", value)
			}
			h.SHA256, sawSHA = value, true
		case "answers":
			decoded, err := base64.StdEncoding.DecodeString(value)
			if err != nil {
				return nil, errors.New("answers: base64 decode failed")
			}
			h.Answers = decoded
		case "unprovisioned":
			h.Unprovisioned = value == "1"
		default:
			return nil, fmt.Errorf("unknown header line: %q", key)
		}
	}

	if !sawSize {
		return nil, errors.New("missing size")
	}
	if !sawSHA {
		return nil, errors.New("missing sha256")
	}
	if h.Size < MinImageBytes {
		return nil, fmt.Errorf("size too small: %d", h.Size)
	}
	// Answers are required only for a provisioned install; an unprovisioned
	// one carries none and onboards on first boot instead.
	if h.Unprovisioned {
		h.Answers = nil
	} else if len(h.Answers) == 0 {
		return nil, errors.New("missing answers")
	}
	return h, nil
}
