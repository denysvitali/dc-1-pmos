package main

import (
	"bufio"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T) *Ctx {
	t.Helper()
	return &Ctx{Root: t.TempDir(), Out: io.Discard, In: bufio.NewReader(strings.NewReader(""))}
}

func put(t *testing.T, c *Ctx, p, s string) {
	t.Helper()
	path := c.path(p)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(s), 0644); err != nil {
		t.Fatal(err)
	}
}

func TestReadInt(t *testing.T) {
	c := fixture(t)
	for _, tc := range []struct {
		text string
		want int64
		bad  bool
	}{
		{"", 0, true}, {" \n", 0, true}, {"08\n", 8, false}, {"-123", -123, false},
		{"1 2", 0, true}, {"0xff", 0, true}, {"9223372036854775808", 0, true},
	} {
		put(t, c, "/value", tc.text)
		v, err := c.readInt("/value")
		if (err != nil) != tc.bad || (!tc.bad && v != tc.want) {
			t.Errorf("%q -> %d %v", tc.text, v, err)
		}
	}
	if _, err := c.readInt("/missing"); err == nil {
		t.Fatal("missing value accepted")
	}
}

func TestGlobLogicalPaths(t *testing.T) {
	c := fixture(t)
	put(t, c, "/sys/test/b", "1")
	put(t, c, "/sys/test/a", "2")
	got := c.glob("/sys/test/*")
	if len(got) != 2 || got[0] != "/sys/test/a" || got[1] != "/sys/test/b" {
		t.Fatal(got)
	}
	c.Root = "/"
	for _, p := range c.glob("/proc/self/stat") {
		if !filepath.IsAbs(p) {
			t.Fatal(p)
		}
	}
}

func TestFixtureIsolation(t *testing.T) {
	c := fixture(t)
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte("secret"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, c.path("/escape")); err != nil {
		t.Fatal(err)
	}
	if _, err := c.read("/escape"); err == nil {
		t.Fatal("read escaped root")
	}
	if c.have("sh") {
		t.Fatal("fixture executable lookup enabled")
	}
	if _, err := c.run(time.Second, "sh", "-c", "exit 0"); err != errNoExec {
		t.Fatal(err)
	}
}

func TestPauseCancellation(t *testing.T) {
	c := fixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	c.Cancel = ctx
	if c.paused(time.Hour) {
		t.Fatal("cancelled pause completed")
	}
	if c.wait("prompt") {
		t.Fatal("cancelled input accepted")
	}
}

func TestBoundedOutput(t *testing.T) {
	var b limitedOutput
	p := make([]byte, (1<<20)+10)
	if n, err := b.Write(p); n != len(p) || err != nil {
		t.Fatal(n, err)
	}
	if !b.overflow || len(b.data) != 1<<20 {
		t.Fatal("output not bounded")
	}
}

func TestRunGroupRecovers(t *testing.T) {
	r := &Reporter{}
	runGroup(group{run: func(*Ctx, *Reporter) { panic("bad fixture") }}, fixture(t), r)
	if len(r.results) != 1 || r.results[0].Status != Fail {
		t.Fatal(r.results)
	}
}

func TestSelection(t *testing.T) {
	m := split("input, sensors,input, ,")
	if len(m) != 2 || !m["input"] || !m["sensors"] {
		t.Fatal(m)
	}
}
