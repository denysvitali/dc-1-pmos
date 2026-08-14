// Package cmdrunner is the single place where this backend executes an
// external program. Everything else takes a Runner, so tests never shell out
// to a real nmcli or cryptpw.
//
// Secrets go in on stdin only: never on the argv (visible in /proc), never in
// the environment (inherited by children, visible in /proc/PID/environ).
package cmdrunner

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// Runner executes a command and returns its standard output.
type Runner interface {
	Run(ctx context.Context, name string, args []string, stdin []byte) ([]byte, error)
}

// Exec is the production Runner.
type Exec struct{}

// env is deliberately minimal and fixed: no secret can be smuggled into a
// child through it, and LC_ALL=C keeps nmcli's terse output stable.
var env = []string{
	"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
	"LC_ALL=C",
}

// Run executes name with args, feeding stdin (which may be nil) to the
// process. On failure the error carries a bounded excerpt of stderr; since no
// secret is ever passed on an argv or in the environment, that excerpt cannot
// contain one.
func (Exec) Run(ctx context.Context, name string, args []string, stdin []byte) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errBuf bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		return out.Bytes(), fmt.Errorf("%s: %w%s", name, err, excerpt(errBuf.String()))
	}
	return out.Bytes(), nil
}

// excerpt trims and caps stderr so an error string stays log-sized.
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
