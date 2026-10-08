package main

import (
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/gateway"
)

// B3-03: an explicit empty --model / --profile is a usage error, never the gateway default.
func TestAskExplicitEmptyModelOrProfileIsAUsageError(t *testing.T) {
	for _, flagName := range []string{"--model", "--profile"} {
		r := newAskRig(t)
		args := append(append([]string{}, askChoiceArgs...), flagName, "", "--dry-run")
		rc, _, e := r.run("", args...)
		if rc != 2 || !strings.Contains(e, "model") {
			t.Fatalf("%s \"\": rc=%d err=%q (want a usage error naming the model)", flagName, rc, e)
		}
		// a named profile and an absent flag still work
		rc, _, e = r.run("", append(append([]string{}, askChoiceArgs...), flagName, "decide-tiny", "--dry-run")...)
		if rc != 0 {
			t.Fatalf("%s decide-tiny: rc=%d %s", flagName, rc, e)
		}
	}
}

type slowResolver struct {
	gateway.Resolver
	d time.Duration
}

func (s slowResolver) Resolve(k, p string) ([]gateway.Endpoint, error) {
	time.Sleep(s.d)
	return s.Resolver.Resolve(k, p)
}

// B3-09: auto decides per profile; a profile served only statically survives a registered sibling,
// an unhealthy registry entry falls back to the static endpoint, and no lock is held across I/O.
func TestAutoResolverDecidesPerProfileWithoutALockAroundIO(t *testing.T) {
	regs, stat := gateway.NewStaticResolver(), gateway.NewStaticResolver()
	regs.Set("decide", "x", gateway.Endpoint{URL: "http://127.0.0.1:1", Healthy: true, Instance: "reg-x"})
	regs.Set("decide", "z", gateway.Endpoint{URL: "http://127.0.0.1:2", Healthy: false, Instance: "reg-z"})
	stat.Set("decide", "x", gateway.Endpoint{URL: "http://127.0.0.1:11", Healthy: true, Instance: "static-x"})
	stat.Set("decide", "y", gateway.Endpoint{URL: "http://127.0.0.1:12", Healthy: true, Instance: "static-y"})
	stat.Set("decide", "z", gateway.Endpoint{URL: "http://127.0.0.1:13", Healthy: true, Instance: "static-z"})
	a := &autoResolver{static: stat, registry: slowResolver{regs, 150 * time.Millisecond}, every: time.Second}
	for prof, want := range map[string]string{"x": "reg-x", "y": "static-y", "z": "static-z"} {
		eps, err := a.Resolve("decide", prof)
		if err != nil || len(eps) == 0 || eps[0].Instance != want {
			t.Fatalf("profile %s: got %+v %v, want %s", prof, eps, err, want)
		}
	}
	start := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = a.Resolve("decide", "x") }()
	}
	wg.Wait()
	if d := time.Since(start); d > 450*time.Millisecond {
		t.Fatalf("6 concurrent resolves took %v: requests are serialised behind the registry read", d)
	}
}
