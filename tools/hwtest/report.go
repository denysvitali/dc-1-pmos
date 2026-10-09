package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Status is the outcome of one check.
type Status string

const (
	Pass Status = "PASS"
	Warn Status = "WARN"
	Fail Status = "FAIL"
	Skip Status = "SKIP"
	Info Status = "INFO"
)

// Result is one observation. Skip means the check could not run (missing
// permission, flag or physical action); it is never a pass.
type Result struct {
	Group  string `json:"group"`
	Name   string `json:"name"`
	Status Status `json:"status"`
	Detail string `json:"detail,omitempty"`
}

// Reporter collects the results of one group.
type Reporter struct {
	group   string
	results []Result
	emit    func(Result)
}

func (r *Reporter) add(s Status, name, format string, a ...any) {
	res := Result{Group: r.group, Name: name, Status: s, Detail: fmt.Sprintf(format, a...)}
	r.results = append(r.results, res)
	if r.emit != nil {
		r.emit(res)
	}
}

func (r *Reporter) Pass(n, f string, a ...any) { r.add(Pass, n, f, a...) }
func (r *Reporter) Warn(n, f string, a ...any) { r.add(Warn, n, f, a...) }
func (r *Reporter) Fail(n, f string, a ...any) { r.add(Fail, n, f, a...) }
func (r *Reporter) Skip(n, f string, a ...any) { r.add(Skip, n, f, a...) }
func (r *Reporter) Info(n, f string, a ...any) { r.add(Info, n, f, a...) }

// Ctx carries run options and the filesystem root. Every path passed to the
// helpers is logical (absolute, as on the device); Root only relocates it so
// the checks can run against a fake tree in tests.
type Ctx struct {
	Root          string
	Active        bool
	Interactive   bool
	Sound         bool
	Cancel        context.Context
	NetworkTarget string
	Microphone    bool
	In            *bufio.Reader
	Out           io.Writer
}

var errNoExec = errors.New("external commands disabled for a relocated root")

func (c *Ctx) path(p string) string { return filepath.Join(c.Root, p) }

func (c *Ctx) readPath(p string) (string, error) {
	path := c.path(p)
	if filepath.Clean(c.Root) == "/" {
		return path, nil
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	root, err := filepath.EvalSymlinks(c.Root)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(root, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return "", fmt.Errorf("fixture path escapes root: %s", p)
	}
	return resolved, nil
}

func (c *Ctx) read(p string) (string, error) {
	path, err := c.readPath(p)
	if err != nil {
		return "", err
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, (1<<20)+1))
	if len(b) > 1<<20 {
		return "", fmt.Errorf("%s: exceeds 1 MiB read limit", p)
	}
	return strings.TrimSpace(strings.TrimRight(string(b), "\x00")), err
}

func (c *Ctx) readInt(p string) (int64, error) {
	s, err := c.read(p)
	if err != nil {
		return 0, err
	}
	f := strings.Fields(s)
	if len(f) != 1 {
		return 0, fmt.Errorf("%s: expected one integer, got %q", p, s)
	}
	return strconv.ParseInt(f[0], 10, 64)
}

func (c *Ctx) exists(p string) bool {
	path, err := c.readPath(p)
	if err != nil {
		return false
	}
	_, err = os.Stat(path)
	return err == nil
}

// glob returns logical paths matching pattern, sorted.
func (c *Ctx) glob(pattern string) []string {
	m, _ := filepath.Glob(c.path(pattern))
	out := make([]string, 0, len(m))
	for _, p := range m {
		rel, err := filepath.Rel(c.Root, p)
		if err == nil {
			out = append(out, "/"+rel)
		}
	}
	sort.Strings(out)
	return out
}

// linkBase returns the last element of a symlink target, or "".
func (c *Ctx) linkBase(p string) string {
	t, err := os.Readlink(c.path(p))
	if err != nil {
		return ""
	}
	return filepath.Base(t)
}

func (c *Ctx) linkTarget(p string) string {
	t, _ := os.Readlink(c.path(p))
	return t
}

func (c *Ctx) run(timeout time.Duration, name string, args ...string) (string, error) {
	if filepath.Clean(c.Root) != "/" {
		return "", errNoExec
	}
	parent := c.Cancel
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	var out limitedOutput
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout, cmd.Stderr = &out, &out
	cmd.WaitDelay = time.Second
	err := cmd.Run()
	if out.overflow {
		return "", fmt.Errorf("command output exceeds 1 MiB")
	}
	return string(out.data), err
}

type limitedOutput struct {
	data     []byte
	overflow bool
}

func (b *limitedOutput) Write(p []byte) (int, error) {
	n := len(p)
	room := (1 << 20) - len(b.data)
	if len(p) > room {
		b.overflow = true
		p = p[:room]
	}
	b.data = append(b.data, p...)
	return n, nil
}

func (c *Ctx) have(name string) bool {
	if filepath.Clean(c.Root) != "/" {
		return false
	}
	_, err := exec.LookPath(name)
	return err == nil
}

func (c *Ctx) say(format string, a ...any) { fmt.Fprintf(c.Out, format+"\n", a...) }

// inputLine returns on cancellation even if terminal input is blocked.
// The buffered reply lets the reader finish without retaining its caller;
// after cancellation no further prompts start readers.
func (c *Ctx) inputLine() (string, bool) {
	if c.In == nil {
		return "", false
	}
	if c.Cancel == nil {
		s, err := c.In.ReadString('\n')
		return s, err == nil
	}
	if c.Cancel.Err() != nil {
		return "", false
	}
	type reply struct {
		text string
		err  error
	}
	ch := make(chan reply, 1)
	go func() { s, err := c.In.ReadString('\n'); ch <- reply{s, err} }()
	select {
	case r := <-ch:
		return r.text, r.err == nil
	case <-c.Cancel.Done():
		return "", false
	}
}

func (c *Ctx) wait(msg string) bool {
	fmt.Fprintf(c.Out, ">> %s [Enter] ", msg)
	_, ok := c.inputLine()
	return ok
}

func (c *Ctx) paused(d time.Duration) bool {
	ctx := c.Cancel
	if ctx == nil {
		ctx = context.Background()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func (c *Ctx) confirm(msg string) bool {
	fmt.Fprintf(c.Out, ">> %s [y/N] ", msg)
	s, ok := c.inputLine()
	if !ok {
		return false
	}
	s = strings.ToLower(strings.TrimSpace(s))
	return s == "y" || s == "yes"
}

// permHint turns an access error into a skip reason.
func permHint(err error) string {
	if errors.Is(err, os.ErrPermission) {
		return "permission denied (re-run as root)"
	}
	return err.Error()
}

type group struct {
	order int
	name  string
	desc  string
	run   func(*Ctx, *Reporter)
}

var groups []group

func register(order int, name, desc string, run func(*Ctx, *Reporter)) {
	groups = append(groups, group{order, name, desc, run})
}

func sortedGroups() []group {
	g := append([]group(nil), groups...)
	sort.Slice(g, func(i, j int) bool { return g[i].order < g[j].order })
	return g
}
