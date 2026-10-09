package gateway

import (
	"errors"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

func TestStaticResolverResolve(t *testing.T) {
	r := NewStaticResolver()
	r.Set(KindDecide, "decide-tiny", Endpoint{URL: "http://127.0.0.1:1", Key: "k", Healthy: true}, Endpoint{URL: "http://127.0.0.1:2", Healthy: false})
	eps, err := r.Resolve(KindDecide, "decide-tiny")
	if err != nil || len(eps) != 2 || eps[0].URL != "http://127.0.0.1:1" || eps[1].Healthy {
		t.Fatalf("%v %v", eps, err)
	}
	eps[0].URL = "mutated"
	again, _ := r.Resolve(KindDecide, "decide-tiny")
	if again[0].URL == "mutated" {
		t.Fatal("Resolve must return a copy")
	}
	none, err := r.Resolve(KindDecide, "absent")
	if err != nil || len(none) != 0 {
		t.Fatalf("unknown profile is an empty list, got %v %v", none, err)
	}
}

func TestStaticResolverFromEnv(t *testing.T) {
	env := map[string]string{
		"LLMCTL_DECIDE_ENDPOINT_DECIDE_TINY": "http://127.0.0.1:9101, http://127.0.0.1:9102",
	}
	specs := testSpecs()
	r := StaticResolverFromEnv(specs, func(k string) string { return env[k] })
	eps, _ := r.Resolve(KindDecide, "decide-tiny")
	if len(eps) != 2 || eps[1].URL != "http://127.0.0.1:9102" || eps[0].Key != "" || !eps[0].Healthy {
		t.Fatalf("%+v", eps)
	}
	// profile without an env var falls back to its catalog port on loopback
	nli, _ := r.Resolve(KindDecide, "decide-nli")
	if len(nli) != 1 || nli[0].URL != "http://127.0.0.1:8096" {
		t.Fatalf("%+v", nli)
	}
}

func TestPortVarName(t *testing.T) {
	if got := PortVar("decide-nli"); got != "LLMCTL_PORT_DECIDE_NLI" {
		t.Fatal(got)
	}
}

// LLMCTL_PORT_<PROFILE> (the bash side's host-local rebind) must move the static fallback; an explicit
// LLMCTL_DECIDE_ENDPOINT_<PROFILE> still wins; invalid values are ignored (catalog port) and never panic.
func TestStaticResolverFromEnvHonoursPortOverride(t *testing.T) {
	specs := testSpecs() // decide-nli has catalog port 8096
	url := func(env map[string]string) string {
		r := StaticResolverFromEnv(specs, func(k string) string { return env[k] })
		eps, _ := r.Resolve(KindDecide, "decide-nli")
		if len(eps) != 1 {
			t.Fatalf("%v: %+v", env, eps)
		}
		return eps[0].URL
	}
	if got := url(map[string]string{"LLMCTL_PORT_DECIDE_NLI": "18096"}); got != "http://127.0.0.1:18096" {
		t.Errorf("port override ignored: %s", got)
	}
	if got := url(map[string]string{"LLMCTL_PORT_DECIDE_NLI": " 18096 "}); got != "http://127.0.0.1:18096" {
		t.Errorf("padded override: %s", got)
	}
	if got := url(map[string]string{"LLMCTL_PORT_DECIDE_NLI": "18096", "LLMCTL_DECIDE_ENDPOINT_DECIDE_NLI": "http://127.0.0.1:9999"}); got != "http://127.0.0.1:9999" {
		t.Errorf("endpoint var must win over port override: %s", got)
	}
	for _, bad := range []string{"abc", "0", "-5", "65536", "99999999999999999999", "80.5", "auto", ""} {
		if got := url(map[string]string{"LLMCTL_PORT_DECIDE_NLI": bad}); got != "http://127.0.0.1:8096" {
			t.Errorf("invalid override %q must fall back to the catalog port, got %s", bad, got)
		}
	}
	if got := url(map[string]string{"LLMCTL_PORT_DECIDE_NLI": "65535"}); got != "http://127.0.0.1:65535" {
		t.Errorf("upper bound: %s", got)
	}
	if got := url(map[string]string{"LLMCTL_PORT_DECIDE_NLI": "1"}); got != "http://127.0.0.1:1" {
		t.Errorf("lower bound: %s", got)
	}
}

// A profile with no catalog port (0) and no usable override must resolve to NO endpoint, never to
// "http://127.0.0.1:0"; the `port > 0` guard in StaticResolverFromEnv is what guarantees it.
func TestStaticResolverFromEnvPortlessProfileHasNoEndpoint(t *testing.T) {
	specs := []ProfileSpec{{ID: "decide-portless", Port: 0}}
	for _, env := range []map[string]string{nil, {"LLMCTL_PORT_DECIDE_PORTLESS": "auto"}, {"LLMCTL_PORT_DECIDE_PORTLESS": "0"}} {
		r := StaticResolverFromEnv(specs, func(k string) string { return env[k] })
		eps, err := r.Resolve(KindDecide, "decide-portless")
		if err != nil || len(eps) != 0 {
			t.Errorf("env %v: portless profile with no override must have no endpoint, got %+v (err %v)", env, eps, err)
		}
	}
	// control: a valid override on the same portless profile does create one
	r := StaticResolverFromEnv(specs, func(k string) string { return map[string]string{"LLMCTL_PORT_DECIDE_PORTLESS": "18100"}[k] })
	eps, _ := r.Resolve(KindDecide, "decide-portless")
	if len(eps) != 1 || eps[0].URL != "http://127.0.0.1:18100" {
		t.Errorf("valid override on a portless profile: %+v", eps)
	}
}

func TestEnvVarName(t *testing.T) {
	if got := EndpointVar("decide-tiny"); got != "LLMCTL_DECIDE_ENDPOINT_DECIDE_TINY" {
		t.Fatal(got)
	}
}

func TestLoopbackOnly(t *testing.T) {
	ok := []string{"http://127.0.0.1:8092", "http://localhost:1", "http://[::1]:5/x", "https://127.0.0.1:1"}
	bad := []string{"http://10.0.0.5:1", "http://example.com", "ftp://127.0.0.1", "127.0.0.1:1", "", "http://0.0.0.0:1", "http://user@127.0.0.1:1"}
	for _, u := range ok {
		if err := checkLoopback(u); err != nil {
			t.Errorf("%s must be accepted: %v", u, err)
		}
	}
	for _, u := range bad {
		if err := checkLoopback(u); err == nil {
			t.Errorf("%q must be refused", u)
		}
	}
}

func TestProbeResolverMarksUnreachableUnhealthy(t *testing.T) {
	srv, _ := fakeServer(t, func(*recorded, http.ResponseWriter) {})
	dead := "http://127.0.0.1:1" // nothing listens on port 1
	in := NewStaticResolver()
	in.Set(KindDecide, "p", Endpoint{URL: srv.URL, Healthy: true}, Endpoint{URL: dead, Healthy: true}, Endpoint{URL: srv.URL + "x", Healthy: false})
	now := time.Unix(1000, 0)
	pr := NewProbeResolver(in, 200*time.Millisecond, time.Second)
	pr.now = func() time.Time { return now }
	eps, err := pr.Resolve(KindDecide, "p")
	if err != nil || len(eps) != 3 {
		t.Fatalf("%v %v", eps, err)
	}
	if !eps[0].Healthy || eps[1].Healthy || eps[2].Healthy {
		t.Fatalf("health: %+v", eps)
	}
}

func TestProbeResolverCachesWithinTTL(t *testing.T) {
	var dials atomic.Int32
	in := NewStaticResolver()
	in.Set(KindDecide, "p", Endpoint{URL: "http://127.0.0.1:2", Healthy: true})
	pr := NewProbeResolver(in, 100*time.Millisecond, time.Second)
	now := time.Unix(1000, 0)
	pr.now = func() time.Time { return now }
	pr.dial = func(network, addr string, d time.Duration) (net.Conn, error) {
		dials.Add(1)
		return nil, errors.New("down")
	}
	for i := 0; i < 5; i++ {
		_, _ = pr.Resolve(KindDecide, "p")
	}
	if dials.Load() != 1 {
		t.Fatalf("probe not cached: %d dials", dials.Load())
	}
	now = now.Add(2 * time.Second)
	_, _ = pr.Resolve(KindDecide, "p")
	if dials.Load() != 2 {
		t.Fatalf("probe must refresh after the TTL: %d", dials.Load())
	}
}

func TestProbeResolverPropagatesInnerError(t *testing.T) {
	pr := NewProbeResolver(errResolver{}, time.Second, time.Second)
	if _, err := pr.Resolve(KindDecide, "p"); err == nil {
		t.Fatal("inner error must surface")
	}
}

type errResolver struct{}

func (errResolver) Resolve(string, string) ([]Endpoint, error) { return nil, errors.New("boom") }
