package validate

import (
	"strings"
	"testing"
)

func rep(c byte, n int) string { return strings.Repeat(string(c), n) }

func TestUsername(t *testing.T) {
	cases := []struct {
		in string
		ok bool
	}{
		{"alice", true},
		{"a", true},
		{"_", true},
		{"a1", true},
		{"a-b_c", true},
		{"a" + rep('b', 31), true},  // 32 bytes: the cap
		{"a" + rep('b', 32), false}, // 33 bytes: one over
		{"", false},
		{"root", false},
		{"nobody", false},
		{"Alice", false},
		{"1alice", false},
		{"-alice", false},
		{"al ice", false},
		{"alice:x", false},
		{"al.ice", false},
		{"aliceé", false},
		{"rooty", true},   // only the exact reserved names are refused
		{"nobody1", true}, // ditto
	}
	for _, c := range cases {
		err := Username(c.in)
		if c.ok && err != nil {
			t.Errorf("Username(%q) = %v, want ok", c.in, err)
		}
		if !c.ok && err == nil {
			t.Errorf("Username(%q) = ok, want error", c.in)
		}
	}
}

func TestHostname(t *testing.T) {
	cases := []struct {
		in string
		ok bool
	}{
		{"dc1", true},
		{"a", true},
		{"0", true},
		{"a-b-c", true},
		{"a" + rep('b', 62), true},  // 63 bytes: the cap
		{"a" + rep('b', 63), false}, // 64 bytes: one over
		{"", false},
		{"dc1-", false},
		{"-dc1", false},
		{"DC1", false},
		{"dc1.local", false},
		{"dc_1", false},
		{rep('-', 1), false},
	}
	for _, c := range cases {
		err := Hostname(c.in)
		if c.ok && err != nil {
			t.Errorf("Hostname(%q) = %v, want ok", c.in, err)
		}
		if !c.ok && err == nil {
			t.Errorf("Hostname(%q) = ok, want error", c.in)
		}
	}
}

func TestTimezone(t *testing.T) {
	cases := []struct {
		in string
		ok bool
	}{
		{"UTC", true},
		{"Europe/Zurich", true},
		{"America/New_York", true},
		{"America/Argentina/Buenos_Aires", true},
		{"Etc/GMT+5", true},
		{"Etc/GMT-5", true},
		{"", false},
		{"..", false},
		{"../../etc/shadow", false},
		{"Europe/../Europe/Zurich", false},
		{"/UTC", false},
		{"UTC/", false},
		{"Europe/Zürich", false},
		{"Europe/Zurich;reboot", false},
		{"Europe Zurich", false},
		{"a.b", false}, // "." is outside [A-Za-z0-9_+/-]
	}
	for _, c := range cases {
		err := Timezone(c.in)
		if c.ok && err != nil {
			t.Errorf("Timezone(%q) = %v, want ok", c.in, err)
		}
		if !c.ok && err == nil {
			t.Errorf("Timezone(%q) = ok, want error", c.in)
		}
	}
}

func TestSSID(t *testing.T) {
	cases := []struct {
		in string
		ok bool
	}{
		{"MyNet", true},
		{rep('s', 32), true},  // the cap
		{rep('s', 33), false}, // one over
		{"", false},
		{"has\nnewline", false},
		{"has:colon", true},
		{"héllo", true}, // 6 bytes, under the byte cap
		{strings.Repeat("é", 16), true},
		{strings.Repeat("é", 17), false}, // 34 bytes: the cap is BYTES
	}
	for _, c := range cases {
		err := SSID(c.in)
		if c.ok && err != nil {
			t.Errorf("SSID(%q) = %v, want ok", c.in, err)
		}
		if !c.ok && err == nil {
			t.Errorf("SSID(%q) = ok, want error", c.in)
		}
	}
}

func TestPSK(t *testing.T) {
	cases := []struct {
		n  int
		ok bool
	}{
		{0, false},
		{7, false},
		{8, true},
		{63, true},
		{64, false},
	}
	for _, c := range cases {
		err := PSK([]byte(rep('p', c.n)))
		if c.ok && err != nil {
			t.Errorf("PSK(len %d) = %v, want ok", c.n, err)
		}
		if !c.ok && err == nil {
			t.Errorf("PSK(len %d) = ok, want error", c.n)
		}
	}
	if err := PSK([]byte("pass\nword")); err == nil {
		t.Error("PSK with newline accepted")
	}
}

func TestPSKErrorDoesNotLeakSecret(t *testing.T) {
	psk := []byte("hunter2")
	err := PSK(psk)
	if err == nil {
		t.Fatal("short PSK accepted")
	}
	if strings.Contains(err.Error(), "hunter2") {
		t.Fatalf("PSK error leaked the passphrase: %v", err)
	}
}

func TestPassword(t *testing.T) {
	if err := Password(nil); err == nil {
		t.Error("empty password accepted")
	}
	if err := Password([]byte("x")); err != nil {
		t.Errorf("one-byte password rejected: %v", err)
	}
	if err := Password([]byte("s3cret")); err != nil {
		t.Fatal(err)
	}
	err := Password(nil)
	if strings.Contains(err.Error(), "s3cret") {
		t.Fatal("password error leaked the password")
	}
}

func TestPasswordHash(t *testing.T) {
	cases := []struct {
		in string
		ok bool
	}{
		{"$6$salt$hash", true},
		{"$1$a$b", true},
		{"", false},
		{"cleartext", false},
		{"$6salt", false},
		{"$6$salt:hash", false},
		{"$6$salt hash", false},
	}
	for _, c := range cases {
		err := PasswordHash(c.in)
		if c.ok && err != nil {
			t.Errorf("PasswordHash(%q) = %v, want ok", c.in, err)
		}
		if !c.ok && err == nil {
			t.Errorf("PasswordHash(%q) = ok, want error", c.in)
		}
	}
}
