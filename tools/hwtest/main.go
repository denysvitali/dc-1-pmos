// hwtest measures the running DC-1 through Linux interfaces. PASS applies
// only to the named observation, not to the whole subsystem.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"unsafe"
)

func main() {
	if runtime.GOOS != "linux" || (runtime.GOARCH != "arm64" && runtime.GOARCH != "amd64") {
		fatal("supported platforms are Linux arm64 and amd64")
	}
	var (
		list   = flag.Bool("list", false, "list check groups and exit")
		only   = flag.String("only", "", "comma-separated groups to run (default: all)")
		skip   = flag.String("skip", "", "comma-separated groups to skip")
		asJSON = flag.Bool("json", false, "write results as JSON to stdout; progress goes to stderr")
		root   = flag.String("root", "/", "filesystem root for fixtures (no commands, devices or active tests)")
		active = flag.Bool("active", false, "short CPU load and temporary-file storage round trip")
		inter  = flag.Bool("interactive", false, "operator tests (input, poses, USB); requires a terminal")
		sound  = flag.Bool("allow-sound", false, "speaker-test consent (currently skipped: no validated quiet route); requires -interactive")
		mic    = flag.Bool("allow-microphone", false, "capture 2 seconds of PCM in memory; never save or play it")
		target = flag.String("network-target", "", "explicit TCP literal-IP:numeric-port via wlan0 (no payload or DNS)")
	)
	flag.Parse()
	if flag.NArg() != 0 {
		fatal("unexpected positional arguments")
	}
	absRoot, err := filepath.Abs(*root)
	if err != nil {
		fatal(err.Error())
	}
	if *list {
		for _, g := range sortedGroups() {
			fmt.Printf("%-10s %s\n", g.name, g.desc)
		}
		return
	}
	if *sound && !*inter {
		fatal("-allow-sound requires -interactive")
	}
	if *inter {
		var term syscall.Termios
		if err := ioctl(os.Stdin.Fd(), 0x5401, unsafe.Pointer(&term)); err != nil { // TCGETS
			fatal("-interactive requires terminal stdin")
		}
	}
	if *target != "" {
		canonical, err := wifiNetworkTarget(*target)
		if err != nil {
			fatal("-network-target must be literal-IP:numeric-port (IPv6 in brackets)")
		}
		*target = canonical
	}
	if absRoot != "/" && (*active || *inter || *sound || *mic || *target != "") {
		fatal("-root fixtures allow read-only checks only")
	}
	sel, skp := split(*only), split(*skip)
	known := map[string]bool{}
	for _, g := range groups {
		known[g.name] = true
	}
	for _, selection := range []map[string]bool{sel, skp} {
		for n := range selection {
			if !known[n] {
				fatal(fmt.Sprintf("unknown group %q (see -list)", n))
			}
		}
	}
	out := os.Stdout
	if *asJSON {
		out = os.Stderr
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	c := &Ctx{Root: absRoot, Active: *active, Interactive: *inter, Sound: *sound,
		Microphone: *mic, NetworkTarget: *target, Cancel: ctx, In: bufio.NewReader(os.Stdin), Out: out}
	all := []Result{}
	counts := map[Status]int{}
	for _, g := range sortedGroups() {
		if (len(sel) > 0 && !sel[g.name]) || skp[g.name] {
			continue
		}
		fmt.Fprintf(out, "\n== %s: %s\n", g.name, g.desc)
		r := &Reporter{group: g.name, emit: func(res Result) {
			fmt.Fprintf(out, "[%s] %s: %s\n", res.Status, res.Name, res.Detail)
		}}
		if ctx.Err() != nil {
			r.Skip("cancelled", "run interrupted")
		} else {
			runGroup(g, c, r)
		}
		for _, res := range r.results {
			counts[res.Status]++
		}
		all = append(all, r.results...)
	}
	fmt.Fprintf(out, "\nSUMMARY: %d pass, %d warn, %d fail, %d skip, %d info\n",
		counts[Pass], counts[Warn], counts[Fail], counts[Skip], counts[Info])
	fmt.Fprintln(out, "PASS proves only the named check. SKIP/INFO do not establish hardware functionality.")
	if *asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(all); err != nil {
			fatal("write JSON: " + err.Error())
		}
	}
	if ctx.Err() != nil {
		os.Exit(130)
	}
	if counts[Fail] > 0 {
		os.Exit(1)
	}
}

func fatal(s string) { fmt.Fprintln(os.Stderr, "hwtest: "+s); os.Exit(2) }

func runGroup(g group, c *Ctx, r *Reporter) {
	defer func() {
		if p := recover(); p != nil {
			r.Fail("internal", "check panicked: %v", p)
		}
	}()
	g.run(c, r)
}

func split(s string) map[string]bool {
	m := map[string]bool{}
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			m[p] = true
		}
	}
	return m
}
