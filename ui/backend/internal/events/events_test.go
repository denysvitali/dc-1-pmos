package events

import (
	"testing"
	"time"
)

func TestPublishReachesSubscribers(t *testing.T) {
	b := NewBus()
	b.Now = func() time.Time { return time.Unix(1700000000, 0).UTC() }

	ch1, cancel1 := b.Subscribe()
	defer cancel1()
	ch2, cancel2 := b.Subscribe()
	defer cancel2()

	b.Publish(StateProvisioning, "alice")

	for i, ch := range []<-chan Event{ch1, ch2} {
		select {
		case ev := <-ch:
			if ev.State != StateProvisioning || ev.Detail != "alice" {
				t.Errorf("subscriber %d got %+v", i, ev)
			}
			if ev.Time != "2023-11-14T22:13:20Z" {
				t.Errorf("subscriber %d timestamp %q", i, ev.Time)
			}
		case <-time.After(time.Second):
			t.Fatalf("subscriber %d got no event", i)
		}
	}
}

func TestLastReplaysCurrentState(t *testing.T) {
	b := NewBus()
	if _, ok := b.Last(); ok {
		t.Fatal("fresh bus reported a last event")
	}
	b.Publish(StateScanningWiFi, "")
	b.Publish(StateComplete, "alice")
	ev, ok := b.Last()
	if !ok || ev.State != StateComplete {
		t.Fatalf("Last = %+v, %v", ev, ok)
	}
}

func TestCancelStopsDelivery(t *testing.T) {
	b := NewBus()
	ch, cancel := b.Subscribe()
	cancel()
	cancel() // idempotent
	if _, open := <-ch; open {
		t.Fatal("channel still delivering after cancel")
	}
	b.Publish(StateFailed, "") // must not panic on a closed subscriber
}

func TestSlowSubscriberIsDroppedNotBlocking(t *testing.T) {
	b := NewBus()
	_, cancel := b.Subscribe()
	defer cancel()
	done := make(chan struct{})
	go func() {
		for i := 0; i < 1000; i++ {
			b.Publish(StateProvisioning, "")
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Publish blocked on a subscriber that never reads")
	}
}
