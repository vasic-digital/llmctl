package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/vasic-digital/llmctl/internal/calibrate"
	"github.com/vasic-digital/llmctl/internal/contract"
)

const calSHA = "1111111111111111111111111111111111111111111111111111111111111111"

func calSpec(t *testing.T) ProfileSpec {
	s := specByID(t, "decide-tiny")
	s.ModelSHA256 = calSHA
	return s
}

func calHash(t *testing.T, s ProfileSpec) string {
	h, err := TemplateHash(s, 1)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

type logSink struct {
	mu    sync.Mutex
	lines []string
}

func (l *logSink) logf(f string, a ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = append(l.lines, fmt.Sprintf(f, a...))
}
func (l *logSink) n() int { l.mu.Lock(); defer l.mu.Unlock(); return len(l.lines) }

func writeCal(t *testing.T, dir string, p *calibrate.Profile) string {
	t.Helper()
	path, err := calibrate.WriteProfile(dir, p)
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func goodProfile(t *testing.T, s ProfileSpec, method string, params map[string]any) *calibrate.Profile {
	return &calibrate.Profile{Version: calibrate.ProfileVersion, Profile: s.ID, Bound: true, ModelSHA256: calSHA,
		TemplateHash: calHash(t, s), Method: method, Params: params, NSamples: 300, FittedAt: "2026-10-08T00:00:00Z"}
}

func choiceAnswer(t *testing.T, probs []float64) contract.Answer {
	t.Helper()
	q := contract.ParsedQuestion{Name: "c", Type: contract.TypeChoice, Instructions: "i"}
	for i := range probs {
		q.Options = append(q.Options, contract.Option{Letter: string(rune('A' + i)), Key: fmt.Sprintf("k%d", i), Label: "l"})
	}
	a, err := contract.BuildAnswer(q, probs)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func TestCalibrationAppliedWhenBoundToLiveModelAndTemplate(t *testing.T) {
	dir := t.TempDir()
	s := calSpec(t)
	writeCal(t, dir, goodProfile(t, s, calibrate.MethodTemperature, map[string]any{"temperature": 2.0}))
	var ls logSink
	set := NewCalibrationSet()
	set.Reload(dir, []ProfileSpec{s}, 1, ls.logf)
	st, ok := set.Status(s.ID)
	if !ok || !st.Applied || st.Method != "temperature" || st.N != 300 || st.ProfileID != s.ID {
		t.Fatalf("status = %+v ok=%v", st, ok)
	}
	if ls.n() != 0 {
		t.Errorf("an applied profile logs nothing: %v", ls.lines)
	}
	raw := choiceAnswer(t, []float64{0.1, 0.9})
	got := set.Apply(s.ID, raw)
	want := contract.Round9((&calibrate.Temperature{T: 2}).Apply(0.9))
	if got.Calibration == nil || got.Confidence != want || got.ConfidenceRaw != raw.Confidence {
		t.Fatalf("confidence %v raw %v cal %+v, want %v / %v", got.Confidence, got.ConfidenceRaw, got.Calibration, want, raw.Confidence)
	}
	if got.Calibration.Method != "temperature" || got.Calibration.N != 300 || got.Calibration.ProfileID != s.ID {
		t.Errorf("calibration = %+v", got.Calibration)
	}
	// ONLY the confidence moves: the raw probabilities and the argmax are untouched
	if got.Choice != raw.Choice || got.Score != raw.Score || fmt.Sprint(got.Probabilities) != fmt.Sprint(raw.Probabilities) {
		t.Errorf("calibration touched more than the confidence: %+v vs %+v", got, raw)
	}
}

func TestCalibrationRefusedWithReason(t *testing.T) {
	s := calSpec(t)
	good := func() *calibrate.Profile {
		return goodProfile(t, s, calibrate.MethodTemperature, map[string]any{"temperature": 2.0})
	}
	cases := map[string]struct {
		mutate func(dir string, p *calibrate.Profile)
		reason string
	}{
		"other model":    {func(_ string, p *calibrate.Profile) { p.ModelSHA256 = strings.Repeat("2", 64) }, "mismatch"},
		"other template": {func(_ string, p *calibrate.Profile) { p.TemplateHash = strings.Repeat("3", 64) }, "mismatch"},
		"unbound flag":   {func(_ string, p *calibrate.Profile) { p.Bound = false; p.Profile = s.ID }, "unbound"},
		"bad params":     {func(_ string, p *calibrate.Profile) { p.Params = map[string]any{"temperature": -1.0} }, "invalid"},
		"unknown method": {func(_ string, p *calibrate.Profile) { p.Method = "magic" }, "invalid"},
	}
	for name, c := range cases {
		dir := t.TempDir()
		p := good()
		c.mutate(dir, p)
		// WriteProfile names an unbound profile <id>.unbound.json; plant the bound-named file by hand
		b, _ := json.Marshal(p)
		if err := os.WriteFile(filepath.Join(dir, s.ID+".json"), b, 0o600); err != nil {
			t.Fatal(err)
		}
		var ls logSink
		set := NewCalibrationSet()
		set.Reload(dir, []ProfileSpec{s}, 1, ls.logf)
		st, ok := set.Status(s.ID)
		if !ok || st.Applied || st.Reason != c.reason {
			t.Errorf("%s: status %+v ok=%v, want not applied / %s", name, st, ok, c.reason)
		}
		if ls.n() != 1 || !strings.Contains(ls.lines[0], s.ID) || !strings.Contains(ls.lines[0], c.reason) {
			t.Errorf("%s: want exactly one log line naming the profile and reason, got %v", name, ls.lines)
		}
		a := choiceAnswer(t, []float64{0.1, 0.9})
		if got := set.Apply(s.ID, a); got.Calibration != nil || got.Confidence != a.Confidence {
			t.Errorf("%s: a refused profile must leave the answer uncalibrated", name)
		}
		// a second reload with the same file does not log again
		set.Reload(dir, []ProfileSpec{s}, 1, ls.logf)
		if ls.n() != 1 {
			t.Errorf("%s: logged again on an unchanged reload: %v", name, ls.lines)
		}
	}
}

func TestCalibrationTemperatureChangeInvalidatesProfile(t *testing.T) {
	dir := t.TempDir()
	s := calSpec(t)
	writeCal(t, dir, goodProfile(t, s, calibrate.MethodTemperature, map[string]any{"temperature": 2.0}))
	set := NewCalibrationSet()
	set.Reload(dir, []ProfileSpec{s}, 1.5, func(string, ...any) {}) // gateway runs at another readout temperature
	if st, _ := set.Status(s.ID); st.Applied || st.Reason != "mismatch" {
		t.Fatalf("a profile fitted at another readout temperature must not apply: %+v", st)
	}
}

func TestCalibrationModelChecksumUnresolved(t *testing.T) {
	dir := t.TempDir()
	s := calSpec(t)
	writeCal(t, dir, goodProfile(t, s, calibrate.MethodTemperature, map[string]any{"temperature": 2.0}))
	s.ModelSHA256 = ""
	var ls logSink
	set := NewCalibrationSet()
	set.Reload(dir, []ProfileSpec{s}, 1, ls.logf)
	if st, _ := set.Status(s.ID); st.Applied || st.Reason != "model_unresolved" || ls.n() != 1 {
		t.Fatalf("%+v %v", st, ls.lines)
	}
}

func TestCalibrationNoProfileIsSilent(t *testing.T) {
	var ls logSink
	set := NewCalibrationSet()
	set.Reload(t.TempDir(), []ProfileSpec{calSpec(t)}, 1, ls.logf)
	if _, ok := set.Status("decide-tiny"); ok || ls.n() != 0 {
		t.Fatalf("no file: status present=%v logs=%v", ok, ls.lines)
	}
	// an unbound file alone is never applied and never named as the bound profile
	dir := t.TempDir()
	p := goodProfile(t, calSpec(t), calibrate.MethodTemperature, map[string]any{"temperature": 2.0})
	p.Bound = false
	writeCal(t, dir, p) // -> decide-tiny.unbound.json
	set.Reload(dir, []ProfileSpec{calSpec(t)}, 1, ls.logf)
	if _, ok := set.Status("decide-tiny"); ok {
		t.Error("an <id>.unbound.json file must be ignored")
	}
	var nilSet *CalibrationSet
	a := choiceAnswer(t, []float64{0.4, 0.6})
	if got := nilSet.Apply("decide-tiny", a); got.Calibration != nil {
		t.Error("nil set must be a no-op")
	}
}

func TestCalibrationRefusesInsecureFile(t *testing.T) {
	s := calSpec(t)
	mk := func(dir string) string {
		return writeCal(t, dir, goodProfile(t, s, calibrate.MethodTemperature, map[string]any{"temperature": 2.0}))
	}
	t.Run("group/world writable", func(t *testing.T) {
		dir := t.TempDir()
		path := mk(dir)
		if err := os.Chmod(path, 0o666); err != nil {
			t.Fatal(err)
		}
		set := NewCalibrationSet()
		set.Reload(dir, []ProfileSpec{s}, 1, func(string, ...any) {})
		if st, _ := set.Status(s.ID); st.Applied || st.Reason != "insecure" {
			t.Fatalf("%+v", st)
		}
	})
	t.Run("symlink", func(t *testing.T) {
		dir := t.TempDir()
		real := mk(filepath.Join(dir, "elsewhere"))
		link := filepath.Join(dir, s.ID+".json")
		if err := os.Symlink(real, link); err != nil {
			t.Fatal(err)
		}
		set := NewCalibrationSet()
		set.Reload(dir, []ProfileSpec{s}, 1, func(string, ...any) {})
		if st, _ := set.Status(s.ID); st.Applied || st.Reason != "insecure" {
			t.Fatalf("%+v", st)
		}
	})
}

type fixedCal struct{ f func(float64) float64 }

func (c fixedCal) Apply(p float64) float64 { return c.f(p) }
func (c fixedCal) Method() string          { return "temperature" }
func (c fixedCal) Params() map[string]any  { return nil }

func setWith(c calibrate.Calibrator) *CalibrationSet {
	set := NewCalibrationSet()
	set.state.Store(&calState{applied: map[string]*appliedCal{"decide-tiny": {cal: c, info: contract.Calibration{Method: "temperature", N: 300, ProfileID: "decide-tiny"}}}})
	return set
}

// The worst-case rule: a flagged (option_missing) answer's probabilities already hold the
// conservative allocation; calibration may LOWER its confidence but never raise it above the
// winner's worst-case share (the answer must not claim more certainty than its readout supported).
func TestCalibrationNeverExceedsWorstCaseOnFlaggedAnswers(t *testing.T) {
	q := contract.ParsedQuestion{Name: "c", Type: contract.TypeChoice, Instructions: "i", Options: []contract.Option{
		{Letter: "A", Key: "a", Label: "a"}, {Letter: "B", Key: "b", Label: "b"}, {Letter: "C", Key: "c", Label: "c"}}}
	flagged, err := contract.BuildAnswerBounded(q, []float64{0.55, 0.3, 0.15}, map[string]float64{"c": 0.25})
	if err != nil || len(flagged.Flags) == 0 {
		t.Fatalf("setup: %v %+v", err, flagged)
	}
	const pmax = 0.55
	raise := setWith(fixedCal{func(float64) float64 { return 0.99 }})
	if got := raise.Apply("decide-tiny", flagged); got.Confidence != pmax {
		t.Errorf("flagged: raising calibrator gave %v, want it capped at the worst-case share %v", got.Confidence, pmax)
	}
	lower := setWith(fixedCal{func(float64) float64 { return 0.30 }})
	if got := lower.Apply("decide-tiny", flagged); got.Confidence != 0.30 || got.ConfidenceRaw != flagged.Confidence {
		t.Errorf("flagged: lowering calibrator gave %v raw %v", got.Confidence, got.ConfidenceRaw)
	}
	// a FULLY LISTED answer is not capped: calibration may raise an under-confident model
	plain := choiceAnswer(t, []float64{0.55, 0.3, 0.15})
	if got := raise.Apply("decide-tiny", plain); got.Confidence != 0.99 {
		t.Errorf("unflagged: confidence %v, want the calibrated 0.99", got.Confidence)
	}
	// the winner is the best LISTED option, never a bounded one, even when a bounded one holds more mass
	bwin, _ := contract.BuildAnswerBounded(q, []float64{0.3, 0.2, 0.5}, map[string]float64{"c": 0.6})
	seen := -1.0
	spy := setWith(fixedCal{func(p float64) float64 { seen = p; return p }})
	spy.Apply("decide-tiny", bwin)
	if seen != 0.3 {
		t.Errorf("calibrator saw %v, want the best listed option's 0.3", seen)
	}
}

func TestCalibrationGuardsAndNonFiniteOutput(t *testing.T) {
	noul := contract.Answer{Type: contract.TypeNoul, Noul: 0.7}
	if got := setWith(fixedCal{func(p float64) float64 { return 0.1 }}).Apply("decide-tiny", noul); got.Calibration != nil || got.Noul != noul.Noul || got.Confidence != 0 {
		t.Error("a noul answer has no confidence and must be untouched")
	}
	a := choiceAnswer(t, []float64{0.4, 0.6})
	for name, f := range map[string]func(float64) float64{
		"NaN": func(float64) float64 { return math.NaN() }, "+Inf": func(float64) float64 { return math.Inf(1) },
	} {
		if got := setWith(fixedCal{f}).Apply("decide-tiny", a); got.Calibration != nil || got.Confidence != a.Confidence {
			t.Errorf("%s: a non-finite calibrator output must leave the answer uncalibrated, got %+v", name, got)
		}
	}
	out := setWith(fixedCal{func(float64) float64 { return 7 }}).Apply("decide-tiny", a)
	if out.Confidence != 1 {
		t.Errorf("calibrated value must be clamped to [0,1], got %v", out.Confidence)
	}
	out = setWith(fixedCal{func(float64) float64 { return -3 }}).Apply("decide-tiny", a)
	if out.Confidence != 0 {
		t.Errorf("calibrated value must be clamped to [0,1], got %v", out.Confidence)
	}
	// another profile is not affected
	if got := setWith(fixedCal{func(p float64) float64 { return 0 }}).Apply("decide-pro", a); got.Calibration != nil {
		t.Error("a calibration applies to its own profile only")
	}
}

func TestCalibrationScoreAnswerUsesWinnerShare(t *testing.T) {
	q := contract.ParsedQuestion{Name: "s", Type: contract.TypeScore, Instructions: "i",
		Options: []contract.Option{{Letter: "A", Key: "0", Label: "a"}, {Letter: "B", Key: "1", Label: "b"}, {Letter: "C", Key: "2", Label: "c"}},
		Legend:  []contract.LegendEntry{{Key: "0", Value: json.RawMessage(`"a"`)}, {Key: "1", Value: json.RawMessage(`"b"`)}, {Key: "2", Value: json.RawMessage(`"c"`)}}}
	a, err := contract.BuildAnswer(q, []float64{0.1, 0.2, 0.7})
	if err != nil {
		t.Fatal(err)
	}
	seen := -1.0
	got := setWith(fixedCal{func(p float64) float64 { seen = p; return p / 2 }}).Apply("decide-tiny", a)
	if seen != 0.7 || got.Confidence != 0.35 || got.Score != a.Score {
		t.Errorf("seen %v conf %v score %v (raw score %v)", seen, got.Confidence, got.Score, a.Score)
	}
}

func TestRouterAppliesCalibrationAndPublishesTemplateHash(t *testing.T) {
	dir := t.TempDir()
	s := calSpec(t)
	writeCal(t, dir, goodProfile(t, s, calibrate.MethodTemperature, map[string]any{"temperature": 3.0}))
	set := NewCalibrationSet()
	specs := []ProfileSpec{s, specByID(t, "decide-nli"), specByID(t, "decide-laya")}
	set.Reload(dir, specs, 1, func(string, ...any) {})
	res := NewStaticResolver()
	two(res)
	res.Set(KindDecide, "decide-nli", Endpoint{URL: "http://127.0.0.1:3", Healthy: true})
	d := &fakeDriver{}
	r, err := NewRouter(RouterConfig{Specs: specs, Resolver: res, Mode: Deterministic, Concurrency: 1,
		Profiles: testProfiles(t), Drivers: map[string]Driver{ProtoLetter: d, ProtoNLI: d, ProtoNative: d}, Calibrations: set})
	if err != nil {
		t.Fatal(err)
	}
	ans, _, err := r.Decide(context.Background(), parseFor(t, choiceBody))
	if err != nil {
		t.Fatal(err)
	}
	if ans[0].Answer.Calibration == nil || ans[0].Answer.Calibration.ProfileID != "decide-tiny" {
		t.Fatalf("the router must apply the profile: %+v", ans[0].Answer)
	}
	var tiny, nli *struct {
		hash string
		cal  bool
	}
	for _, m := range r.Models() {
		e := &struct {
			hash string
			cal  bool
		}{m.TemplateHash, m.Calibration != nil && m.Calibration.Applied}
		switch m.ID {
		case "decide-tiny":
			tiny = e
		case "decide-nli":
			nli = e
		}
	}
	want := calHash(t, s)
	if tiny == nil || tiny.hash != want || !tiny.cal {
		t.Errorf("tiny model info: %+v want hash %s calibrated", tiny, want)
	}
	if nli == nil || !hex64.MatchString(nli.hash) || nli.cal {
		t.Errorf("nli model info: %+v", nli)
	}
	meta := r.DecisionMeta("decide-tiny")
	if meta.ModelSHA256 != calSHA || meta.TemplateHash != want || meta.CalibrationProfile != "decide-tiny" {
		t.Errorf("decision meta = %+v", meta)
	}
	if m := r.DecisionMeta("decide-nli"); m.CalibrationProfile != "" || m.TemplateHash == "" {
		t.Errorf("uncalibrated meta = %+v", m)
	}
}

func TestCalibrationReloadSwapsAtomically(t *testing.T) {
	dir := t.TempDir()
	s := calSpec(t)
	path := writeCal(t, dir, goodProfile(t, s, calibrate.MethodTemperature, map[string]any{"temperature": 2.0}))
	set := NewCalibrationSet()
	set.Reload(dir, []ProfileSpec{s}, 1, func(string, ...any) {})
	a := choiceAnswer(t, []float64{0.2, 0.8})
	first := set.Apply(s.ID, a).Confidence
	var wg sync.WaitGroup
	stop := make(chan struct{})
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
					set.Apply(s.ID, a)
					set.Status(s.ID)
				}
			}
		}()
	}
	for i := 0; i < 20; i++ {
		set.Reload(dir, []ProfileSpec{s}, 1, func(string, ...any) {})
	}
	close(stop)
	wg.Wait()
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	set.Reload(dir, []ProfileSpec{s}, 1, func(string, ...any) {})
	if got := set.Apply(s.ID, a); got.Calibration != nil || got.Confidence != a.Confidence {
		t.Error("removing the profile and reloading must stop applying it")
	}
	if first == a.Confidence {
		t.Error("setup: calibration did not change the confidence")
	}
}
