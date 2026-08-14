// Package validate is a byte-for-byte port of the installer's answer
// validators.
//
// The rules live in three places already (installer/src/tui.sh:37-65,
// installer/src/provision.sh:58-108 and the frozen host script
// installer/host/dc1-install.sh:55-82). This is the fourth, and it must agree
// with them exactly: a typo has to be caught on-screen, not after a
// destructive step.
//
// Every length cap here is a BYTE cap (Go's len() over a string or []byte).
// That is deliberately not what the shell counts: busybox ash's ${#var} is
// locale-dependent, and measured on Alpine's busybox 1.37.0-r14 it counts
// CODEPOINTS under a UTF-8 locale -- which is musl's default when LANG and
// LC_ALL are unset, i.e. the environment the installer runs in -- and bytes
// only under LC_ALL=C:
//
//	busybox ash -c 'v=café; echo ${#v}'   # UTF-8 locale -> 4, LC_ALL=C -> 5
//
// Bytes are counted here regardless, because bytes are what consumes these
// values: 802.11 gives an SSID 32 octets, NetworkManager measures the WPA
// passphrase in bytes, and /etc/passwd, /etc/shadow and /etc/hostname are
// byte-oriented files. For the ASCII-only charsets these validators enforce --
// username, hostname, timezone -- the two counts are identical, so all layers
// agree exactly. SSID and PSK are not charset-restricted, and there counting
// bytes is the STRICTER rule: it can only reject a value the shell would have
// accepted, never the reverse. (provision.sh:97 already says "longer than 32
// bytes"; on a UTF-8 locale that message names the unit this file uses, not
// the one the shell measured.)
package validate

import (
	"errors"
	"fmt"
	"strings"
)

// Username mirrors valid_username (installer/src/tui.sh:37-44) plus
// provision.sh's reserved-name rejection.
func Username(u string) error {
	switch u {
	case "root", "nobody":
		return fmt.Errorf("refusing reserved username: %s", u)
	}
	if u == "" {
		return errors.New("username is empty")
	}
	if !isUserFirst(u[0]) {
		return fmt.Errorf("invalid username: %q", u)
	}
	for i := 1; i < len(u); i++ {
		if !isUserRest(u[i]) {
			return fmt.Errorf("invalid username: %q", u)
		}
	}
	if len(u) > 32 {
		return errors.New("username too long (max 32)")
	}
	return nil
}

// Hostname mirrors valid_hostname (installer/src/tui.sh:46-53). The
// trailing-dash rejection comes first, exactly as in the shell.
func Hostname(h string) error {
	if strings.HasSuffix(h, "-") {
		return errors.New("hostname may not end with -")
	}
	if h == "" {
		return errors.New("hostname is empty")
	}
	if !isHostFirst(h[0]) {
		return fmt.Errorf("invalid hostname: %q", h)
	}
	for i := 1; i < len(h); i++ {
		if !isHostRest(h[i]) {
			return fmt.Errorf("invalid hostname: %q", h)
		}
	}
	if len(h) > 63 {
		return errors.New("hostname too long (max 63)")
	}
	return nil
}

// Timezone mirrors valid_timezone (installer/src/tui.sh:55-61): non-empty, no
// ".." anywhere, no leading or trailing "/", and only [A-Za-z0-9_+/-].
func Timezone(tz string) error {
	if tz == "" {
		return errors.New("timezone is empty")
	}
	if strings.Contains(tz, "..") || strings.HasPrefix(tz, "/") || strings.HasSuffix(tz, "/") {
		return fmt.Errorf("invalid timezone path: %q", tz)
	}
	for i := 0; i < len(tz); i++ {
		if !isTZChar(tz[i]) {
			return fmt.Errorf("invalid timezone characters: %q", tz)
		}
	}
	return nil
}

// SSID mirrors provision.sh's SSID rules (installer/src/provision.sh:95-102):
// non-empty, at most 32 bytes, no newline.
func SSID(s string) error {
	if s == "" {
		return errors.New("empty SSID")
	}
	if len(s) > 32 {
		return errors.New("SSID longer than 32 bytes")
	}
	if strings.ContainsAny(s, "\n") {
		return errors.New("SSID contains newline")
	}
	return nil
}

// PSK mirrors valid_psk (installer/src/tui.sh:63-65) plus provision.sh's
// newline rejection. The passphrase itself never appears in the error.
func PSK(psk []byte) error {
	if len(psk) < 8 || len(psk) > 63 {
		return errors.New("WPA-PSK passphrase must be 8..63 characters")
	}
	for _, c := range psk {
		if c == '\n' {
			return errors.New("PSK contains newline")
		}
	}
	return nil
}

// Password rejects an empty password, the same way tui.sh silently
// re-prompts on one (installer/src/tui.sh:198). The password never appears in
// the error.
func Password(pw []byte) error {
	if len(pw) == 0 {
		return errors.New("password is empty")
	}
	return nil
}

// PasswordHash mirrors provision.sh's crypt-hash rules
// (installer/src/provision.sh:68-75). A hash is not a secret in the sense the
// cleartext is, but it still never goes into the message.
func PasswordHash(h string) error {
	if h == "" {
		return errors.New("missing password hash")
	}
	if !strings.HasPrefix(h, "$") || !strings.Contains(h[1:], "$") {
		return errors.New("password hash is not a crypt hash")
	}
	if strings.ContainsAny(h, ": ") {
		return errors.New("password hash contains invalid characters")
	}
	return nil
}

func isUserFirst(c byte) bool { return c >= 'a' && c <= 'z' || c == '_' }

func isUserRest(c byte) bool {
	return isUserFirst(c) || c >= '0' && c <= '9' || c == '-'
}

func isHostFirst(c byte) bool { return c >= 'a' && c <= 'z' || c >= '0' && c <= '9' }

func isHostRest(c byte) bool { return isHostFirst(c) || c == '-' }

func isTZChar(c byte) bool {
	switch {
	case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		return true
	}
	return c == '_' || c == '+' || c == '/' || c == '-'
}
