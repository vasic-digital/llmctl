// Package calibrate holds the calibration maths of `llmctl decide calibrate` (spec 009, FR-080):
// accuracy with a Wilson interval, the trivial baselines, ECE/MCE/Brier, and three one-dimensional
// confidence recalibrators (temperature, Platt, isotonic). Standard library only.
//
// The numbers are defined to be identical to scripts/golden/stats.py (the Python reference
// implementation): same Wilson formula, same baselines, same 10 equal-width bins with
// bin = min(int(p*10), 9), same confidence-Brier. Golden-master tests pin the agreement.
package calibrate

import (
	"math"
	"sort"
)

// Z95 is the two-sided 95% normal quantile (stats.py Z95).
const Z95 = 1.959963984540054

// Calibration thresholds. MinLabels is the floor below which no calibration claim is made
// (SC-003 amendment); MinIsotonic is the data-model floor for the isotonic method.
const (
	MinLabels   = 200
	MinIsotonic = 1000
	Bins        = 10
)

// Status values of a calibration measurement.
const (
	StatusOK     = "ok"
	Insufficient = "insufficient for ECE"
)

// Pair is one confidence observation: P is the probability the answer gave to its own prediction,
// Y is 1 when that prediction was correct.
type Pair struct {
	P float64
	Y int
}

// Wilson is the Wilson score interval for k successes in n trials; (0, 1) when n == 0.
func Wilson(k, n int) (lo, hi float64) {
	if n <= 0 {
		return 0, 1
	}
	nf := float64(n)
	p := float64(k) / nf
	denom := 1 + Z95*Z95/nf
	centre := (p + Z95*Z95/(2*nf)) / denom
	half := Z95 * math.Sqrt(p*(1-p)/nf+Z95*Z95/(4*nf*nf)) / denom
	return math.Max(0, centre-half), math.Min(1, centre+half)
}

// Bin is one reliability-diagram bin.
type Bin struct {
	Lo       float64 `json:"lo"`
	Hi       float64 `json:"hi"`
	N        int     `json:"n"`
	Conf     float64 `json:"confidence"`
	Accuracy float64 `json:"accuracy"`
}

// Measurement is the result of Metrics.
type Measurement struct {
	Status   string  `json:"status"`
	N        int     `json:"n"`
	Required int     `json:"required,omitempty"`
	ECE      float64 `json:"ece"`
	MCE      float64 `json:"mce"`
	Brier    float64 `json:"brier"`
	Bins     []Bin   `json:"bins,omitempty"`
}

// Metrics computes ECE, MCE and the confidence Brier score, or the insufficiency marker (and no
// number) when fewer than MinLabels pairs exist.
func Metrics(pairs []Pair) Measurement {
	n := len(pairs)
	if n < MinLabels {
		return Measurement{Status: Insufficient, N: n, Required: MinLabels}
	}
	return metrics(pairs)
}

// metrics is Metrics without the sample-size floor (used for held-out folds that are summed later).
func metrics(pairs []Pair) Measurement {
	n := len(pairs)
	type acc struct {
		cnt        int
		sumP, sumY float64
	}
	var bins [Bins]acc
	brier := 0.0
	for _, pr := range pairs {
		b := int(pr.P * Bins)
		if b > Bins-1 {
			b = Bins - 1
		}
		if b < 0 {
			b = 0
		}
		bins[b].cnt++
		bins[b].sumP += pr.P
		bins[b].sumY += float64(pr.Y)
		d := pr.P - float64(pr.Y)
		brier += d * d
	}
	m := Measurement{Status: StatusOK, N: n}
	for i, b := range bins {
		row := Bin{Lo: float64(i) / Bins, Hi: float64(i+1) / Bins, N: b.cnt}
		if b.cnt > 0 {
			row.Conf = b.sumP / float64(b.cnt)
			row.Accuracy = b.sumY / float64(b.cnt)
			gap := math.Abs(row.Accuracy - row.Conf)
			m.ECE += float64(b.cnt) / float64(n) * gap
			m.MCE = math.Max(m.MCE, gap)
		}
		m.Bins = append(m.Bins, row)
	}
	if n > 0 {
		m.Brier = brier / float64(n)
	}
	return m
}

// Record is one labelled evaluation item. Expected/Predicted are canonical tagged strings
// ("b:true", "n:3", "s:billing") so that equality means what Python's == means on the decoded value.
type Record struct {
	ID          string
	Type        string // noul | choice | score | "" (unknown)
	HasExpected bool
	Expected    string
	Predicted   string // "" = no answer
	// CorrectSet/Correct carry an explicit correctness column (CSV `correct`), used when there is
	// no expected/predicted pair.
	CorrectSet bool
	Correct    bool
	WellFormed bool
	HasP       bool
	P          float64
	Options    int // option count (choice) / scale (score); 0 = unknown
}

// IsCorrect mirrors stats._correct: a malformed or empty answer is wrong.
func (r Record) IsCorrect() bool {
	if !r.WellFormed {
		return false
	}
	if r.CorrectSet {
		return r.Correct
	}
	return r.Predicted != "" && r.Predicted == r.Expected
}

// Labelled reports whether the record counts in accuracy rows (stats.py: expected is not None).
func (r Record) Labelled() bool { return r.HasExpected || r.CorrectSet }

// Row is an accuracy row with its interval and trivial baselines (stats._acc_row plus by_type).
type Row struct {
	N                    int     `json:"n"`
	Correct              int     `json:"correct"`
	Accuracy             float64 `json:"accuracy"`
	WilsonLow            float64 `json:"wilson_low"`
	WilsonHigh           float64 `json:"wilson_high"`
	MajorityLabel        string  `json:"majority_label,omitempty"`
	MajorityShare        float64 `json:"majority_share"`
	Chance               float64 `json:"chance_level"`
	Baseline             float64 `json:"baseline"`
	BaselineKind         string  `json:"baseline_kind"`
	LowerExceedsBaseline bool    `json:"lower_bound_exceeds_baseline"`
	BaselineAvailable    bool    `json:"baseline_available"`
	Note                 string  `json:"note,omitempty"`
}

func accRow(recs []Record) Row {
	r := Row{N: len(recs)}
	for _, x := range recs {
		if x.IsCorrect() {
			r.Correct++
		}
	}
	if r.N > 0 {
		r.Accuracy = float64(r.Correct) / float64(r.N)
	}
	r.WilsonLow, r.WilsonHigh = Wilson(r.Correct, r.N)
	return r
}

// withBaseline fills the baseline fields: the larger of the majority-class share of the EXPECTED
// answers and the chance level (mean of 1/options), exactly as stats.py by_type does. Without any
// expected labels the baseline is unavailable and the verdict is not claimed.
func withBaseline(recs []Record, typ string) Row {
	r := accRow(recs)
	var labels []string
	for _, x := range recs {
		if x.HasExpected {
			labels = append(labels, x.Expected)
		}
	}
	if len(labels) == 0 {
		r.Note = "no expected labels: baseline unavailable"
		return r
	}
	counts := map[string]int{}
	for _, l := range labels {
		counts[l]++
	}
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	best := keys[0]
	for _, k := range keys {
		if counts[k] > counts[best] {
			best = k
		}
	}
	r.MajorityLabel = best
	r.MajorityShare = float64(counts[best]) / float64(len(labels))
	sum, cnt := 0.0, 0
	for _, x := range recs {
		s := x.Options
		if s == 0 && typ == "noul" {
			s = 2
		}
		if s > 0 {
			sum += 1 / float64(s)
			cnt++
		}
	}
	if cnt > 0 {
		r.Chance = sum / float64(cnt)
	}
	r.Baseline = math.Max(r.MajorityShare, r.Chance)
	r.BaselineKind = "majority"
	if r.MajorityShare < r.Chance {
		r.BaselineKind = "chance"
	}
	r.BaselineAvailable = true
	r.LowerExceedsBaseline = r.WilsonLow > r.Baseline
	return r
}

// AccuracyByType returns one row per type present among the labelled records (noul, choice, score
// and any other type string), keyed by type; records of unknown type ("") are in no row.
func AccuracyByType(recs []Record) map[string]Row {
	by := map[string][]Record{}
	for _, r := range recs {
		if r.Labelled() && r.Type != "" {
			by[r.Type] = append(by[r.Type], r)
		}
	}
	out := map[string]Row{}
	for t, rs := range by {
		out[t] = withBaseline(rs, t)
	}
	return out
}

// AccuracyAll is the pooled row over every labelled record.
func AccuracyAll(recs []Record) Row {
	var rs []Record
	for _, r := range recs {
		if r.Labelled() {
			rs = append(rs, r)
		}
	}
	return withBaseline(rs, "")
}

// Pairs extracts the calibration observations: labelled, well-formed records that carry a
// confidence (stats.py: expected is not None, well_formed, p_pred is not None).
func Pairs(recs []Record) []Pair {
	var out []Pair
	for _, r := range recs {
		if r.Labelled() && r.WellFormed && r.HasP {
			y := 0
			if r.IsCorrect() {
				y = 1
			}
			out = append(out, Pair{P: r.P, Y: y})
		}
	}
	return out
}
