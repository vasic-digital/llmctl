package client

import (
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

const calObj = `{"method":"temperature","n":240,"profile_id":"decide-tiny"}`

func calBody(extra string) []byte {
	return []byte(`{"model":"m","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":0.7,"b":0.3},"confidence":0.8,"confidence_raw":0.4,"calibration":` + calObj + extra + `}}}`)
}

// The abstention gate compares the CALIBRATED confidence (probability scale) when the answer carries
// a calibration object; the shaped-scale re-derivation must not drag a calibrated flagged answer down.
func TestGateUsesCalibratedConfidenceWhenPresent(t *testing.T) {
	got, err := MinConfidence(calBody(``))
	if err != nil || math.Abs(got-0.8) > 1e-9 {
		t.Fatalf("calibrated confidence is what the gate reads: %v %v", got, err)
	}
	flagged := []byte(`{"model":"m","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":0.7,"b":0.3},"confidence":0.65,"confidence_raw":0.4,"calibration":` + calObj + `,"flags":["option_missing"],"upper_bounds":{"b":0.3}}}}`)
	got, _ = MinConfidence(flagged)
	if math.Abs(got-0.65) > 1e-9 { // the shaped cap (0.4) is a different scale: the gateway already capped at the winner's share
		t.Fatalf("a calibrated flagged answer keeps its calibrated confidence: %v", got)
	}
	// "mixed" metadata (a permuted run whose calls disagreed) is NOT calibrated: the shaped rule applies
	mixed := []byte(strings.Replace(string(flagged), calObj, `"mixed"`, 1))
	got, _ = MinConfidence(mixed)
	if math.Abs(got-0.4) > 1e-9 {
		t.Fatalf("mixed calibration is read as uncalibrated: %v", got)
	}
}

func TestAnyCalibrated(t *testing.T) {
	if ok, err := AnyCalibrated(calBody(``)); err != nil || !ok {
		t.Fatal(ok, err)
	}
	plain := []byte(`{"model":"m","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":0.7,"b":0.3},"confidence":0.4}}}`)
	if ok, _ := AnyCalibrated(plain); ok {
		t.Fatal("uncalibrated answer")
	}
	mixed := []byte(strings.Replace(string(calBody(``)), calObj, `"mixed"`, 1))
	if ok, _ := AnyCalibrated(mixed); ok {
		t.Fatal("mixed is not calibrated")
	}
}

func TestAnnotateEvidenceCalibratedAndPassThrough(t *testing.T) {
	body := calBody(``)
	for _, c := range []bool{true, false} {
		out, err := Annotate(body, Annotation{Profile: "m", Port: 1, Latency: 1, Calibrated: c})
		if err != nil {
			t.Fatal(err)
		}
		var d struct {
			Answers  map[string]map[string]json.RawMessage `json:"answers"`
			Evidence map[string]json.RawMessage            `json:"evidence"`
		}
		if err := json.Unmarshal(out, &d); err != nil {
			t.Fatal(err)
		}
		want := "false"
		if c {
			want = "true"
		}
		if string(d.Evidence["calibrated"]) != want {
			t.Fatalf("evidence.calibrated %s want %s: %s", d.Evidence["calibrated"], want, out)
		}
		// the gateway's additive fields are passed through byte for byte
		if string(d.Answers["q"]["confidence_raw"]) != "0.4" || string(d.Answers["q"]["calibration"]) != calObj {
			t.Fatalf("calibration fields altered: %s", out)
		}
	}
}

// permCalGateway answers every call with a calibrated answer whose metadata comes from meta(call#).
func permCalGateway(t *testing.T, meta func(i int32) string, conf func(i int32) string) *Client {
	t.Helper()
	var n atomic.Int32
	srv := newTLSServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		i := n.Add(1) - 1
		keys := criteriaOrder(t, b, "c")
		var probs []string
		for _, k := range keys {
			kb, _ := json.Marshal(k)
			probs = append(probs, string(kb)+":0.5")
		}
		fk, _ := json.Marshal(keys[0])
		extra := ""
		if m := meta(i); m != "" {
			extra = `,"confidence_raw":0.1,"calibration":` + m
		}
		_, _ = w.Write([]byte(`{"model":"m","answers":{"c":{"type":"choice","choice":` + string(fk) + `,"probabilities":{` + strings.Join(probs, ",") + `},"confidence":` + conf(i) + extra + `}},"usage":{"input_tokens":1,"output_tokens":1}}`))
	}))
	c, _ := newTestClient(t, srv, nil)
	return c
}

const permReq = `{"state":"s","questions":{"c":{"type":"choice","instructions":"p","criteria":{"a":"1","b":"2"}}}}`

func permAnswerOf(t *testing.T, res *Result) map[string]json.RawMessage {
	t.Helper()
	var out struct {
		Answers map[string]map[string]json.RawMessage `json:"answers"`
	}
	if err := json.Unmarshal(res.Body, &out); err != nil {
		t.Fatal(err)
	}
	return out.Answers["c"]
}

func TestPermuteKeepsIdenticalCalibrationAndAveragesCalibratedConfidence(t *testing.T) {
	c := permCalGateway(t, func(int32) string { return calObj }, func(i int32) string { return []string{"0.6", "0.8"}[i%2] })
	res, _, err := c.AskPermuted(t.Context(), []byte(permReq), 2)
	if err != nil {
		t.Fatal(err)
	}
	a := permAnswerOf(t, res)
	if string(a["calibration"]) != calObj {
		t.Fatalf("identical calibration metadata is kept: %s", res.Body)
	}
	var conf, raw float64
	_ = json.Unmarshal(a["confidence"], &conf)
	_ = json.Unmarshal(a["confidence_raw"], &raw)
	if math.Abs(conf-0.7) > 1e-9 || raw != 0 { // mean(0.6,0.8); averaged probabilities are tied: shaped 0
		t.Fatalf("confidence %v (calibrated mean) raw %v (shaped from the averaged probabilities): %s", conf, raw, res.Body)
	}
}

func TestPermuteDifferingCalibrationIsMixedAndNotCalibrated(t *testing.T) {
	for name, meta := range map[string]func(int32) string{
		"different n":      func(i int32) string { return strings.Replace(calObj, "240", []string{"240", "300"}[i%2], 1) },
		"one uncalibrated": func(i int32) string { return []string{calObj, ""}[i%2] },
		"different profile": func(i int32) string {
			return strings.Replace(calObj, "decide-tiny", []string{"decide-tiny", "other"}[i%2], 1)
		},
	} {
		c := permCalGateway(t, meta, func(int32) string { return "0.9" })
		res, _, err := c.AskPermuted(t.Context(), []byte(permReq), 2)
		if err != nil {
			t.Fatal(name, err)
		}
		a := permAnswerOf(t, res)
		if string(a["calibration"]) != `"mixed"` {
			t.Fatalf("%s: want calibration \"mixed\": %s", name, res.Body)
		}
		var conf float64
		_ = json.Unmarshal(a["confidence"], &conf)
		if conf != 0 { // tied averaged probabilities: shaped confidence 0, NOT the 0.9 calibrated claims
			t.Fatalf("%s: mixed answers carry the shaped confidence, got %v", name, conf)
		}
		if ok, _ := AnyCalibrated(res.Body); ok {
			t.Fatalf("%s: mixed must not count as calibrated", name)
		}
	}
}

func TestPermuteWithoutCalibrationAddsNoFields(t *testing.T) {
	c := permCalGateway(t, func(int32) string { return "" }, func(int32) string { return "0.5" })
	res, _, err := c.AskPermuted(t.Context(), []byte(permReq), 2)
	if err != nil {
		t.Fatal(err)
	}
	a := permAnswerOf(t, res)
	if _, ok := a["calibration"]; ok {
		t.Fatalf("no calibration field when no call was calibrated: %s", res.Body)
	}
	if _, ok := a["confidence_raw"]; ok {
		t.Fatalf("no confidence_raw when no call was calibrated: %s", res.Body)
	}
}
