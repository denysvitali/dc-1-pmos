package systeminit

import (
	"encoding/binary"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

func TestLineIsOnePrefixedTruncatedLine(t *testing.T) {
	if got := Line("hello"); got != "[dc1-boot] hello\n" {
		t.Fatalf("got %q", got)
	}
	long := Line(strings.Repeat("x", 4096))
	if len(long) > lineMax {
		t.Fatalf("line is %d bytes, past the %d-byte console buffer", len(long), lineMax)
	}
	if !strings.HasSuffix(long, "\n") {
		t.Fatal("a truncated line lost its newline; the next line would run into it")
	}
}

// The lease is what stops the board being held alive forever by a petter that
// nobody is watching -- and what keeps it alive while someone is.
func TestLeaseFresh(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	cases := []struct {
		name      string
		haveLease bool
		mtime     time.Time
		now       time.Time
		want      bool
	}{
		{"no lease file at all", false, now, now, false},
		{"just renewed", true, now, now, true},
		{"renewed a minute ago", true, now.Add(-time.Minute), now, true},
		{"one second inside the window", true, now.Add(-leaseSeconds * time.Second), now, true},
		{"one second past the window", true, now.Add(-leaseSeconds*time.Second - time.Second), now, false},
		// No usable clock, or a clock that jumped backwards: fail towards
		// staying alive rather than resetting a board someone is debugging.
		{"no clock", true, now, time.Time{}, true},
		{"mtime in the future", true, now.Add(time.Hour), now, true},
	}
	for _, c := range cases {
		if got := LeaseFresh(c.haveLease, c.mtime, c.now); got != c.want {
			t.Errorf("%s: LeaseFresh = %v, want %v", c.name, got, c.want)
		}
	}
}

// The label gate is the whole safety property of this boot: only the
// filesystem the installer wrote and hash-verified carries it.
func TestSelectRoot(t *testing.T) {
	ok := Candidate{"/dev/sdc57", "ext4", "jagar-root"}
	cases := []struct {
		name    string
		cands   []Candidate
		want    string
		wantErr string
	}{
		{"the installed filesystem", []Candidate{ok}, "/dev/sdc57", ""},
		{"stock android", []Candidate{{"/dev/sdc57", "", ""}}, "", "not ext4"},
		{"ext4 someone else made", []Candidate{{"/dev/sdc57", "ext4", "userdata"}}, "", "not our filesystem"},
		{"half install, no label yet", []Candidate{{"/dev/sdc57", "ext4", ""}}, "", "not our filesystem"},
		{"nothing probed", nil, "", "no partition to probe"},
		{"two labelled the same", []Candidate{ok, {"/dev/sdd1", "ext4", "jagar-root"}}, "", "refusing to guess"},
		{"one of several", []Candidate{{"/dev/sdd1", "ext2", "boot"}, ok}, "/dev/sdc57", ""},
		{"several, none ours", []Candidate{{"/dev/sdd1", "ext2", "boot"}, {"/dev/sdc57", "ext4", "x"}}, "", "none of 2"},
	}
	for _, c := range cases {
		got, err := SelectRoot(c.cands)
		if c.wantErr == "" {
			if err != nil || got != c.want {
				t.Errorf("%s: got (%q, %v), want %q", c.name, got, err, c.want)
			}
			continue
		}
		if err == nil {
			t.Errorf("%s: accepted %q", c.name, got)
		} else if !strings.Contains(err.Error(), c.wantErr) {
			t.Errorf("%s: error %q does not mention %q", c.name, err, c.wantErr)
		}
	}
}

func superblock(magic uint16, compat, incompat uint32, label string) []byte {
	sb := make([]byte, SuperblockSize)
	binary.LittleEndian.PutUint16(sb[sbMagic:], magic)
	binary.LittleEndian.PutUint32(sb[sbFeatureCompat:], compat)
	binary.LittleEndian.PutUint32(sb[sbFeatureIncompat:], incompat)
	copy(sb[sbVolumeName:sbVolumeName+sbVolumeNameLen], label)
	return sb
}

// The feature words below are the ones `mke2fs -t ext2/ext3/ext4` actually
// wrote, read back out of the images, not recalled -- blkid reported TYPE=ext2
// / ext3 / ext4 for exactly these.
func TestProbeSuperblock(t *testing.T) {
	cases := []struct {
		name      string
		sb        []byte
		wantType  string
		wantLabel string
	}{
		{"ext4 as the installer writes it", superblock(extMagic, 0x103c, 0x22c2, "jagar-root"), "ext4", "jagar-root"},
		{"ext3", superblock(extMagic, 0x3c, 0x2, "jagar-root"), "ext3", "jagar-root"},
		{"ext2", superblock(extMagic, 0x38, 0x2, "jagar-root"), "ext2", "jagar-root"},
		{"not ext at all (stock f2fs, or wiped)", superblock(0x0000, 0, 0, ""), "", ""},
		{"ext4 with no label", superblock(extMagic, 0x103c, 0x22c2, ""), "ext4", ""},
		{"a label that fills the field", superblock(extMagic, 0x103c, 0x22c2, "0123456789abcdef"), "ext4", "0123456789abcdef"},
		{"short read", make([]byte, 64), "", ""},
	}
	for _, c := range cases {
		gotType, gotLabel := ProbeSuperblock(c.sb)
		if gotType != c.wantType || gotLabel != c.wantLabel {
			t.Errorf("%s: got (%q, %q), want (%q, %q)", c.name, gotType, gotLabel,
				c.wantType, c.wantLabel)
		}
	}
}

// e2fsck exit 1 means "errors corrected", which is a success for us.
func TestFsckAcceptable(t *testing.T) {
	for rc, want := range map[int]bool{-1: false, 0: true, 1: true, 2: false, 8: false} {
		if got := FsckAcceptable(rc); got != want {
			t.Errorf("FsckAcceptable(%d) = %v, want %v", rc, got, want)
		}
	}
}

func TestWaitingNoticeOnlyAtTheMarks(t *testing.T) {
	for _, s := range []int{10, 30, 50} {
		if _, ok := WaitingNotice(s); !ok {
			t.Errorf("no notice at %ds", s)
		}
	}
	for _, s := range []int{1, 9, 11, 60} {
		if msg, ok := WaitingNotice(s); ok {
			t.Errorf("unexpected notice at %ds: %q", s, msg)
		}
	}
}

func TestParseArgs(t *testing.T) {
	cases := []struct {
		name    string
		args    []string
		want    Config
		wantErr bool
	}{
		{"no arguments is the boot itself", nil, Config{}, false},
		{"dry run", []string{"-n"}, Config{DryRun: true}, false},
		{"watchdog helper", []string{"-helper", "watchdog"}, Config{Helper: helperWatchdog}, false},
		{"kmsg helper", []string{"-helper", "kmsg"}, Config{Helper: helperKmsg}, false},
		{"shell helper", []string{"-helper", "shell", "-tty", "/dev/ttyGS1"},
			Config{Helper: helperShell, TTY: "/dev/ttyGS1"}, false},
		{"a shell helper with no console has nothing to do", []string{"-helper", "shell"}, Config{}, true},
		{"a tty without the shell role is a typo", []string{"-tty", "/dev/ttyGS1"}, Config{}, true},
		{"unknown role", []string{"-helper", "reboot"}, Config{}, true},
		{"unknown flag", []string{"-flash"}, Config{}, true},
	}
	for _, c := range cases {
		got, err := ParseArgs(c.args, io.Discard)
		if c.wantErr {
			if err == nil {
				t.Errorf("%s: accepted %v", c.name, c.args)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", c.name, err)
			continue
		}
		if got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

// `dc1tools system-init` on a live host must be a no-op, and so must a helper
// that was not put there by PID 1 -- every daemon on a normal host has PPID 1,
// so parentage alone is not proof.
func TestOnlyARealPID1MayAct(t *testing.T) {
	if !initAllowed(1) || initAllowed(4242) {
		t.Fatal("initAllowed does not gate on PID 1")
	}
	cases := []struct {
		name   string
		ppid   int
		marker string
		want   bool
	}{
		{"spawned by PID 1", 1, "1", true},
		{"an orphan that ended up reparented to PID 1", 1, "", false},
		{"typed by hand with the marker copied out of ps", 4242, "1", false},
		{"typed by hand", 4242, "", false},
	}
	for _, c := range cases {
		if got := helperAllowed(c.ppid, c.marker); got != c.want {
			t.Errorf("%s: helperAllowed = %v, want %v", c.name, got, c.want)
		}
	}
}

// A boot that cannot read /proc/self/exe still has to start its helpers.
func TestSelfPathFallsBackToTheStagedName(t *testing.T) {
	if got := selfPath("/init", nil); got != "/init" {
		t.Fatalf("got %q", got)
	}
	if got := selfPath("", errors.New("no /proc yet")); got != "/bin/dc1tools" {
		t.Fatalf("got %q", got)
	}
}

// The gadget is the only channel a failed boot is visible on, so its shape is
// worth pinning: two ACM functions, both linked into the one config.
func TestGadgetStepsLinkBothACMsIntoTheConfig(t *testing.T) {
	links := map[string]string{}
	for _, s := range gadgetSteps(gadgetRoot) {
		if !strings.HasPrefix(s.Path, gadgetRoot+"/") {
			t.Fatalf("step escapes the gadget directory: %+v", s)
		}
		if s.Kind == "symlink" {
			links[s.Path] = s.Value
		}
	}
	for _, f := range []string{"acm.0", "acm.1"} {
		want := gadgetRoot + "/functions/" + f
		if got := links[gadgetRoot+"/configs/c.1/"+f]; got != want {
			t.Errorf("%s links to %q, want %q", f, got, want)
		}
	}
}
