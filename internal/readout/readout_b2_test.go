package readout_test

import (
	"testing"

	"github.com/vasic-digital/llmctl/internal/readout"
)

// B2-01: the bound of an absent letter must cover every spelling the readout sums for a present
// letter ("B", " B", "▁B"), not just the smallest single listed token.
func TestAbsentLetterBoundCoversAllSpellings(t *testing.T) {
	top := []readout.Entry{e(" A", .4), e("x", .05), e("y", .05), e("z", .05), e("w", .05)}
	r := compute(t, top, []string{"A", "B"}, .4)
	ub := r.UpperBounds["B"]
	// worst case realisable by the unlisted tail (mass .4): "B", " B" and "▁B" each at the floor (.05)
	if ub < .15-1e-9 {
		t.Fatalf("upper bound %v is not a bound: three unlisted spellings of B could hold 0.15", ub)
	}
	if ub > 1 {
		t.Fatalf("bound above 1: %v", ub)
	}
}

func TestAbsentLetterBoundIsCappedAtOne(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .9)}, abc, .5)
	for _, l := range []string{"B", "C"} {
		if r.UpperBounds[l] > 1 || r.UpperBounds[l] <= 0 {
			t.Fatalf("%s bound %v", l, r.UpperBounds[l])
		}
	}
}

// B2-02: the wire value must be comparable with probabilities: a missing option's normalised
// bound is never below its own reported (conservative) probability.
func TestNormalisedBoundIsAtLeastTheConservativeProbability(t *testing.T) {
	for _, temp := range []float64{.5, 1, 2} {
		top := []readout.Entry{e(" A", .55), e("\n", .15), e("x", .1), e("y", .1), e("z", .1)}
		r, err := readout.Compute(top, []string{"A", "B"}, .5, temp)
		if err != nil {
			t.Fatal(err)
		}
		nb, ok := r.NormalisedBounds["B"]
		if !ok {
			t.Fatalf("T=%v: no normalised bound", temp)
		}
		if r.Conservative["B"] > nb+1e-12 {
			t.Fatalf("T=%v: conservative %v exceeds its own bound %v", temp, r.Conservative["B"], nb)
		}
		if nb < 0 || nb > 1 {
			t.Fatalf("T=%v: bound %v", temp, nb)
		}
	}
}

// B2-03/B2-15 (R4): the conservative distribution depends on the temperature.
func TestConservativeDistributionDependsOnTemperature(t *testing.T) {
	top := []readout.Entry{e("A", .6), e("B", .3), e("x", .04), e("y", .02)}
	r1, err := readout.Compute(top, abc, .5, 1)
	if err != nil {
		t.Fatal(err)
	}
	r2, err := readout.Compute(top, abc, .5, 2)
	if err != nil {
		t.Fatal(err)
	}
	if near(r1.Conservative["A"], r2.Conservative["A"]) || near(r1.Conservative["C"], r2.Conservative["C"]) {
		t.Fatalf("temperature ignored by the conservative distribution: %v vs %v", r1.Conservative, r2.Conservative)
	}
	// T=2 flattens: A shrinks, C grows
	if !(r2.Conservative["A"] < r1.Conservative["A"] && r2.Conservative["C"] > r1.Conservative["C"]) {
		t.Fatalf("T=2 must flatten: %v vs %v", r2.Conservative, r1.Conservative)
	}
	sum := 0.0
	for _, p := range r2.Conservative {
		sum += p
	}
	if !near(sum, 1) {
		t.Fatalf("sum %v", sum)
	}
}

// B2-03: an absent letter never outranks a present one in the conservative distribution.
func TestAbsentLetterNeverOutranksAPresentOne(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .9)}, abc, .5)
	if r.Conservative["B"] > r.Conservative["A"]+1e-12 || r.Conservative["C"] > r.Conservative["A"]+1e-12 {
		t.Fatalf("absent letters outrank the present one: %v", r.Conservative)
	}
	r = compute(t, []readout.Entry{e(" B", .5), e("x", .5)}, []string{"A", "B"}, .5)
	if r.Conservative["A"] > r.Conservative["B"]+1e-12 {
		t.Fatalf("absent A outranks present B: %v", r.Conservative)
	}
}
