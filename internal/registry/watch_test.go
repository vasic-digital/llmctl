package registry

import (
	"context"
	"testing"
	"time"
)

func recv(t *testing.T, ch <-chan Snapshot, d time.Duration) (Snapshot, bool) {
	t.Helper()
	select {
	case s, ok := <-ch:
		return s, ok
	case <-time.After(d):
		return Snapshot{}, false
	}
}

func names(s Snapshot) []string {
	var n []string
	for _, e := range s.Entries {
		n = append(n, e.Name)
	}
	return n
}

func TestWatchEmitsInitialThenChangesOnly(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := r.Watch(ctx, 20*time.Millisecond)

	s0, ok := recv(t, ch, time.Second)
	if !ok || len(s0.Entries) != 0 {
		t.Fatalf("initial empty snapshot expected: %v %+v", ok, s0)
	}
	// nothing changes: nothing is emitted
	if s, got := recv(t, ch, 200*time.Millisecond); got {
		t.Fatalf("spurious snapshot %+v", s)
	}

	_, a := startSvc(t, "a", false)
	_ = New(cfg).Register(a) // a different handle = another process
	s1, ok := recv(t, ch, 2*time.Second)
	if !ok || len(s1.Entries) != 1 || s1.Entries[0].Name != "a" || s1.Seq <= s0.Seq {
		t.Fatalf("registration not announced: %v %+v", ok, s1)
	}

	// a health flip changes what is routable: announced
	_ = r.markHealth("a", false, time.Now())
	s2, ok := recv(t, ch, 2*time.Second)
	if !ok || len(s2.Entries) != 1 || s2.Entries[0].Healthy {
		t.Fatalf("health flip not announced: %v %+v", ok, s2)
	}

	// the heartbeat-only rewrite (same content, new timestamps) is not a change
	_ = r.markHealth("a", false, time.Now().Add(time.Second))
	if s, got := recv(t, ch, 200*time.Millisecond); got {
		t.Fatalf("timestamp-only rewrite announced: %+v", s)
	}

	_, _ = r.Unregister("a")
	s3, ok := recv(t, ch, 2*time.Second)
	if !ok || len(s3.Entries) != 0 {
		t.Fatalf("removal not announced: %v %+v", ok, s3)
	}
}

func TestWatchStopsAndClosesOnCancel(t *testing.T) {
	r := New(testCfg(t))
	ctx, cancel := context.WithCancel(context.Background())
	ch := r.Watch(ctx, 10*time.Millisecond)
	_, _ = recv(t, ch, time.Second)
	cancel()
	deadline := time.After(2 * time.Second)
	for {
		select {
		case _, ok := <-ch:
			if !ok {
				return
			}
		case <-deadline:
			t.Fatal("channel not closed after cancel")
		}
	}
}

func TestWatchSlowConsumerGetsLatest(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := r.Watch(ctx, 10*time.Millisecond)
	_, _ = recv(t, ch, time.Second)
	for _, n := range []string{"x", "y", "z"} {
		_, e := startSvc(t, n, false)
		_ = r.Register(e)
		time.Sleep(50 * time.Millisecond) // consumer is not reading
	}
	var last Snapshot
	for {
		s, ok := recv(t, ch, 300*time.Millisecond)
		if !ok {
			break
		}
		last = s
	}
	if len(last.Entries) != 3 {
		t.Fatalf("slow consumer must converge on the latest state, got %v", names(last))
	}
}

func TestRunReconcilerRemovesKilledServiceWithinTheInterval(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	p, e := startSvc(t, "victim", false)
	_ = r.Register(e)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := r.Watch(ctx, 20*time.Millisecond)
	_, _ = recv(t, ch, time.Second)
	interval := 100 * time.Millisecond
	go r.RunReconciler(ctx, interval, ReconcileOptions{Grace: time.Minute})
	time.Sleep(3 * interval)
	if l, _ := r.List(); len(l) != 1 {
		t.Fatalf("healthy service disappeared: %+v", l)
	}
	killed := time.Now()
	p.kill()
	for {
		s, ok := recv(t, ch, 3*time.Second)
		if !ok {
			t.Fatal("removal never announced")
		}
		if len(s.Entries) == 0 {
			if d := time.Since(killed); d > 3*interval {
				t.Fatalf("removal took %v (> 3 health intervals of %v)", d, interval)
			}
			return
		}
	}
}
