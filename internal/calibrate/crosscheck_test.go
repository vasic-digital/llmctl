package calibrate

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// goldenFixture builds a deterministic 240-record result file in the shape run_golden.py writes.
// Hand-countable properties (see the test below):
//   - i = 0..239; type = noul, choice, score for i%3 = 0, 1, 2 (80 each)
//   - the answer is wrong exactly when i%5 == 0 (48 wrong) -> accuracy 192/240 = 0.8 overall
//   - p_pred = 0.50 + ((i*37) % 50)/100
func goldenFixture() []map[string]any {
	var recs []map[string]any
	for i := 0; i < 240; i++ {
		typ := []string{"noul", "choice", "score"}[i%3]
		rec := map[string]any{"id": fmt.Sprintf("g%03d", i), "type": typ, "variant": "orig", "well_formed": true,
			"p_pred": 0.5 + float64((i*37)%50)/100}
		var exp, pred any
		switch typ {
		case "noul":
			exp = i%4 == 0
			pred = exp
			if i%5 == 0 {
				pred = !(exp.(bool))
			}
		case "choice":
			n := 2 + i%4
			rec["option_count"] = n
			exp = fmt.Sprintf("opt%d", i%n)
			pred = exp
			if i%5 == 0 {
				pred = fmt.Sprintf("opt%d", (i+1)%n)
			}
		case "score":
			rec["scale"] = 5
			exp = i % 5
			pred = exp
			if i%5 == 0 {
				pred = (i + 1) % 5
			}
		}
		rec["expected"], rec["predicted"] = exp, pred
		recs = append(recs, rec)
	}
	return recs
}

// TestGoldenMasterAgainstStatsPy runs the Python reference implementation (scripts/golden/stats.py)
// on the fixture and requires every number of the Go implementation to agree with it.
func TestGoldenMasterAgainstStatsPy(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 is not installed: the live stats.py cross-check cannot run (the hand-computed fixtures in stats_test.go still bind the numbers)")
	}
	script, _ := filepath.Abs("../../scripts/golden/stats.py")
	if _, err := os.Stat(script); err != nil {
		t.Fatalf("reference implementation missing: %v", err)
	}
	recs := goldenFixture()
	blob, _ := json.Marshal(map[string]any{"records": recs})
	file := filepath.Join(t.TempDir(), "golden.json")
	if err := os.WriteFile(file, blob, 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(py, "-I", script, file, "--json").Output()
	if err != nil {
		t.Fatalf("stats.py failed: %v", err)
	}
	var raw struct {
		ByType map[string]map[string]any `json:"by_type"`
		Cal    map[string]any            `json:"calibration"`
	}
	raw.ByType = map[string]map[string]any{}
	if err := json.Unmarshal(out, &raw); err != nil {
		t.Fatal(err)
	}

	l, err := ParseJSON(blob)
	if err != nil {
		t.Fatal(err)
	}
	rows := AccuracyByType(l.Records)
	if len(rows) != len(raw.ByType) || len(rows) != 3 {
		t.Fatalf("types: go %d python %d", len(rows), len(raw.ByType))
	}
	num := func(m map[string]any, k string) float64 { return m[k].(float64) }
	for typ, py := range raw.ByType {
		g, ok := rows[typ]
		if !ok {
			t.Fatalf("type %s missing in Go", typ)
		}
		near(t, typ+" n", float64(g.N), num(py, "n"), 0)
		near(t, typ+" accuracy", g.Accuracy, num(py, "accuracy"), 1e-12)
		near(t, typ+" wilson_low", g.WilsonLow, num(py, "wilson_low"), 1e-12)
		near(t, typ+" wilson_high", g.WilsonHigh, num(py, "wilson_high"), 1e-12)
		near(t, typ+" majority", g.MajorityShare, num(py, "majority_share"), 1e-12)
		near(t, typ+" chance", g.Chance, num(py, "chance_level"), 1e-12)
		near(t, typ+" baseline", g.Baseline, num(py, "baseline"), 1e-12)
		if g.LowerExceedsBaseline != py["lower_bound_exceeds_baseline"].(bool) {
			t.Errorf("%s verdict differs", typ)
		}
		if g.BaselineKind != py["baseline_kind"].(string) {
			t.Errorf("%s baseline kind %s vs %s", typ, g.BaselineKind, py["baseline_kind"])
		}
	}
	m := Metrics(Pairs(l.Records))
	if m.Status != StatusOK || raw.Cal["status"] != "ok" {
		t.Fatalf("calibration status go=%q python=%v", m.Status, raw.Cal["status"])
	}
	near(t, "n", float64(m.N), num(raw.Cal, "n"), 0)
	near(t, "ece", m.ECE, num(raw.Cal, "ece"), 1e-12)
	near(t, "mce", m.MCE, num(raw.Cal, "mce"), 1e-12)
	near(t, "brier", m.Brier, num(raw.Cal, "brier"), 1e-12)
	if math.IsNaN(m.ECE) {
		t.Fatal("nan")
	}
	t.Logf("go == stats.py: n=%d ece=%.9f mce=%.9f brier=%.9f", m.N, m.ECE, m.MCE, m.Brier)
}

// The same fixture below the 200-label floor: both implementations refuse with the same count.
func TestBothRefuseCalibrationBelow200(t *testing.T) {
	recs := goldenFixture()[:150]
	blob, _ := json.Marshal(map[string]any{"records": recs})
	l, err := ParseJSON(blob)
	if err != nil {
		t.Fatal(err)
	}
	if m := Metrics(Pairs(l.Records)); m.Status != Insufficient || m.N != 150 {
		t.Fatalf("%+v", m)
	}
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 not installed")
	}
	script, _ := filepath.Abs("../../scripts/golden/stats.py")
	file := filepath.Join(t.TempDir(), "g.json")
	os.WriteFile(file, blob, 0o600)
	out, err := exec.Command(py, "-I", script, file, "--json").Output()
	if err != nil {
		t.Fatal(err)
	}
	var ref struct {
		Calibration struct {
			Status string
			N      int
		}
	}
	json.Unmarshal(out, &ref)
	if ref.Calibration.Status != "insufficient for calibration" || ref.Calibration.N != 150 {
		t.Errorf("stats.py disagrees: %+v", ref.Calibration)
	}
}
