package gateway

import (
	"context"
	"math"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
)

func ep(url string) Endpoint { return Endpoint{URL: url, Key: "internal-k", Healthy: true} }

func newLetter() *LetterLogitBackend { return &LetterLogitBackend{Mode: Deterministic, Seed: 7} }

func TestLetterNoulProbabilityAndRequestShape(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.3}, lpEntry{" the", -0.5}))
	})
	req := parseFor(t, noulBody)
	ans, usage, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), req)
	if err != nil {
		t.Fatal(err)
	}
	want := math.Exp(-0.1) / (math.Exp(-0.1) + math.Exp(-2.3))
	if len(ans) != 1 || ans[0].Name != "q" || ans[0].Answer.Type != "noul" || math.Abs(ans[0].Answer.Noul-want) > 1e-6 {
		t.Fatalf("answer %+v want noul≈%v", ans, want)
	}
	if usage.OutputTokens != 1 || usage.InputTokens <= 0 {
		t.Fatalf("usage %+v", usage)
	}
	if rec.path != "/v1/chat/completions" || rec.auth != "Bearer internal-k" {
		t.Fatalf("path/auth: %s %s", rec.path, rec.auth)
	}
	b := rec.body
	if b["max_tokens"] != float64(1) || b["temperature"] != float64(0) || b["logprobs"] != true || b["cache_prompt"] != false {
		t.Fatalf("body %v", b)
	}
	if b["seed"] != float64(7) {
		t.Fatalf("deterministic mode must send the fixed seed, got %v", b["seed"])
	}
	if b["top_logprobs"] != float64(32) || b["n_probs"] != float64(32) {
		t.Fatalf("n_probs/top_logprobs: %v %v", b["n_probs"], b["top_logprobs"])
	}
	msgs := b["messages"].([]any)
	prompt := msgs[0].(map[string]any)["content"].(string)
	wantPrompt, _ := contract.RenderPrompt(req.Questions[0], req.StateText)
	if prompt != wantPrompt {
		t.Fatalf("prompt must be the shared template:\n%s", prompt)
	}
	if _, has := b["model"]; has {
		t.Fatal("no model field is needed for a single-model llama-server")
	}
}

// Root cause (live, nezha 2026-10-08): thinking-mode chat templates (Qwen3/3.5 family: decide,
// decide-2b, decide-max, decide-pro) make the engine open with a reasoning token (delivered in
// reasoning_content, content empty), so no option letter is ever in the first-token alternatives
// (HTTP 422 readout_failed / option_missing). llama-server honours a per-request
// chat_template_kwargs {"enable_thinking": false}; the letter-logit request MUST send it, in both
// modes, so the first generated token is the answer position.
func TestLetterRequestDisablesThinking(t *testing.T) {
	for _, mode := range []Mode{Deterministic, Throughput} {
		srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
			_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.3}))
		})
		be := &LetterLogitBackend{Mode: mode, Seed: 7}
		if _, _, err := be.Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody)); err != nil {
			t.Fatal(err)
		}
		kw, ok := rec.body["chat_template_kwargs"].(map[string]any)
		if !ok || kw["enable_thinking"] != false {
			t.Fatalf("mode %v: letter-logit request must carry chat_template_kwargs.enable_thinking=false, got %v", mode, rec.body["chat_template_kwargs"])
		}
	}
}

func TestLetterChoiceAndScore(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" B", -0.2}, lpEntry{" A", -2.0}, lpEntry{" C", -3.0}))
	})
	spec := specByID(t, "decide-tiny")
	ans, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, parseFor(t, choiceBody))
	if err != nil {
		t.Fatal(err)
	}
	a := ans[0].Answer
	if a.Type != "choice" || a.Choice != "support" || len(a.Probabilities) != 3 {
		t.Fatalf("%+v", a)
	}
	sum := 0.0
	for _, p := range a.Probabilities {
		sum += p.Value
	}
	if math.Abs(sum-1) > 1e-6 {
		t.Fatalf("sum %v", sum)
	}
	ans, _, err = newLetter().Decide(context.Background(), ep(srv.URL), spec, parseFor(t, scoreBody))
	if err != nil {
		t.Fatal(err)
	}
	if s := ans[0].Answer; s.Type != "score" || len(s.Legend) != 3 || s.Score <= 0 || s.Score >= 2 {
		t.Fatalf("%+v", s)
	}
}

func TestLetterMultipleQuestionsInOrder(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{"A", -0.1}, lpEntry{"B", -2.0}))
	})
	body := `{"model":"decide-tiny","state":"s","questions":{"z":{"type":"noul","instructions":"one"},"a":{"type":"noul","instructions":"two"}}}`
	ans, usage, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, body))
	if err != nil || len(ans) != 2 || ans[0].Name != "z" || ans[1].Name != "a" {
		t.Fatalf("%v %v", ans, err)
	}
	if rec.n != 2 || usage.OutputTokens != 2 {
		t.Fatalf("calls=%d usage=%+v", rec.n, usage)
	}
}

func TestLetterLowMassIsReadoutFailed(t *testing.T) {
	// A+B mass = exp(-1.6)+exp(-1.7) ≈ 0.38 < 0.5 threshold of the profile
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -1.6}, lpEntry{" B", -1.7}, lpEntry{" The", -0.3}))
	})
	_, _, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody))
	c := ce(t, err)
	if c.Status != 422 || c.ErrorType != contract.ErrTypeReadoutFailed {
		t.Fatalf("%+v", c)
	}
	// the same distribution passes when the profile's own threshold is lower (threshold is honoured, not hardcoded)
	spec := specByID(t, "decide-tiny")
	spec.Readout.MassThreshold = 0.3
	if _, _, err := newLetter().Decide(context.Background(), ep(srv.URL), spec, parseFor(t, noulBody)); err != nil {
		t.Fatalf("threshold 0.3 must pass: %v", err)
	}
}

func TestLetterGlobalThresholdOverride(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.4}, lpEntry{" B", -1.7}, lpEntry{" The", -0.3}))
	}) // mass ≈ 0.67+0.18 = 0.85
	b := newLetter()
	b.MassThreshold = 0.9
	_, _, err := b.Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody))
	if c := ce(t, err); c.ErrorType != contract.ErrTypeReadoutFailed {
		t.Fatalf("%+v", c)
	}
}

func TestLetterBackendFailures(t *testing.T) {
	cases := map[string]func(*recorded, http.ResponseWriter){
		"http500": func(_ *recorded, w http.ResponseWriter) {
			w.WriteHeader(500)
			_, _ = w.Write([]byte(`secret engine text`))
		},
		"badjson": func(_ *recorded, w http.ResponseWriter) { _, _ = w.Write([]byte(`{not json`)) },
		"nologprob": func(_ *recorded, w http.ResponseWriter) {
			_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"A"}}]}`))
		},
		"http401": func(_ *recorded, w http.ResponseWriter) { w.WriteHeader(401) },
	}
	for name, h := range cases {
		t.Run(name, func(t *testing.T) {
			srv, _ := fakeServer(t, h)
			_, _, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody))
			c := ce(t, err)
			if c.Status != 502 || c.ErrorType != contract.ErrTypeBackendFailed {
				t.Fatalf("%+v", c)
			}
			if strings.Contains(c.Message, "secret") {
				t.Fatal("engine text leaked")
			}
		})
	}
}

func TestLetterConnectFailureIs502(t *testing.T) {
	srv, _ := fakeServer(t, func(*recorded, http.ResponseWriter) {})
	url := srv.URL
	srv.Close()
	_, _, err := newLetter().Decide(context.Background(), ep(url), specByID(t, "decide-tiny"), parseFor(t, noulBody))
	if c := ce(t, err); c.Status != 502 {
		t.Fatalf("%+v", c)
	}
}

func TestLetterRefusesNonLoopbackEndpoint(t *testing.T) {
	_, _, err := newLetter().Decide(context.Background(), Endpoint{URL: "http://10.255.255.1:1", Healthy: true}, specByID(t, "decide-tiny"), parseFor(t, noulBody))
	if c := ce(t, err); c.Status != 502 {
		t.Fatalf("%+v", c)
	}
}

func TestLetterThroughputModeOmitsSeed(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{"A", -0.1}, lpEntry{"B", -2.0}))
	})
	b := &LetterLogitBackend{Mode: Throughput}
	if _, _, err := b.Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody)); err != nil {
		t.Fatal(err)
	}
	if _, has := rec.body["seed"]; has {
		t.Fatal("throughput mode must not pin a seed")
	}
	if rec.body["cache_prompt"] != false {
		t.Fatal("cache_prompt stays false")
	}
}

func TestLetterDeterministicRepeatsAreByteIdentical(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" B", -0.3}, lpEntry{" A", -1.4}, lpEntry{" C", -2.5}))
	})
	var first string
	for i := 0; i < 5; i++ {
		ans, u, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, choiceBody))
		if err != nil {
			t.Fatal(err)
		}
		r, _ := contract.BuildResponse("decide-tiny", ans, u.InputTokens, u.OutputTokens)
		b, _ := r.MarshalJSON()
		if i == 0 {
			first = string(b)
		} else if string(b) != first {
			t.Fatal("repeat differs")
		}
	}
}

func TestLetterContextCancelled(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		time.Sleep(300 * time.Millisecond)
		_, _ = w.Write(llamaResponse())
	})
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	_, _, err := newLetter().Decide(ctx, ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody))
	if c := ce(t, err); c.Status != 502 {
		t.Fatalf("%+v", c)
	}
}

func TestLetterWrongProtocolRefused(t *testing.T) {
	_, _, err := newLetter().Decide(context.Background(), ep("http://127.0.0.1:1"), specByID(t, "decide-nli"), parseFor(t, noulBody))
	if err == nil {
		t.Fatal("letter driver must refuse an nli profile")
	}
}
