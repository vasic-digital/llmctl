package contract_test

import (
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// B3-01: the winner of a bounded answer is chosen among the options the readout LISTED; the worst
// case it carries must never be reported for an option nobody saw.
func TestBoundedAnswerChoosesAmongListedOptionsOnly(t *testing.T) {
	q := question(t, "choice", `{"a":"x","b":"y","c":"z"}`)
	// worst-case distribution in which the absent option "c" holds more than any listed one
	a, err := contract.BuildAnswerBounded(q, []float64{0.2, 0.1, 0.7}, map[string]float64{"c": 0.9})
	if err != nil {
		t.Fatal(err)
	}
	if a.Choice != "a" {
		t.Fatalf("choice %q: the absent option won", a.Choice)
	}
	// confidence is that of the listed winner (share 0.2 of 3 options -> (0.2-1/3)/(2/3) < 0 -> 0)
	if a.Confidence != 0 {
		t.Fatalf("confidence %v", a.Confidence)
	}
	a, err = contract.BuildAnswerBounded(q, []float64{0.5, 0.1, 0.4}, map[string]float64{"c": 0.4})
	if err != nil || a.Choice != "a" || a.Confidence <= 0.2 || a.Confidence >= 0.3 {
		t.Fatalf("%+v %v", a, err)
	}
}
