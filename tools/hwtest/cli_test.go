package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestCLI(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "hwtest")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	root := t.TempDir()
	for _, args := range [][]string{
		{"-only", "nonexistent"}, {"-skip", "nonexistent"}, {"unexpected"},
		{"-allow-sound"}, {"-network-target", "example.org:443"},
		{"-network-target", "127.0.0.1:0"}, {"-network-target", "127.0.0.1:+443"},
		{"-root", root, "-active"}, {"-root", root, "-allow-microphone"},
		{"-root", root, "-network-target", "127.0.0.1:443"},
	} {
		cmd := exec.Command(bin, args...)
		out, err := cmd.CombinedOutput()
		if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 2 {
			t.Errorf("%v: want exit 2, got %v\n%s", args, err, out)
		}
	}
	for _, path := range []string{"/dev/null", "/dev/zero"} {
		in, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(bin, "-interactive", "-only", "input")
		cmd.Stdin = in
		out, err := cmd.CombinedOutput()
		in.Close()
		if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 2 {
			t.Fatalf("%s stdin: want exit 2, got %v\n%s", path, err, out)
		}
	}
	cmd := exec.Command(bin, "-root", root, "-only", "thermal", "-json")
	out, err := cmd.Output()
	if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 1 {
		t.Fatalf("empty fixture: %v", err)
	}
	var results []Result
	if err := json.Unmarshal(out, &results); err != nil {
		t.Fatalf("JSON: %v\n%s", err, out)
	}
	if len(results) == 0 {
		t.Fatal("empty results")
	}
	for _, res := range results {
		if res.Group != "thermal" || res.Status == Pass {
			t.Fatal(res)
		}
	}
}
