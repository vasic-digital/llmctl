package gateway

import (
	"context"
	"math"
	"net/http"
	"testing"
)

// Parity with the retired Python gateway's tests/test_decide.sh sections 2-4 (decide_shape_response):
// the same fixture logprobs, the expected values computed here with the same softmax definition.
// ' the' is a non-letter token that must be filtered out.

func softmax(lps []float64) []float64 {
	m := lps[0]
	for _, x := range lps {
		m = math.Max(m, x)
	}
	var d float64
	e := make([]float64, len(lps))
	for i, x := range lps {
		e[i] = math.Exp(x - m)
		d += e[i]
	}
	for i := range e {
		e[i] /= d
	}
	return e
}

func rawABC(t *testing.T) *httpFixture {
	return newFixture(t, llamaResponse(lpEntry{" A", -0.5}, lpEntry{" B", -1.5}, lpEntry{" C", -2.5}, lpEntry{" the", -0.1}))
}

type httpFixture struct{ url string }

func newFixture(t *testing.T, body []byte) *httpFixture {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) { _, _ = w.Write(body) })
	return &httpFixture{url: srv.URL}
}

func TestParityChoiceExactRenormalisedProbabilities(t *testing.T) {
	f := rawABC(t)
	body := `{"model":"decide-tiny","state":"Routing.","questions":{"q":{"type":"choice","instructions":"Which?","criteria":{"x":"desc x","y":"desc y","z":"desc z"}}}}`
	ans, _, err := newLetter().Decide(context.Background(), ep(f.url), specByID(t, "decide-tiny"), parseFor(t, body))
	if err != nil {
		t.Fatal(err)
	}
	a := ans[0].Answer
	want := softmax([]float64{-0.5, -1.5, -2.5})
	if a.Choice != "x" || len(a.Probabilities) != 3 {
		t.Fatalf("%+v", a)
	}
	for i, k := range []string{"x", "y", "z"} {
		if a.Probabilities[i].Key != k || math.Abs(a.Probabilities[i].Value-want[i]) > 1e-8 {
			t.Fatalf("p[%s]=%v want %v", k, a.Probabilities[i].Value, want[i])
		}
	}
	// confidence = clamp((n*pmax-1)/(n-1))
	wc := math.Max(0, math.Min(1, (3*want[0]-1)/2))
	if math.Abs(a.Confidence-wc) > 1e-8 {
		t.Fatalf("confidence %v want %v", a.Confidence, wc)
	}
}

func TestParityNoulExactYesProbabilityNoConfidence(t *testing.T) {
	f := newFixture(t, llamaResponse(lpEntry{" A", -0.03}, lpEntry{" B", -3.5}, lpEntry{" the", -0.5}))
	ans, _, err := newLetter().Decide(context.Background(), ep(f.url), specByID(t, "decide-tiny"), parseFor(t, noulBody))
	if err != nil {
		t.Fatal(err)
	}
	a := ans[0].Answer
	want := softmax([]float64{-0.03, -3.5})[0]
	if a.Type != "noul" || math.Abs(a.Noul-want) > 1e-8 {
		t.Fatalf("noul %v want %v", a.Noul, want)
	}
	if a.Confidence != 0 {
		t.Fatalf("noul carries no confidence, got %v", a.Confidence)
	}
}

func TestParityScoreWeightedExpectationAndLegend(t *testing.T) {
	f := rawABC(t)
	body := `{"model":"decide-tiny","state":"outcome","questions":{"s":{"type":"score","instructions":"Rate","criteria":["bad outcome","mixed outcome","excellent outcome"]}}}`
	ans, _, err := newLetter().Decide(context.Background(), ep(f.url), specByID(t, "decide-tiny"), parseFor(t, body))
	if err != nil {
		t.Fatal(err)
	}
	a := ans[0].Answer
	p := softmax([]float64{-0.5, -1.5, -2.5})
	want := 0*p[0] + 1*p[1] + 2*p[2]
	if math.Abs(a.Score-want) > 1e-8 || len(a.Legend) != 3 || a.Legend[0].Key != "0" || a.Legend[2].Key != "2" {
		t.Fatalf("score %v want %v legend %+v", a.Score, want, a.Legend)
	}
}

// Temperature divides the letter logprobs before the softmax (LLMCTL_DECIDE_TEMPERATURE).
func TestParityTemperatureDividesLogprobs(t *testing.T) {
	f := rawABC(t)
	b := newLetter()
	b.Temperature = 2
	body := `{"model":"decide-tiny","state":"Routing.","questions":{"q":{"type":"choice","instructions":"Which?","criteria":{"x":"a","y":"b","z":"c"}}}}`
	ans, _, err := b.Decide(context.Background(), ep(f.url), specByID(t, "decide-tiny"), parseFor(t, body))
	if err != nil {
		t.Fatal(err)
	}
	want := softmax([]float64{-0.25, -0.75, -1.25})
	for i := range want {
		if math.Abs(ans[0].Answer.Probabilities[i].Value-want[i]) > 1e-8 {
			t.Fatalf("p[%d]=%v want %v", i, ans[0].Answer.Probabilities[i].Value, want[i])
		}
	}
}
