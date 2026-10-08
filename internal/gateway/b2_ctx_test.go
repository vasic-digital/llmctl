package gateway

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

const ctxCatalog = `{"profiles":{"decide-tiny":{"port":8092,"capability":["decide"],"defaults":{"ctx":8192,"parallel":1},
 "decision":{"protocol":"letter-logit"}}}}`

// B2-05: the gateway applies LLMCTL_CTX_<PROFILE> exactly as lib/catalog.sh resolve_ctx does.
func TestCatalogHonoursTheCtxEnvOverrideLikeTheLauncher(t *testing.T) {
	t.Setenv("LLMCTL_CTX_DECIDE_TINY", "2048")
	specs, err := ParseCatalog([]byte(ctxCatalog))
	if err != nil {
		t.Fatal(err)
	}
	if specs[0].Ctx != 2048 {
		t.Fatalf("Ctx = %d, want the override 2048 (the engine launcher serves 2048)", specs[0].Ctx)
	}
	if got, want := specs[0].Limits(contract.DefaultLimits()).MaxPromptTokens, contract.PromptTokenBudget(2048); got != want {
		t.Fatalf("token budget %d, want %d", got, want)
	}
	// reverse direction: a larger ctx raises the budget, the gateway does not refuse what the engine can serve
	t.Setenv("LLMCTL_CTX_DECIDE_TINY", "32768")
	specs, _ = ParseCatalog([]byte(ctxCatalog))
	if specs[0].Ctx != 32768 {
		t.Fatalf("Ctx = %d", specs[0].Ctx)
	}
}

func TestCatalogRejectsABadCtxOverrideLoudly(t *testing.T) {
	for _, v := range []string{"abc", "0", "-5", "100", "12.5"} {
		t.Setenv("LLMCTL_CTX_DECIDE_TINY", v)
		if _, err := ParseCatalog([]byte(ctxCatalog)); err == nil || !strings.Contains(err.Error(), "LLMCTL_CTX_DECIDE_TINY") {
			t.Errorf("override %q must be refused naming the variable, got %v", v, err)
		}
	}
	t.Setenv("LLMCTL_CTX_DECIDE_TINY", "")
	if specs, err := ParseCatalog([]byte(ctxCatalog)); err != nil || specs[0].Ctx != 8192 {
		t.Fatalf("empty override = catalog default: %v %+v", err, specs)
	}
}

func propsServer(t *testing.T, nctx int, chat *int) *recordedServer {
	t.Helper()
	return newRecordedServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/props":
			if nctx == 0 {
				http.NotFound(w, r)
				return
			}
			_, _ = w.Write([]byte(`{"default_generation_settings":{"n_ctx":` + itoa(nctx) + `}}`))
		default:
			*chat++
			_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.3}))
		}
	})
}

// B2-05/G-093: when the engine reports a smaller per-slot context than the gateway budgeted
// (launcher env the gateway did not see), the prompt is refused as 422 BEFORE the engine is asked.
func TestLetterRefusesWhatTheEngineReportedCtxCannotHold(t *testing.T) {
	chat := 0
	srv := propsServer(t, 2048, &chat)
	spec := specByID(t, "decide-tiny")
	spec.Ctx = 8192
	state := strings.Repeat("0123456789", 400) // ~4000 digits ~ 4000 tokens: > 2048, < 8192
	body := `{"model":"decide-tiny","state":` + jsonStr(state) + `,"questions":{"q":{"type":"noul","instructions":"i"}}}`
	req := parseForLimits(t, body, spec)
	_, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, req)
	c := ce(t, err)
	if c.Status != 422 {
		t.Fatalf("status %d: %+v", c.Status, c)
	}
	if chat != 0 {
		t.Fatalf("the engine completion was contacted %d times; the refusal must come first", chat)
	}
}

func TestLetterFallsBackToTheConfiguredCtxWhenPropsIsUnavailable(t *testing.T) {
	chat := 0
	srv := propsServer(t, 0, &chat) // /props -> 404
	spec := specByID(t, "decide-tiny")
	spec.Ctx = 8192
	state := strings.Repeat("0123456789", 400)
	body := `{"model":"decide-tiny","state":` + jsonStr(state) + `,"questions":{"q":{"type":"noul","instructions":"i"}}}`
	req := parseForLimits(t, body, spec)
	if _, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, req); err != nil || chat != 1 {
		t.Fatalf("with no /props the configured budget applies: err=%v chat=%d", err, chat)
	}
}

// /v1/models must advertise the effective values.
func TestModelsAdvertiseTheEffectiveEngineCtx(t *testing.T) {
	chat := 0
	srv := propsServer(t, 2048, &chat)
	res := NewStaticResolver()
	spec := specByID(t, "decide-tiny")
	spec.Ctx = 8192
	res.Set(KindDecide, "decide-tiny", Endpoint{URL: srv.URL, Healthy: true, Key: "k"})
	r, err := NewRouter(RouterConfig{Specs: []ProfileSpec{spec}, Resolver: res, Drivers: DefaultDrivers(Deterministic, false)})
	if err != nil {
		t.Fatal(err)
	}
	ms := r.Models()
	if len(ms) != 1 || ms[0].MaxContextTokens != contract.PromptTokenBudget(2048) {
		t.Fatalf("max_context_tokens = %+v, want %d", ms, contract.PromptTokenBudget(2048))
	}
}

// B2-12: determinism must not depend on unguarded catalog data.
func TestDeterministicRouterRefusesACatalogWithPromptCaching(t *testing.T) {
	specs := testSpecs()
	specs[0].Readout.CachePrompt = true
	res := NewStaticResolver()
	_, err := NewRouter(RouterConfig{Specs: specs, Resolver: res, Mode: Deterministic, Drivers: DefaultDrivers(Deterministic, false)})
	if err == nil || !strings.Contains(err.Error(), "cache_prompt") {
		t.Fatalf("a deterministic router must refuse a letter profile with cache_prompt=true, got %v", err)
	}
	if _, err := NewRouter(RouterConfig{Specs: specs, Resolver: res, Mode: Throughput, Drivers: DefaultDrivers(Throughput, false)}); err != nil {
		t.Fatalf("throughput mode does not promise byte identity: %v", err)
	}
}

func TestDeterministicDriverNeverSendsCachePromptTrue(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.3}))
	})
	spec := specByID(t, "decide-tiny")
	spec.Readout.CachePrompt = true
	if _, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, parseFor(t, noulBody)); err != nil {
		t.Fatal(err)
	}
	if rec.body["cache_prompt"] != false {
		t.Fatalf("deterministic mode sent cache_prompt=%v", rec.body["cache_prompt"])
	}
}

// B2-11: a deterministic request served by an overflow instance says which instance answered.
func TestRouterNotesTheServingInstance(t *testing.T) {
	srvA, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.3}))
	})
	res := NewStaticResolver()
	res.Set(KindDecide, "decide-tiny", Endpoint{URL: srvA.URL, Healthy: true, Key: "k", Instance: "decide-tiny.2"})
	r := newRouterWith(t, res)
	ctx, get := contract.WithInstanceNote(context.Background())
	if _, _, err := r.Decide(ctx, parseFor(t, noulBody)); err != nil {
		t.Fatal(err)
	}
	if get() != "decide-tiny.2" {
		t.Fatalf("serving instance = %q", get())
	}
}

// B3-11: the gateway reads LLMCTL_CTX_<PROFILE> like the launcher's Python int(): surrounding blanks,
// a sign and single underscores between digits are accepted (a rejected value the launcher serves
// would make the gateway disagree with the engine it fronts).
func TestCtxOverrideParsesLikePythonInt(t *testing.T) {
	for v, want := range map[string]int{"4_096": 4096, " 4096 ": 4096, "+4096": 4096, "8_192": 8192, "1_0_0_0": 1000} {
		t.Setenv("LLMCTL_CTX_DECIDE_TINY", v)
		specs, err := ParseCatalog([]byte(ctxCatalog))
		if err != nil || specs[0].Ctx != want {
			t.Errorf("%q: got %+v %v, want %d", v, specs, err, want)
		}
	}
	for _, v := range []string{"4__096", "_4096", "4096_", "0x1000", "4,096", "1e3", "４０９６x"} {
		t.Setenv("LLMCTL_CTX_DECIDE_TINY", v)
		if _, err := ParseCatalog([]byte(ctxCatalog)); err == nil {
			t.Errorf("%q must be refused", v)
		}
	}
}
