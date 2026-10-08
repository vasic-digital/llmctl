package gateway

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// testSpecs are catalog-shaped specs used across the unit tests.
func testSpecs() []ProfileSpec {
	lr := ReadoutSpec{NProbs: 32, MassThreshold: 0.5, Spellings: []string{"A", " A", "a", " a"}}
	return []ProfileSpec{
		{ID: "decide-tiny", Protocol: ProtoLetter, Port: 8092, MaxOptions: 20, ScoreLevels: [2]int{2, 10}, Readout: lr},
		{ID: "decide-nli", Protocol: ProtoNLI, Port: 8096, MaxOptions: 20, ScoreLevels: [2]int{2, 10}},
		{ID: "decide-laya", Protocol: ProtoNative, Port: 8099, MaxOptions: 255, ScoreLevels: [2]int{2, 10}},
	}
}

func testProfiles(t *testing.T) *contract.Profiles {
	t.Helper()
	p, err := BuildProfiles(testSpecs(), "decide-tiny", contract.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// parseFor parses a request body for the profile model name.
func parseFor(t *testing.T, body string) *contract.ParsedRequest {
	t.Helper()
	p := testProfiles(t)
	r, err := contract.ParseRequest([]byte(body), contract.DefaultLimits(), p)
	if err != nil {
		t.Fatalf("ParseRequest: %v", err)
	}
	return r
}

func specByID(t *testing.T, id string) ProfileSpec {
	t.Helper()
	for _, s := range testSpecs() {
		if s.ID == id {
			return s
		}
	}
	t.Fatalf("no spec %s", id)
	return ProfileSpec{}
}

const noulBody = `{"model":"decide-tiny","state":"the printer is on fire","questions":{"q":{"type":"noul","instructions":"Is it urgent?"}}}`
const choiceBody = `{"model":"decide-tiny","state":"invoice overdue","questions":{"c":{"type":"choice","instructions":"Which team?","criteria":{"billing":"money","support":"help","sales":"deals"}}}}`
const scoreBody = `{"model":"decide-tiny","state":"great product","questions":{"s":{"type":"score","instructions":"Rate it","criteria":["bad","ok","good"]}}}`

type lpEntry struct {
	Token string  `json:"token"`
	LP    float64 `json:"logprob"`
}

// llamaResponse is a llama-server chat.completion body with the given first-token alternatives.
func llamaResponse(entries ...lpEntry) []byte {
	b, _ := json.Marshal(map[string]any{
		"choices": []any{map[string]any{
			"message":  map[string]any{"role": "assistant", "content": "A"},
			"logprobs": map[string]any{"top_logprobs": []any{entries}},
		}},
		"usage": map[string]any{"prompt_tokens": 9, "completion_tokens": 1},
	})
	return b
}

// fakeServer starts an httptest server whose handler records the last request.
type recorded struct {
	path, auth string
	body       map[string]any
	n          int
}

func fakeServer(t *testing.T, h func(rec *recorded, w http.ResponseWriter)) (*httptest.Server, *recorded) {
	t.Helper()
	rec := &recorded{}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/props" { // the gateway's ctx probe (B2-05): not a decision call
			http.NotFound(w, r)
			return
		}
		rec.n++
		rec.path = r.URL.Path
		rec.auth = r.Header.Get("Authorization")
		rec.body = nil
		_ = json.NewDecoder(r.Body).Decode(&rec.body)
		h(rec, w)
	}))
	t.Cleanup(s.Close)
	return s, rec
}

func ce(t *testing.T, err error) *contract.ContractError {
	t.Helper()
	var c *contract.ContractError
	if err == nil {
		t.Fatal("expected an error")
	}
	if !asCE(err, &c) {
		t.Fatalf("not a ContractError: %T %v", err, err)
	}
	return c
}

func asCE(err error, c **contract.ContractError) bool     { return errorsAs(err, c) }
func errorsAs(err error, c **contract.ContractError) bool { return errors.As(err, c) }

// ---- helpers for the B2 tests ----

type recordedServer struct{ URL string }

func newRecordedServer(t *testing.T, h func(w http.ResponseWriter, r *http.Request)) *recordedServer {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(h))
	t.Cleanup(s.Close)
	return &recordedServer{URL: s.URL}
}

func jsonStr(s string) string { b, _ := json.Marshal(s); return string(b) }

// parseForLimits parses body against the limits of spec (per-profile budgets).
func parseForLimits(t *testing.T, body string, spec ProfileSpec) *contract.ParsedRequest {
	t.Helper()
	p, err := BuildProfiles([]ProfileSpec{spec}, spec.ID, contract.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	base := contract.DefaultLimits()
	base.MaxStateChars = 1 << 20
	r, err := contract.ParseRequest([]byte(body), base, p)
	if err != nil {
		t.Fatalf("ParseRequest: %v", err)
	}
	return r
}
