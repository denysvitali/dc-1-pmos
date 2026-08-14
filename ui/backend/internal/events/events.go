// Package events is the progress bus behind GET /events.
//
// The installer has no progress enum: it whole-file-overwrites free-form
// uppercase strings into /tmp/installer-status, which PID 1 repaints
// (installer/src/tui.sh:31, installer/src/init.c:614-632). The states below
// reuse that vocabulary verbatim where one already exists, and add the
// onboarding-specific ones this backend needs. Keeping the strings identical
// means one glossary covers both the initramfs status screen and the UI.
package events

import (
	"sync"
	"time"
)

// States taken verbatim from the installer's status vocabulary.
const (
	StateScanningWiFi   = "SCANNING WI-FI NETWORKS" // installer/src/tui.sh:130
	StateConnectingWiFi = "CONNECTING TO WI-FI"     // installer/src/tui.sh:173
	StateRequestingIP   = "REQUESTING IP ADDRESS"   // installer/src/tui.sh:181
	StateProvisioning   = "PROVISIONING"            // installer/src/writelib.sh:142
)

// States specific to on-device onboarding, which the initramfs never reaches.
const (
	StateIdle            = "IDLE"
	StateWiFiConnected   = "WI-FI CONNECTED"
	StateWiFiFailed      = "WI-FI CONNECTION FAILED" // installer/src/tui.sh:176
	StateHashingPassword = "HASHING PASSWORD"
	StateApplyingUser    = "APPLYING USER"
	StateApplyingSystem  = "APPLYING HOSTNAME AND TIMEZONE"
	StateWritingWiFi     = "WRITING WI-FI PROFILE"
	StateComplete        = "ONBOARDING COMPLETE"
	StateFailed          = "ONBOARDING FAILED"
	StateAlreadyDone     = "ALREADY PROVISIONED"
)

// Event is one NDJSON line on the stream. Detail is free-form and must never
// carry a credential.
type Event struct {
	Time   string `json:"ts"`
	State  string `json:"state"`
	Detail string `json:"detail,omitempty"`
}

// Bus fans progress events out to every /events subscriber. A slow subscriber
// is dropped events, never allowed to block a provisioning step.
type Bus struct {
	Now func() time.Time

	mu   sync.Mutex
	subs map[chan Event]struct{}
	last *Event
}

// NewBus returns an empty bus.
func NewBus() *Bus {
	return &Bus{subs: make(map[chan Event]struct{})}
}

// Publish records a state transition and delivers it to every subscriber.
func (b *Bus) Publish(state, detail string) {
	now := time.Now
	if b.Now != nil {
		now = b.Now
	}
	ev := Event{Time: now().UTC().Format(time.RFC3339), State: state, Detail: detail}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.last = &ev
	for ch := range b.subs {
		select {
		case ch <- ev:
		default: // subscriber is behind; drop rather than stall the caller
		}
	}
}

// Last returns the most recent event, if any, so a subscriber that attaches
// late still learns the current state.
func (b *Bus) Last() (Event, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.last == nil {
		return Event{}, false
	}
	return *b.last, true
}

// Subscribe returns a channel of future events and a function that
// unsubscribes and closes it. The channel is buffered; see Publish.
func (b *Bus) Subscribe() (<-chan Event, func()) {
	ch := make(chan Event, 16)
	b.mu.Lock()
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	var once sync.Once
	return ch, func() {
		once.Do(func() {
			b.mu.Lock()
			delete(b.subs, ch)
			b.mu.Unlock()
			close(ch)
		})
	}
}
