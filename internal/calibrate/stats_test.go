package calibrate

import (
	"math"
	"testing"
)

func near(t *testing.T, what string, got, want, tol float64) {
	t.Helper()
	if math.IsNaN(got) || math.Abs(got-want) > tol {
		t.Errorf("%s = %.9f, want %.9f (tol %g)", what, got, want, tol)
	}
}

// Golden master against scripts/golden/stats.py (wilson()). Hand derivation for k=8, n=10:
//
//	z = 1.959963984540054, z^2 = 3.841458820694124
//	denom  = 1 + z^2/n                    = 1.3841458820694124
//	centre = (0.8 + z^2/(2n)) / denom     = 0.99207294 / 1.38414588 = 0.716740
//	half   = z*sqrt(0.8*0.2/10 + z^2/(4n^2)) / denom
//	       = 1.959964*sqrt(0.016 + 0.00960365) / 1.384146 = 0.313613 / 1.384146 = 0.226578
//	lo/hi  = 0.490162 / 0.943318  (the textbook Wilson 8/10 interval is (0.4902, 0.9433))
//
// 90/100: denom 1.0384146, centre 0.885 , half 1.959964*0.0315605/1.0384146 = 0.059573 -> (0.8256, 0.9448).
// The expected values below were then confirmed by running stats.wilson (stats.py) on the same inputs.
func TestWilsonMatchesStatsPy(t *testing.T) {
	cases := []struct {
		k, n   int
		lo, hi float64
	}{
		{8, 10, 0.490162472, 0.943317849},
		{0, 0, 0, 1},                        // n == 0 -> (0, 1)
		{0, 10, 0, 0.2775328},               // k == 0: lower bound is clamped to 0
		{10, 10, 0.7224672, 1},              // k == n: upper bound clamped to 1
		{90, 100, 0.825634338, 0.944770863}, // used by the calibration fixture below
	}
	for _, c := range cases {
		lo, hi := Wilson(c.k, c.n)
		near(t, "lo", lo, c.lo, 1e-8)
		near(t, "hi", hi, c.hi, 1e-8)
	}
}

// 200 items: 100 at p=0.9 (90 correct), 100 at p=0.6 (50 correct). Hand computation:
//
//	bins (10 equal width, bin = min(int(p*10), 9)): p=0.9 -> bin 9, p=0.6 -> bin 6
//	bin 9: n=100 conf 0.9 acc 0.9 gap 0.0     bin 6: n=100 conf 0.6 acc 0.5 gap 0.1
//	ECE   = 0.5*0.0 + 0.5*0.1 = 0.05          MCE = max(0.0, 0.1) = 0.1
//	Brier = (90*0.1^2 + 10*0.9^2 + 50*0.4^2 + 50*0.6^2)/200 = (0.9+8.1+8+18)/200 = 0.175
func TestCalibrationMetricsHandComputed(t *testing.T) {
	var pairs []Pair
	for i := 0; i < 100; i++ {
		y := 0
		if i < 90 {
			y = 1
		}
		pairs = append(pairs, Pair{P: 0.9, Y: y})
	}
	for i := 0; i < 100; i++ {
		y := 0
		if i < 50 {
			y = 1
		}
		pairs = append(pairs, Pair{P: 0.6, Y: y})
	}
	m := Metrics(pairs)
	if m.Status != StatusOK || m.N != 200 {
		t.Fatalf("status %q n %d", m.Status, m.N)
	}
	near(t, "ece", m.ECE, 0.05, 1e-12)
	near(t, "mce", m.MCE, 0.1, 1e-12)
	near(t, "brier", m.Brier, 0.175, 1e-12)
}

func TestCalibrationRefusedBelow200Labels(t *testing.T) {
	pairs := make([]Pair, 199)
	for i := range pairs {
		pairs[i] = Pair{P: 0.7, Y: i % 2}
	}
	m := Metrics(pairs)
	if m.Status != Insufficient || m.N != 199 || m.Required != 200 {
		t.Fatalf("got %+v, want the insufficiency marker with n=199 required=200", m)
	}
	if m.ECE != 0 || m.MCE != 0 || m.Brier != 0 {
		t.Errorf("no number may be claimed below 200 labels: %+v", m)
	}
	pairs = append(pairs, Pair{P: 0.7, Y: 1})
	if Metrics(pairs).Status != StatusOK {
		t.Error("exactly 200 labels must be enough")
	}
}

// p == 1.0 must land in the last bin (min(int(p*10), 9)), as in stats.py.
func TestMetricsTopBinAndRounding(t *testing.T) {
	pairs := make([]Pair, 200)
	for i := range pairs {
		pairs[i] = Pair{P: 1.0, Y: 1}
	}
	m := Metrics(pairs)
	near(t, "ece", m.ECE, 0, 1e-12)
	near(t, "brier", m.Brier, 0, 1e-12)
}

// Perfectly calibrated synthetic data (y ~ Bernoulli(p), deterministic generator): ECE ~ 0.
func TestPerfectlyCalibratedSyntheticSetHasTinyECE(t *testing.T) {
	pairs := syntheticCalibrated(50000, 1)
	m := Metrics(pairs)
	if m.ECE > 0.02 {
		t.Errorf("ECE of a calibrated set = %.4f, want < 0.02", m.ECE)
	}
}

// A deliberately overconfident set has a large ECE (the metric can see miscalibration).
func TestOverconfidentSetHasLargeECE(t *testing.T) {
	pairs := make([]Pair, 400)
	for i := range pairs {
		pairs[i] = Pair{P: 0.95, Y: i % 2}
	}
	if m := Metrics(pairs); m.ECE < 0.4 {
		t.Errorf("ECE = %.3f, want >= 0.4 for 95%% confidence at 50%% accuracy", m.ECE)
	}
}

// ---- accuracy rows: hand computed and equal to stats._acc_row / by_type

func TestAccuracyRowBaselines(t *testing.T) {
	// 10 noul items: expected true x7, false x3; predicted correct on 8. Majority share 0.7,
	// chance (2 options) 0.5 -> baseline 0.7 (majority), accuracy 0.8, lower bound 0.490162 < 0.7.
	var recs []Record
	for i := 0; i < 10; i++ {
		exp := "b:true"
		if i >= 7 {
			exp = "b:false"
		}
		pred := exp
		if i == 0 || i == 9 { // two wrong answers
			if exp == "b:true" {
				pred = "b:false"
			} else {
				pred = "b:true"
			}
		}
		recs = append(recs, Record{Type: "noul", HasExpected: true, Expected: exp, Predicted: pred, WellFormed: true})
	}
	rows := AccuracyByType(recs)
	r, ok := rows["noul"]
	if !ok {
		t.Fatal("no noul row")
	}
	if r.N != 10 || r.Correct != 8 {
		t.Fatalf("n/correct = %d/%d", r.N, r.Correct)
	}
	near(t, "accuracy", r.Accuracy, 0.8, 1e-12)
	near(t, "wilson_low", r.WilsonLow, 0.490162, 2e-6)
	near(t, "majority", r.MajorityShare, 0.7, 1e-12)
	near(t, "chance", r.Chance, 0.5, 1e-12)
	near(t, "baseline", r.Baseline, 0.7, 1e-12)
	if r.BaselineKind != "majority" || r.LowerExceedsBaseline {
		t.Errorf("kind %q lowerExceeds %v", r.BaselineKind, r.LowerExceedsBaseline)
	}
}

func TestMalformedAnswerCountsAsWrong(t *testing.T) {
	recs := []Record{
		{Type: "choice", HasExpected: true, Expected: "s:a", Predicted: "s:a", WellFormed: true, Options: 3},
		{Type: "choice", HasExpected: true, Expected: "s:b", Predicted: "s:b", WellFormed: false, Options: 3},
		{Type: "choice", HasExpected: true, Expected: "s:c", Predicted: "", WellFormed: true, Options: 3},
	}
	r := AccuracyByType(recs)["choice"]
	if r.Correct != 1 || r.N != 3 {
		t.Fatalf("correct/n = %d/%d, want 1/3 (malformed and empty answers are wrong, as in stats.py)", r.Correct, r.N)
	}
	near(t, "chance", r.Chance, 1.0/3, 1e-12)
}
