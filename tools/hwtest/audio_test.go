package main

import (
	"encoding/binary"
	"math"
	"strings"
	"testing"
)

func TestAudioPCMMatches(t *testing.T) {
	for _, test := range []struct {
		text       string
		device     int
		stream, id string
		want       bool
	}{
		{"card: 0\ndevice: 0\nstream: PLAYBACK\nid: Playback_1 (*)\nname: OMIT_ME", 0, "PLAYBACK", "Playback_1", true},
		{"card: 0\ndevice: 9\nstream: CAPTURE\nid: Capture_1", 9, "CAPTURE", "Capture_1", true},
		{"card: 0\ndevice: 0\nstream: CAPTURE\nid: Capture_1", 9, "CAPTURE", "Capture_1", false},
		{"card: 1\ndevice: 9\nstream: CAPTURE\nid: Capture_1", 9, "CAPTURE", "Capture_1", false},
		{"card: 0\ndevice: 9\nstream: CAPTURE\nid: Another Capture_1", 9, "CAPTURE", "Capture_1", false},
		{"id: Capture_1", 9, "CAPTURE", "Capture_1", false},
	} {
		if got := audioPCMMatches(test.text, test.device, test.stream, test.id); got != test.want {
			t.Errorf("PCM match %v, want %v", got, test.want)
		}
	}
}

func TestAudioPassiveFixtureGuards(t *testing.T) {
	c := storageAudioFixture(t)
	c.Microphone, c.Sound, c.Interactive = true, true, true
	storageAudioPut(t, c, "/proc/asound/card0/pcm0p/info", "card: 0\ndevice: 0\nstream: PLAYBACK\nid: Playback_1 (*)\nname: PRIVATE_IDENTIFIER")
	storageAudioPut(t, c, "/proc/asound/card0/pcm9c/info", "card: 0\ndevice: 9\nstream: CAPTURE\nid: Capture_1 (*)")
	r := &Reporter{group: "audio"}
	checkAudio(c, r)
	for _, name := range []string{"PCM0 playback", "PCM9 DMIC frontend"} {
		if result := storageAudioResult(t, r, name); result.Status != Pass {
			t.Errorf("%s: %+v", name, result)
		}
	}
	for _, name := range []string{"user service pipewire.service", "user service pipewire-pulse.service", "user service wireplumber.service", "microphone signal", "speaker listening"} {
		if result := storageAudioResult(t, r, name); result.Status != Skip {
			t.Errorf("unsafe fixture action: %+v", result)
		}
	}
	for _, result := range r.results {
		if strings.Contains(result.Detail, "PRIVATE_IDENTIFIER") {
			t.Fatal("PCM identifier leaked")
		}
	}
}

func TestAudioMissingEvidence(t *testing.T) {
	c := storageAudioFixture(t)
	r := &Reporter{group: "audio"}
	checkAudio(c, r)
	for _, result := range r.results {
		if result.Status != Skip {
			t.Errorf("missing evidence not skipped: %+v", result)
		}
	}
}

func TestAudioCaptureBufferBound(t *testing.T) {
	cancelled := false
	b := &audioCaptureBuffer{limit: 8, cancel: func() { cancelled = true }}
	if n, err := b.Write([]byte{1, 2, 3, 4}); n != 4 || err != nil {
		t.Fatal(n, err)
	}
	if n, err := b.Write(make([]byte, 12)); n != 12 || err == nil {
		t.Fatal(n, err)
	}
	if len(b.data) != 8 || !b.overflow || !cancelled {
		t.Fatal("capture bound not enforced")
	}
	b.discard()
	if len(b.data) != 0 {
		t.Fatal("PCM retained after discard")
	}
	if _, err := b.Write([]byte{9, 9}); err != nil || len(b.data) != 0 {
		t.Fatal("late recorder output retained")
	}
}

func TestAudioSignalMetrics(t *testing.T) {
	for _, data := range [][]byte{nil, {1}, {1, 2}, make([]byte, audioCaptureBytes+4)} {
		if _, err := audioSignalMetrics(data); err == nil {
			t.Errorf("accepted invalid %d bytes", len(data))
		}
	}
	data := make([]byte, 8)
	for i, sample := range []int16{0, 16384, -16384, 32767} {
		binary.LittleEndian.PutUint16(data[2*i:], uint16(sample))
	}
	got, err := audioSignalMetrics(data)
	if err != nil {
		t.Fatal(err)
	}
	wantRMS := math.Sqrt((.25 + .25 + math.Pow(32767.0/32768, 2)) / 4)
	if got.samples != 4 || got.nonzero != 3 || got.clipped != 1 || math.Abs(got.rms-wantRMS) > 1e-12 {
		t.Fatalf("bad metrics: %+v", got)
	}
	zero, err := audioSignalMetrics(make([]byte, audioCaptureBytes))
	if err != nil || zero.nonzero != 0 || zero.rms != 0 || zero.clipped != 0 {
		t.Fatal(zero, err)
	}
}
