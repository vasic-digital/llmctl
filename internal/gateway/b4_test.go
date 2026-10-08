package gateway

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
)

func resetProps(t *testing.T) {
	t.Helper()
	clear := func() {
		propsMu.Lock()
		propsCache = map[string]propsEntry{}
		propsMu.Unlock()
		propsNow = time.Now
	}
	clear()
	t.Cleanup(clear)
}

// countingProps serves /props (n_ctx = *n; 404 when *n == 0) and counts the reads; every other path
// is a letter completion (counted in chat).
func countingProps(t *testing.T, n *atomic.Int64, hits, chat *atomic.Int64, delay time.Duration) *recordedServer {
	t.Helper()
	return newRecordedServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/props" {
			hits.Add(1)
			time.Sleep(delay)
			if n.Load() == 0 {
				http.NotFound(w, r)
				return
			}
			_, _ = w.Write([]byte(fmt.Sprintf(`{"default_generation_settings":{"n_ctx":%d}}`, n.Load())))
			return
		}
		chat.Add(1)
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.3}))
	})
}

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

// B3-04 / B3-10 (M2, M3): positive entries expire (propsTTL), negative ones sooner (propsNegativeTTL).
func TestPropsCacheTTLs(t *testing.T) {
	resetProps(t)
	var n, hits, chat atomic.Int64
	n.Store(2048)
	srv := countingProps(t, &n, &hits, &chat, 0)
	clk := &fakeClock{t: time.Unix(1_000_000, 0)}
	propsNow = clk.now
	e := ep(srv.URL)
	if got, ok := engineCtx(context.Background(), nil, e); !ok || got != 2048 {
		t.Fatalf("%d %v", got, ok)
	}
	clk.t = clk.t.Add(propsTTL - time.Second)
	engineCtx(context.Background(), nil, e)
	if hits.Load() != 1 {
		t.Fatalf("a positive entry younger than the TTL is served from the cache, hits=%d", hits.Load())
	}
	clk.t = clk.t.Add(2 * time.Second)
	n.Store(4096) // the engine was restarted with a larger context
	if got, ok := engineCtx(context.Background(), nil, e); !ok || got != 4096 || hits.Load() != 2 {
		t.Fatalf("a positive entry older than the TTL is refetched: %d %v hits=%d", got, ok, hits.Load())
	}
	// negative: unavailable /props is re-probed after propsNegativeTTL (much sooner than propsTTL)
	resetProps(t)
	n.Store(0)
	hits.Store(0)
	propsNow = clk.now
	if _, ok := engineCtx(context.Background(), nil, e); ok {
		t.Fatal("404 /props is unavailable")
	}
	clk.t = clk.t.Add(propsNegativeTTL - time.Second)
	engineCtx(context.Background(), nil, e)
	if hits.Load() != 1 {
		t.Fatalf("negative entry cached, hits=%d", hits.Load())
	}
	clk.t = clk.t.Add(2 * time.Second)
	n.Store(2048)
	if got, ok := engineCtx(context.Background(), nil, e); !ok || got != 2048 {
		t.Fatalf("a negative entry must not outlive propsNegativeTTL (the engine came up): %d %v", got, ok)
	}
	if propsNegativeTTL >= propsTTL {
		t.Fatal("negative TTL must be the shorter one")
	}
}

// M11: the plausible-n_ctx floor (16) and ceiling.
func TestPropsRejectsImplausibleContexts(t *testing.T) {
	for _, tc := range []struct {
		n    int64
		want bool
	}{{15, false}, {16, true}, {1 << 24, true}, {1<<24 + 1, false}} {
		resetProps(t)
		var n, hits, chat atomic.Int64
		n.Store(tc.n)
		srv := countingProps(t, &n, &hits, &chat, 0)
		if _, ok := engineCtx(context.Background(), nil, ep(srv.URL)); ok != tc.want {
			t.Errorf("n_ctx %d: accepted=%v want %v", tc.n, ok, tc.want)
		}
	}
}

// B3-04: a cancelled request neither gets a poisoned cache entry nor poisons it for the others.
func TestPropsCancelledRequestDoesNotPoisonTheCache(t *testing.T) {
	resetProps(t)
	var n, hits, chat atomic.Int64
	n.Store(2048)
	srv := countingProps(t, &n, &hits, &chat, 0)
	cctx, cancel := context.WithCancel(context.Background())
	cancel()
	engineCtx(cctx, nil, ep(srv.URL))
	if got, ok := engineCtx(context.Background(), nil, ep(srv.URL)); !ok || got != 2048 {
		t.Fatalf("a request whose context is already cancelled cached an unavailable engine: %d %v", got, ok)
	}
}

// B3-04: concurrent misses share one fetch (singleflight).
func TestPropsConcurrentMissesShareOneFetch(t *testing.T) {
	resetProps(t)
	var n, hits, chat atomic.Int64
	n.Store(2048)
	srv := countingProps(t, &n, &hits, &chat, 150*time.Millisecond)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if got, ok := engineCtx(context.Background(), nil, ep(srv.URL)); !ok || got != 2048 {
				t.Errorf("%d %v", got, ok)
			}
		}()
	}
	wg.Wait()
	if hits.Load() != 1 {
		t.Fatalf("8 concurrent misses made %d /props reads", hits.Load())
	}
}

// B3-04: an engine error or an unreachable engine drops the cached context (restart on the same URL).
func TestPropsInvalidatedByAnEngineError(t *testing.T) {
	resetProps(t)
	var n, hits atomic.Int64
	n.Store(2048)
	var fail atomic.Bool
	srv := newRecordedServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/props" {
			hits.Add(1)
			_, _ = w.Write([]byte(fmt.Sprintf(`{"default_generation_settings":{"n_ctx":%d}}`, n.Load())))
			return
		}
		if fail.Load() {
			w.WriteHeader(500)
			return
		}
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.3}))
	})
	spec := specByID(t, "decide-tiny")
	spec.Ctx = 8192
	if _, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, parseFor(t, noulBody)); err != nil {
		t.Fatal(err)
	}
	if hits.Load() != 1 {
		t.Fatalf("hits %d", hits.Load())
	}
	if _, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, parseFor(t, noulBody)); err != nil || hits.Load() != 1 {
		t.Fatalf("second request served from the cache: %v hits=%d", err, hits.Load())
	}
	fail.Store(true)
	n.Store(4096)
	if _, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, parseFor(t, noulBody)); err == nil {
		t.Fatal("the engine answered 500")
	}
	fail.Store(false)
	if _, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, parseFor(t, noulBody)); err != nil {
		t.Fatal(err)
	}
	if hits.Load() != 2 {
		t.Fatalf("an engine error must invalidate the cached context, /props reads = %d", hits.Load())
	}
}

// B3-04: the cache is bounded.
func TestPropsCacheIsBounded(t *testing.T) {
	resetProps(t)
	for i := 0; i < propsMaxEntries+40; i++ {
		engineCtx(context.Background(), nil, Endpoint{URL: fmt.Sprintf("http://127.0.0.1:%d", 20000+i), Healthy: true})
	}
	propsMu.Lock()
	n := len(propsCache)
	propsMu.Unlock()
	if n > propsMaxEntries {
		t.Fatalf("props cache grew to %d entries (limit %d)", n, propsMaxEntries)
	}
}

// B3-10 (M4): the engine-ctx refusal boundary is exact: an estimate equal to the budget is served,
// one token more is refused, and a refused request never reaches the completion endpoint.
func TestEngineCtxBoundaryIsExact(t *testing.T) {
	resetProps(t)
	var n, hits, chat atomic.Int64
	n.Store(2048)
	srv := countingProps(t, &n, &hits, &chat, 0)
	spec := specByID(t, "decide-tiny")
	spec.Ctx = 1 << 20
	budget := contract.PromptTokenBudget(2048)
	mk := func(l int) *contract.ParsedRequest {
		return parseForLimits(t, `{"model":"decide-tiny","state":`+jsonStr(strings.Repeat("0", l))+`,"questions":{"q":{"type":"noul","instructions":"i"}}}`, spec)
	}
	est := func(l int) int {
		r := mk(l)
		p, err := contract.RenderPrompt(r.Questions[0], r.StateText)
		if err != nil {
			t.Fatal(err)
		}
		return contract.EstimateTextTokens(p)
	}
	l := 1
	for est(l) <= budget {
		l++
		if l > 1<<16 {
			t.Fatal("estimate never exceeded the budget")
		}
	}
	// l is the first length over the budget; l-1 is at most the budget (the largest one served)
	if est(l-1) > budget {
		t.Fatalf("test construction: est(%d)=%d budget %d", l-1, est(l-1), budget)
	}
	if _, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, mk(l-1)); err != nil {
		t.Fatalf("an estimate at the budget (%d <= %d) must be served: %v", est(l-1), budget, err)
	}
	chat.Store(0)
	_, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, mk(l))
	if c := ce(t, err); c.Status != 422 || chat.Load() != 0 {
		t.Fatalf("est %d > budget %d must be 422 before the engine: %+v chat=%d", est(l), budget, c, chat.Load())
	}
}

// B3-05: every question is budget-checked before the first completion is requested.
func TestMultiQuestionRequestIsRefusedBeforeAnyCompletion(t *testing.T) {
	resetProps(t)
	var n, hits, chat atomic.Int64
	n.Store(2048)
	srv := countingProps(t, &n, &hits, &chat, 0)
	spec := specByID(t, "decide-tiny")
	spec.Ctx = 1 << 20
	big := strings.Repeat("0123456789", 300)
	body := `{"model":"decide-tiny","state":"s","questions":{"a":{"type":"noul","instructions":"short?"},"b":{"type":"noul","instructions":"short too?"},"c":{"type":"noul","instructions":` + jsonStr(big) + `}}}`
	_, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, parseForLimits(t, body, spec))
	if c := ce(t, err); c.Status != 422 {
		t.Fatalf("%+v", c)
	}
	if chat.Load() != 0 {
		t.Fatalf("%d completions were computed for a request whose third question is refused", chat.Load())
	}
}

// B3-10 (M8): /v1/models advertises the SMALLEST budget over the healthy instances.
func TestModelsAdvertiseTheSmallestHealthyInstanceBudget(t *testing.T) {
	resetProps(t)
	res := NewStaticResolver()
	spec := specByID(t, "decide-tiny")
	spec.Ctx = 1 << 20
	var eps []Endpoint
	for _, c := range []int64{4096, 2048, 8192} {
		var n, hits, chat atomic.Int64
		n.Store(c)
		srv := countingProps(t, &n, &hits, &chat, 0)
		eps = append(eps, Endpoint{URL: srv.URL, Healthy: true, Key: "k", Instance: fmt.Sprintf("i%d", c)})
	}
	res.Set(KindDecide, "decide-tiny", eps...)
	r, err := NewRouter(RouterConfig{Specs: []ProfileSpec{spec}, Resolver: res, Drivers: DefaultDrivers(Deterministic, false)})
	if err != nil {
		t.Fatal(err)
	}
	ms := r.Models()
	if len(ms) != 1 || ms[0].MaxContextTokens != contract.PromptTokenBudget(2048) {
		t.Fatalf("max_context_tokens %+v, want the 2048 instance's %d", ms, contract.PromptTokenBudget(2048))
	}
}

// B3-01 end to end (reviewer probe): a low-ranked present letter must not shrink the absent bound.
func TestLetterLowRankedPresentLetterKeepsTheFullAbsentBound(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", math.Log(0.6)}, lpEntry{"x", math.Log(0.1)}, lpEntry{"y", math.Log(0.1)}, lpEntry{"z", math.Log(0.1)}, lpEntry{" C", math.Log(0.05)}))
	})
	spec := specByID(t, "decide-tiny")
	spec.Readout.MassThreshold = 0.5
	ans, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, parseFor(t, `{"model":"decide-tiny","state":"s","questions":{"c":{"type":"choice","instructions":"?","criteria":{"alpha":"1","beta":"2","gamma":"3"}}}}`))
	if err != nil {
		t.Fatal(err)
	}
	m := answerJSON(t, ans[0].Answer)
	// listed .95, so everything unlisted is .05: B holds at most .05 -> A share .6/.7
	pr := m["probabilities"].(map[string]any)
	if math.Abs(pr["alpha"].(float64)-0.6/0.7) > 1e-6 || m["choice"] != "alpha" {
		t.Fatalf("%v", m)
	}
	// the TRUE worst case (all .05 unlisted mass on B) leaves A the same share: the gate value is
	// that worst case, not the old optimistic .857
	conf := m["confidence"].(float64)
	worst := (0.6/0.7 - 1.0/3) / (2.0 / 3)
	if math.Abs(conf-worst) > 1e-6 {
		t.Fatalf("confidence %v want the worst-case %v", conf, worst)
	}
}

// B3-08: a configured seed of 0 reaches the engine as 0 (not the default seed).
func TestLetterSendsAnExplicitZeroSeed(t *testing.T) {
	for _, tc := range []struct{ configured, want int }{{0, DefaultSeed}, {SeedZero, 0}, {7, 7}} {
		if got := ResolveSeed(tc.configured); got != tc.want {
			t.Errorf("ResolveSeed(%d) = %d want %d", tc.configured, got, tc.want)
		}
		srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
			_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.3}))
		})
		resetProps(t)
		b := &LetterLogitBackend{Mode: Deterministic, Seed: tc.configured}
		if _, _, err := b.Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody)); err != nil {
			t.Fatal(err)
		}
		if got, ok := rec.body["seed"].(float64); !ok || int(got) != tc.want {
			t.Errorf("configured %d: the engine got seed %v want %d", tc.configured, rec.body["seed"], tc.want)
		}
	}
}
