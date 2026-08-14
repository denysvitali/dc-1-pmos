// Package secret holds cleartext credentials (passwords, WPA passphrases) in
// mutable byte slices that can be wiped as soon as they are consumed.
//
// The rules this package exists to enforce, mirroring installer/src/tui.sh:
// a secret is never rendered by fmt, never marshalled into a response, never
// put on an argv and never written to a log. Decoding goes straight from the
// JSON bytes into a []byte, so no immutable string copy of the cleartext is
// ever created.
package secret

import (
	"errors"
	"unicode/utf16"
	"unicode/utf8"
)

// Secret is a cleartext credential. Zero it with Wipe once it is consumed.
type Secret []byte

// Wipe overwrites the secret with zero bytes and empties it.
func (s *Secret) Wipe() {
	Zero(*s)
	*s = nil
}

// Bytes exposes the raw cleartext. Callers must not retain the slice past the
// point where the owner wipes it.
func (s Secret) Bytes() []byte { return []byte(s) }

// Len is the length in bytes (the installer's length caps are byte caps).
func (s Secret) Len() int { return len(s) }

// String never reveals the secret; it exists so accidental %v/%s formatting of
// a struct containing one cannot leak it.
func (s Secret) String() string { return "[redacted]" }

// GoString is the %#v counterpart of String.
func (s Secret) GoString() string { return "secret.Secret(\"[redacted]\")" }

// MarshalJSON never reveals the secret either: a handler that mistakenly
// echoes its request back must not disclose the credential.
func (s Secret) MarshalJSON() ([]byte, error) { return []byte(`"[redacted]"`), nil }

// UnmarshalJSON decodes a JSON string straight into bytes, without going
// through an immutable Go string that could not be wiped afterwards.
func (s *Secret) UnmarshalJSON(data []byte) error {
	if len(data) == 4 && string(data) == "null" {
		*s = nil
		return nil
	}
	if len(data) < 2 || data[0] != '"' || data[len(data)-1] != '"' {
		return errors.New("secret: expected a JSON string")
	}
	out, err := unquote(data[1 : len(data)-1])
	if err != nil {
		Zero(out)
		return err
	}
	*s = out
	return nil
}

// Zero overwrites b with zero bytes.
func Zero(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

var errBadEscape = errors.New("secret: invalid JSON string escape")

// unquote decodes the body of a JSON string literal into a fresh byte slice.
func unquote(in []byte) ([]byte, error) {
	out := make([]byte, 0, len(in))
	for i := 0; i < len(in); {
		c := in[i]
		if c != '\\' {
			out = append(out, c)
			i++
			continue
		}
		i++
		if i >= len(in) {
			return out, errBadEscape
		}
		switch in[i] {
		case '"', '\\', '/':
			out = append(out, in[i])
			i++
		case 'b':
			out = append(out, '\b')
			i++
		case 'f':
			out = append(out, '\f')
			i++
		case 'n':
			out = append(out, '\n')
			i++
		case 'r':
			out = append(out, '\r')
			i++
		case 't':
			out = append(out, '\t')
			i++
		case 'u':
			r, n, err := unhex(in[i+1:])
			if err != nil {
				return out, err
			}
			i += 1 + n
			if utf16.IsSurrogate(r) && len(in) > i+1 && in[i] == '\\' && in[i+1] == 'u' {
				r2, n2, err := unhex(in[i+2:])
				if err != nil {
					return out, err
				}
				if dec := utf16.DecodeRune(r, r2); dec != utf8.RuneError {
					r = dec
					i += 2 + n2
				}
			}
			if utf16.IsSurrogate(r) {
				r = utf8.RuneError
			}
			out = utf8.AppendRune(out, r)
		default:
			return out, errBadEscape
		}
	}
	return out, nil
}

// unhex decodes the 4 hex digits of a \u escape, returning the rune and the
// number of bytes consumed.
func unhex(in []byte) (rune, int, error) {
	if len(in) < 4 {
		return 0, 0, errBadEscape
	}
	var r rune
	for i := 0; i < 4; i++ {
		c := in[i]
		var v rune
		switch {
		case c >= '0' && c <= '9':
			v = rune(c - '0')
		case c >= 'a' && c <= 'f':
			v = rune(c-'a') + 10
		case c >= 'A' && c <= 'F':
			v = rune(c-'A') + 10
		default:
			return 0, 0, errBadEscape
		}
		r = r<<4 | v
	}
	return r, 4, nil
}
