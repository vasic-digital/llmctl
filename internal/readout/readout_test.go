package readout_test

import (
	"encoding/json"
	"errors"
	"math"
	"testing"

	"github.com/vasic-digital/llmctl/internal/readout"
)

var inf = math.Inf(1)

func e(tok string, p float64) readout.Entry {
	if p <= 0 {
		return readout.Entry{Token: tok, Logprob: math.Inf(-1)}
	}
	return readout.Entry{Token: tok, Logprob: math.Log(p)}
}

func near(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func compute(t *testing.T, top []readout.Entry, letters []string, th float64) *readout.Readout {
	t.Helper()
	r, err := readout.Compute(top, letters, th, 1.0)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

var abc = []string{"A", "B", "C"}

func TestSumOverSpellings(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .2), e(" A", .3), e("B", .25), e(" B", .05), e("C", .1)}, abc, .5)
	if !near(r.Mass, .9) || !near(r.Probabilities["A"], .5/.9) || !near(r.Probabilities["B"], .3/.9) {
		t.Fatalf("%+v", r)
	}
	sum := 0.0
	for _, p := range r.Probabilities {
		sum += p
	}
	if !near(sum, 1) || len(r.Missing) != 0 || r.Flagged() {
		t.Fatalf("%+v", r)
	}
}

func TestLowercaseAndOtherTokensDoNotCount(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .5), e("a", .3), e(" a", .1), e("AB", .05), e("B", .1), e("\n", .05), e("  A", .01), e("Á", .01)}, []string{"A", "B"}, .5)
	if !near(r.Mass, .6) || !near(r.Probabilities["A"], .5/.6) {
		t.Fatalf("%+v", r)
	}
}

func TestSentencepieceSpaceMarker(t *testing.T) {
	r := compute(t, []readout.Entry{e("▁A", .6), e("B", .3)}, []string{"A", "B"}, .5)
	if !near(r.Probabilities["A"], .6/.9) {
		t.Fatalf("%+v", r)
	}
	// the marker alone, or two markers, is not a letter
	r = compute(t, []readout.Entry{e("▁", .3), e("▁▁A", .3), e("A", .6), e("B", .3)}, []string{"A", "B"}, .5)
	if !near(r.Mass, .9) {
		t.Fatalf("%+v", r)
	}
}

// B-10: llama-server lists one entry per token ID, so two entries with the same text and DIFFERENT
// ids are different probability mass and are summed; only the very same id listed twice is one entry.
func TestSameTextDistinctTokensAreSummed(t *testing.T) {
	// without ids the entries are distinct tokens: 0.4 + 0.4 of "A"
	r := compute(t, []readout.Entry{e("A", .4), e("A", .4), e("B", .1)}, []string{"A", "B"}, .5)
	if !near(r.Mass, .9) || !near(r.Probabilities["A"], .8/.9) {
		t.Fatalf("same-text tokens must be summed, not max-ed: %+v", r)
	}
	// and the order does not matter
	r = compute(t, []readout.Entry{e("A", .1), e("A", .4), e("B", .5)}, []string{"A", "B"}, .5)
	if !near(r.Mass, 1.0) {
		t.Fatalf("mass %v", r.Mass)
	}
	// a mass that only reaches the threshold when both ids are counted passes
	r = compute(t, []readout.Entry{e("A", .3), e(" A", .3), e("A", .2), e("B", .1)}, []string{"A", "B"}, .5)
	if !near(r.Mass, .9) {
		t.Fatalf("mass %v", r.Mass)
	}
}

func ide(tok string, p float64, id int) readout.Entry {
	en := e(tok, p)
	en.ID, en.HasID = id, true
	return en
}

func TestSameTokenIDListedTwiceIsOneEntry(t *testing.T) {
	r := compute(t, []readout.Entry{ide("A", .4, 7), ide("A", .4, 7), ide("B", .1, 8)}, []string{"A", "B"}, .5)
	if !near(r.Mass, .5) {
		t.Fatalf("one id is one entry (the highest logprob wins): %+v", r)
	}
	r = compute(t, []readout.Entry{ide("A", .1, 7), ide("A", .4, 7), ide("B", .1, 8)}, []string{"A", "B"}, .5)
	if !near(r.Mass, .5) {
		t.Fatalf("highest wins for a repeated id: %+v", r)
	}
	r = compute(t, []readout.Entry{ide("A", .3, 7), ide("A", .3, 9), ide("B", .1, 8)}, []string{"A", "B"}, .5)
	if !near(r.Mass, .7) {
		t.Fatalf("two ids with the same text are two entries: %+v", r)
	}
}

func TestRawEntriesCarryTheTokenID(t *testing.T) {
	top := []any{
		map[string]any{"token": "A", "logprob": math.Log(.3), "id": float64(7)},
		map[string]any{"token": "A", "logprob": math.Log(.3), "id": float64(9)},
		map[string]any{"token": "B", "logprob": math.Log(.2), "id": float64(8)},
	}
	r, err := readout.ComputeRaw(top, []string{"A", "B"}, .5, 1)
	if err != nil || !near(r.Mass, .8) {
		t.Fatalf("%v %+v", err, r)
	}
}

// B-01: the conservative distribution gives an absent option its upper bound as mass.
func TestConservativeDistributionFillsMissingWithUpperBound(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .6), e("B", .3), e("x", .04), e("y", .02)}, abc, .5)
	c, ok := r.Conservative["C"]
	if !ok || c <= 0 {
		t.Fatalf("an absent option must hold mass in the conservative distribution, never 0: %+v", r.Conservative)
	}
	want := .04 / (.6 + .3 + .04) // the bound is min(3*p_min=.06, 1-listed=.04) (B3-01)
	if !near(c, want) {
		t.Fatalf("C = %v, want %v", c, want)
	}
	sum := 0.0
	for _, p := range r.Conservative {
		sum += p
	}
	if !near(sum, 1) {
		t.Fatalf("sum %v", sum)
	}
	if r.Probabilities["C"] != 0 {
		t.Fatal("Probabilities keeps the flagged zero (bounds are the honest claim)")
	}
	// a complete readout: both views agree
	r = compute(t, []readout.Entry{e("A", .5), e("B", .3), e("C", .1)}, abc, .5)
	for k, v := range r.Probabilities {
		if !near(r.Conservative[k], v) {
			t.Fatalf("complete readout: conservative %v != %v", r.Conservative, r.Probabilities)
		}
	}
	// the noul case of the review: only A listed
	r = compute(t, []readout.Entry{e("A", .74), e("\n", .2)}, []string{"A", "B"}, .5)
	// listed .94, so everything unlisted is .06: B holds at most min(3*.2, .06) = .06 (B3-01)
	if !near(r.Conservative["B"], .06/.80) || !near(r.Conservative["A"]+r.Conservative["B"], 1) {
		t.Fatalf("B is bounded by the unlisted mass, not 0: %+v", r.Conservative)
	}
}

func TestLettersNotInOptionsIgnored(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .5), e("B", .3), e("Z", .15)}, []string{"A", "B"}, .5)
	if !near(r.Mass, .8) {
		t.Fatal(r.Mass)
	}
}

func TestBelowThresholdFailsNotRetryable(t *testing.T) {
	_, err := readout.Compute([]readout.Entry{e("A", .1), e("B", .1), e("The", .8)}, []string{"A", "B"}, .5, 1)
	var rf *readout.ReadoutFailed
	if !errors.As(err, &rf) {
		t.Fatalf("%v", err)
	}
	if rf.Status() != 422 || rf.ErrorType() != "readout_failed" || rf.Retryable() || !near(rf.Mass, .2) {
		t.Fatalf("%+v", rf)
	}
}

func TestExactThresholdPasses(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .25), e("B", .25)}, []string{"A", "B"}, .5)
	if !near(r.Mass, .5) {
		t.Fatal(r.Mass)
	}
	// the boundary is on the computed mass: a threshold exactly equal to it passes, one ulp above fails
	th := math.Exp(math.Log(.25)) + math.Exp(math.Log(.25))
	if _, err := readout.Compute([]readout.Entry{e("A", .25), e("B", .25)}, []string{"A", "B"}, th, 1); err != nil {
		t.Fatalf("mass == threshold must pass: %v", err)
	}
	if _, err := readout.Compute([]readout.Entry{e("A", .25), e("B", .25)}, []string{"A", "B"}, math.Nextafter(th, 1), 1); err == nil {
		t.Fatal("mass below threshold must fail")
	}
}

func TestRenormalisedOnlyAboveThresholdAndMassReported(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .45), e("B", .45)}, []string{"A", "B"}, .5)
	if !near(r.Probabilities["A"], .5) || !near(r.Mass, .9) {
		t.Fatalf("%+v", r)
	}
}

func TestNoLettersAtAllFails(t *testing.T) {
	_, err := readout.Compute([]readout.Entry{e("The", .9)}, []string{"A", "B"}, .5, 1)
	var rf *readout.ReadoutFailed
	if !errors.As(err, &rf) || rf.Mass != 0 {
		t.Fatal(err)
	}
}

func TestBadThresholdAndTemperatureAndLetters(t *testing.T) {
	top := []readout.Entry{e("A", .5), e("B", .4)}
	for _, th := range []float64{0, -.1, 1.5, math.NaN(), inf} {
		if _, err := readout.Compute(top, []string{"A", "B"}, th, 1); !errors.Is(err, readout.ErrBadArgument) {
			t.Errorf("threshold %v: %v", th, err)
		}
	}
	if _, err := readout.Compute(top, []string{"A", "B"}, 1, 1); err != nil && !errors.As(err, new(*readout.ReadoutFailed)) {
		t.Fatalf("threshold 1 is legal: %v", err)
	}
	for _, tt := range []float64{0, -1, math.NaN(), inf} {
		if _, err := readout.Compute(top, []string{"A", "B"}, .1, tt); !errors.Is(err, readout.ErrBadArgument) {
			t.Errorf("temperature %v: %v", tt, err)
		}
	}
	for _, l := range [][]string{{"a", "B"}, {"A", "A"}, {"AB", "C"}, {}, {"A"}, {"1", "B"}, {"A", ""}, nil, {"É", "B"}} {
		if _, err := readout.Compute(top, l, .1, 1); !errors.Is(err, readout.ErrBadArgument) {
			t.Errorf("letters %q: %v", l, err)
		}
	}
}

func TestMissingLetterFlaggedWithUpperBoundNotSilentZero(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .6), e("B", .3), e("x", .04), e("y", .02)}, abc, .5)
	if len(r.Missing) != 1 || r.Missing[0] != "C" || !r.Flagged() {
		t.Fatalf("%+v", r)
	}
	ub, ok := r.UpperBounds["C"]
	if !ok || !near(ub, .04) { // min(3*.02, 1-.96)
		t.Fatalf("upper bound %v", r.UpperBounds)
	}
	if r.Probabilities["C"] != 0 {
		t.Fatal("flagged zero")
	}
	if _, bad := r.UpperBounds["A"]; bad {
		t.Fatal("observed letter has no upper bound")
	}
}

func TestAllMissingButOne(t *testing.T) {
	r := compute(t, []readout.Entry{e("A", .9)}, abc, .5)
	if len(r.Missing) != 2 || r.Missing[0] != "B" || r.Missing[1] != "C" || len(r.UpperBounds) != 2 || !near(r.UpperBounds["B"], .1) { // 1 - listed(.9)
		t.Fatalf("%+v", r)
	}
}

func TestInvalidLogprobs(t *testing.T) {
	ab := []string{"A", "B"}
	cases := map[string][]readout.Entry{
		"nan":           {{Token: "A", Logprob: math.NaN()}, e("B", .5)},
		"+inf":          {{Token: "A", Logprob: inf}, e("B", .5)},
		"above zero":    {{Token: "A", Logprob: 0.5}, e("B", .5)},
		"all -inf":      {{Token: "A", Logprob: math.Inf(-1)}, {Token: "B", Logprob: math.Inf(-1)}},
		"tiny positive": {{Token: "A", Logprob: 1e-8}, e("B", .5)},
	}
	for name, top := range cases {
		_, err := readout.Compute(top, ab, .1, 1)
		var rf *readout.ReadoutFailed
		if !errors.As(err, &rf) {
			t.Errorf("%s: %v", name, err)
		}
	}
	// 1e-9 above zero is within the tolerance
	if _, err := readout.Compute([]readout.Entry{{Token: "A", Logprob: 5e-10}, e("B", .5)}, ab, .1, 1); err != nil {
		t.Fatalf("5e-10 is tolerated: %v", err)
	}
}

func TestSingleNegativeInfinityIsZeroMassNotMissing(t *testing.T) {
	r := compute(t, []readout.Entry{{Token: "A", Logprob: math.Inf(-1)}, e("B", .8)}, []string{"A", "B"}, .5)
	if r.Probabilities["A"] != 0 || !near(r.Probabilities["B"], 1) || r.Flagged() {
		t.Fatalf("%+v", r)
	}
}

func TestRawEntriesNonNumericAndMalformed(t *testing.T) {
	ab := []string{"A", "B"}
	good := map[string]any{"token": "B", "logprob": math.Log(.5)}
	for _, bad := range []any{"-0.1", nil, true, []any{1.0}, json.Number("x")} {
		_, err := readout.ComputeRaw([]any{map[string]any{"token": "A", "logprob": bad}, good}, ab, .1, 1)
		var rf *readout.ReadoutFailed
		if !errors.As(err, &rf) {
			t.Errorf("logprob %#v: %v", bad, err)
		}
	}
	for _, bad := range [][]any{nil, {}, {1, 2}, {map[string]any{"logprob": -1.0}}, {map[string]any{"token": 5.0, "logprob": -1.0}}, {map[string]any{"token": "A"}}, {"x"}} {
		_, err := readout.ComputeRaw(bad, ab, .1, 1)
		var be *readout.BackendReadoutError
		if !errors.As(err, &be) {
			t.Errorf("entries %#v: %v", bad, err)
		}
	}
	// ints, float32 and json.Number are numbers
	r, err := readout.ComputeRaw([]any{map[string]any{"token": "A", "logprob": json.Number("-0.5")}, map[string]any{"token": "B", "logprob": float32(-1)}, map[string]any{"token": "C", "logprob": 0}}, ab, .1, 1)
	if err != nil || r.Mass <= 0 {
		t.Fatal(r, err)
	}
	// ordering: the first problem in entry order decides which error class wins
	_, err = readout.ComputeRaw([]any{map[string]any{"token": "A", "logprob": math.NaN()}, map[string]any{"logprob": 1.0}}, ab, .1, 1)
	var rf *readout.ReadoutFailed
	if !errors.As(err, &rf) {
		t.Fatal("NaN before a malformed entry decides first", err)
	}
	_, err = readout.ComputeRaw([]any{map[string]any{"logprob": 1.0}, map[string]any{"token": "A", "logprob": math.NaN()}}, ab, .1, 1)
	var be *readout.BackendReadoutError
	if !errors.As(err, &be) {
		t.Fatal("malformed before NaN decides first", err)
	}
}

func TestBackendErrorMapping(t *testing.T) {
	be := &readout.BackendReadoutError{Reason: "x"}
	if be.Status() != 502 || be.ErrorType() != "backend_failed" || !be.Retryable() {
		t.Fatal(be)
	}
}

func TestTemperature(t *testing.T) {
	top := []readout.Entry{e("A", .6), e("B", .3)}
	ab := []string{"A", "B"}
	base := compute(t, top, ab, .5).Probabilities["A"]
	one, _ := readout.Compute(top, ab, .5, 1.0)
	if one.Probabilities["A"] != base {
		t.Fatal("T=1 is plain renormalisation")
	}
	hot, _ := readout.Compute(top, ab, .5, 4.0)
	cold, _ := readout.Compute(top, ab, .5, .25)
	if !(hot.Probabilities["A"] < base && cold.Probabilities["A"] > base) {
		t.Fatalf("hot %v base %v cold %v", hot.Probabilities["A"], base, cold.Probabilities["A"])
	}
	if !near(hot.Probabilities["B"], 1-hot.Probabilities["A"]) {
		t.Fatal("sums to 1")
	}
}

func rawLlama(entries []any) map[string]any {
	return map[string]any{"choices": []any{map[string]any{"logprobs": map[string]any{"top_logprobs": []any{entries}}}}}
}

func rawOpenAI(entries []any) map[string]any {
	return map[string]any{"choices": []any{map[string]any{"logprobs": map[string]any{"content": []any{map[string]any{"token": "A", "logprob": -.1, "top_logprobs": entries}}}}}}
}

func TestExtraction(t *testing.T) {
	ents := []any{map[string]any{"token": "A", "logprob": math.Log(.7)}, map[string]any{"token": "B", "logprob": math.Log(.2)}}
	for name, raw := range map[string]any{"llama": rawLlama(ents), "openai": rawOpenAI(ents)} {
		got, err := readout.ExtractTopLogprobs(raw)
		if err != nil || len(got) != 2 {
			t.Fatalf("%s: %v %v", name, got, err)
		}
		r, err := readout.ComputeRaw(got, []string{"A", "B"}, .5, 1)
		if err != nil || !near(r.Probabilities["A"], .7/.9) {
			t.Fatalf("%s: %v %v", name, r, err)
		}
	}
	bads := []any{map[string]any{}, map[string]any{"choices": []any{}}, map[string]any{"choices": []any{map[string]any{}}},
		map[string]any{"choices": []any{map[string]any{"logprobs": nil}}},
		map[string]any{"choices": []any{map[string]any{"logprobs": map[string]any{"top_logprobs": []any{}}}}},
		[]any{}, nil, "x", map[string]any{"choices": []any{map[string]any{"logprobs": map[string]any{"content": []any{}}}}},
		map[string]any{"choices": []any{map[string]any{"logprobs": map[string]any{"top_logprobs": []any{[]any{}}}}}},
		map[string]any{"choices": []any{map[string]any{"logprobs": map[string]any{"top_logprobs": []any{"notalist"}}}}},
		map[string]any{"choices": []any{map[string]any{"logprobs": map[string]any{"top_logprobs": map[string]any{"a": 1.0}}}}},
		map[string]any{"choices": "x"}}
	for i, bad := range bads {
		_, err := readout.ExtractTopLogprobs(bad)
		var be *readout.BackendReadoutError
		if !errors.As(err, &be) {
			t.Errorf("bad %d (%#v): %v", i, bad, err)
		}
	}
}

func TestExtractFromJSONBytes(t *testing.T) {
	raw := []byte(`{"choices":[{"logprobs":{"top_logprobs":[[{"token":"A","logprob":-0.3566749439},{"token":" B","logprob":-1.6094379124}]]}}]}`)
	top, err := readout.ExtractTopLogprobsJSON(raw)
	if err != nil {
		t.Fatal(err)
	}
	r, err := readout.ComputeRaw(top, []string{"A", "B"}, .5, 1)
	if err != nil || !near(r.Mass, .7+.2) && math.Abs(r.Mass-.9) > 1e-6 {
		t.Fatal(r, err)
	}
	for _, bad := range []string{``, `{`, `[]`, `{"choices":[{"logprobs":null}]}`} {
		_, err := readout.ExtractTopLogprobsJSON([]byte(bad))
		var be *readout.BackendReadoutError
		if !errors.As(err, &be) {
			t.Errorf("%q: %v", bad, err)
		}
	}
}

// FuzzCompute: Compute never panics and, when it succeeds, returns a distribution over the letters.
func FuzzCompute(f *testing.F) {
	f.Add("A", -0.5, "B", -1.0, 0.5, 1.0)
	f.Add(" A", -0.1, "▁B", -2.0, 0.1, 0.5)
	f.Add("A", math.Inf(-1), "B", math.Inf(-1), 0.1, 1.0)
	f.Add("", math.NaN(), "\xff", 3.0, 2.0, -1.0)
	f.Fuzz(func(t *testing.T, t1 string, l1 float64, t2 string, l2 float64, th, temp float64) {
		r, err := readout.Compute([]readout.Entry{{Token: t1, Logprob: l1}, {Token: t2, Logprob: l2}}, []string{"A", "B"}, th, temp)
		if err != nil {
			return
		}
		sum := 0.0
		for _, p := range r.Probabilities {
			if p < 0 || p > 1+1e-9 || math.IsNaN(p) {
				t.Fatalf("bad probability %v", r.Probabilities)
			}
			sum += p
		}
		if math.Abs(sum-1) > 1e-6 {
			t.Fatalf("sum %v for %v", sum, r.Probabilities)
		}
	})
}

// A temperature small enough to overflow log(mass)/T must give the argmax one-hot, never NaN.
func TestTinyTemperatureIsOneHotNotNaN(t *testing.T) {
	r, err := readout.Compute([]readout.Entry{e("A", .6), e("B", .3)}, []string{"A", "B"}, .5, 1e-320)
	if err != nil {
		t.Fatal(err)
	}
	if r.Probabilities["A"] != 1 || r.Probabilities["B"] != 0 {
		t.Fatalf("%v", r.Probabilities)
	}
}
