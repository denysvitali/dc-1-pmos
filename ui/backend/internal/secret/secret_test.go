package secret

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestUnmarshalJSON(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{`"hunter2hunter2"`, "hunter2hunter2"},
		{`"with \"quote\""`, `with "quote"`},
		{`"back\\slash"`, `back\slash`},
		{`"tab\there"`, "tab\there"},
		{`"newline\nhere"`, "newline\nhere"},
		{`"été"`, "été"},
		{`"😀"`, "\U0001F600"},
		{`""`, ""},
	}
	for _, c := range cases {
		var s Secret
		if err := json.Unmarshal([]byte(c.in), &s); err != nil {
			t.Fatalf("Unmarshal(%s): %v", c.in, err)
		}
		if string(s) != c.want {
			t.Errorf("Unmarshal(%s) = %q, want %q", c.in, string(s), c.want)
		}
	}
}

func TestUnmarshalRejectsNonString(t *testing.T) {
	for _, in := range []string{`42`, `{}`, `[]`, `"bad\qescape"`, `"trailing\`} {
		var s Secret
		if err := json.Unmarshal([]byte(in), &s); err == nil {
			t.Errorf("Unmarshal(%s) accepted", in)
		}
	}
	var s Secret
	if err := json.Unmarshal([]byte(`null`), &s); err != nil || s != nil {
		t.Errorf("null: err=%v s=%v", err, s)
	}
}

func TestNeverRendersCleartext(t *testing.T) {
	s := Secret("swordfish")
	if got := fmt.Sprintf("%s|%v|%#v", s, s, s); strings.Contains(got, "swordfish") {
		t.Fatalf("formatting leaked the secret: %s", got)
	}
	type payload struct {
		PSK Secret `json:"psk"`
	}
	b, err := json.Marshal(payload{PSK: s})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "swordfish") {
		t.Fatalf("marshalling leaked the secret: %s", b)
	}
}

func TestWipe(t *testing.T) {
	s := Secret("swordfish")
	raw := s.Bytes()
	if s.Len() != 9 {
		t.Fatalf("Len = %d", s.Len())
	}
	s.Wipe()
	if s != nil {
		t.Fatalf("Wipe left %v", s)
	}
	for i, b := range raw {
		if b != 0 {
			t.Fatalf("byte %d not zeroed: %q", i, raw)
		}
	}
}

func TestZero(t *testing.T) {
	b := []byte("abc")
	Zero(b)
	if string(b) != "\x00\x00\x00" {
		t.Fatalf("Zero left %q", b)
	}
	Zero(nil) // must not panic
}
