package client

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAnnotatePreservesBytesAndAddsEvidence(t *testing.T) {
	in := []byte(`{"model":"decide-tiny","answers":{"q":{"type":"noul","noul":0.9}},"usage":{"input_tokens":4,"output_tokens":1}}` + "\n")
	tr := true
	out, err := Annotate(in, Annotation{Profile: "decide-tiny", Port: 8095, Latency: 12.3456, Truncated: true, Abstained: &tr})
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	if !strings.HasPrefix(s, strings.TrimSpace(string(in))[:len(strings.TrimSpace(string(in)))-1]) {
		t.Fatalf("gateway bytes altered: %s", s)
	}
	var d map[string]json.RawMessage
	if err := json.Unmarshal(out, &d); err != nil {
		t.Fatal(err)
	}
	var ev struct {
		Profile   string  `json:"profile"`
		Port      int     `json:"port"`
		LatencyMS float64 `json:"latency_ms"`
		Truncated bool    `json:"truncated"`
	}
	if err := json.Unmarshal(d["evidence"], &ev); err != nil || ev.Profile != "decide-tiny" || ev.Port != 8095 || ev.LatencyMS != 12.346 || !ev.Truncated {
		t.Fatalf("evidence %s %v", d["evidence"], err)
	}
	if string(d["abstained"]) != "true" {
		t.Fatal(string(d["abstained"]))
	}
}

func TestAnnotateOmitsAbstainedAndRejectsNonObjects(t *testing.T) {
	out, err := Annotate([]byte(`{"model":"m"}`), Annotation{Profile: "m", Port: 1, Latency: 0.5})
	if err != nil || strings.Contains(string(out), "abstained") || strings.Contains(string(out), "truncated") {
		t.Fatalf("%s %v", out, err)
	}
	for _, bad := range []string{`[1]`, `"x"`, ``, `{`} {
		if _, err := Annotate([]byte(bad), Annotation{}); err == nil {
			t.Errorf("Annotate(%q) should fail", bad)
		}
	}
	if o, err := Annotate([]byte(`{}`), Annotation{Profile: "m"}); err != nil || !json.Valid(o) {
		t.Fatalf("empty object: %s %v", o, err)
	}
}

func TestMinConfidence(t *testing.T) {
	body := []byte(`{"model":"m","answers":{
		"a":{"type":"choice","choice":"x","probabilities":{"x":0.7,"y":0.3},"confidence":0.4},
		"b":{"type":"noul","noul":0.95},
		"c":{"type":"score","score":1.2,"legend":{},"probabilities":{"0":0.1,"1":0.9},"confidence":0.8}}}`)
	got, err := MinConfidence(body)
	if err != nil || got != 0.4 {
		t.Fatalf("min=%v err=%v", got, err)
	}
	noul, _ := MinConfidence([]byte(`{"answers":{"b":{"type":"noul","noul":0.6}}}`))
	if noul < 0.19 || noul > 0.21 { // (0.6-0.5)/0.5
		t.Fatalf("noul confidence %v", noul)
	}
	flat, _ := MinConfidence([]byte(`{"answers":{"b":{"type":"noul","noul":0.5}}}`))
	if flat != 0 {
		t.Fatalf("a coin-flip noul has confidence 0, got %v", flat)
	}
	if _, err := MinConfidence([]byte(`nope`)); err == nil {
		t.Fatal("malformed body must error")
	}
}
