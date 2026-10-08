package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/calibrate"
	"github.com/vasic-digital/llmctl/internal/gateway"
	"github.com/vasic-digital/llmctl/internal/keyring"
)

const calModelSHA = "0a19bc29bacc33e0d871146c8612b24dd14c2ed2e61cedeb7a928b0852628bac"

type calRig struct {
	t     *testing.T
	state string
	dir   string
	env   keyring.Environ
}

func newCalRig(t *testing.T) *calRig {
	t.Helper()
	d := t.TempDir()
	r := &calRig{t: t, dir: d, state: filepath.Join(d, "state"), env: keyring.Environ{}}
	r.env["LLMCTL_STATE_DIR"] = r.state
	r.env["HOME"] = d
	return r
}

func (r *calRig) write(name, content string) string {
	r.t.Helper()
	p := filepath.Join(r.dir, name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		r.t.Fatal(err)
	}
	return p
}

func (r *calRig) catalog(extraDecision string, files string) string {
	if files == "" {
		files = fmt.Sprintf(`[{"name":"m.gguf","size":1,"sha256":%q,"role":"model"}]`, calModelSHA)
	}
	return r.write("catalog.json", fmt.Sprintf(`{"profiles":{"decide-tiny":{"capability":["decide"],"files":%s,"decision":{"protocol":"letter-logit"%s}}}}`, files, extraDecision))
}

func (r *calRig) run(args ...string) (int, string, string) {
	r.t.Helper()
	old := askEnviron
	askEnviron = func() keyring.Environ {
		c := keyring.Environ{}
		for k, v := range r.env {
			c[k] = v
		}
		return c
	}
	defer func() { askEnviron = old }()
	var out, errb bytes.Buffer
	rc := run(append([]string{"calibrate"}, args...), &out, &errb)
	return rc, out.String(), errb.String()
}

// overconfidentCSV makes n deterministic labels where the model says p but is right with
// probability 0.5+(p-0.5)*0.5 (overconfident), as a CSV with a correct column.
func overconfidentCSV(n int) string {
	var b strings.Builder
	b.WriteString("id,type,p_pred,correct\n")
	s := uint64(12345)
	next := func() float64 {
		s = s*6364136223846793005 + 1442695040888963407
		return float64(s>>11) / float64(1<<53)
	}
	for i := 0; i < n; i++ {
		p := 0.5 + 0.5*next()
		q := 0.5 + (p-0.5)*0.5
		y := 0
		if next() < q {
			y = 1
		}
		fmt.Fprintf(&b, "r%d,noul,%.4f,%d\n", i, p, y)
	}
	return b.String()
}

func TestCalibrateUsageErrorsExit2(t *testing.T) {
	r := newCalRig(t)
	good := r.write("l.csv", overconfidentCSV(250))
	bad := r.write("bad.csv", "p_pred,correct\n2.5,1\n")
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"no flags", nil, "--profile"},
		{"no labels", []string{"--profile", "decide-tiny"}, "--labels"},
		{"bad profile name", []string{"--profile", "Decide Tiny", "--labels", good}, "profile"},
		{"bad method", []string{"--profile", "decide-tiny", "--labels", good, "--method", "isotone"}, "temperature"},
		{"unknown flag", []string{"--profile", "decide-tiny", "--labels", good, "--nope"}, "nope"},
		{"stray arg", []string{"--profile", "decide-tiny", "--labels", good, "extra"}, "unexpected argument"},
		{"missing file", []string{"--profile", "decide-tiny", "--labels", filepath.Join(r.dir, "nofile.csv")}, "cannot read"},
		{"unparseable labels", []string{"--profile", "decide-tiny", "--labels", bad}, "line 2"},
		{"unbound with sha", []string{"--profile", "decide-tiny", "--labels", good, "--unbound", "--model-sha", calModelSHA}, "--unbound"},
		{"bad sha", []string{"--profile", "decide-tiny", "--labels", good, "--model-sha", "xyz", "--template-hash", strings.Repeat("a", 64)}, "64"},
	}
	for _, c := range cases {
		rc, out, errs := r.run(c.args...)
		if rc != 2 {
			t.Errorf("%s: exit %d, want 2 (stdout %q stderr %q)", c.name, rc, out, errs)
		}
		if !strings.Contains(errs, c.want) {
			t.Errorf("%s: stderr %q does not mention %q", c.name, errs, c.want)
		}
	}
	if _, err := os.Stat(r.state); err == nil {
		t.Error("a usage error must not create state")
	}
}

func TestCalibrateRefusesBelow200LabelsButReports(t *testing.T) {
	r := newCalRig(t)
	labels := r.write("l.csv", overconfidentCSV(150))
	rc, out, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", r.catalog("", ""))
	if rc != 0 {
		t.Fatalf("exit %d, want 0 (a report, not a profile): %s", rc, errs)
	}
	for _, want := range []string{"insufficient for ECE", "n=150", "need 200", "no calibration profile written"} {
		if !strings.Contains(out, want) {
			t.Errorf("stdout lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "ECE 0.") || strings.Contains(out, "ECE=") {
		t.Errorf("a number was claimed below 200 labels:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(r.state, "decide", "calibration")); err == nil {
		t.Error("no profile directory/file may be created below 200 labels")
	}
	// accuracy and its interval are still reported
	if !strings.Contains(out, "accuracy") || !strings.Contains(out, "Wilson") {
		t.Errorf("accuracy/interval missing:\n%s", out)
	}
}

func TestCalibrateFitsAndWritesABoundProfile(t *testing.T) {
	for _, method := range []string{"temperature", "platt", "isotonic"} {
		t.Run(method, func(t *testing.T) {
			r := newCalRig(t)
			n := 3000 // large enough that sampling noise cannot mask the miscalibration (n=400 can)
			labels := r.write("l.csv", overconfidentCSV(n))
			th := strings.Repeat("b", 64)
			rc, out, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--method", method,
				"--catalog", r.catalog("", ""), "--template-hash", th, "--json")
			if rc != 0 {
				t.Fatalf("exit %d: %s", rc, errs)
			}
			var rep struct {
				Records     int `json:"records"`
				Calibration struct {
					Status string  `json:"status"`
					ECE    float64 `json:"ece"`
				} `json:"calibration"`
				Fit struct {
					Method string `json:"method"`
					After  struct {
						ECE float64 `json:"ece"`
					} `json:"after_in_sample"`
					HeldOut *struct {
						ECE float64 `json:"ece"`
					} `json:"after_held_out"`
				} `json:"fit"`
				ProfilePath string `json:"profile_path"`
			}
			if err := json.Unmarshal([]byte(out), &rep); err != nil {
				t.Fatalf("stdout is not JSON: %v\n%s", err, out)
			}
			if rep.Records != n || rep.Calibration.Status != "ok" || rep.Fit.Method != method {
				t.Errorf("report = %+v", rep)
			}
			if rep.Fit.After.ECE >= rep.Calibration.ECE {
				t.Errorf("ECE did not improve: %.4f -> %.4f", rep.Calibration.ECE, rep.Fit.After.ECE)
			}
			if rep.Fit.HeldOut == nil || rep.Fit.HeldOut.ECE >= rep.Calibration.ECE {
				t.Errorf("held-out ECE missing or not better: %+v", rep.Fit.HeldOut)
			}
			want := filepath.Join(r.state, "decide", "calibration", "decide-tiny.json")
			if rep.ProfilePath != want {
				t.Fatalf("profile_path = %q, want %q", rep.ProfilePath, want)
			}
			st, err := os.Stat(want)
			if err != nil || st.Mode().Perm() != 0o600 {
				t.Fatalf("profile mode: %v %v", st, err)
			}
			p, err := calibrate.LoadProfile(want, calModelSHA, th)
			if err != nil {
				t.Fatalf("the written profile does not load with its own bindings: %v", err)
			}
			if p.Method != method || p.NSamples != n || p.LabelsSHA256 == "" {
				t.Errorf("profile = %+v", p)
			}
			sum := sha256.Sum256([]byte(overconfidentCSV(n)))
			if p.LabelsSHA256 != hex.EncodeToString(sum[:]) {
				t.Error("labels_sha256 is not the sha256 of the label file")
			}
			if _, err := calibrate.LoadProfile(want, strings.Repeat("e", 64), th); err == nil {
				t.Error("a profile loaded against a different model sha")
			}
			if _, err := calibrate.LoadProfile(want, calModelSHA, strings.Repeat("e", 64)); err == nil {
				t.Error("a profile loaded against a different template hash")
			}
		})
	}
}

func TestCalibrateRefusesBoundProfileWhenBindingUnresolvable(t *testing.T) {
	r := newCalRig(t)
	labels := r.write("l.csv", overconfidentCSV(300))
	// a catalog entry whose protocol the gateway cannot hash and that publishes no template_hash: the
	// template binding cannot be resolved (a letter-logit entry now resolves, see
	// TestCalibrateComputesTheTemplateHashTheGatewayChecks)
	bogus := r.write("bogus.json", fmt.Sprintf(`{"profiles":{"decide-tiny":{"capability":["decide"],"files":[{"name":"m.gguf","size":1,"sha256":%q,"role":"model"}],"decision":{"protocol":"future-proto"}}}}`, calModelSHA))
	rc, out, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", bogus)
	if rc != 2 {
		t.Fatalf("exit %d, want 2", rc)
	}
	if !strings.Contains(errs, "template hash") || !strings.Contains(errs, "--unbound") {
		t.Errorf("stderr must say what cannot be resolved and the way out: %q", errs)
	}
	if !strings.Contains(out, "ECE") {
		t.Errorf("the report is still printed before the refusal:\n%s", out)
	}
	if ents, _ := os.ReadDir(filepath.Join(r.state, "decide", "calibration")); len(ents) != 0 {
		t.Errorf("a profile was written despite the refusal: %v", ents)
	}
	// unknown profile in the catalog: model sha cannot be resolved
	rc, _, errs = r.run("--profile", "decide-nope", "--labels", labels, "--catalog", r.catalog("", ""), "--template-hash", strings.Repeat("a", 64))
	if rc != 2 || !strings.Contains(errs, "model sha256") {
		t.Errorf("unknown profile: exit %d stderr %q", rc, errs)
	}
	// missing catalog file
	rc, _, errs = r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", filepath.Join(r.dir, "none.json"))
	if rc != 2 || !strings.Contains(errs, "catalog") {
		t.Errorf("missing catalog: exit %d stderr %q", rc, errs)
	}
}

func TestCalibrateTemplateHashFromCatalogAndModelShaAmbiguity(t *testing.T) {
	r := newCalRig(t)
	labels := r.write("l.csv", overconfidentCSV(300))
	th := strings.Repeat("c", 64)
	rc, out, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", r.catalog(fmt.Sprintf(`,"template_hash":%q`, th), ""), "--json")
	if rc != 0 {
		t.Fatalf("exit %d: %s", rc, errs)
	}
	var rep struct {
		ModelSHA     string `json:"model_sha256"`
		TemplateHash string `json:"template_hash"`
	}
	json.Unmarshal([]byte(out), &rep)
	if rep.ModelSHA != calModelSHA || rep.TemplateHash != th {
		t.Errorf("bindings = %+v", rep)
	}
	two := fmt.Sprintf(`[{"name":"a","size":1,"sha256":%q,"role":"model"},{"name":"b","size":1,"sha256":%q,"role":"model"}]`, calModelSHA, strings.Repeat("d", 64))
	rc, _, errs = r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", r.catalog(fmt.Sprintf(`,"template_hash":%q`, th), two))
	if rc != 2 || !strings.Contains(errs, "more than one model file") {
		t.Errorf("ambiguous model files: exit %d stderr %q", rc, errs)
	}
	// an explicit flag resolves the ambiguity
	rc, _, errs = r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", r.catalog("", two), "--model-sha", calModelSHA, "--template-hash", th)
	if rc != 0 {
		t.Errorf("explicit --model-sha refused: %d %s", rc, errs)
	}
}

func TestCalibrateUnboundWritesDistinctFile(t *testing.T) {
	r := newCalRig(t)
	labels := r.write("l.csv", overconfidentCSV(300))
	rc, out, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--unbound")
	if rc != 0 {
		t.Fatalf("exit %d: %s", rc, errs)
	}
	dir := filepath.Join(r.state, "decide", "calibration")
	if _, err := os.Stat(filepath.Join(dir, "decide-tiny.unbound.json")); err != nil {
		t.Fatalf("unbound profile missing: %v\n%s", err, out)
	}
	if _, err := os.Stat(filepath.Join(dir, "decide-tiny.json")); err == nil {
		t.Error("an unbound fit must never occupy the bound profile name")
	}
	if !strings.Contains(out, "UNBOUND") {
		t.Errorf("the report must say the profile is unbound:\n%s", out)
	}
}

func TestCalibrateIsotonicNeeds1000(t *testing.T) {
	r := newCalRig(t)
	labels := r.write("l.csv", overconfidentCSV(500))
	rc, out, _ := r.run("--profile", "decide-tiny", "--labels", labels, "--method", "isotonic", "--unbound")
	if rc != 0 || !strings.Contains(out, "1000") || !strings.Contains(out, "no calibration profile written") {
		t.Errorf("exit %d\n%s", rc, out)
	}
	if _, err := os.Stat(r.state); err == nil {
		t.Error("state created")
	}
}

func TestCalibrateDryRunWritesNothing(t *testing.T) {
	r := newCalRig(t)
	labels := r.write("l.csv", overconfidentCSV(300))
	rc, out, _ := r.run("--profile", "decide-tiny", "--labels", labels, "--unbound", "--dry-run")
	if rc != 0 || !strings.Contains(out, "dry-run") {
		t.Errorf("exit %d\n%s", rc, out)
	}
	if _, err := os.Stat(r.state); err == nil {
		t.Error("--dry-run created state")
	}
}

func TestCalibrateSingleClassWritesNoProfile(t *testing.T) {
	r := newCalRig(t)
	var b strings.Builder
	b.WriteString("p_pred,correct\n")
	for i := 0; i < 250; i++ {
		b.WriteString("0.9,1\n")
	}
	rc, out, _ := r.run("--profile", "decide-tiny", "--labels", r.write("l.csv", b.String()), "--unbound")
	if rc != 0 || !strings.Contains(out, "same outcome") || !strings.Contains(out, "no calibration profile written") {
		t.Errorf("exit %d\n%s", rc, out)
	}
}

func TestCalibrateReadsRunGoldenJSON(t *testing.T) {
	r := newCalRig(t)
	blob, _ := json.Marshal(map[string]any{"records": calGoldenFixture()})
	labels := r.write("golden.json", string(blob))
	rc, out, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--unbound", "--dry-run", "--json")
	if rc != 0 {
		t.Fatalf("exit %d: %s", rc, errs)
	}
	var rep struct {
		ByType map[string]struct {
			N        int     `json:"n"`
			Accuracy float64 `json:"accuracy"`
		} `json:"by_type"`
		All struct {
			N       int `json:"n"`
			Correct int `json:"correct"`
		} `json:"all"`
		Calibration struct {
			N int `json:"n"`
		} `json:"calibration"`
	}
	if err := json.Unmarshal([]byte(out), &rep); err != nil {
		t.Fatal(err)
	}
	// 240 records, wrong exactly when i%5 == 0 (48 wrong): 192 correct
	if rep.All.N != 240 || rep.All.Correct != 192 || rep.Calibration.N != 240 || len(rep.ByType) != 3 {
		t.Errorf("report = %+v", rep)
	}
}

func TestCalibrateOutputIsDeterministic(t *testing.T) {
	r := newCalRig(t)
	labels := r.write("l.csv", overconfidentCSV(600))
	args := []string{"--profile", "decide-tiny", "--labels", labels, "--unbound", "--dry-run", "--method", "platt"}
	_, a, _ := r.run(args...)
	_, b, _ := r.run(args...)
	if a != b || a == "" {
		t.Errorf("two runs differ:\n%s\n----\n%s", a, b)
	}
}

// calGoldenFixture mirrors the fixture of internal/calibrate's golden-master test.
func calGoldenFixture() []map[string]any {
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

// The catalog publishes no decision.template_hash; the gateway computes it (gateway.TemplateHash).
// `calibrate` must bind to that same value, or every profile it writes would be refused at load.
func TestCalibrateComputesTheTemplateHashTheGatewayChecks(t *testing.T) {
	r := newCalRig(t)
	labels := r.write("l.csv", overconfidentCSV(300))
	cat := r.catalog("", "")
	specs, err := gateway.LoadCatalog(cat)
	if err != nil || len(specs) != 1 {
		t.Fatal(err)
	}
	for _, temp := range []string{"", "2"} {
		if temp != "" {
			r.env["LLMCTL_DECIDE_TEMPERATURE"] = temp
		}
		want, _ := gateway.TemplateHash(specs[0], map[string]float64{"": 1, "2": 2}[temp])
		rc, out, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", cat, "--json")
		if rc != 0 {
			t.Fatalf("temperature %q: exit %d: %s", temp, rc, errs)
		}
		var rep struct {
			TemplateHash string `json:"template_hash"`
		}
		json.Unmarshal([]byte(out), &rep)
		if rep.TemplateHash != want {
			t.Errorf("temperature %q: bound to %s, the gateway computes %s", temp, rep.TemplateHash, want)
		}
		// and the gateway accepts the profile calibrate just wrote
		set := gateway.NewCalibrationSet()
		set.Reload(filepath.Join(r.state, "decide", "calibration"), specs, map[string]float64{"": 1, "2": 2}[temp], func(string, ...any) {})
		if st, ok := set.Status("decide-tiny"); !ok || !st.Applied {
			t.Errorf("temperature %q: the gateway refused the profile calibrate wrote: %+v", temp, st)
		}
	}
	delete(r.env, "LLMCTL_DECIDE_TEMPERATURE")
	// a catalog value that disagrees with the computed one still binds (explicit data wins) but warns
	th := strings.Repeat("c", 64)
	rc, _, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", r.catalog(fmt.Sprintf(`,"template_hash":%q`, th), ""))
	if rc != 0 || !strings.Contains(errs, "differs") || !strings.Contains(errs, "refuse") {
		t.Errorf("a stale catalog template_hash must warn that the gateway will refuse the profile: rc %d %q", rc, errs)
	}
}

// calibratedCSV makes n labels collected from a CALIBRATED gateway: confidence is the calibrated
// value, the calibration column marks it, withRaw adds the raw winner probability as p_pred.
func calibratedCSV(n int, withRaw bool) string {
	var b strings.Builder
	if withRaw {
		b.WriteString("id,type,p_pred,confidence,calibration,correct\n")
	} else {
		b.WriteString("id,type,confidence,calibration,correct\n")
	}
	base := strings.Split(overconfidentCSV(n), "\n")[1:]
	for _, line := range base {
		f := strings.Split(line, ",")
		if len(f) < 4 {
			continue
		}
		if withRaw {
			fmt.Fprintf(&b, "%s,%s,%s,0.6000,temperature,%s\n", f[0], f[1], f[2], f[3])
		} else {
			fmt.Fprintf(&b, "%s,%s,%s,temperature,%s\n", f[0], f[1], f[2], f[3])
		}
	}
	return b.String()
}

func TestCalibrateRefusesCalibratedLabelsWithoutRawSource(t *testing.T) {
	r := newCalRig(t)
	cat := r.catalog("", "")
	labels := r.write("cal.csv", calibratedCSV(250, false))
	rc, out, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", cat, "--dry-run")
	if rc != 2 {
		t.Fatalf("exit %d, want 2 (double-calibration refused): out=%s err=%s", rc, out, errs)
	}
	for _, want := range []string{"calibrated answers", "confidence_raw", "--assume-uncalibrated"} {
		if !strings.Contains(errs, want) {
			t.Errorf("stderr lacks %q: %s", want, errs)
		}
	}
	// the explicit acknowledgement reads the confidence as is, and the report says so
	rc, out, errs = r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", cat, "--dry-run", "--assume-uncalibrated")
	if rc != 0 || !strings.Contains(out, "assume-uncalibrated") {
		t.Fatalf("--assume-uncalibrated: rc=%d out=%s err=%s", rc, out, errs)
	}
}

func TestCalibrateAcceptsCalibratedLabelsWithARawSource(t *testing.T) {
	r := newCalRig(t)
	labels := r.write("cal.csv", calibratedCSV(250, true))
	rc, out, errs := r.run("--profile", "decide-tiny", "--labels", labels, "--catalog", r.catalog("", ""), "--dry-run", "--json")
	if rc != 0 {
		t.Fatalf("exit %d: %s %s", rc, out, errs)
	}
	var rep struct {
		CalibratedRows int  `json:"calibrated_rows"`
		RawSource      int  `json:"raw_source_rows"`
		Assumed        bool `json:"assumed_uncalibrated"`
	}
	if err := json.Unmarshal([]byte(out), &rep); err != nil || rep.CalibratedRows != 250 || rep.RawSource != 250 || rep.Assumed {
		t.Fatalf("report %+v %v\n%s", rep, err, out)
	}
}
