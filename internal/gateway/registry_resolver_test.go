package gateway

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"digital.vasic.containers/pkg/health"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/registry"
)

// ---- helpers ---------------------------------------------------------------------

// A registry entry needs a live process whose argv holds the token: this test binary itself.
func selfToken() string { return filepath.Base(os.Args[0]) }

func newReg(t *testing.T) *registry.Registry {
	t.Helper()
	return registry.New(registry.Config{StateDir: t.TempDir(), Strategy: registry.Fixed, RangeLo: 34000, RangeHi: 34099})
}

// backend is a fake llama-server: counts the requests it served and records the bearer it saw.
type backend struct {
	srv  *httptest.Server
	hits atomic.Int64
	auth atomic.Value // string
	port int
}

func newBackend(t *testing.T) *backend {
	t.Helper()
	b := &backend{}
	b.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/props" { // the gateway's ctx probe is not a decision
			http.NotFound(w, r)
			return
		}
		b.hits.Add(1)
		b.auth.Store(r.Header.Get("Authorization"))
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.3}, lpEntry{" the", -0.5}))
	}))
	t.Cleanup(b.srv.Close)
	_, p, _ := net.SplitHostPort(b.srv.Listener.Addr().String())
	b.port, _ = strconv.Atoi(p)
	return b
}

func (b *backend) entry(name, profile, instance, keyFile string) registry.Entry {
	l := map[string]string{registry.LabelKind: KindDecide, registry.LabelProfile: profile}
	if instance != "" {
		l[registry.LabelInstance] = instance
	}
	if keyFile != "" {
		l[registry.LabelKeyFile] = keyFile
	}
	return registry.Entry{Name: name, Host: "127.0.0.1", Port: b.port, Protocol: "http", HealthPath: "/health",
		Labels: l, PID: os.Getpid(), CmdToken: selfToken(), LoopbackOnly: true}
}

func writeKey(t *testing.T, dir, name, key string, mode os.FileMode) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(key+"\n"), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, mode); err != nil {
		t.Fatal(err)
	}
	return p
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// ---- Resolve ---------------------------------------------------------------------

func TestRegistryResolverOrdersPrimaryFirstDeterministically(t *testing.T) {
	reg := newReg(t)
	a, b, c := newBackend(t), newBackend(t), newBackend(t)
	t0 := time.Now()
	// registered in a scrambled order; instance 1 is the primary, then 2, then 10 (numeric, not lexical)
	for _, x := range []struct {
		be   *backend
		name string
		inst string
		at   time.Time
	}{{c, "decide-tiny.10", "10", t0}, {a, "decide-tiny", "1", t0.Add(time.Second)}, {b, "decide-tiny.2", "2", t0.Add(-time.Hour)}} {
		e := x.be.entry(x.name, "decide-tiny", x.inst, "")
		e.Started = x.at
		must(t, reg.Register(e))
	}
	r := NewRegistryResolver(reg, time.Second, "")
	for i := 0; i < 3; i++ { // deterministic: same answer every time
		eps, err := r.Resolve(KindDecide, "decide-tiny")
		must(t, err)
		if len(eps) != 3 || eps[0].URL != a.srv.URL || eps[1].URL != b.srv.URL || eps[2].URL != c.srv.URL {
			t.Fatalf("order %+v want %s,%s,%s", eps, a.srv.URL, b.srv.URL, c.srv.URL)
		}
		if !eps[0].Healthy || eps[0].Instance != "decide-tiny" {
			t.Fatalf("%+v", eps[0])
		}
	}
}

func TestRegistryResolverTieBreaksByStartTimeThenName(t *testing.T) {
	reg := newReg(t)
	a, b := newBackend(t), newBackend(t)
	t0 := time.Now()
	ea, eb := a.entry("x-a", "decide-tiny", "", ""), b.entry("x-b", "decide-tiny", "", "") // no instance label: both rank 1
	ea.Started, eb.Started = t0.Add(time.Second), t0
	must(t, reg.Register(ea))
	must(t, reg.Register(eb))
	eps, _ := NewRegistryResolver(reg, time.Second, "").Resolve(KindDecide, "decide-tiny")
	if len(eps) != 2 || eps[0].URL != b.srv.URL {
		t.Fatalf("the earlier-started instance is primary: %+v", eps)
	}
}

func TestRegistryResolverInstanceFromNameSuffix(t *testing.T) {
	reg := newReg(t)
	a, b := newBackend(t), newBackend(t)
	must(t, reg.Register(b.entry("decide-tiny.2", "decide-tiny", "", "")))
	must(t, reg.Register(a.entry("decide-tiny", "decide-tiny", "", "")))
	eps, _ := NewRegistryResolver(reg, time.Second, "").Resolve(KindDecide, "decide-tiny")
	if len(eps) != 2 || eps[0].URL != a.srv.URL {
		t.Fatalf("name 'decide-tiny' is instance 1, 'decide-tiny.2' instance 2: %+v", eps)
	}
}

func TestRegistryResolverFiltersKindAndProfile(t *testing.T) {
	reg := newReg(t)
	a, b := newBackend(t), newBackend(t)
	must(t, reg.Register(a.entry("decide-tiny", "decide-tiny", "", "")))
	nli := b.entry("decide-nli", "decide-nli", "", "")
	must(t, reg.Register(nli))
	r := NewRegistryResolver(reg, time.Second, "")
	if eps, _ := r.Resolve(KindDecide, "decide-nli"); len(eps) != 1 || eps[0].URL != b.srv.URL {
		t.Fatalf("%+v", eps)
	}
	if eps, err := r.Resolve("gateway", "decide-tiny"); err != nil || len(eps) != 0 {
		t.Fatalf("unknown kind: %+v %v", eps, err)
	}
	if eps, err := r.Resolve(KindDecide, "nope"); err != nil || len(eps) != 0 {
		t.Fatalf("unknown profile is empty, not an error: %+v %v", eps, err)
	}
}

func TestRegistryResolverCarriesKeyFromKeyFile(t *testing.T) {
	reg := newReg(t)
	dir := t.TempDir()
	a, b := newBackend(t), newBackend(t)
	ka := writeKey(t, dir, "ka", "key-of-a", 0o600)
	must(t, reg.Register(a.entry("decide-tiny", "decide-tiny", "1", ka)))
	must(t, reg.Register(b.entry("decide-tiny.2", "decide-tiny", "2", ""))) // no key file: shared fallback
	eps, _ := NewRegistryResolver(reg, time.Second, "shared-key").Resolve(KindDecide, "decide-tiny")
	if len(eps) != 2 || eps[0].Key != "key-of-a" || eps[1].Key != "shared-key" {
		t.Fatalf("per-instance key from the file, shared fallback otherwise: %+v", eps)
	}
	// rotating the file is picked up without a restart
	time.Sleep(10 * time.Millisecond)
	writeKey(t, dir, "ka", "rotated-key-a", 0o600)
	eps, _ = NewRegistryResolver(reg, time.Second, "").Resolve(KindDecide, "decide-tiny")
	if eps[0].Key != "rotated-key-a" {
		t.Fatalf("rotated key not read: %+v", eps[0])
	}
}

func TestRegistryResolverRefusesUnusableKeyFiles(t *testing.T) {
	reg := newReg(t)
	dir := t.TempDir()
	a, b, c := newBackend(t), newBackend(t), newBackend(t)
	loose := writeKey(t, dir, "loose", "k", 0o644)
	must(t, reg.Register(a.entry("decide-tiny", "decide-tiny", "1", loose)))
	must(t, reg.Register(b.entry("decide-tiny.2", "decide-tiny", "2", filepath.Join(dir, "absent"))))
	empty := writeKey(t, dir, "empty", "", 0o600)
	must(t, os.WriteFile(empty, nil, 0o600))
	must(t, reg.Register(c.entry("decide-tiny.3", "decide-tiny", "3", empty)))
	d := newBackend(t)
	real := writeKey(t, dir, "real", "k", 0o600)
	link := filepath.Join(dir, "link")
	must(t, os.Symlink(real, link))
	must(t, reg.Register(d.entry("decide-tiny.4", "decide-tiny", "4", link)))
	eps, _ := NewRegistryResolver(reg, time.Second, "shared").Resolve(KindDecide, "decide-tiny")
	if len(eps) != 4 {
		t.Fatalf("%+v", eps)
	}
	for _, e := range eps {
		if e.Healthy || e.Key != "" {
			t.Fatalf("an instance whose key file is group/world readable, missing or empty must be unhealthy and carry no key (group/world readable, missing, empty, symlink): %+v", e)
		}
	}
}

func TestRegistryResolverRefusesNonLoopbackEndpoints(t *testing.T) {
	reg := newReg(t)
	be := newBackend(t)
	e := be.entry("decide-tiny", "decide-tiny", "", "")
	e.Host = "192.0.2.10" // TEST-NET-1: routable-looking, never loopback
	e.LoopbackOnly = false
	must(t, reg.Register(e))
	eps, err := NewRegistryResolver(reg, time.Second, "").Resolve(KindDecide, "decide-tiny")
	if err != nil || len(eps) != 0 {
		t.Fatalf("a non-loopback engine must never be offered: %+v %v", eps, err)
	}
}

func TestRegistryResolverShowsUnhealthyAsDegradedNotGone(t *testing.T) {
	reg := newReg(t)
	be := newBackend(t)
	must(t, reg.Register(be.entry("decide-tiny", "decide-tiny", "", "")))
	reg.Prober = alwaysSick{}
	_, err := reg.Reconcile(context.Background(), registry.ReconcileOptions{Grace: time.Hour})
	must(t, err)
	eps, _ := NewRegistryResolver(reg, time.Second, "").Resolve(KindDecide, "decide-tiny")
	if len(eps) != 1 || eps[0].Healthy {
		t.Fatalf("unhealthy entry is listed as unhealthy: %+v", eps)
	}
}

// ---- Watch: re-resolve without a restart ---------------------------------------------

func TestRegistryResolverFollowsWatchWithoutRestart(t *testing.T) {
	reg := newReg(t)
	be := newBackend(t)
	r := NewRegistryResolver(reg, 20*time.Millisecond, "")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	must(t, r.Start(ctx))
	defer r.Close()
	if eps, _ := r.Resolve(KindDecide, "decide-tiny"); len(eps) != 0 {
		t.Fatalf("starts empty: %+v", eps)
	}
	must(t, reg.Register(be.entry("decide-tiny", "decide-tiny", "", "")))
	waitFor(t, "resolver sees the new instance", func() bool {
		eps, _ := r.Resolve(KindDecide, "decide-tiny")
		return len(eps) == 1 && eps[0].Healthy
	})
	_, err := reg.Unregister("decide-tiny")
	must(t, err)
	waitFor(t, "resolver drops the removed instance", func() bool {
		eps, _ := r.Resolve(KindDecide, "decide-tiny")
		return len(eps) == 0
	})
}

func TestRegistryResolverCloseStopsTheWatch(t *testing.T) {
	reg := newReg(t)
	r := NewRegistryResolver(reg, 10*time.Millisecond, "")
	must(t, r.Start(context.Background()))
	r.Close()
	r.Close() // idempotent
	be := newBackend(t)
	must(t, reg.Register(be.entry("decide-tiny", "decide-tiny", "", "")))
	// after Close the resolver falls back to direct reads, never to a frozen stale cache
	eps, _ := r.Resolve(KindDecide, "decide-tiny")
	if len(eps) != 1 {
		t.Fatalf("closed resolver must still answer correctly: %+v", eps)
	}
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for: %s", what)
}

type alwaysSick struct{}

func (alwaysSick) Check(_ context.Context, tg health.HealthTarget) *health.HealthResult {
	return &health.HealthResult{Target: tg.Name, Healthy: false, Error: "sick"}
}

// ---- integration: real registry state in a temp dir, fake backends --------------------

func TestGatewayRoutesViaRegistryAndFollowsItsChanges(t *testing.T) {
	reg := newReg(t)
	dir := t.TempDir()
	primary, secondary := newBackend(t), newBackend(t)
	k1 := writeKey(t, dir, "k1", "key-one", 0o600)
	k2 := writeKey(t, dir, "k2", "key-two", 0o600)

	const interval = 25 * time.Millisecond
	res := NewRegistryResolver(reg, interval, "")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	must(t, res.Start(ctx))
	defer res.Close()
	rt := newRouterWith(t, res)

	decide := func() error {
		_, _, err := rt.Decide(context.Background(), parseFor(t, noulBody))
		return err
	}
	assert503 := func(why string) {
		t.Helper()
		c := ce(t, decide())
		if c.Status != http.StatusServiceUnavailable {
			t.Fatalf("%s: want 503 not_ready, got %+v", why, c)
		}
	}

	// nothing registered: not ready
	if rt.Ready() || len(rt.Models()) != 0 {
		t.Fatal("an empty registry means no models and not ready")
	}
	assert503("empty registry")

	// start two instances
	must(t, reg.Register(primary.entry("decide-tiny", "decide-tiny", "1", k1)))
	must(t, reg.Register(secondary.entry("decide-tiny.2", "decide-tiny", "2", k2)))
	waitFor(t, "router ready and listing the model", func() bool { return rt.Ready() && len(rt.Models()) == 1 })
	if m := rt.Models()[0]; m.ID != "decide-tiny" || m.Status != "ready" {
		t.Fatalf("%+v", m)
	}

	// routes to the primary with the primary's own key
	for i := 0; i < 3; i++ {
		must(t, decide())
	}
	if primary.hits.Load() != 3 || secondary.hits.Load() != 0 {
		t.Fatalf("deterministic routing must use the primary: primary=%d secondary=%d", primary.hits.Load(), secondary.hits.Load())
	}
	if got, _ := primary.auth.Load().(string); got != "Bearer key-one" {
		t.Fatalf("the primary must be called with its own key file's key, got %q", got)
	}

	// kill the primary's entry: the other one serves within one interval (+ slack), no restart
	_, err := reg.Unregister("decide-tiny")
	must(t, err)
	waitFor(t, "traffic moves to the second instance", func() bool {
		before := secondary.hits.Load()
		return decide() == nil && secondary.hits.Load() > before
	})
	if got, _ := secondary.auth.Load().(string); got != "Bearer key-two" {
		t.Fatalf("the second instance must be called with its own key, got %q", got)
	}
	pHits := primary.hits.Load()
	for i := 0; i < 3; i++ {
		must(t, decide())
	}
	if primary.hits.Load() != pHits {
		t.Fatal("a removed instance must receive no traffic")
	}

	// a primary that comes back is primary again (lowest instance number) with no restart
	must(t, reg.Register(primary.entry("decide-tiny", "decide-tiny", "1", k1)))
	waitFor(t, "returned primary serves again", func() bool {
		before := primary.hits.Load()
		return decide() == nil && primary.hits.Load() > before
	})

	// remove everything: 503 not_ready and an empty model list
	for _, n := range []string{"decide-tiny", "decide-tiny.2"} {
		_, err := reg.Unregister(n)
		must(t, err)
	}
	waitFor(t, "router notices the empty registry", func() bool { return !rt.Ready() && len(rt.Models()) == 0 })
	assert503("all instances removed")
}

func newRouterWith(t *testing.T, res Resolver) *Router {
	t.Helper()
	rt, err := NewRouter(RouterConfig{Specs: testSpecs(), Resolver: res, Mode: Deterministic, Concurrency: 1,
		Profiles: testProfiles(t), Drivers: DefaultDrivers(Deterministic, false)})
	if err != nil {
		t.Fatal(err)
	}
	return rt
}

var _ = contract.DefaultLimits
