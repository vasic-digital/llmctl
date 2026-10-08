package gateway

import (
	"context"
	"errors"
	"math"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func smokeCfg(url, proto string) SmokeConfig {
	return SmokeConfig{URL: url, Key: "internal-k", Protocol: proto, Options: 2, Timeout: 5 * time.Second}
}

// letter-logit: a llama-server that favours option A (billing) -> valid typed choice answer.
func TestSmokeLetterLogitOK(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.5}))
	})
	cfg := smokeCfg(srv.URL, ProtoLetter)
	cfg.ExpectChoice = "billing"
	r, err := Smoke(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !r.OK || r.Type != "choice" || r.Choice != "billing" || len(r.Probabilities) != 2 {
		t.Fatalf("result %+v", r)
	}
	sum := 0.0
	for _, p := range r.Probabilities {
		if math.IsNaN(p.Value) || math.IsInf(p.Value, 0) {
			t.Fatal("non-finite probability")
		}
		sum += p.Value
	}
	if math.Abs(sum-1) > 1e-6 {
		t.Fatalf("probabilities sum %v", sum)
	}
	if rec.path != "/v1/chat/completions" || rec.auth != "Bearer internal-k" {
		t.Fatalf("path/auth %s %s", rec.path, rec.auth)
	}
}

// The prompt is deterministic: two smokes send byte-identical engine requests.
func TestSmokeDeterministicPrompt(t *testing.T) {
	var bodies []string
	srv, rec := fakeServer(t, func(rec *recorded, w http.ResponseWriter) {
		bodies = append(bodies, strings.TrimSpace(rec.body["messages"].([]any)[0].(map[string]any)["content"].(string)))
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.5}))
	})
	_ = rec
	for i := 0; i < 2; i++ {
		if _, err := Smoke(context.Background(), smokeCfg(srv.URL, ProtoLetter)); err != nil {
			t.Fatal(err)
		}
	}
	if len(bodies) != 2 || bodies[0] != bodies[1] || !strings.Contains(bodies[0], "billing") {
		t.Fatalf("prompts differ or lack the fixture: %q", bodies)
	}
}

// --options N renders N lettered options.
func TestSmokeOptionsCount(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.5}, lpEntry{" C", -3}, lpEntry{" D", -4}))
	})
	cfg := smokeCfg(srv.URL, ProtoLetter)
	cfg.Options = 4
	r, err := Smoke(context.Background(), cfg)
	if err != nil || len(r.Probabilities) != 4 {
		t.Fatalf("%+v %v", r, err)
	}
}

// A wrong expected choice is a backend failure (the model answered, but not sanely).
func TestSmokeExpectChoiceMismatch(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" B", -0.1}, lpEntry{" A", -2.5}))
	})
	cfg := smokeCfg(srv.URL, ProtoLetter)
	cfg.ExpectChoice = "billing"
	if _, err := Smoke(context.Background(), cfg); err == nil || errors.Is(err, ErrSmokeUnreachable) {
		t.Fatalf("want a backend failure, got %v", err)
	}
}

// A model that answers with non-letters (or an engine 500) is a backend failure, never OK.
func TestSmokeBackendFailure(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) { w.WriteHeader(500) })
	if _, err := Smoke(context.Background(), smokeCfg(srv.URL, ProtoLetter)); err == nil || errors.Is(err, ErrSmokeUnreachable) {
		t.Fatalf("want backend failure, got %v", err)
	}
	srv2, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" the", -0.1}, lpEntry{" and", -1}))
	})
	if _, err := Smoke(context.Background(), smokeCfg(srv2.URL, ProtoLetter)); err == nil {
		t.Fatal("a response with no option letters must fail the smoke")
	}
}

// Nothing listening -> ErrSmokeUnreachable (exit 6), not a backend failure.
func TestSmokeUnreachable(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	_, err = Smoke(context.Background(), smokeCfg("http://"+addr, ProtoLetter))
	if !errors.Is(err, ErrSmokeUnreachable) {
		t.Fatalf("want ErrSmokeUnreachable, got %v", err)
	}
}

// nli-onnx: the score runtime returns entail/contradict/neutral columns.
func TestSmokeNLI(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write([]byte(`{"labels":["entailment","neutral","contradiction"],"label_source":"model_config","truncated":[false,false],"scores":[[0.9,0.05,0.05],[0.1,0.1,0.8]]}`))
	})
	r, err := Smoke(context.Background(), smokeCfg(srv.URL, ProtoNLI))
	if err != nil {
		t.Fatal(err)
	}
	if !r.OK || r.Type != "choice" || r.Choice != "billing" || rec.path != "/v1/score" {
		t.Fatalf("%+v path=%s", r, rec.path)
	}
}

// systemone-native: the engine's /v1/systemone answer is re-validated.
func TestSmokeNative(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write([]byte(`{"model":"smoke","answers":{"q":{"type":"choice","choice":"billing","probabilities":{"billing":0.8,"legal":0.2},"confidence":0.6}},"usage":{"input_tokens":5,"output_tokens":1}}`))
	})
	r, err := Smoke(context.Background(), smokeCfg(srv.URL, ProtoNative))
	if err != nil || !r.OK || r.Choice != "billing" || rec.path != "/v1/systemone" {
		t.Fatalf("%+v %v path=%s", r, err, rec.path)
	}
}

func TestSmokeUsageErrors(t *testing.T) {
	for _, c := range []SmokeConfig{
		{URL: "http://127.0.0.1:1", Protocol: "bogus", Options: 2},
		{URL: "http://127.0.0.1:1", Protocol: ProtoLetter, Options: 1},
		{URL: "http://127.0.0.1:1", Protocol: ProtoLetter, Options: 27},
		{URL: "", Protocol: ProtoLetter, Options: 2},
		{URL: "http://example.com:80", Protocol: ProtoLetter, Options: 2},
	} {
		_, err := Smoke(context.Background(), c)
		if !errors.Is(err, ErrSmokeUsage) {
			t.Errorf("%+v: want ErrSmokeUsage, got %v", c, err)
		}
	}
}

// B2-10: a smoke whose engine readout lacks an option letter does NOT admit the profile.
func TestSmokeRejectsAFlaggedAnswer(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{"\n", -2.5}, lpEntry{"x", -3}))
	})
	r, err := Smoke(context.Background(), smokeCfg(srv.URL, ProtoLetter))
	if err == nil || !strings.Contains(err.Error(), "option_missing") {
		t.Fatalf("a flagged smoke answer must fail naming the flag: %+v %v", r, err)
	}
}
