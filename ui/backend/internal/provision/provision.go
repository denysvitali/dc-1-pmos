// Package provision applies onboarding answers to the running system.
//
// It is a Go port of installer/src/provision.sh, kept step-for-step and
// byte-for-byte identical to it: same file contents, same /etc/shadow field
// edits, same in-place rewrites (so /etc/shadow keeps its inode, mode and
// owner), same NetworkManager keyfile, same marker. The shell version stays
// authoritative for the installer; this one runs on the installed system,
// where there is no answers file and no chroot.
//
// What this package deliberately does NOT do: anything from the installer's
// write path (partition resolution, image download, ext4 write). That stays
// shell, fail-closed, in installer/src/writelib.sh and friends.
package provision

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/cmdrunner"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/events"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/secret"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/validate"
	"github.com/denysvitali/dc-1-pmos/ui/backend/internal/wifi"
)

// MarkerRel is the idempotence marker, relative to the rootfs
// (installer/src/provision.sh:273-283).
const MarkerRel = "var/lib/dc1-installer/provisioned"

// Publisher is the subset of events.Bus this package uses.
type Publisher interface {
	Publish(state, detail string)
}

// Request is one onboarding submission. SSID/PSK are optional and must be
// either both set or both empty, as in installer/src/provision.sh:90-92.
type Request struct {
	User     string        `json:"user"`
	Password secret.Secret `json:"password"`
	Hostname string        `json:"hostname"`
	Timezone string        `json:"timezone"`
	SSID     string        `json:"ssid,omitempty"`
	PSK      secret.Secret `json:"psk,omitempty"`
}

// Wipe zeroes every credential in the request.
func (r *Request) Wipe() {
	r.Password.Wipe()
	r.PSK.Wipe()
}

// Validate applies the installer's rules, in the installer's order.
func (r *Request) Validate() error {
	if err := validate.Username(r.User); err != nil {
		return err
	}
	if err := validate.Password(r.Password.Bytes()); err != nil {
		return err
	}
	if err := validate.Hostname(r.Hostname); err != nil {
		return err
	}
	if err := validate.Timezone(r.Timezone); err != nil {
		return err
	}
	if r.SSID == "" && r.PSK.Len() == 0 {
		return nil
	}
	if r.SSID == "" || r.PSK.Len() == 0 {
		return errors.New("Wi-Fi SSID and PSK must both be set (or both empty)")
	}
	if err := validate.SSID(r.SSID); err != nil {
		return err
	}
	return validate.PSK(r.PSK.Bytes())
}

// InvalidRequest wraps the errors caused by the submitted answers, as opposed
// to a failure of this side (a shadow rewrite, a missing zoneinfo file, the
// marker). Only the former is something the user can fix by retyping, so it is
// the only one the HTTP layer reports as 400.
type InvalidRequest struct{ Err error }

func (e InvalidRequest) Error() string { return e.Err.Error() }

func (e InvalidRequest) Unwrap() error { return e.Err }

// Result is what a successful (or already-done) Apply reports. It carries no
// credential.
type Result struct {
	AlreadyProvisioned bool   `json:"already_provisioned"`
	User               string `json:"user,omitempty"`
	Hostname           string `json:"hostname,omitempty"`
	Timezone           string `json:"timezone,omitempty"`
	WiFiConfigured     bool   `json:"wifi_configured"`
}

// Provisioner applies requests to a rootfs.
type Provisioner struct {
	Root    string // "/" in production, a temp dir in tests
	Runner  cmdrunner.Runner
	Bus     Publisher
	Now     func() time.Time
	NewUUID func() string
}

// Provisioned reports whether the marker already exists.
func (p *Provisioner) Provisioned() bool {
	_, err := os.Stat(filepath.Join(p.Root, MarkerRel))
	return err == nil
}

// Apply validates and applies a request. It is a no-op returning
// AlreadyProvisioned when the marker exists: without that gate, a second run
// with a different username would RENAME the first user rather than create a
// new one (installer/src/provision.sh:168-187).
func (p *Provisioner) Apply(ctx context.Context, req *Request) (Result, error) {
	if err := req.Validate(); err != nil {
		return Result{}, InvalidRequest{err}
	}
	if p.Provisioned() {
		p.publish(events.StateAlreadyDone, "")
		return Result{AlreadyProvisioned: true}, nil
	}

	p.publish(events.StateHashingPassword, "")
	hash, err := p.hashPassword(ctx, req.Password.Bytes())
	if err != nil {
		p.publish(events.StateFailed, "password hashing failed")
		return Result{}, err
	}
	if err := validate.PasswordHash(hash); err != nil {
		p.publish(events.StateFailed, "password hashing failed")
		return Result{}, err
	}

	p.publish(events.StateApplyingSystem, req.Hostname)
	if err := p.applyHostname(req.Hostname); err != nil {
		p.publish(events.StateFailed, "hostname")
		return Result{}, err
	}
	if err := p.applyTimezone(req.Timezone); err != nil {
		p.publish(events.StateFailed, "timezone")
		return Result{}, err
	}

	p.publish(events.StateApplyingUser, req.User)
	if err := p.applyUser(req.User, hash); err != nil {
		p.publish(events.StateFailed, "user")
		return Result{}, err
	}

	if req.SSID != "" {
		p.publish(events.StateWritingWiFi, req.SSID)
		uuid := ""
		if p.NewUUID != nil {
			uuid = p.NewUUID()
		}
		if _, err := wifi.WriteKeyfile(p.Root, req.SSID, req.PSK.Bytes(), uuid); err != nil {
			p.publish(events.StateFailed, "wi-fi profile")
			return Result{}, err
		}
	}

	res := Result{
		User:           req.User,
		Hostname:       req.Hostname,
		Timezone:       req.Timezone,
		WiFiConfigured: req.SSID != "",
	}
	if err := p.writeMarker(res); err != nil {
		p.publish(events.StateFailed, "marker")
		return Result{}, err
	}
	p.publish(events.StateComplete, req.User)
	return res, nil
}

// hashPassword runs busybox cryptpw the way installer/src/tui.sh:71-75 does:
// the cleartext arrives on stdin (-P 0), never on the argv, and cryptpw picks
// its own salt.
func (p *Provisioner) hashPassword(ctx context.Context, pw []byte) (string, error) {
	out, err := p.Runner.Run(ctx, "cryptpw", []string{"-m", "sha512", "-P", "0"}, pw)
	if err != nil {
		return "", errors.New("could not hash password")
	}
	hash := strings.TrimSpace(string(out))
	if hash == "" {
		return "", errors.New("could not hash password")
	}
	return hash, nil
}

// applyHostname mirrors installer/src/provision.sh:112-119.
func (p *Provisioner) applyHostname(hostname string) error {
	if err := os.WriteFile(filepath.Join(p.Root, "etc/hostname"), []byte(hostname+"\n"), 0o644); err != nil {
		return err
	}
	hosts := filepath.Join(p.Root, "etc/hosts")
	line := "127.0.1.1\t" + hostname
	b, err := os.ReadFile(hosts)
	if err != nil {
		if !os.IsNotExist(err) {
			return err
		}
		return appendLine(hosts, line)
	}
	lines, trailing := splitLines(b)
	// EVERY matching line, not just the first: the shell is
	// `sed -i "s/^127\.0\.1\.1.*/.../"`, which substitutes on every line it
	// matches, so a /etc/hosts carrying two 127.0.1.1 records ends up with
	// neither still naming the old hostname.
	found := false
	for i, l := range lines {
		if strings.HasPrefix(l, "127.0.1.1") {
			lines[i] = line
			found = true
		}
	}
	if found {
		return os.WriteFile(hosts, []byte(joinLines(lines, trailing)), 0o644)
	}
	return appendLine(hosts, line)
}

// applyTimezone mirrors installer/src/provision.sh:121-125: the zoneinfo file
// must exist, and the symlink is RELATIVE.
func (p *Provisioner) applyTimezone(tz string) error {
	if _, err := os.Stat(filepath.Join(p.Root, "usr/share/zoneinfo", tz)); err != nil {
		return fmt.Errorf("timezone not present in rootfs: %s", tz)
	}
	link := filepath.Join(p.Root, "etc/localtime")
	if err := os.Remove(link); err != nil && !os.IsNotExist(err) {
		return err
	}
	return os.Symlink("../usr/share/zoneinfo/"+tz, link)
}

// applyUser mirrors installer/src/provision.sh:156-207: set the password on
// an existing user, else rename the single regular user, else create one.
func (p *Provisioner) applyUser(user, hash string) error {
	passwd := filepath.Join(p.Root, "etc/passwd")
	shadow := filepath.Join(p.Root, "etc/shadow")
	group := filepath.Join(p.Root, "etc/group")
	for _, f := range []string{passwd, shadow, group} {
		if st, err := os.Stat(f); err != nil || st.IsDir() {
			return errors.New("rootfs has no passwd/shadow/group")
		}
	}

	pwLines, pwTrailing, err := readLines(passwd)
	if err != nil {
		return err
	}
	if hasUser(pwLines, user) {
		return p.setPassword(user, hash)
	}

	// Exactly one regular user -> rename it, preserving uid/gid and groups.
	var regular []string
	for _, l := range pwLines {
		f := strings.Split(l, ":")
		if len(f) < 3 {
			continue
		}
		uid, err := strconv.Atoi(f[2])
		if err != nil {
			continue
		}
		if uid >= 1000 && uid < 65534 {
			regular = append(regular, f[0])
		}
	}
	if len(regular) == 1 {
		old := regular[0]
		for i, l := range pwLines {
			f := strings.Split(l, ":")
			if len(f) > 0 && f[0] == old {
				f = setField(f, 0, user)
				f = setField(f, 5, "/home/"+user)
				pwLines[i] = strings.Join(f, ":")
			}
		}
		if err := writeInPlace(passwd, joinLines(pwLines, pwTrailing)); err != nil {
			return err
		}
		if err := renameInFile(shadow, old, user); err != nil {
			return err
		}
		if err := renameInGroup(group, old, user); err != nil {
			return err
		}
		oldHome := filepath.Join(p.Root, "home", old)
		if st, err := os.Stat(oldHome); err == nil && st.IsDir() && old != user {
			if err := os.Rename(oldHome, filepath.Join(p.Root, "home", user)); err != nil {
				return err
			}
		}
		return p.setPassword(user, hash)
	}

	// No regular user in the image: create one, first free uid from 10000.
	uid := 10000
	for usedUID(pwLines, uid) {
		uid++
	}
	su := strconv.Itoa(uid)
	if err := appendLine(passwd, user+":x:"+su+":"+su+"::/home/"+user+":/bin/sh"); err != nil {
		return err
	}
	if err := appendLine(group, user+":x:"+su+":"); err != nil {
		return err
	}
	if err := appendLine(shadow, user+":!::0:::::"); err != nil {
		return err
	}
	for _, g := range []string{"wheel", "audio", "video", "input", "netdev", "plugdev"} {
		if err := addToGroup(group, g, user); err != nil {
			return err
		}
	}
	home := filepath.Join(p.Root, "home", user)
	if err := os.MkdirAll(home, 0o755); err != nil {
		return err
	}
	_ = os.Chown(home, uid, uid) // best effort, exactly as provision.sh
	if err := os.Chmod(home, 0o700); err != nil {
		return err
	}
	return p.setPassword(user, hash)
}

// setPassword mirrors installer/src/provision.sh:146-154: field 2 gets the
// hash, field 3 the last-change day; the aging fields are left alone and the
// file is rewritten in place so its inode, mode and owner survive.
func (p *Provisioner) setPassword(user, hash string) error {
	now := time.Now
	if p.Now != nil {
		now = p.Now
	}
	days := strconv.FormatInt(now().Unix()/86400, 10)
	shadow := filepath.Join(p.Root, "etc/shadow")
	lines, trailing, err := readLines(shadow)
	if err != nil {
		return err
	}
	for i, l := range lines {
		f := strings.Split(l, ":")
		if len(f) > 0 && f[0] == user {
			f = setField(f, 1, hash)
			f = setField(f, 2, days)
			lines[i] = strings.Join(f, ":")
		}
	}
	if err := writeInPlace(shadow, joinLines(lines, trailing)); err != nil {
		return err
	}
	after, _, err := readLines(shadow)
	if err != nil {
		return err
	}
	if !hasUser(after, user) {
		return errors.New("user missing from shadow after edit")
	}
	return nil
}

// writeMarker mirrors installer/src/provision.sh:273-283. No secrets: names
// only.
func (p *Provisioner) writeMarker(res Result) error {
	now := time.Now
	if p.Now != nil {
		now = p.Now
	}
	dir := filepath.Join(p.Root, filepath.Dir(MarkerRel))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	wifiConfigured := "no"
	if res.WiFiConfigured {
		wifiConfigured = "yes"
	}
	body := "provisioned_at=" + now().UTC().Format("2006-01-02T15:04:05Z") + "\n" +
		"user=" + res.User + "\n" +
		"hostname=" + res.Hostname + "\n" +
		"timezone=" + res.Timezone + "\n" +
		"wifi_configured=" + wifiConfigured + "\n"
	return os.WriteFile(filepath.Join(p.Root, MarkerRel), []byte(body), 0o644)
}

func (p *Provisioner) publish(state, detail string) {
	if p.Bus != nil {
		p.Bus.Publish(state, detail)
	}
}

// ------------------------------------------------------------------ helpers

// splitLines splits file content into records the way awk reads them: a
// trailing newline does not produce an empty last record.
func splitLines(b []byte) (lines []string, trailingNewline bool) {
	s := string(b)
	if s == "" {
		return nil, false
	}
	if strings.HasSuffix(s, "\n") {
		return strings.Split(strings.TrimSuffix(s, "\n"), "\n"), true
	}
	return strings.Split(s, "\n"), false
}

// joinLines is the inverse of splitLines, except that (like awk's print) a
// file that lacked a final newline gains one.
func joinLines(lines []string, _ bool) string {
	if len(lines) == 0 {
		return ""
	}
	return strings.Join(lines, "\n") + "\n"
}

func readLines(path string) ([]string, bool, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, false, err
	}
	lines, trailing := splitLines(b)
	return lines, trailing, nil
}

// writeInPlace truncates and rewrites an existing file without recreating it,
// which is how provision.sh's `cat "$f.tmp" > "$f"` preserves the inode, mode
// and ownership of /etc/shadow.
func writeInPlace(path, content string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// appendLine appends one newline-terminated line, creating the file if needed
// (the shell's `>>`).
func appendLine(path, line string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(line + "\n"); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// setField assigns fields[i], padding with empty fields first, the way awk
// extends a record when a field past NF is assigned.
func setField(fields []string, i int, v string) []string {
	for len(fields) <= i {
		fields = append(fields, "")
	}
	fields[i] = v
	return fields
}

func hasUser(lines []string, user string) bool {
	for _, l := range lines {
		if strings.HasPrefix(l, user+":") {
			return true
		}
	}
	return false
}

func usedUID(pwLines []string, uid int) bool {
	want := strconv.Itoa(uid)
	for _, l := range pwLines {
		f := strings.Split(l, ":")
		if len(f) >= 3 && f[2] == want {
			return true
		}
	}
	return false
}

// renameInFile renames the record whose first field is old (used for
// /etc/shadow).
func renameInFile(path, old, newName string) error {
	lines, trailing, err := readLines(path)
	if err != nil {
		return err
	}
	for i, l := range lines {
		f := strings.Split(l, ":")
		if len(f) > 0 && f[0] == old {
			f[0] = newName
			lines[i] = strings.Join(f, ":")
		}
	}
	return writeInPlace(path, joinLines(lines, trailing))
}

// renameInGroup mirrors installer/src/provision.sh:129-144: rename a group
// named old, and rewrite every member list mentioning old, preserving order.
func renameInGroup(path, old, newName string) error {
	lines, trailing, err := readLines(path)
	if err != nil {
		return err
	}
	for i, l := range lines {
		f := strings.Split(l, ":")
		if len(f) > 0 && f[0] == old {
			f[0] = newName
		}
		f = setField(f, 3, rewriteMembers(fieldAt(f, 3), old, newName))
		lines[i] = strings.Join(f, ":")
	}
	return writeInPlace(path, joinLines(lines, trailing))
}

// addToGroup appends user to group g's member list if that group exists
// (installer/src/provision.sh:196-202).
func addToGroup(path, g, user string) error {
	lines, trailing, err := readLines(path)
	if err != nil {
		return err
	}
	changed := false
	for i, l := range lines {
		f := strings.Split(l, ":")
		if len(f) == 0 || f[0] != g {
			continue
		}
		members := fieldAt(f, 3)
		if members == "" {
			members = user
		} else {
			members += "," + user
		}
		f = setField(f, 3, members)
		lines[i] = strings.Join(f, ":")
		changed = true
	}
	if !changed {
		return nil
	}
	return writeInPlace(path, joinLines(lines, trailing))
}

func fieldAt(fields []string, i int) string {
	if i < len(fields) {
		return fields[i]
	}
	return ""
}

func rewriteMembers(members, old, newName string) string {
	if members == "" {
		return ""
	}
	parts := strings.Split(members, ",")
	for i, m := range parts {
		if m == old {
			parts[i] = newName
		}
	}
	return strings.Join(parts, ",")
}
