package server

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/metrics"
)

// capDecisions captures decision-log lines in memory (unit tier).
type capDecisions struct {
	mu    sync.Mutex
	lines []string
	err   error
}

func (c *capDecisions) WriteLine(l string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err != nil {
		return c.err
	}
	c.lines = append(c.lines, l)
	return nil
}
func (c *capDecisions) get() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.lines...)
}

var decisionMetaForTest = DecisionMeta{ModelSHA256: strings.Repeat("a", 64), TemplateHash: strings.Repeat("b", 64), CalibrationProfile: "decide-tiny"}

func (b *fakeBackend) DecisionMeta(string) DecisionMeta { return decisionMetaForTest }

const choiceReq = `{"model":"decide-tiny","state":"SECRET invoice overdue","questions":{"team":{"type":"choice","instructions":"SECRET which team?","criteria":{"billing":"money","support":"help","sales":"deals"}}}}`

func withDecisions(c *capDecisions, consent bool) hopt {
	return func(cfg *Config) { cfg.Decisions, cfg.DecisionState = c, consent }
}

func choiceBackend(h *harness, calibrated bool) {
	h.be.setDecide(func(_ context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		a, err := contract.BuildAnswer(r.Questions[0], []float64{0.2, 0.7, 0.1})
		if err != nil {
			return nil, contract.Usage{}, err
		}
		if calibrated {
			a.ConfidenceRaw, a.Confidence = a.Confidence, 0.66
			a.Calibration = &contract.Calibration{Method: "temperature", N: 300, ProfileID: "decide-tiny"}
		}
		return []contract.NamedAnswer{{Name: "team", Answer: a}}, contract.Usage{InputTokens: 9, OutputTokens: 1}, nil
	})
}

func TestDecisionLogRecordsOneDecisionWithoutText(t *testing.T) {
	dl := &capDecisions{}
	h := startServer(t, withDecisions(dl, false))
	choiceBackend(h, true)
	r := h.do(h.client(), "POST", "/v1/systemone", choiceReq, nil)
	if r.status != 200 {
		t.Fatalf("status %d %s", r.status, r.body)
	}
	lines := dl.get()
	if len(lines) != 1 {
		t.Fatalf("want one decision line, got %d", len(lines))
	}
	line := lines[0]
	for _, leak := range []string{"SECRET", "billing", "support", "sales", "team", testKey} {
		if strings.Contains(line, leak) {
			t.Errorf("decision log without consent leaked %q: %s", leak, line)
		}
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		t.Fatal(err)
	}
	if m["profile"] != "decide-tiny" || m["status"] != 200.0 || m["state_logged"] != false ||
		m["model_sha256"] != decisionMetaForTest.ModelSHA256 || m["template_hash"] != decisionMetaForTest.TemplateHash ||
		m["calibration_profile"] != "decide-tiny" {
		t.Errorf("record: %s", line)
	}
	if rid := r.hdr.Get("x-request-id"); m["request_id"] != rid {
		t.Errorf("request_id %v != response header %s", m["request_id"], rid)
	}
	a := m["answers"].([]any)[0].(map[string]any)
	if a["type"] != "choice" || a["choice_index"] != 1.0 || a["confidence"] != 0.66 || a["calibrated"] != true || a["confidence_raw"] == nil {
		t.Errorf("answer summary: %v", a)
	}
	if m["types"].(map[string]any)["choice"] != 1.0 {
		t.Errorf("types: %v", m["types"])
	}
	if h.sink.count() != 1 {
		t.Errorf("the request log must still hold its own record: %d", h.sink.count())
	}
}

func TestDecisionLogWithConsentCarriesText(t *testing.T) {
	dl := &capDecisions{}
	h := startServer(t, withDecisions(dl, true))
	choiceBackend(h, false)
	if r := h.do(h.client(), "POST", "/v1/systemone", choiceReq, nil); r.status != 200 {
		t.Fatalf("status %d", r.status)
	}
	line := dl.get()[0]
	for _, want := range []string{"SECRET invoice overdue", "SECRET which team?", `"choice":"support"`, `"name":"team"`} {
		if !strings.Contains(line, want) {
			t.Errorf("consenting record lacks %q: %s", want, line)
		}
	}
	if strings.Contains(line, testKey) {
		t.Error("the access key must never reach the decision log")
	}
	if !strings.Contains(line, `"calibrated":false`) || strings.Contains(line, "confidence_raw") {
		t.Errorf("uncalibrated summary: %s", line)
	}
}

func TestDecisionLogRecordsFailedDecisionsButNotRejectedRequests(t *testing.T) {
	dl := &capDecisions{}
	h := startServer(t, withDecisions(dl, false))
	h.be.setDecide(func(context.Context, *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		return nil, contract.Usage{}, errors.New("engine down")
	})
	if r := h.do(h.client(), "POST", "/v1/systemone", choiceReq, nil); r.status != 502 {
		t.Fatalf("status %d", r.status)
	}
	lines := dl.get()
	if len(lines) != 1 || !strings.Contains(lines[0], `"status":502`) || !strings.Contains(lines[0], `"answers":[]`) {
		t.Fatalf("a failed decision is logged with its status and no answers: %v", lines)
	}
	h.do(h.client(), "POST", "/v1/systemone", choiceReq, map[string]string{"Authorization": "Bearer wrong"})
	h.do(h.client(), "POST", "/v1/systemone", `{"model":"nope"}`, nil)
	h.do(h.client(), "GET", "/v1/models", "", nil)
	if n := len(dl.get()); n != 1 {
		t.Errorf("unauthenticated, invalid and non-decision requests are not decisions: %d lines", n)
	}
}

func TestDecisionLogWriteFailureNeverFailsTheRequest(t *testing.T) {
	dl := &capDecisions{err: errors.New("disk full")}
	var errBuf strings.Builder
	h := startServer(t, withDecisions(dl, false), func(c *Config) { c.Stderr = &errBuf })
	choiceBackend(h, false)
	for i := 0; i < 3; i++ {
		if r := h.do(h.client(), "POST", "/v1/systemone", choiceReq, nil); r.status != 200 {
			t.Fatalf("status %d", r.status)
		}
	}
	if got := h.srv.metrics.Count(metrics.AuditWriteFailure); got != 3 {
		t.Errorf("write failures counted = %d, want 3", got)
	}
	if n := strings.Count(errBuf.String(), "decision log write failed"); n != 1 {
		t.Errorf("first failure reported once on stderr, got %d: %q", n, errBuf.String())
	}
}

func TestDecisionLogOffByDefault(t *testing.T) {
	h := startServer(t) // no Decisions configured
	choiceBackend(h, false)
	if r := h.do(h.client(), "POST", "/v1/systemone", choiceReq, nil); r.status != 200 {
		t.Fatalf("status %d", r.status)
	}
}

func TestModelsListingPublishesTemplateHashAndCalibration(t *testing.T) {
	h := startServer(t)
	h.be.mu.Lock()
	h.be.models[0].TemplateHash = strings.Repeat("c", 64)
	h.be.models[0].Calibration = &CalibrationInfo{Applied: true, Method: "platt", N: 450, ProfileID: "decide-tiny"}
	h.be.mu.Unlock()
	r := h.do(h.client(), "GET", "/v1/models", "", nil)
	var v struct {
		Data []struct {
			ID           string `json:"id"`
			TemplateHash string `json:"template_hash"`
			Calibration  *struct {
				Applied   bool   `json:"applied"`
				Method    string `json:"method"`
				N         int    `json:"n"`
				ProfileID string `json:"profile_id"`
				Reason    string `json:"reason"`
			} `json:"calibration"`
		} `json:"data"`
	}
	if err := json.Unmarshal(r.body, &v); err != nil || len(v.Data) != 1 {
		t.Fatalf("%v %s", err, r.body)
	}
	d := v.Data[0]
	if d.TemplateHash != strings.Repeat("c", 64) || d.Calibration == nil || !d.Calibration.Applied || d.Calibration.Method != "platt" || d.Calibration.N != 450 || d.Calibration.ProfileID != "decide-tiny" {
		t.Errorf("listing: %+v", d)
	}
	// not applied: only the closed reason code is published
	h.be.mu.Lock()
	h.be.models[0].Calibration = &CalibrationInfo{Reason: "mismatch"}
	h.be.mu.Unlock()
	r = h.do(h.client(), "GET", "/v1/models", "", nil)
	if !strings.Contains(string(r.body), `"calibration":{"applied":false,"reason":"mismatch"}`) {
		t.Errorf("refused profile listing: %s", r.body)
	}
	// no calibration file: neither field of the object appears, the hash still does
	h.be.mu.Lock()
	h.be.models[0].Calibration = nil
	h.be.mu.Unlock()
	r = h.do(h.client(), "GET", "/v1/models", "", nil)
	if strings.Contains(string(r.body), `"calibration"`) || !strings.Contains(string(r.body), `"template_hash":"`+strings.Repeat("c", 64)+`"`) {
		t.Errorf("uncalibrated listing: %s", r.body)
	}
}

// The winner of a score answer (and so the logged index) is the best LISTED option: a bounded option
// holds worst-case mass, never a measurement, even when it holds the most.
func TestDecisionAnswerWinnerIgnoresBoundedOptions(t *testing.T) {
	q := contract.ParsedQuestion{Name: "s", Type: contract.TypeScore, Instructions: "i", Options: []contract.Option{
		{Letter: "A", Key: "0", Label: "a"}, {Letter: "B", Key: "1", Label: "b"}, {Letter: "C", Key: "2", Label: "c"}},
		Legend: []contract.LegendEntry{{Key: "0", Value: []byte(`"a"`)}, {Key: "1", Value: []byte(`"b"`)}, {Key: "2", Value: []byte(`"c"`)}}}
	a, err := contract.BuildAnswerBounded(q, []float64{0.3, 0.2, 0.5}, map[string]float64{"2": 0.6})
	if err != nil {
		t.Fatal(err)
	}
	da := decisionAnswer(q, a)
	if da.ChoiceIndex != 0 || da.ChoiceKey != "0" || da.Value == nil || da.Confidence == nil || len(da.Flags) != 1 {
		t.Fatalf("summary = %+v", da)
	}
	noul := decisionAnswer(contract.ParsedQuestion{Name: "n", Type: contract.TypeNoul}, contract.Answer{Type: contract.TypeNoul, Noul: 0.25})
	if noul.ChoiceIndex != -1 || noul.Value == nil || *noul.Value != 0.25 || noul.Confidence != nil {
		t.Fatalf("noul summary = %+v", noul)
	}
}
