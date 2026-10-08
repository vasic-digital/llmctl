package gateway

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/server"
)

// fakeDriver records which endpoint served each call (unit tier only).
type fakeDriver struct {
	mu      sync.Mutex
	served  []string
	hold    chan struct{}
	entered chan string
	err     error
}

func (f *fakeDriver) Decide(ctx context.Context, e Endpoint, s ProfileSpec, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
	f.mu.Lock()
	f.served = append(f.served, e.URL)
	f.mu.Unlock()
	if f.entered != nil {
		f.entered <- e.URL
	}
	if f.hold != nil {
		select {
		case <-f.hold:
		case <-ctx.Done():
			return nil, contract.Usage{}, ctx.Err()
		}
	}
	if f.err != nil {
		return nil, contract.Usage{}, f.err
	}
	var out []contract.NamedAnswer
	for _, q := range r.Questions {
		p := make([]float64, len(q.Options))
		for i := range p {
			p[i] = 1 / float64(len(q.Options))
		}
		a, _ := contract.BuildAnswer(q, p)
		out = append(out, contract.NamedAnswer{Name: q.Name, Answer: a})
	}
	return out, contract.Usage{InputTokens: 1, OutputTokens: 1}, nil
}

func newRouter(t *testing.T, res Resolver, mode Mode, d Driver, conc int) *Router {
	t.Helper()
	r, err := NewRouter(RouterConfig{
		Specs: testSpecs(), Resolver: res, Mode: mode, Concurrency: conc, NativeEnabled: false, Profiles: testProfiles(t),
		Drivers: map[string]Driver{ProtoLetter: d, ProtoNLI: d, ProtoNative: d},
	})
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func two(res *StaticResolver) {
	res.Set(KindDecide, "decide-tiny", Endpoint{URL: "http://127.0.0.1:1", Healthy: true}, Endpoint{URL: "http://127.0.0.1:2", Healthy: true})
}

var _ server.Backend = (*Router)(nil)

func TestRouterDeterministicUsesPrimary(t *testing.T) {
	res := NewStaticResolver()
	two(res)
	d := &fakeDriver{}
	r := newRouter(t, res, Deterministic, d, 1)
	for i := 0; i < 5; i++ {
		if _, _, err := r.Decide(context.Background(), parseFor(t, noulBody)); err != nil {
			t.Fatal(err)
		}
	}
	for _, u := range d.served {
		if u != "http://127.0.0.1:1" {
			t.Fatalf("deterministic mode must serve from the primary: %v", d.served)
		}
	}
}

func TestRouterDeterministicOverflowsOnlyWhenPrimarySaturated(t *testing.T) {
	res := NewStaticResolver()
	two(res)
	d := &fakeDriver{hold: make(chan struct{}), entered: make(chan string, 4)}
	r := newRouter(t, res, Deterministic, d, 1)
	var wg sync.WaitGroup
	wg.Add(2)
	for i := 0; i < 2; i++ {
		go func() { defer wg.Done(); _, _, _ = r.Decide(context.Background(), parseFor(t, noulBody)) }()
		<-d.entered // sequential so the first occupies the primary before the second arrives
	}
	d.mu.Lock()
	got := append([]string(nil), d.served...)
	d.mu.Unlock()
	if got[0] != "http://127.0.0.1:1" || got[1] != "http://127.0.0.1:2" {
		t.Fatalf("overflow order %v", got)
	}
	close(d.hold)
	wg.Wait()
}

func TestRouterThroughputLeastLoaded(t *testing.T) {
	res := NewStaticResolver()
	two(res)
	d := &fakeDriver{hold: make(chan struct{}), entered: make(chan string, 4)}
	r := newRouter(t, res, Throughput, d, 4)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _, _ = r.Decide(context.Background(), parseFor(t, noulBody)) }()
		<-d.entered
	}
	count := map[string]int{}
	d.mu.Lock()
	for _, u := range d.served {
		count[u]++
	}
	d.mu.Unlock()
	if count["http://127.0.0.1:1"] != 2 || count["http://127.0.0.1:2"] != 2 {
		t.Fatalf("least-loaded must spread evenly: %v", count)
	}
	close(d.hold)
	wg.Wait()
}

func TestRouterSkipsUnhealthyAndNoReady503(t *testing.T) {
	res := NewStaticResolver()
	res.Set(KindDecide, "decide-tiny", Endpoint{URL: "http://127.0.0.1:1", Healthy: false}, Endpoint{URL: "http://127.0.0.1:2", Healthy: true})
	d := &fakeDriver{}
	r := newRouter(t, res, Deterministic, d, 1)
	if _, _, err := r.Decide(context.Background(), parseFor(t, noulBody)); err != nil {
		t.Fatal(err)
	}
	if d.served[0] != "http://127.0.0.1:2" {
		t.Fatalf("%v", d.served)
	}
	res.Set(KindDecide, "decide-tiny", Endpoint{URL: "http://127.0.0.1:1", Healthy: false})
	_, _, err := r.Decide(context.Background(), parseFor(t, noulBody))
	c := ce(t, err)
	if c.Status != 503 || c.ErrorType != contract.ErrTypeNotReady || c.Headers["Retry-After"] == "" {
		t.Fatalf("%+v", c)
	}
	res.Set(KindDecide, "decide-tiny") // no instance at all
	_, _, err = r.Decide(context.Background(), parseFor(t, noulBody))
	if c := ce(t, err); c.Status != 503 {
		t.Fatalf("%+v", c)
	}
}

func TestRouterNativeDisabledGivesNotReadyAndNotListed(t *testing.T) {
	res := NewStaticResolver()
	res.Set(KindDecide, "decide-laya", Endpoint{URL: "http://127.0.0.1:3", Healthy: true})
	d := &fakeDriver{}
	r := newRouter(t, res, Deterministic, d, 1)
	req := parseFor(t, `{"model":"decide-laya","state":"s","questions":{"q":{"type":"noul","instructions":"i"}}}`)
	_, _, err := r.Decide(context.Background(), req)
	if c := ce(t, err); c.Status != 503 {
		t.Fatalf("engine advance gate OD-1: native stays disabled: %+v", c)
	}
	if r.Ready() {
		t.Fatal("a disabled native profile must not make the gateway ready")
	}
	if len(d.served) != 0 {
		t.Fatal("must not call the engine")
	}
	r2, err2 := NewRouter(RouterConfig{Specs: testSpecs(), Resolver: res, Concurrency: 1, NativeEnabled: true,
		Drivers: map[string]Driver{ProtoLetter: d, ProtoNLI: d, ProtoNative: d}})
	if err2 != nil {
		t.Fatal(err2)
	}
	if !r2.Ready() {
		t.Fatal("enabled native profile is ready")
	}
}

func TestRouterModelsAndReady(t *testing.T) {
	res := NewStaticResolver()
	r := newRouter(t, res, Deterministic, &fakeDriver{}, 1)
	if r.Ready() || len(r.Models()) != 0 {
		t.Fatal("empty registry: not ready, no models")
	}
	res.Set(KindDecide, "decide-tiny", Endpoint{URL: "http://127.0.0.1:1", Healthy: true})
	res.Set(KindDecide, "decide-nli", Endpoint{URL: "http://127.0.0.1:4", Healthy: false})
	if !r.Ready() {
		t.Fatal("one healthy profile is enough")
	}
	ms := r.Models()
	if len(ms) != 2 {
		t.Fatalf("%+v", ms)
	}
	by := map[string]server.ModelInfo{}
	for _, m := range ms {
		by[m.ID] = m
	}
	tiny := by["decide-tiny"]
	if tiny.Status != "ready" || tiny.Protocol != ProtoLetter || tiny.MaxOptions != 20 || tiny.ScoreLevels != [2]int{2, 10} {
		t.Fatalf("%+v", tiny)
	}
	hasAlias := false
	for _, a := range tiny.Aliases {
		if a == "jev-latest" {
			hasAlias = true
		}
	}
	if !hasAlias || by["decide-nli"].Status != "degraded" {
		t.Fatalf("%+v %+v", tiny, by["decide-nli"])
	}
}

func TestRouterPassesThroughDriverErrors(t *testing.T) {
	res := NewStaticResolver()
	two(res)
	boom := errors.New("engine exploded")
	r := newRouter(t, res, Deterministic, &fakeDriver{err: boom}, 1)
	if _, _, err := r.Decide(context.Background(), parseFor(t, noulBody)); !errors.Is(err, boom) {
		t.Fatalf("%v", err)
	}
}

func TestRouterSlotsReleasedOnError(t *testing.T) {
	res := NewStaticResolver()
	res.Set(KindDecide, "decide-tiny", Endpoint{URL: "http://127.0.0.1:1", Healthy: true})
	d := &fakeDriver{err: errors.New("x")}
	r := newRouter(t, res, Deterministic, d, 1)
	for i := 0; i < 3; i++ {
		_, _, _ = r.Decide(context.Background(), parseFor(t, noulBody))
	}
	d.err = nil
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, _, err := r.Decide(ctx, parseFor(t, noulBody)); err != nil {
		t.Fatalf("slot leaked: %v", err)
	}
}

func TestRouterSaturatedWaitsThenOverloaded(t *testing.T) {
	res := NewStaticResolver()
	res.Set(KindDecide, "decide-tiny", Endpoint{URL: "http://127.0.0.1:1", Healthy: true})
	d := &fakeDriver{hold: make(chan struct{}), entered: make(chan string, 2)}
	r := newRouter(t, res, Deterministic, d, 1)
	go func() { _, _, _ = r.Decide(context.Background(), parseFor(t, noulBody)) }()
	<-d.entered
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, _, err := r.Decide(ctx, parseFor(t, noulBody))
	if c := ce(t, err); c.Status != 529 || c.ErrorType != contract.ErrTypeOverloaded {
		t.Fatalf("%+v", c)
	}
	close(d.hold)
}

func TestRouterRaceFree(t *testing.T) {
	res := NewStaticResolver()
	two(res)
	var n atomic.Int32
	d := &fakeDriver{}
	r := newRouter(t, res, Throughput, d, 4)
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, _, err := r.Decide(context.Background(), parseFor(t, noulBody)); err == nil {
				n.Add(1)
			}
			_ = r.Models()
			_ = r.Ready()
		}()
	}
	wg.Wait()
	if n.Load() != 32 {
		t.Fatalf("ok=%d", n.Load())
	}
}

func TestNewRouterValidation(t *testing.T) {
	if _, err := NewRouter(RouterConfig{}); err == nil {
		t.Fatal("empty config must fail")
	}
	if _, err := NewRouter(RouterConfig{Specs: testSpecs(), Resolver: NewStaticResolver(), Concurrency: 1}); err == nil {
		t.Fatal("no drivers must fail")
	}
}

func TestDefaultDriversAndMode(t *testing.T) {
	d := DefaultDrivers(Deterministic, false)
	if d[ProtoLetter] == nil || d[ProtoNLI] == nil || d[ProtoNative] == nil {
		t.Fatal("all three protocols have a driver")
	}
	if m, err := ParseMode(""); err != nil || m != Deterministic {
		t.Fatal("default deterministic")
	}
	if m, _ := ParseMode("throughput"); m != Throughput {
		t.Fatal()
	}
	if _, err := ParseMode("turbo"); err == nil {
		t.Fatal("unknown mode")
	}
}
