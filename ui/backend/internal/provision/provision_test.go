package provision

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/cmdrunner"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/events"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/secret"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/wifi"
)

const (
	testHash     = "$6$testsalt$abcdefghijklmnopqrstuvwxyz0123456789"
	testPassword = "correct-horse-battery"
	testPSK      = "hunter2hunter2"
)

// fakeRootfs builds the same shape as installer/tests/test-provision.sh's
// make_rootfs: a pmOS-ish tree with exactly one regular user, "dc1".
func fakeRootfs(t *testing.T) string {
	t.Helper()
	r := t.TempDir()
	for _, d := range []string{"etc", "home/dc1", "usr/share/zoneinfo/Europe", "var/lib", "etc/NetworkManager"} {
		if err := os.MkdirAll(filepath.Join(r, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(rel, content string, mode os.FileMode) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(r, rel), []byte(content), mode); err != nil {
			t.Fatal(err)
		}
	}
	write("etc/passwd", "root:x:0:0:root:/root:/bin/sh\n"+
		"daemon:x:2:2:daemon:/sbin:/sbin/nologin\n"+
		"dc1:x:10000:10000:dc1 user:/home/dc1:/bin/ash\n", 0o644)
	write("etc/shadow", "root:!::0:::::\n"+
		"daemon:!::0:::::\n"+
		"dc1:!:19000:0:99999:7:::\n", 0o640)
	write("etc/group", "root:x:0:\n"+
		"wheel:x:10:dc1\n"+
		"video:x:27:dc1\n"+
		"audio:x:18:dc1\n"+
		"dc1:x:10000:\n", 0o644)
	write("etc/hosts", "127.0.0.1\tlocalhost\n127.0.1.1\toldname\n", 0o644)
	write("etc/hostname", "oldname\n", 0o644)
	write("usr/share/zoneinfo/Europe/Zurich", "TZif", 0o644)
	write("usr/share/zoneinfo/UTC", "TZif", 0o644)
	write("home/dc1/.profile", "", 0o644)
	return r
}

// newProvisioner returns a Provisioner whose only external command is a fake
// cryptpw: no test ever runs the real one, and none of them touches /etc.
func newProvisioner(t *testing.T, root string) (*Provisioner, *cmdrunner.Fake, *events.Bus) {
	t.Helper()
	fake := &cmdrunner.Fake{Func: func(name string, args []string, stdin []byte) ([]byte, error) {
		if name != "cryptpw" {
			t.Errorf("unexpected command %q", name)
		}
		return []byte(testHash + "\n"), nil
	}}
	bus := events.NewBus()
	return &Provisioner{
		Root:    root,
		Runner:  fake,
		Bus:     bus,
		Now:     func() time.Time { return time.Unix(1700000000, 0).UTC() },
		NewUUID: func() string { return "11111111-2222-4333-8444-555555555555" },
	}, fake, bus
}

func goodRequest() *Request {
	return &Request{
		User:     "alice",
		Password: secret.Secret(testPassword),
		Hostname: "mydc1",
		Timezone: "Europe/Zurich",
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestApplyRenamesTheSingleRegularUser(t *testing.T) {
	root := fakeRootfs(t)
	p, _, _ := newProvisioner(t, root)

	req := goodRequest()
	req.SSID = "MyNet"
	req.PSK = secret.Secret(testPSK)
	res, err := p.Apply(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if res.AlreadyProvisioned || res.User != "alice" || !res.WiFiConfigured {
		t.Fatalf("res = %+v", res)
	}

	passwd := read(t, filepath.Join(root, "etc/passwd"))
	if !strings.Contains(passwd, "alice:x:10000:10000:dc1 user:/home/alice:/bin/ash\n") {
		t.Fatalf("passwd not renamed in place:\n%s", passwd)
	}
	if strings.Contains(passwd, "\ndc1:") || strings.HasPrefix(passwd, "dc1:") {
		t.Fatalf("old user still present:\n%s", passwd)
	}

	shadow := read(t, filepath.Join(root, "etc/shadow"))
	if !strings.Contains(shadow, "alice:"+testHash+":19675:0:99999:7:::\n") {
		t.Fatalf("shadow not updated (hash + last-change day):\n%s", shadow)
	}

	group := read(t, filepath.Join(root, "etc/group"))
	for _, want := range []string{"wheel:x:10:alice\n", "video:x:27:alice\n", "audio:x:18:alice\n", "alice:x:10000:\n"} {
		if !strings.Contains(group, want) {
			t.Errorf("group missing %q:\n%s", want, group)
		}
	}

	if _, err := os.Stat(filepath.Join(root, "home/alice/.profile")); err != nil {
		t.Errorf("home directory not moved: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "home/dc1")); !os.IsNotExist(err) {
		t.Errorf("old home directory still there: %v", err)
	}

	if got := read(t, filepath.Join(root, "etc/hostname")); got != "mydc1\n" {
		t.Errorf("hostname = %q", got)
	}
	if got := read(t, filepath.Join(root, "etc/hosts")); got != "127.0.0.1\tlocalhost\n127.0.1.1\tmydc1\n" {
		t.Errorf("hosts = %q", got)
	}
	link, err := os.Readlink(filepath.Join(root, "etc/localtime"))
	if err != nil || link != "../usr/share/zoneinfo/Europe/Zurich" {
		t.Errorf("localtime = %q, %v", link, err)
	}

	keyfile := read(t, filepath.Join(root, wifi.KeyfileRel))
	if !strings.Contains(keyfile, "ssid=MyNet\n") || !strings.Contains(keyfile, "psk="+testPSK+"\n") {
		t.Errorf("keyfile = %q", keyfile)
	}
}

func TestApplyCreatesAUserWhenTheImageHasNone(t *testing.T) {
	root := fakeRootfs(t)
	// Strip the single regular user so neither the existing- nor the
	// rename-branch applies.
	if err := os.WriteFile(filepath.Join(root, "etc/passwd"),
		[]byte("root:x:0:0:root:/root:/bin/sh\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc/shadow"), []byte("root:!::0:::::\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc/group"),
		[]byte("root:x:0:\nwheel:x:10:\nnetdev:x:28:someone\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	p, _, _ := newProvisioner(t, root)
	if _, err := p.Apply(context.Background(), goodRequest()); err != nil {
		t.Fatal(err)
	}

	passwd := read(t, filepath.Join(root, "etc/passwd"))
	if !strings.Contains(passwd, "alice:x:10000:10000::/home/alice:/bin/sh\n") {
		t.Fatalf("created passwd entry wrong:\n%s", passwd)
	}
	group := read(t, filepath.Join(root, "etc/group"))
	if !strings.Contains(group, "alice:x:10000:\n") {
		t.Errorf("primary group missing:\n%s", group)
	}
	if !strings.Contains(group, "wheel:x:10:alice\n") {
		t.Errorf("empty group not joined:\n%s", group)
	}
	if !strings.Contains(group, "netdev:x:28:someone,alice\n") {
		t.Errorf("non-empty group not appended to:\n%s", group)
	}
	if strings.Contains(group, "video") {
		t.Errorf("a group absent from the image was created:\n%s", group)
	}
	shadow := read(t, filepath.Join(root, "etc/shadow"))
	if !strings.Contains(shadow, "alice:"+testHash+":19675:0:::::\n") {
		t.Errorf("shadow entry wrong:\n%s", shadow)
	}
	st, err := os.Stat(filepath.Join(root, "home/alice"))
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o700 {
		t.Errorf("home mode = %o, want 700", st.Mode().Perm())
	}
}

func TestApplyPicksTheFirstFreeUIDWhenSeveralRegularUsersExist(t *testing.T) {
	root := fakeRootfs(t)
	// Two regular users: neither the existing- nor the rename-branch applies,
	// so a fresh user is created and the uid search must skip 10000/10001.
	if err := os.WriteFile(filepath.Join(root, "etc/passwd"),
		[]byte("root:x:0:0:root:/root:/bin/sh\n"+
			"dc1:x:10000:10000::/home/dc1:/bin/ash\n"+
			"bob:x:10001:10001::/home/bob:/bin/ash\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc/shadow"),
		[]byte("root:!::0:::::\ndc1:!:19000:0:99999:7:::\nbob:!:19000:0:99999:7:::\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	p, _, _ := newProvisioner(t, root)
	if _, err := p.Apply(context.Background(), goodRequest()); err != nil {
		t.Fatal(err)
	}
	passwd := read(t, filepath.Join(root, "etc/passwd"))
	if !strings.Contains(passwd, "alice:x:10002:10002::/home/alice:/bin/sh\n") {
		t.Fatalf("uid search wrong:\n%s", passwd)
	}
	if !strings.Contains(passwd, "dc1:x:10000:") || !strings.Contains(passwd, "bob:x:10001:") {
		t.Fatalf("existing users disturbed:\n%s", passwd)
	}
}

func TestApplyOnAnExistingUserOnlySetsThePassword(t *testing.T) {
	root := fakeRootfs(t)
	p, _, _ := newProvisioner(t, root)
	req := goodRequest()
	req.User = "dc1"
	if _, err := p.Apply(context.Background(), req); err != nil {
		t.Fatal(err)
	}
	passwd := read(t, filepath.Join(root, "etc/passwd"))
	if !strings.Contains(passwd, "dc1:x:10000:10000:dc1 user:/home/dc1:/bin/ash\n") {
		t.Fatalf("passwd was rewritten:\n%s", passwd)
	}
	shadow := read(t, filepath.Join(root, "etc/shadow"))
	if !strings.Contains(shadow, "dc1:"+testHash+":19675:0:99999:7:::\n") {
		t.Fatalf("shadow = %s", shadow)
	}
}

func TestApplyPreservesShadowInodeAndMode(t *testing.T) {
	root := fakeRootfs(t)
	shadow := filepath.Join(root, "etc/shadow")
	before, err := os.Stat(shadow)
	if err != nil {
		t.Fatal(err)
	}
	p, _, _ := newProvisioner(t, root)
	if _, err := p.Apply(context.Background(), goodRequest()); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(shadow)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Error("/etc/shadow was replaced; the shell keeps the inode")
	}
	if after.Mode().Perm() != 0o640 {
		t.Errorf("/etc/shadow mode = %o, want 640", after.Mode().Perm())
	}
}

func TestMarkerContentsAndMode(t *testing.T) {
	root := fakeRootfs(t)
	p, _, _ := newProvisioner(t, root)
	req := goodRequest()
	req.SSID = "MyNet"
	req.PSK = secret.Secret(testPSK)
	if _, err := p.Apply(context.Background(), req); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(root, MarkerRel)
	got := read(t, marker)
	want := "provisioned_at=2023-11-14T22:13:20Z\n" +
		"user=alice\n" +
		"hostname=mydc1\n" +
		"timezone=Europe/Zurich\n" +
		"wifi_configured=yes\n"
	if got != want {
		t.Fatalf("marker =\n%q\nwant\n%q", got, want)
	}
	st, err := os.Stat(marker)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o644 {
		t.Errorf("marker mode = %o, want 644", st.Mode().Perm())
	}
	for _, s := range []string{testPassword, testPSK, testHash} {
		if strings.Contains(got, s) {
			t.Error("marker leaked a credential")
		}
	}
}

func TestMarkerRecordsNoWiFi(t *testing.T) {
	root := fakeRootfs(t)
	p, _, _ := newProvisioner(t, root)
	if _, err := p.Apply(context.Background(), goodRequest()); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(read(t, filepath.Join(root, MarkerRel)), "wifi_configured=no\n") {
		t.Error("marker should record wifi_configured=no")
	}
	if _, err := os.Stat(filepath.Join(root, wifi.KeyfileRel)); !os.IsNotExist(err) {
		t.Error("a keyfile was written without Wi-Fi answers")
	}
}

func TestApplyIsIdempotent(t *testing.T) {
	root := fakeRootfs(t)
	p, _, _ := newProvisioner(t, root)
	if _, err := p.Apply(context.Background(), goodRequest()); err != nil {
		t.Fatal(err)
	}
	passwdAfterFirst := read(t, filepath.Join(root, "etc/passwd"))
	markerAfterFirst := read(t, filepath.Join(root, MarkerRel))

	second := goodRequest()
	second.User = "bob"
	second.Hostname = "other"
	res, err := p.Apply(context.Background(), second)
	if err != nil {
		t.Fatal(err)
	}
	if !res.AlreadyProvisioned {
		t.Fatal("second Apply did not report already-provisioned")
	}
	if got := read(t, filepath.Join(root, "etc/passwd")); got != passwdAfterFirst {
		t.Fatalf("second Apply renamed the user:\n%s", got)
	}
	if got := read(t, filepath.Join(root, "etc/hostname")); got != "mydc1\n" {
		t.Fatalf("second Apply changed the hostname: %q", got)
	}
	if got := read(t, filepath.Join(root, MarkerRel)); got != markerAfterFirst {
		t.Fatal("second Apply rewrote the marker")
	}
	if !p.Provisioned() {
		t.Fatal("Provisioned() = false after provisioning")
	}
}

func TestPasswordReachesCryptpwOnStdinOnly(t *testing.T) {
	root := fakeRootfs(t)
	p, fake, bus := newProvisioner(t, root)
	sub, cancel := bus.Subscribe()
	defer cancel()
	go func() {
		for ev := range sub {
			if strings.Contains(ev.Detail, testPassword) || strings.Contains(ev.Detail, testPSK) {
				t.Errorf("event leaked a credential: %+v", ev)
			}
		}
	}()

	req := goodRequest()
	req.SSID = "MyNet"
	req.PSK = secret.Secret(testPSK)
	if _, err := p.Apply(context.Background(), req); err != nil {
		t.Fatal(err)
	}

	call, err := fake.FindCall("cryptpw")
	if err != nil {
		t.Fatal(err)
	}
	if got := call.Line(); got != "cryptpw -m sha512 -P 0" {
		t.Fatalf("cryptpw invocation = %q", got)
	}
	if string(call.Stdin) != testPassword {
		t.Fatalf("password did not arrive on stdin (got %d bytes)", len(call.Stdin))
	}
	for _, c := range fake.Calls() {
		if strings.Contains(c.Line(), testPassword) || strings.Contains(c.Line(), testPSK) {
			t.Fatalf("credential on an argv: %q", c.Line())
		}
	}
	// The PSK never goes to a command at all; it only reaches the keyfile.
	for _, c := range fake.Calls() {
		if strings.Contains(string(c.Stdin), testPSK) {
			t.Fatal("PSK was piped to a command")
		}
	}
}

func TestApplyRejectsBadAnswersBeforeTouchingTheRootfs(t *testing.T) {
	cases := []struct {
		name  string
		mutga func(*Request)
	}{
		{"reserved user", func(r *Request) { r.User = "root" }},
		{"bad user", func(r *Request) { r.User = "Alice" }},
		{"empty password", func(r *Request) { r.Password = nil }},
		{"bad hostname", func(r *Request) { r.Hostname = "-bad-" }},
		{"traversal timezone", func(r *Request) { r.Timezone = "../../etc/shadow" }},
		{"short psk", func(r *Request) { r.SSID = "MyNet"; r.PSK = secret.Secret("short") }},
		{"ssid without psk", func(r *Request) { r.SSID = "MyNet" }},
		{"psk without ssid", func(r *Request) { r.PSK = secret.Secret(testPSK) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root := fakeRootfs(t)
			p, fake, _ := newProvisioner(t, root)
			req := goodRequest()
			c.mutga(req)
			if _, err := p.Apply(context.Background(), req); err == nil {
				t.Fatal("accepted")
			}
			if got := read(t, filepath.Join(root, "etc/hostname")); got != "oldname\n" {
				t.Errorf("rootfs was modified: hostname = %q", got)
			}
			if len(fake.Calls()) != 0 {
				t.Errorf("ran a command despite invalid answers: %+v", fake.Calls())
			}
			if p.Provisioned() {
				t.Error("marker written for an invalid request")
			}
		})
	}
}

func TestApplyRejectsATimezoneMissingFromTheRootfs(t *testing.T) {
	root := fakeRootfs(t)
	p, _, _ := newProvisioner(t, root)
	req := goodRequest()
	req.Timezone = "Asia/Tokyo"
	if _, err := p.Apply(context.Background(), req); err == nil {
		t.Fatal("accepted a timezone absent from the rootfs")
	}
	if p.Provisioned() {
		t.Error("marker written after a failed step")
	}
}

func TestApplyFailsWhenCryptpwFails(t *testing.T) {
	root := fakeRootfs(t)
	p, _, _ := newProvisioner(t, root)
	p.Runner = &cmdrunner.Fake{Func: func(string, []string, []byte) ([]byte, error) {
		return []byte("not-a-hash"), nil
	}}
	if _, err := p.Apply(context.Background(), goodRequest()); err == nil {
		t.Fatal("accepted a non-crypt hash")
	}
	if p.Provisioned() {
		t.Error("marker written after a failed hash")
	}
}

func TestHostsLineIsAppendedWhenAbsent(t *testing.T) {
	root := fakeRootfs(t)
	if err := os.WriteFile(filepath.Join(root, "etc/hosts"), []byte("127.0.0.1\tlocalhost\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	p, _, _ := newProvisioner(t, root)
	if _, err := p.Apply(context.Background(), goodRequest()); err != nil {
		t.Fatal(err)
	}
	if got := read(t, filepath.Join(root, "etc/hosts")); got != "127.0.0.1\tlocalhost\n127.0.1.1\tmydc1\n" {
		t.Fatalf("hosts = %q", got)
	}
}

// provision.sh rewrites the hosts line with sed, which substitutes on EVERY
// matching line; a rootfs that somehow carries two 127.0.1.1 records must not
// be left with one of them still naming the old hostname.
func TestEveryHostsLineIsRewritten(t *testing.T) {
	root := fakeRootfs(t)
	hosts := "127.0.0.1\tlocalhost\n127.0.1.1\toldname\n::1\tlocalhost\n127.0.1.1\toldname.lan oldname\n"
	if err := os.WriteFile(filepath.Join(root, "etc/hosts"), []byte(hosts), 0o644); err != nil {
		t.Fatal(err)
	}
	p, _, _ := newProvisioner(t, root)
	if _, err := p.Apply(context.Background(), goodRequest()); err != nil {
		t.Fatal(err)
	}
	want := "127.0.0.1\tlocalhost\n127.0.1.1\tmydc1\n::1\tlocalhost\n127.0.1.1\tmydc1\n"
	if got := read(t, filepath.Join(root, "etc/hosts")); got != want {
		t.Fatalf("hosts = %q, want %q", got, want)
	}
}

// Apply must say whose fault a failure is: the answers (InvalidRequest, 400 at
// the HTTP layer) or this side (500).
func TestApplyTagsAnswerErrorsAndOnlyThose(t *testing.T) {
	root := fakeRootfs(t)
	p, _, _ := newProvisioner(t, root)
	bad := goodRequest()
	bad.User = "root"
	var invalid InvalidRequest
	if _, err := p.Apply(context.Background(), bad); !errors.As(err, &invalid) {
		t.Fatalf("bad answer not tagged InvalidRequest: %v", err)
	}

	// A valid answer that this side cannot honour: the zoneinfo file is absent.
	root2 := fakeRootfs(t)
	p2, _, _ := newProvisioner(t, root2)
	missing := goodRequest()
	missing.Timezone = "Asia/Tokyo"
	_, err := p2.Apply(context.Background(), missing)
	if err == nil {
		t.Fatal("accepted a timezone absent from the rootfs")
	}
	if errors.As(err, &invalid) {
		t.Fatalf("server-side failure tagged as the user's fault: %v", err)
	}
}

func TestRequestWipeZeroesCredentials(t *testing.T) {
	req := goodRequest()
	req.PSK = secret.Secret(testPSK)
	pw := req.Password.Bytes()
	psk := req.PSK.Bytes()
	req.Wipe()
	for _, b := range append(append([]byte{}, pw...), psk...) {
		if b != 0 {
			t.Fatal("Wipe left cleartext behind")
		}
	}
}
