package gateway

// Engine-advance hardening of the native (/v1/systemone) path, G-116 (specs/009-jev-decision-models/
// evidence/gaps-register.md). Test-first: every test below was observed RED before the change in
// classifyEngineStatus (see evidence/live/NATIVE-REPORT.md).

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// The verbatim body llama.cpp b11379 answers at the default physical batch (upstream #30073;
// captured in evidence/engine-advance/raw/out/large.txt).
const batchTooLargeBody = `{"error":{"code":500,"message":"input (2118 tokens) is too large to process. increase the physical batch size (current batch size: 512)","type":"server_error"}}`

func nativeDecideStatus(t *testing.T, status int, body string) (*contract.ContractError, int) {
	t.Helper()
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	})
	_, _, err := (&NativeBackend{Enabled: true}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-laya"),
		parseFor(t, strings.Replace(noulBody, "decide-tiny", "decide-laya", 1)))
	return ce(t, err), rec.n
}

// G-116: a state that does not fit the engine's physical batch is a request the model cannot take:
// 422 validation_failed, not the retryable 502 (a retry would fail identically).
func TestNativeBatchTooLargeIs422(t *testing.T) {
	c, n := nativeDecideStatus(t, 500, batchTooLargeBody)
	if n != 1 {
		t.Fatalf("engine contacted %d times", n)
	}
	if c.Status != 422 || c.ErrorType != contract.ErrTypeValidationFailed {
		t.Fatalf("want 422 validation_failed, got %+v", c)
	}
	if strings.Contains(c.Message, "2118") || strings.Contains(c.Message, "batch") {
		t.Fatalf("engine text leaked to the client: %q", c.Message)
	}
}

// Golden-false (§11.4.201): a different 500 from the native engine stays the generic 502, so the
// mapping is not a blanket "every 500 is the client's fault".
func TestNativeOther500StaysBackendFailed(t *testing.T) {
	c, _ := nativeDecideStatus(t, 500, `{"error":{"code":500,"message":"boom","type":"server_error"}}`)
	if c.Status != 502 {
		t.Fatalf("want 502, got %+v", c)
	}
}

// The batch-size text is only meaningful for /v1/systemone; the letter-logit path must not map it.
func TestBatchTooLargeMappingIsNativeOnly(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		w.WriteHeader(500)
		_, _ = w.Write([]byte(batchTooLargeBody))
	})
	_, _, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody))
	if c := ce(t, err); c.Status == 422 {
		t.Fatalf("letter-logit path must not map the native batch text: %+v", c)
	}
}

// A chat (non-decision) model answers 501 "This model is not a decision model": a deterministic
// configuration fault (a chat model behind a decision profile), not retryable -> 500, never 502.
func TestNative501NotADecisionModelIsNotRetryable(t *testing.T) {
	c, _ := nativeDecideStatus(t, 501, `{"error":{"code":501,"message":"This model is not a decision model","type":"not_supported_error"}}`)
	if c.Status != 500 {
		t.Fatalf("want non-retryable 500, got %+v", c)
	}
}

// The native `model` field echoes the engine's local file path; the client must see the served
// profile name (the path would leak the host's directory layout).
func TestNativeResponseModelIsTheProfileNotTheEnginePath(t *testing.T) {
	const path = "/home/someone/llmctl/models/decide-laya/Laya-Q8_0.gguf"
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write([]byte(`{"model":"` + path + `","answers":{"q":{"type":"noul","noul":0.7}},"usage":{"input_tokens":9,"output_tokens":0}}`))
	})
	sr := NewStaticResolver()
	sr.Set(KindDecide, "decide-laya", ep(srv.URL))
	r, err := NewRouter(RouterConfig{Specs: testSpecs(), Resolver: sr, NativeEnabled: true, Drivers: DefaultDrivers(Deterministic, true)})
	if err != nil {
		t.Fatal(err)
	}
	req := parseFor(t, strings.Replace(noulBody, "decide-tiny", "decide-laya", 1))
	ans, u, err := r.Decide(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := contract.BuildResponse(req.Model, ans, u.InputTokens, u.OutputTokens)
	if err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(resp)
	if err != nil {
		t.Fatal(err)
	}
	var out struct{ Model string }
	_ = json.Unmarshal(b, &out)
	if out.Model != "decide-laya" || strings.Contains(string(b), "someone") || strings.Contains(string(b), ".gguf") {
		t.Fatalf("response leaks the engine's model field: %s", b)
	}
}

// The engine accepts a one-option choice with p=1.0 (measured, b11379); the gateway must refuse it
// before any engine contact (hosted contract: a choice needs >= 2 options).
func TestNativeSingleOptionChoiceRefusedBeforeTheEngine(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(nativeResp(`{"c":{"type":"choice","choice":"only","probabilities":{"only":1},"confidence":1}}`))
	})
	_ = srv
	body := `{"model":"decide-laya","state":"s","questions":{"c":{"type":"choice","instructions":"Pick","criteria":{"only":"the single option"}}}}`
	p, err := BuildProfiles(testSpecs(), "decide-laya", contract.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := contract.ParseRequest([]byte(body), contract.DefaultLimits(), p); err == nil {
		t.Fatal("a one-option choice must be refused by the contract for a native profile")
	}
	if rec.n != 0 {
		t.Fatal("the engine must not be contacted")
	}
}
