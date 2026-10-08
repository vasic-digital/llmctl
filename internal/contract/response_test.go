package contract_test

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

func question(t *testing.T, typ, crit string) contract.ParsedQuestion {
	t.Helper()
	q := `{"type":"` + typ + `","instructions":"i"`
	if crit != "" {
		q += `,"criteria":` + crit
	}
	return mustParse(t, body("questions", qs("q", q+"}"))).Questions[0]
}

func asMap(t *testing.T, v any) map[string]any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func keysOf(m map[string]any) string {
	var k []string
	for x := range m {
		k = append(k, x)
	}
	return strings.Join(sortStrings(k), ",")
}

func sortStrings(s []string) []string {
	for i := range s {
		for j := i + 1; j < len(s); j++ {
			if s[j] < s[i] {
				s[i], s[j] = s[j], s[i]
			}
		}
	}
	return s
}

func near(a, b, tol float64) bool { return math.Abs(a-b) <= tol }

func TestNoulHasNoConfidence(t *testing.T) {
	a, err := contract.BuildAnswer(question(t, "noul", ""), []float64{0.8, 0.2})
	if err != nil {
		t.Fatal(err)
	}
	m := asMap(t, a)
	if keysOf(m) != "noul,type" || m["noul"] != 0.8 || m["type"] != "noul" {
		t.Fatalf("%v", m)
	}
	raw, _ := json.Marshal(a)
	if string(raw) != `{"type":"noul","noul":0.8}` {
		t.Fatal(string(raw))
	}
}

func TestChoiceAnswer(t *testing.T) {
	a, err := contract.BuildAnswer(question(t, "choice", `{"x":"1","y":"2","z":"3"}`), []float64{0.2, 0.7, 0.1})
	if err != nil {
		t.Fatal(err)
	}
	m := asMap(t, a)
	if keysOf(m) != "choice,confidence,probabilities,type" || m["choice"] != "y" {
		t.Fatalf("%v", m)
	}
	sum := 0.0
	for _, v := range m["probabilities"].(map[string]any) {
		sum += v.(float64)
	}
	if !near(sum, 1, 1e-6) || !near(m["confidence"].(float64), (0.7-1.0/3)/(1-1.0/3), 1e-6) {
		t.Fatalf("%v", m)
	}
	raw, _ := json.Marshal(a)
	if !strings.Contains(string(raw), `"probabilities":{"x":0.2,"y":0.7,"z":0.1}`) {
		t.Fatalf("probabilities must be in option order: %s", raw)
	}
}

func TestChoiceConfidenceExtremesAndTies(t *testing.T) {
	q := question(t, "choice", `{"x":"1","y":"2"}`)
	a, _ := contract.BuildAnswer(q, []float64{0.5, 0.5})
	if a.Confidence != 0 || a.Choice != "x" {
		t.Fatalf("uniform: %+v (first maximum wins)", a)
	}
	a, _ = contract.BuildAnswer(q, []float64{1.0, 0.0})
	if a.Confidence != 1 {
		t.Fatal(a)
	}
	a, _ = contract.BuildAnswer(q, []float64{0.0, 1.0})
	if a.Choice != "y" || a.Confidence != 1 {
		t.Fatal(a)
	}
}

func TestScoreAnswer(t *testing.T) {
	a, err := contract.BuildAnswer(question(t, "score", `["lo","mid","hi"]`), []float64{0.1, 0.2, 0.7})
	if err != nil {
		t.Fatal(err)
	}
	m := asMap(t, a)
	if keysOf(m) != "confidence,legend,probabilities,score,type" {
		t.Fatalf("%v", m)
	}
	if !near(m["score"].(float64), 0.2+1.4, 1e-9) {
		t.Fatal(m["score"])
	}
	l := m["legend"].(map[string]any)
	if l["0"] != "lo" || l["1"] != "mid" || l["2"] != "hi" || len(m["probabilities"].(map[string]any)) != 3 {
		t.Fatalf("%v", m)
	}
	if s := m["score"].(float64); s < 0 || s > 2 {
		t.Fatal(s)
	}
	// legend values keep their original JSON (objects in original key order)
	a, _ = contract.BuildAnswer(question(t, "score", `[{"b":1,"a":2},null]`), []float64{0.5, 0.5})
	raw, _ := json.Marshal(a)
	if !strings.Contains(string(raw), `"legend":{"0":{"b":1,"a":2},"1":null}`) {
		t.Fatal(string(raw))
	}
}

func TestRoundingTo9DecimalsHalfEven(t *testing.T) {
	q := question(t, "choice", `{"x":"1","y":"2"}`)
	a, _ := contract.BuildAnswer(q, []float64{0.1234567894, 0.8765432106})
	if a.Probabilities[0].Value != 0.123456789 || a.Probabilities[1].Value != 0.876543211 {
		t.Fatalf("%+v", a.Probabilities)
	}
	if contract.Round9(2.0/3) != 0.666666667 {
		t.Fatal(contract.Round9(2.0 / 3))
	}
}

func TestBadProbabilitiesRejected(t *testing.T) {
	q := question(t, "choice", `{"x":"1","y":"2"}`)
	nan, inf := math.NaN(), math.Inf(1)
	for _, bad := range [][]float64{{0.5}, {0.5, 0.5, 0}, {nan, 1}, {-0.1, 1.1}, {0.4, 0.4}, {inf, 0}, {math.Inf(-1), 1}, {}, nil, {1 + 2e-9, 0}} {
		if _, err := contract.BuildAnswer(q, bad); err == nil {
			t.Errorf("%v accepted", bad)
		}
	}
	// a probability within 1e-9 above 1 is clamped, not rejected
	a, err := contract.BuildAnswer(q, []float64{1 + 5e-10, 0})
	if err != nil || a.Probabilities[0].Value != 1 {
		t.Fatal(a, err)
	}
	// sum tolerance 1e-6
	if _, err := contract.BuildAnswer(q, []float64{0.5, 0.5 + 9e-7}); err != nil {
		t.Fatal(err)
	}
	if _, err := contract.BuildAnswer(q, []float64{0.5, 0.5 + 2e-6}); err == nil {
		t.Fatal("sum off by 2e-6 accepted")
	}
}

func TestRoundingKeepsSumFor255Options(t *testing.T) {
	n := 255
	probs := make([]float64, n)
	for i := range probs {
		probs[i] = 1.0 / float64(n)
	}
	q := mustParse2(t, body("questions", qs("c", choiceQ(n))))
	a, err := contract.BuildAnswer(q, probs)
	if err != nil {
		t.Fatal(err)
	}
	sum := 0.0
	for _, p := range a.Probabilities {
		sum += p.Value
	}
	if !near(sum, 1, 1e-6) {
		t.Fatal(sum)
	}
}

func mustParse2(t *testing.T, b []byte) contract.ParsedQuestion {
	t.Helper()
	p, err := contract.ParseRequest(b, bigLimit, tinyBig)
	if err != nil {
		t.Fatal(err)
	}
	return p.Questions[0]
}

func TestResponseEnvelope(t *testing.T) {
	a, _ := contract.BuildAnswer(question(t, "noul", ""), []float64{0.8, 0.2})
	b, _ := contract.BuildAnswer(question(t, "choice", `{"x":"1","y":"2"}`), []float64{0.3, 0.7})
	r, err := contract.BuildResponse("decide-tiny", []contract.NamedAnswer{{Name: "zeta", Answer: a}, {Name: "alpha", Answer: b}}, 10, 1)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(r)
	want := `{"model":"decide-tiny","answers":{"zeta":{"type":"noul","noul":0.8},"alpha":{"type":"choice","choice":"y","probabilities":{"x":0.3,"y":0.7},"confidence":0.4}},"usage":{"input_tokens":10,"output_tokens":1}}`
	if string(raw) != want {
		t.Fatalf("\n%s\n%s", raw, want)
	}
	if _, err := contract.BuildResponse("m", nil, -1, 0); err == nil {
		t.Fatal("negative token count")
	}
	if _, err := contract.BuildResponse("m", nil, 0, -1); err == nil {
		t.Fatal("negative token count")
	}
	if _, err := contract.BuildResponse("", nil, 0, 0); err == nil {
		t.Fatal("empty model id")
	}
	r, _ = contract.BuildResponse("m", nil, 0, 0)
	raw, _ = json.Marshal(r)
	if string(raw) != `{"model":"m","answers":{},"usage":{"input_tokens":0,"output_tokens":0}}` {
		t.Fatal(string(raw))
	}
}

func TestEstimateTokens(t *testing.T) {
	for in, want := range map[int]int{0: 0, 1: 1, 4: 1, 5: 2, 9: 3} {
		got, err := contract.EstimateTokens(in)
		if err != nil || got != want {
			t.Errorf("%d -> %d, %v", in, got, err)
		}
	}
	if _, err := contract.EstimateTokens(-1); err == nil {
		t.Fatal("negative chars")
	}
}

// A calibrated answer carries the audit pair (raw confidence + the calibration that replaced it) and
// nothing else changes; an uncalibrated answer is byte-identical to the original shape.
func TestCalibratedAnswerAdditiveFields(t *testing.T) {
	q := question(t, "choice", `{"x":"1","y":"2"}`)
	a, err := contract.BuildAnswer(q, []float64{0.2, 0.8})
	if err != nil {
		t.Fatal(err)
	}
	plain, _ := json.Marshal(a)
	if strings.Contains(string(plain), "calibration") || strings.Contains(string(plain), "confidence_raw") {
		t.Fatalf("an uncalibrated answer must keep the original shape: %s", plain)
	}
	raw := a.Confidence
	a.ConfidenceRaw = raw
	a.Confidence = 0.64
	a.Calibration = &contract.Calibration{Method: "temperature", N: 250, ProfileID: "decide-tiny"}
	b, _ := json.Marshal(a)
	m := asMap(t, a)
	if keysOf(m) != "calibration,choice,confidence,confidence_raw,probabilities,type" {
		t.Fatalf("keys: %s", keysOf(m))
	}
	if m["confidence"].(float64) != 0.64 || m["confidence_raw"].(float64) != raw {
		t.Errorf("confidence/raw: %v", m)
	}
	c := m["calibration"].(map[string]any)
	if c["method"] != "temperature" || c["n"].(float64) != 250 || c["profile_id"] != "decide-tiny" {
		t.Errorf("calibration: %v", c)
	}
	if !strings.Contains(string(b), `"probabilities":{"x":0.2,"y":0.8},"confidence":0.64,"confidence_raw":`) {
		t.Errorf("field order: %s", b)
	}
	// a flagged answer keeps flags/upper_bounds after the calibration fields
	f, _ := contract.BuildAnswerBounded(q, []float64{0.3, 0.7}, map[string]float64{"x": 0.4})
	f.ConfidenceRaw, f.Calibration = f.Confidence, &contract.Calibration{Method: "platt", N: 300, ProfileID: "p"}
	fm := asMap(t, f)
	if keysOf(fm) != "calibration,choice,confidence,confidence_raw,flags,probabilities,type,upper_bounds" {
		t.Errorf("flagged keys: %s", keysOf(fm))
	}
}
