package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

func init() {
	register(90, "audio", "PCM0 playback, PCM9 DMIC and user-service evidence; opt-in bounded microphone metrics", checkAudio)
}

func checkAudio(c *Ctx, r *Reporter) {
	audioPCM(c, r, "PCM0 playback", "/proc/asound/card0/pcm0p/info", 0, "PLAYBACK", "Playback_1")
	audioPCM(c, r, "PCM9 DMIC frontend", "/proc/asound/card0/pcm9c/info", 9, "CAPTURE", "Capture_1")
	for _, service := range []string{"pipewire.service", "pipewire-pulse.service", "wireplumber.service"} {
		name := "user service " + service
		if filepath.Clean(c.Root) != "/" {
			r.Skip(name, "fixture mode: user service commands disabled")
			continue
		}
		if os.Geteuid() == 0 {
			r.Skip(name, "run as the desktop owner; root's user manager is not desktop evidence")
			continue
		}
		if !c.have("systemctl") {
			r.Skip(name, "systemctl unavailable")
			continue
		}
		out, err := c.run(2*time.Second, "systemctl", "--user", "show", "--property=ActiveState", "--value", service)
		if err != nil {
			r.Skip(name, "desktop owner user manager unavailable; no service changes attempted")
			continue
		}
		switch strings.TrimSpace(out) {
		case "active":
			r.Pass(name, "owner user manager reports active; this does not prove an audio route or audible output")
		case "inactive", "failed", "activating", "deactivating", "reloading":
			r.Warn(name, "owner user manager does not report active")
		default:
			r.Skip(name, "unrecognized or missing service state")
		}
	}
	if !c.Microphone {
		r.Skip("microphone signal", "requires -allow-microphone; no capture performed")
	} else if filepath.Clean(c.Root) != "/" {
		r.Skip("microphone signal", "disabled for fixtures")
	} else {
		audioMicrophone(c, r)
	}
	// No validated route/volume ceiling can be established without touching
	// mixers. In particular direct ALSA bypasses the desktop owner's volume.
	// Safely leave audible acceptance to an explicitly approved manual test.
	if !c.Sound || !c.Interactive {
		r.Skip("speaker listening", "requires -interactive, -allow-sound and owner confirmation; no sound generated")
	} else {
		r.Skip("speaker listening", "unsupported: no validated quiet playback path without mixer changes; no sound generated or confirmation requested")
	}
}

func audioPCM(c *Ctx, r *Reporter, name, path string, device int, stream, id string) {
	s, err := c.read(path)
	if err != nil {
		r.Skip(name, "procfs PCM information unavailable")
		return
	}
	if audioPCMMatches(s, device, stream, id) {
		r.Pass(name, "expected PCM device, direction and frontend registered; enumeration does not prove sound or microphone signal")
	} else {
		r.Warn(name, "procfs PCM information does not match the expected frontend (identifiers omitted)")
	}
}

func audioPCMMatches(s string, device int, stream, id string) bool {
	fields := map[string]string{}
	for _, line := range strings.Split(s, "\n") {
		key, value, found := strings.Cut(line, ":")
		if found {
			fields[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	pcmID := strings.TrimSuffix(fields["id"], " (*)")
	return fields["card"] == "0" && fields["device"] == strconv.Itoa(device) && fields["stream"] == stream && pcmID == id
}

const audioCaptureBytes = 48000 * 2 * 2 * 2 // 2 seconds, stereo, S16_LE

// audioCaptureBuffer retains at most the consented PCM window. Excess data
// cancels the recorder rather than growing memory. Stderr is never retained.
type audioCaptureBuffer struct {
	mu       sync.Mutex
	data     []byte
	limit    int
	overflow bool
	closed   bool
	cancel   context.CancelFunc
}

func (b *audioCaptureBuffer) discard() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.closed = true
	for i := range b.data {
		b.data[i] = 0
	}
	b.data = nil
}

func (b *audioCaptureBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return len(p), nil
	}
	n := len(p)
	room := b.limit - len(b.data)
	if len(p) > room {
		b.data = append(b.data, p[:room]...)
		b.overflow = true
		if b.cancel != nil {
			b.cancel()
		}
		return n, errors.New("microphone output limit exceeded")
	}
	b.data = append(b.data, p...)
	return n, nil
}

type audioSignal struct {
	samples int
	nonzero int
	clipped int
	rms     float64 // normalized to full-scale
}

func audioSignalMetrics(data []byte) (audioSignal, error) {
	if len(data) == 0 || len(data)%4 != 0 || len(data) > audioCaptureBytes {
		return audioSignal{}, errors.New("empty, incomplete or excessive stereo PCM")
	}
	var result audioSignal
	var sum float64
	for i := 0; i < len(data); i += 2 {
		sample := int(int16(binary.LittleEndian.Uint16(data[i : i+2])))
		result.samples++
		if sample != 0 {
			result.nonzero++
		}
		if sample >= 32760 || sample <= -32760 {
			result.clipped++
		}
		value := float64(sample) / 32768
		sum += value * value
	}
	result.rms = math.Sqrt(sum / float64(result.samples))
	return result, nil
}

func audioMicrophone(c *Ctx, r *Reporter) {
	if !c.have("arecord") {
		r.Skip("microphone signal", "arecord unavailable; no capture performed")
		return
	}
	parent := c.Cancel
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	pcm := &audioCaptureBuffer{limit: audioCaptureBytes, cancel: cancel}
	defer pcm.discard()
	cmd := exec.CommandContext(ctx, "arecord", "-q", "-N", "-D", "hw:0,9", "-t", "raw", "-f", "S16_LE", "-r", "48000", "-c", "2", "-d", "2", "-")
	cmd.Stdout, cmd.Stderr = pcm, io.Discard
	cmd.WaitDelay = time.Second
	if err := cmd.Start(); err != nil {
		r.Skip("microphone signal", "cannot start recorder; no capture performed")
		return
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var runErr error
	select {
	case <-ctx.Done():
		r.Skip("microphone signal", "recorder cancelled or timed out; in-memory PCM discarded")
		return
	case runErr = <-done:
	}
	if runErr != nil {
		if pcm.overflow {
			r.Warn("microphone signal", "recorder exceeded 2-second PCM byte bound; cancelled and discarded")
		} else if ctx.Err() != nil {
			r.Skip("microphone signal", "recorder cancelled or timed out; in-memory PCM discarded")
		} else {
			r.Skip("microphone signal", "capture unavailable (busy, permission, unsupported format or device); no mixer changes")
		}
		return
	}
	metrics, err := audioSignalMetrics(pcm.data)
	if err != nil {
		r.Warn("microphone signal", "no complete bounded stereo PCM frames returned")
		return
	}
	r.Info("microphone metrics", "%.3f seconds, RMS %.6f full-scale, %d/%d nonzero samples, %d clipping samples; PCM only in memory, not saved or played; not an intelligibility test", float64(metrics.samples)/(48000*2), metrics.rms, metrics.nonzero, metrics.samples, metrics.clipped)
	if len(pcm.data) != audioCaptureBytes {
		r.Warn("microphone duration", "recorder returned less than the requested 2-second window")
	}
	if metrics.nonzero == 0 {
		r.Warn("microphone signal", "digital silence; mixer state is untouched")
	} else if metrics.clipped > 0 {
		r.Warn("microphone signal", "nonzero signal includes near-full-scale clipping; this is not an intelligibility test")
	} else {
		r.Pass("microphone signal", "nonzero bounded PCM without near-full-scale clipping; this proves signal only, not intelligibility or acoustic provenance")
	}
}
