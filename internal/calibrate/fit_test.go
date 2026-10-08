package calibrate

import (
	"math"
	"sort"
	"testing"
)

// syntheticCalibrated draws p ~ U(0.5,1) and y ~ Bernoulli(p) with a fixed linear congruential
// generator, so the data are deterministic and perfectly calibrated in expectation.
func syntheticCalibrated(n int, seed uint64) []Pair {
	s := seed*6364136223846793005 + 1442695040888963407
	next := func() float64 {
		s = s*6364136223846793005 + 1442695040888963407
		return float64(s>>11) / float64(1<<53)
	}
	out := make([]Pair, n)
	for i := range out {
		p := 0.5 + 0.5*next()
		y := 0
		if next() < p {
			y = 1
		}
		out[i] = Pair{P: p, Y: y}
	}
	return out
}

// synthetic overconfident: the model says p but the true probability is 0.5+(p-0.5)*shrink.
func syntheticOverconfident(n int, seed uint64, shrink float64) []Pair {
	s := seed*6364136223846793005 + 1442695040888963407
	next := func() float64 {
		s = s*6364136223846793005 + 1442695040888963407
		return float64(s>>11) / float64(1<<53)
	}
	out := make([]Pair, n)
	for i := range out {
		p := 0.5 + 0.5*next()
		q := 0.5 + (p-0.5)*shrink
		y := 0
		if next() < q {
			y = 1
		}
		out[i] = Pair{P: p, Y: y}
	}
	return out
}

func TestTemperatureRecoversIdentityOnCalibratedData(t *testing.T) {
	c, err := FitTemperature(syntheticCalibrated(40000, 7))
	if err != nil {
		t.Fatal(err)
	}
	// on calibrated data the fitted logit scale 1/T must be ~1 (identity); a wide-ish band for sampling noise
	if math.Abs(c.T-1) > 0.15 {
		t.Errorf("T = %.4f, want about 1 on calibrated data", c.T)
	}
	for _, p := range []float64{0.55, 0.7, 0.9, 0.99} {
		if math.Abs(c.Apply(p)-p) > 0.04 {
			t.Errorf("Apply(%.2f) = %.4f, want about the identity", p, c.Apply(p))
		}
	}
}

func TestTemperatureSoftensOverconfidentData(t *testing.T) {
	data := syntheticOverconfident(40000, 3, 0.5)
	c, err := FitTemperature(data)
	if err != nil {
		t.Fatal(err)
	}
	if c.T <= 1.2 {
		t.Errorf("T = %.3f, want > 1.2 (a softening temperature) for overconfident data", c.T)
	}
	before := Metrics(data)
	after := Metrics(applyAll(c, data))
	if after.ECE >= before.ECE {
		t.Errorf("ECE did not improve: %.4f -> %.4f", before.ECE, after.ECE)
	}
}

func TestTemperaturePreservesOrderOfConfidences(t *testing.T) {
	c := &Temperature{T: 2.3}
	prev := -1.0
	for p := 0.01; p < 1; p += 0.01 {
		v := c.Apply(p)
		if v < prev {
			t.Fatalf("Apply is not monotone at p=%.2f", p)
		}
		prev = v
	}
}

func TestPlattFitsKnownMapping(t *testing.T) {
	data := syntheticOverconfident(10000, 11, 0.5)
	c, err := FitPlatt(data)
	if err != nil {
		t.Fatal(err)
	}
	if c.A >= 0.9 || c.A <= 0.1 {
		t.Errorf("A = %.3f, want a shrinking slope (0.1..0.9) for overconfident data", c.A)
	}
	before := Metrics(data)
	after := Metrics(applyAll(c, data))
	if after.ECE >= before.ECE {
		t.Errorf("ECE did not improve: %.4f -> %.4f", before.ECE, after.ECE)
	}
}

func TestPlattIdentityOnCalibratedData(t *testing.T) {
	c, err := FitPlatt(syntheticCalibrated(10000, 5))
	if err != nil {
		t.Fatal(err)
	}
	if math.Abs(c.A-1) > 0.2 || math.Abs(c.B) > 0.25 {
		t.Errorf("A=%.3f B=%.3f, want about 1 and 0 on calibrated data", c.A, c.B)
	}
}

// Perfectly separated data would drive an unregularised Newton fit to infinity; the guard keeps it finite.
func TestPlattStaysFiniteOnSeparableData(t *testing.T) {
	var d []Pair
	for i := 0; i < 300; i++ {
		d = append(d, Pair{P: 0.9, Y: 1}, Pair{P: 0.3, Y: 0})
	}
	c, err := FitPlatt(d)
	if err != nil {
		t.Fatal(err)
	}
	if math.IsNaN(c.A) || math.IsInf(c.A, 0) || math.Abs(c.A) > 1e3 || math.IsNaN(c.B) || math.Abs(c.B) > 1e3 {
		t.Errorf("A=%v B=%v not finite/bounded", c.A, c.B)
	}
}

// ---- isotonic

func TestIsotonicIsMonotoneAndReducesECE(t *testing.T) {
	data := syntheticOverconfident(30000, 9, 0.4)
	c, err := FitIsotonic(data)
	if err != nil {
		t.Fatal(err)
	}
	prev := -1.0
	for p := 0.0; p <= 1.0; p += 0.005 {
		v := c.Apply(p)
		if v < prev-1e-12 {
			t.Fatalf("isotonic output decreases at p=%.3f: %.6f < %.6f", p, v, prev)
		}
		if v < 0 || v > 1 {
			t.Fatalf("output %v outside [0,1]", v)
		}
		prev = v
	}
	before := Metrics(data)
	after := Metrics(applyAll(c, data))
	if after.ECE >= before.ECE {
		t.Errorf("ECE did not improve: %.4f -> %.4f", before.ECE, after.ECE)
	}
}

// Hand-worked pool-adjacent-violators: points (p, y) = (0.1,0) (0.2,1) (0.3,0) (0.4,1) (0.5,1)
// weights 1. Sorted by p the y's are 0,1,0,1,1. 1 then 0 violate monotonicity -> pool to 0.5.
// Blocks: [0.1]->0 ; [0.2,0.3]->0.5 ; [0.4]->1 ; [0.5]->1 . Merging equal neighbours is optional,
// so the fitted values are 0, .5, .5, 1, 1.
func TestIsotonicPAVHandComputed(t *testing.T) {
	d := []Pair{{0.5, 1}, {0.1, 0}, {0.3, 0}, {0.2, 1}, {0.4, 1}} // unsorted on purpose
	c, err := FitIsotonicUnchecked(d)
	if err != nil {
		t.Fatal(err)
	}
	want := map[float64]float64{0.1: 0, 0.4: 1, 0.5: 1}
	for p, w := range want {
		near(t, "Apply", c.Apply(p), w, 1e-12)
	}
	// the pooled block (0.2, 0.3) has mean y 0.5 and its x centre 0.25: exactly at the centre it is 0.5
	near(t, "Apply(0.25)", c.Apply(0.25), 0.5, 1e-12)
	if !sort.Float64sAreSorted(c.X) {
		t.Errorf("knots not sorted: %v", c.X)
	}
}

func TestIsotonicTiesArePooled(t *testing.T) {
	d := []Pair{{0.6, 1}, {0.6, 0}, {0.6, 0}, {0.6, 0}, {0.9, 1}}
	c, err := FitIsotonicUnchecked(d)
	if err != nil {
		t.Fatal(err)
	}
	near(t, "ties pooled to 0.25", c.Apply(0.6), 0.25, 1e-12)
}

func TestIsotonicRefusedBelow1000Labels(t *testing.T) {
	if _, err := FitIsotonic(syntheticCalibrated(999, 1)); err == nil {
		t.Fatal("isotonic must be refused below 1000 labels")
	}
	if _, err := FitIsotonic(syntheticCalibrated(1000, 1)); err != nil {
		t.Fatalf("1000 labels must be enough: %v", err)
	}
}

func TestFitRefusesSingleClass(t *testing.T) {
	d := make([]Pair, 300)
	for i := range d {
		d[i] = Pair{P: 0.8, Y: 1}
	}
	for name, f := range map[string]func() error{
		"temperature": func() error { _, e := FitTemperature(d); return e },
		"platt":       func() error { _, e := FitPlatt(d); return e },
	} {
		if err := f(); err == nil {
			t.Errorf("%s accepted a one-class label set", name)
		}
	}
}

func TestFitIsDeterministic(t *testing.T) {
	d := syntheticOverconfident(5000, 4, 0.6)
	a, _ := FitTemperature(d)
	b, _ := FitTemperature(d)
	if a.T != b.T {
		t.Errorf("temperature fit not deterministic: %v vs %v", a.T, b.T)
	}
	p1, _ := FitPlatt(d)
	p2, _ := FitPlatt(d)
	if p1.A != p2.A || p1.B != p2.B {
		t.Errorf("platt fit not deterministic")
	}
}

func TestCrossFitIsReportedAndSane(t *testing.T) {
	d := syntheticOverconfident(5000, 2, 0.5)
	cf, ok := CrossFit(d, "temperature", 5)
	if !ok {
		t.Fatal("cross-fit unavailable")
	}
	if cf.ECE >= Metrics(d).ECE {
		t.Errorf("held-out ECE %.4f not better than raw %.4f", cf.ECE, Metrics(d).ECE)
	}
}

func applyAll(c Calibrator, d []Pair) []Pair {
	out := make([]Pair, len(d))
	for i, x := range d {
		out[i] = Pair{P: c.Apply(x.P), Y: x.Y}
	}
	return out
}
