package registry

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func waitFor(t *testing.T, d time.Duration, what string, cond func() bool) {
	t.Helper()
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// G-057: one registry, two gateways, exactly one reconciler - and the role is proven by flock.
func TestOnlyOneOwnedReconcilerPerRegistry(t *testing.T) {
	cfg := testCfg(t)
	var n1, n2 atomic.Int64
	a, b := New(cfg), New(cfg) // two handles = two gateway processes' registries
	a.OnReconcilePass = func() { n1.Add(1) }
	b.OnReconcilePass = func() { n2.Add(1) }
	ctx1, cancel1 := context.WithCancel(context.Background())
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); a.RunOwnedReconciler(ctx1, 10*time.Millisecond, ReconcileOptions{}) }()
	waitFor(t, 3*time.Second, "first reconciler to pass", func() bool { return n1.Load() >= 2 })
	go func() { defer wg.Done(); b.RunOwnedReconciler(ctx2, 10*time.Millisecond, ReconcileOptions{}) }()

	time.Sleep(300 * time.Millisecond) // plenty of intervals for a second reconciler to (wrongly) run
	if n2.Load() != 0 || b.OwnsReconciler() || !a.OwnsReconciler() {
		t.Fatalf("exactly one reconciler: first passes=%d second passes=%d, owner a=%v b=%v", n1.Load(), n2.Load(), a.OwnsReconciler(), b.OwnsReconciler())
	}

	// the owner stops (drain / death): the lock is released and the standby takes over
	cancel1()
	waitFor(t, 3*time.Second, "the standby to take over", func() bool { return n2.Load() >= 2 && b.OwnsReconciler() })
	if a.OwnsReconciler() {
		t.Fatal("a stopped reconciler must not claim the role")
	}
	cancel2()
	wg.Wait()
	if b.OwnsReconciler() {
		t.Fatal("the role is released when the reconciler stops")
	}
}

// G-057: health flags are written without any external reconcile call - a killed engine goes
// unhealthy, then is removed once the grace has passed.
func TestOwnedReconcilerMarksThenRemovesDeadEngine(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	live, le := startSvc(t, "alive", false)
	dead, de := startSvc(t, "doomed", false)
	_, se := startSvc(t, "sick", true) // alive, but /health answers 500
	for _, e := range []Entry{le, de, se} {
		if err := r.Register(e); err != nil {
			t.Fatal(err)
		}
	}
	gw := New(cfg) // the gateway's own handle: nothing else calls reconcile in this test
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		gw.RunOwnedReconciler(ctx, 20*time.Millisecond, ReconcileOptions{Grace: 400 * time.Millisecond})
		close(done)
	}()

	waitFor(t, 3*time.Second, "the healthy engines routable", func() bool {
		es, _ := r.Resolve(nil)
		return len(es) >= 2
	})
	// the sick one: flagged unhealthy first (with the unhealthy clock running) ...
	waitFor(t, 3*time.Second, "sick to be flagged unhealthy", func() bool {
		e, ok, _ := r.Get("sick")
		return ok && !e.Healthy && !e.UnhealthySince.IsZero()
	})
	// a live process whose port stops answering is unhealthy first (health flag flips) ...
	dead.kill()
	waitFor(t, 3*time.Second, "doomed to go not-routable", func() bool {
		es, _ := r.Resolve(nil)
		return len(es) == 1 && es[0].Name == "alive"
	})
	// ... and both are removed by the reconciler itself (no external reconcile call anywhere)
	waitFor(t, 5*time.Second, "doomed and sick to be removed", func() bool {
		_, ok1, _ := r.Get("doomed")
		_, ok2, _ := r.Get("sick")
		return !ok1 && !ok2
	})
	if _, ok, _ := r.Get("alive"); !ok || !live.alive() {
		t.Fatal("the healthy engine must be untouched")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the reconciler must stop when its context ends")
	}
}
