package server

import (
	"encoding/json"
	"strings"
	"testing"
)

// T138 / OD-24: an answer of a type the profile has not measured above its baseline carries the additive
// `maturity: "experimental"`; an answer of a measured type is byte-identical to the original shape.
const mixedBody = `{"model":"decide-tiny","state":"the printer is on fire","questions":{` +
	`"n":{"type":"noul","instructions":"Is it urgent?"},` +
	`"c":{"type":"choice","instructions":"Which team?","criteria":{"billing":"money","support":"help"}}}}`

func TestAnswerOfAnExperimentalTypeCarriesMaturity(t *testing.T) {
	h := startServer(t)
	h.be.mu.Lock()
	h.be.maturity = map[string]string{"noul": "experimental"}
	h.be.mu.Unlock()
	r := h.do(h.client(), "POST", "/v1/systemone", mixedBody, map[string]string{"Authorization": "Bearer " + testKey, "Content-Type": "application/json"})
	if r.status != 200 {
		t.Fatalf("status %d: %s", r.status, r.body)
	}
	var v struct {
		Answers map[string]map[string]json.RawMessage `json:"answers"`
	}
	if err := json.Unmarshal(r.body, &v); err != nil {
		t.Fatal(err)
	}
	if string(v.Answers["n"]["maturity"]) != `"experimental"` {
		t.Errorf("the noul answer must carry maturity=experimental: %s", r.body)
	}
	if _, ok := v.Answers["c"]["maturity"]; ok {
		t.Errorf("golden-false: the measured choice answer must NOT carry maturity: %s", r.body)
	}
}

func TestNoMaturityInformationLeavesTheAnswerShapeUntouched(t *testing.T) {
	h := startServer(t)
	r := h.do(h.client(), "POST", "/v1/systemone", mixedBody, map[string]string{"Authorization": "Bearer " + testKey, "Content-Type": "application/json"})
	if r.status != 200 || strings.Contains(string(r.body), "maturity") {
		t.Errorf("a backend that reports no maturity must not change the response: %d %s", r.status, r.body)
	}
}

func TestModelsListingPublishesMaturityPerType(t *testing.T) {
	h := startServer(t)
	lo, base := 0.425, 0.667
	h.be.mu.Lock()
	h.be.models[0].Maturity = map[string]MaturityInfo{
		"noul":   {Status: "experimental", LowerBound: &lo, Baseline: &base, N: 60},
		"choice": {Status: "measured", LowerBound: &base, Baseline: &lo, N: 41},
		"score":  {Status: "unmeasured", Reason: "not yet measured"},
	}
	h.be.mu.Unlock()
	r := h.do(h.client(), "GET", "/v1/models", "", nil)
	var v struct {
		Data []struct {
			Maturity          map[string]map[string]json.RawMessage `json:"maturity"`
			ExperimentalTypes []string                              `json:"experimental_types"`
		} `json:"data"`
	}
	if err := json.Unmarshal(r.body, &v); err != nil || len(v.Data) != 1 {
		t.Fatalf("%v %s", err, r.body)
	}
	m := v.Data[0].Maturity
	if string(m["noul"]["status"]) != `"experimental"` || string(m["noul"]["lower_bound"]) != "0.425" || string(m["noul"]["baseline"]) != "0.667" || string(m["noul"]["n"]) != "60" {
		t.Errorf("noul maturity: %v", m["noul"])
	}
	if string(m["choice"]["status"]) != `"measured"` {
		t.Errorf("choice maturity: %v", m["choice"])
	}
	if string(m["score"]["status"]) != `"unmeasured"` || string(m["score"]["reason"]) != `"not yet measured"` {
		t.Errorf("score maturity: %v", m["score"])
	}
	if got := strings.Join(v.Data[0].ExperimentalTypes, ","); got != "noul,score" {
		t.Errorf("experimental_types = %q, want noul,score (experimental and unmeasured are both shown as experimental, in type order)", got)
	}
	// golden-false: no maturity info -> neither key appears
	h.be.mu.Lock()
	h.be.models[0].Maturity = nil
	h.be.mu.Unlock()
	r = h.do(h.client(), "GET", "/v1/models", "", nil)
	if strings.Contains(string(r.body), `"maturity"`) || strings.Contains(string(r.body), `"experimental_types"`) {
		t.Errorf("a profile without maturity data must not publish the keys: %s", r.body)
	}
}

// A type missing from a non-empty maturity map is listed as unmeasured (experimental), like the planner.
func TestMaturityOfMissingTypeIsUnmeasured(t *testing.T) {
	v, exp := maturityOf(map[string]MaturityInfo{"noul": {Status: "measured"}})
	if v["choice"].Status != "unmeasured" || v["score"].Status != "unmeasured" || v["choice"].Reason != "not yet measured" {
		t.Errorf("missing types = %+v", v)
	}
	if strings.Join(exp, ",") != "choice,score" {
		t.Errorf("experimental_types = %v, want choice,score", exp)
	}
}
