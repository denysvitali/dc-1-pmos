package wire

import (
	"bufio"
	"encoding/base64"
	"io"
	"strings"
	"testing"
)

const goodSHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func parse(t *testing.T, s string) (*Header, *bufio.Reader, error) {
	t.Helper()
	br := bufio.NewReader(strings.NewReader(s))
	h, err := ParseHeader(br)
	return h, br, err
}

func TestParsesAProvisionedSession(t *testing.T) {
	answers := base64.StdEncoding.EncodeToString([]byte("DC1_USER=alice\n"))
	h, _, err := parse(t, Magic+"\nsize=16777216\nsha256="+goodSHA+"\nanswers="+answers+"\n\n")
	if err != nil {
		t.Fatal(err)
	}
	if h.Size != 16777216 || h.SHA256 != goodSHA {
		t.Fatalf("header = %+v", h)
	}
	if string(h.Answers) != "DC1_USER=alice\n" {
		t.Fatalf("answers = %q", h.Answers)
	}
	if h.Unprovisioned {
		t.Fatal("provisioned session parsed as unprovisioned")
	}
}

func TestParsesAnUnprovisionedSession(t *testing.T) {
	h, _, err := parse(t, Magic+"\nsize=16777216\nsha256="+goodSHA+"\nunprovisioned=1\n\n")
	if err != nil {
		t.Fatal(err)
	}
	if !h.Unprovisioned || h.Answers != nil {
		t.Fatalf("header = %+v", h)
	}
}

// The body must start exactly after the blank line: an off-by-one here is the
// same class of bug as the over-read that corrupted every install.
func TestBodyStartsImmediatelyAfterTheHeader(t *testing.T) {
	body := "IMAGE-BODY-STARTS-HERE"
	_, br, err := parse(t, Magic+"\nsize=16777216\nsha256="+goodSHA+"\nunprovisioned=1\n\n"+body)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(br)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != body {
		t.Fatalf("body = %q, want %q", got, body)
	}
}

func TestRejectsBadHeaders(t *testing.T) {
	cases := map[string]string{
		"bad magic":               "NOPE\nsize=16777216\nsha256=" + goodSHA + "\nunprovisioned=1\n\n",
		"missing size":            Magic + "\nsha256=" + goodSHA + "\nunprovisioned=1\n\n",
		"missing sha":             Magic + "\nsize=16777216\nunprovisioned=1\n\n",
		"short sha":               Magic + "\nsize=16777216\nsha256=abc\nunprovisioned=1\n\n",
		"non-hex sha":             Magic + "\nsize=16777216\nsha256=" + strings.Repeat("z", 64) + "\nunprovisioned=1\n\n",
		"size below the floor":    Magic + "\nsize=1024\nsha256=" + goodSHA + "\nunprovisioned=1\n\n",
		"provisioned, no answers": Magic + "\nsize=16777216\nsha256=" + goodSHA + "\n\n",
		"unknown key":             Magic + "\nsize=16777216\nsha256=" + goodSHA + "\nwat=1\nunprovisioned=1\n\n",
	}
	for name, input := range cases {
		if _, _, err := parse(t, input); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
