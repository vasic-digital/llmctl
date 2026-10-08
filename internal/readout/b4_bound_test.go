package readout_test

import (
	"math"
	"math/rand"
	"testing"

	"github.com/vasic-digital/llmctl/internal/readout"
)

// B3-01: the listed mass is 1.0, so an absent letter provably holds ~0 (the old bound said 0.6).
func TestListedMassOneGivesAbsentLettersBoundZero(t *testing.T) {
	r := compute(t, []readout.Entry{e(" A", .5), e(" C", .2), e("x", .3)}, abc, .5)
	if len(r.Missing) != 1 || r.Missing[0] != "B" {
		t.Fatalf("%+v", r)
	}
	if r.UpperBounds["B"] > 1e-9 || r.NormalisedBounds["B"] > 1e-9 {
		t.Fatalf("a fully listed distribution leaves nothing to hide: %+v", r)
	}
}

// B3-01 (reviewer probe): a low-ranked present letter must not shrink the absent bound to the floor.
func TestAbsentLetterKeepsItsFullBoundNextToALowRankedPresentLetter(t *testing.T) {
	top := []readout.Entry{e(" A", .6), e("x", .1), e("y", .1), e("z", .1), e(" C", .05)}
	r := compute(t, top, abc, .5)
	// pmin .05, U = 1-.95 = .05: bound = min(3*.05, .05) = .05; present masses 0.6 and 0.05
	if !near(r.UpperBounds["B"], .05) {
		t.Fatalf("bound %v", r.UpperBounds["B"])
	}
	// the conservative A share is the worst case: .6/(.6+.05+.05)
	if !near(r.Conservative["A"], .6/.7) {
		t.Fatalf("A = %v, want %v", r.Conservative["A"], .6/.7)
	}
}

// Every absent letter gets its OWN full bound; the masses they hold jointly never exceed U.
func TestEveryAbsentLetterReportsItsOwnBoundAndTheJointMassIsCapped(t *testing.T) {
	top := []readout.Entry{e(" A", .4), e("x", .1), e("y", .1), e("z", .1), e("w", .1)} // listed .8, U .2, pmin .1
	r := compute(t, top, []string{"A", "B", "C", "D"}, .3)
	for _, l := range []string{"B", "C", "D"} {
		if !near(r.UpperBounds[l], .2) { // min(3*.1, .2)
			t.Fatalf("%s bound %v", l, r.UpperBounds[l])
		}
	}
	// jointly: sum of hidden mass <= U = .2, so A >= .4/(.4+.2)
	if got := r.Conservative["A"]; got < .4/.6-1e-9 || got > .4/.6+1e-9 {
		t.Fatalf("A = %v want %v", got, .4/.6)
	}
	sum := 0.0
	for _, p := range r.Conservative {
		sum += p
	}
	if !near(sum, 1) {
		t.Fatalf("not normalised: %v", sum)
	}
}

// B3-01 property: for random listed distributions and ALL feasible placements of the hidden mass
// (every absent letter x_i in [0, bound_i], sum x_i <= U) the winner's true share is not below the
// share the Conservative distribution reports (soundness), and the report is not looser than the
// worst grid placement by more than the grid resolution (tightness). Seeded.
func TestConservativeShareIsATrueLowerBoundForEveryFeasibleHiddenAllocation(t *testing.T) {
	rng := rand.New(rand.NewSource(20261008))
	letters := []string{"A", "B", "C", "D"}
	for iter := 0; iter < 300; iter++ {
		// random listed set: 1-3 present letters + 2-6 other tokens, total listed mass in (0.5, 1]
		nPres := 1 + rng.Intn(3)
		nOther := 2 + rng.Intn(5)
		var ps []float64
		var toks []string
		for i := 0; i < nPres; i++ {
			toks = append(toks, " "+letters[i])
		}
		for i := 0; i < nOther; i++ {
			toks = append(toks, "t"+string(rune('a'+i)))
		}
		raw := make([]float64, len(toks))
		tot := 0.0
		for i := range raw {
			raw[i] = 0.05 + rng.Float64()
			tot += raw[i]
		}
		listedMass := 0.5 + 0.5*rng.Float64()
		if rng.Intn(4) == 0 {
			listedMass = 1
		}
		var top []readout.Entry
		for i := range raw {
			p := raw[i] / tot * listedMass
			ps = append(ps, p)
			top = append(top, e(toks[i], p))
		}
		// the oracle is derived HERE from the input, not read from the code under test
		S, pmin := 0.0, math.Inf(1)
		for _, p := range ps {
			S += p
			pmin = math.Min(pmin, p)
		}
		U := math.Max(0, 1-S)
		if U < readout.UnlistedEpsilon {
			U = 0
		}
		bound := math.Min(3*pmin, U)
		letterMass := map[string]float64{}
		for i := 0; i < nPres; i++ {
			letterMass[letters[i]] = ps[i]
		}
		var absent []string
		for _, l := range letters {
			if _, ok := letterMass[l]; !ok {
				absent = append(absent, l)
			}
		}
		for _, T := range []float64{0.5, 1, 2} {
			thr := 0.01
			r, err := readout.Compute(top, letters, thr, T)
			if err != nil {
				t.Fatal(err)
			}
			if len(absent) == 0 {
				continue
			}
			a := 1 / T
			for i := 0; i < nPres; i++ {
				w := letters[i]
				// brute force over a grid of hidden allocations
				const G = 12
				worst := math.Inf(1)
				var rec func(k int, left float64, den float64)
				rec = func(k int, left float64, den float64) {
					if k == len(absent) {
						share := math.Pow(letterMass[w], a) / den
						worst = math.Min(worst, share)
						return
					}
					for j := 0; j <= G; j++ {
						x := bound * float64(j) / G
						if x > left+1e-15 {
							// also try the remaining-mass vertex
							rec(k+1, 0, den+math.Pow(left, a))
							break
						}
						rec(k+1, left-x, den+math.Pow(x, a))
					}
				}
				den0 := 0.0
				for k := 0; k < nPres; k++ {
					den0 += math.Pow(letterMass[letters[k]], a)
				}
				rec(0, U, den0)
				got := r.Conservative[w]
				if got > worst+1e-9 {
					t.Fatalf("iter %d T=%v letter %s: reported share %.6f exceeds a feasible hidden allocation's %.6f (S=%.4f pmin=%.4f U=%.4f)", iter, T, w, got, worst, S, pmin, U)
				}
				if worst-got > 0.05 {
					t.Fatalf("iter %d T=%v letter %s: reported share %.6f is far below the grid worst case %.6f (too loose)", iter, T, w, got, worst)
				}
			}
			// every absent letter's own bound
			for _, l := range absent {
				if !near(r.UpperBounds[l], bound) {
					t.Fatalf("iter %d: %s bound %v want %v", iter, l, r.UpperBounds[l], bound)
				}
			}
		}
	}
}

func TestWorstAllocationShapes(t *testing.T) {
	// concave (a<=1): even split up to the caps
	got := readout.WorstAllocation([]float64{.3, .3, .3}, .3, 1)
	for _, x := range got {
		if !near(x, .1) {
			t.Fatalf("concave: %v", got)
		}
	}
	// convex (a>1): concentrate on the largest cap first
	got = readout.WorstAllocation([]float64{.3, .3, .3}, .5, 2)
	if !near(got[0]+got[1]+got[2], .5) || !(near(got[0], .3) || near(got[1], .3) || near(got[2], .3)) {
		t.Fatalf("convex: %v", got)
	}
	// caps bind
	got = readout.WorstAllocation([]float64{.05, .4}, 1, 1)
	if !near(got[0], .05) || !near(got[1], .4) {
		t.Fatalf("caps: %v", got)
	}
}
