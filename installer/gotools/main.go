// dc1tools -- the DC-1 initramfs userland, as one multi-call binary.
//
// Busybox-style dispatch on argv[0], so the image can carry `bootctl` and
// `dc1-reboot-fastboot` as links to a single executable. That matters here:
// the Go runtime is ~1.2 MB, so five separate binaries would cost ~6 MB of an
// initramfs that is loaded into RAM, while one multi-call binary costs it
// once.
//
// Why Go at all, for code that was small, working C: the installer's byte
// path was silently corrupting every install because a busybox `head -c`
// discarded what it over-read past its count, and no amount of care in the
// shell would have made that visible. CGO_ENABLED=0 also gives a genuinely
// static binary with no libc, which is a stronger guarantee than -static
// against musl, and it cross-compiles to aarch64 without a toolchain.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/ask"
	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/bootctl"
	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/debugtools"
	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/installd"
	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/installerinit"
	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/rebootfastboot"
	"github.com/denysvitali/dc-1-pmos/installer/gotools/internal/systeminit"
)

func applets() map[string]func([]string) int {
	return map[string]func([]string) int{
		"bootctl": func(a []string) int {
			return bootctl.Main(a, os.Stdout, os.Stderr)
		},
		"dc1-reboot-fastboot": func(a []string) int {
			return rebootfastboot.Main(a, os.Stdout, os.Stderr)
		},
		"dc1-ask": func(a []string) int {
			return ask.Main(a, os.Stdout, os.Stderr)
		},
		// The on-device debugging toolkit: screen-first (its own menu
		// drives PID 1's dialog server), with plain subcommands for the
		// USB shells. Strictly read-only on partitions and memory.
		"dc1-debug": func(a []string) int {
			return debugtools.Main(a, os.Stdout, os.Stderr)
		},
		"dc1-installd": installd.Main,
		// The installer image stages this binary AS /init (a symlink), so the
		// kernel's ramdisk_execute_command "/init" reaches it with argv[0]
		// "/init", i.e. filepath.Base == "init". "system-init" and
		// "dc1-installer-init" remain as the explicit subcommands for review
		// and dry-run. Each init refuses to do anything unless genuinely PID 1
		// and prints its ordered plan otherwise.
		"init": func(a []string) int {
			return installerinit.Main(a, os.Stdout, os.Stderr)
		},
		"system-init": func(a []string) int {
			return systeminit.Main(a, os.Stdout, os.Stderr)
		},
		"dc1-installer-init": func(a []string) int {
			return installerinit.Main(a, os.Stdout, os.Stderr)
		},
	}
}

func main() {
	table := applets()

	// argv[0] first (the link name), then an explicit subcommand, so the
	// binary is usable both ways: `dc1-reboot-fastboot -n` via a link, and
	// `dc1tools dc1-reboot-fastboot -n` directly.
	name := filepath.Base(os.Args[0])
	args := os.Args[1:]
	if _, ok := table[name]; !ok {
		if len(args) == 0 {
			usage(table)
			os.Exit(2)
		}
		name, args = args[0], args[1:]
	}

	run, ok := table[name]
	if !ok {
		fmt.Fprintf(os.Stderr, "dc1tools: unknown applet %q\n", name)
		usage(table)
		os.Exit(2)
	}
	os.Exit(run(args))
}

func usage(table map[string]func([]string) int) {
	fmt.Fprintln(os.Stderr, "usage: dc1tools <applet> [args...]")
	fmt.Fprintln(os.Stderr, "applets:")
	for name := range table {
		fmt.Fprintf(os.Stderr, "  %s\n", name)
	}
}
