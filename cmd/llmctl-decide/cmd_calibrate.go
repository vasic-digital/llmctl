package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/vasic-digital/llmctl/internal/calibrate"
	"github.com/vasic-digital/llmctl/internal/gateway"
	"github.com/vasic-digital/llmctl/internal/keyring"
)

// `llmctl-decide calibrate --profile P --labels F [--method temperature|platt|isotonic]`
// (contracts/cli.md, FR-080): accuracy with a Wilson interval, the trivial baselines, ECE / MCE /
// Brier over operator-labelled answers, a one-dimensional recalibration fit and a calibration
// profile bound to the model checksum and prompt-template hash. Pure computation: no network, no
// key. Exit codes: 0 report produced (with or without a profile - see the refusal rules below),
// 2 usage / input error / bound profile requested but a binding cannot be resolved, 1 the profile
// could not be written.
//
// Refusals that still exit 0 (the report is the product, no profile is written, the message says
// why): fewer than calibrate.MinLabels (200) calibration pairs ("insufficient for ECE"), isotonic
// with fewer than calibrate.MinIsotonic (1000), a label set whose outcomes are all the same.
func init() {
	register("calibrate", func(a []string, o, e io.Writer) int { return runCalibrate(a, o, e) })
}

// calNow is the clock of the profile's fitted_at (a seam for tests).
var calNow = time.Now

var calHexRE = regexp.MustCompile(`^[0-9a-f]{64}$`)

const calMaxLabelBytes = 64 << 20

type calFlags struct {
	profile, labels, method, catalog, stateDir string
	modelSHA, templateHash                     string
	unbound, dryRun, asJSON, assumeUncal       bool
}

type calAfter struct {
	ECE   float64 `json:"ece"`
	MCE   float64 `json:"mce,omitempty"`
	Brier float64 `json:"brier"`
	Folds int     `json:"folds,omitempty"`
}

type calFit struct {
	Method      string         `json:"method"`
	Params      map[string]any `json:"params"`
	AfterIn     calAfter       `json:"after_in_sample"`
	AfterHeld   *calAfter      `json:"after_held_out,omitempty"`
	InSampleNot string         `json:"in_sample_note"`
}

type calReport struct {
	Profile        string                   `json:"profile"`
	LabelsSource   string                   `json:"labels_source"`
	LabelsSHA256   string                   `json:"labels_sha256"`
	Format         string                   `json:"format"`
	Records        int                      `json:"records"`
	SkippedVariant int                      `json:"skipped_variant"`
	SkippedNoLabel int                      `json:"skipped_unlabelled"`
	NoConfidence   int                      `json:"no_confidence"`
	CalibratedRows int                      `json:"calibrated_rows,omitempty"`      // rows collected from calibrated answers
	RawSourceRows  int                      `json:"raw_source_rows,omitempty"`      // of those, rows fitted on their raw probability
	Assumed        bool                     `json:"assumed_uncalibrated,omitempty"` // --assume-uncalibrated read calibrated confidences
	All            calibrate.Row            `json:"all"`
	ByType         map[string]calibrate.Row `json:"by_type"`
	Calibration    calibrate.Measurement    `json:"calibration"`
	Method         string                   `json:"method"`
	Fit            *calFit                  `json:"fit"`
	Notes          []string                 `json:"notes"`
	Bound          bool                     `json:"bound"`
	ModelSHA256    string                   `json:"model_sha256,omitempty"`
	TemplateHash   string                   `json:"template_hash,omitempty"`
	ProfileWritten bool                     `json:"profile_written"`
	ProfilePath    string                   `json:"profile_path,omitempty"`
	DryRun         bool                     `json:"dry_run,omitempty"`
}

func runCalibrate(args []string, stdout, stderr io.Writer) int {
	var f calFlags
	fs := askNewFlagSet("calibrate")
	fs.StringVar(&f.profile, "profile", "", "decision profile id the labels were collected for (required)")
	fs.StringVar(&f.labels, "labels", "", "label file: CSV (p_pred + correct, or p_pred + expected + predicted) or the JSON written by scripts/golden/run_golden.py (required)")
	fs.StringVar(&f.method, "method", calibrate.MethodTemperature, "temperature | platt | isotonic (isotonic needs >= 1000 labels)")
	fs.StringVar(&f.catalog, "catalog", "", "catalog.json used to resolve the model checksum (default $LLMCTL_CATALOG, then <root>/models/catalog.json)")
	fs.StringVar(&f.stateDir, "state-dir", "", "state directory (default $LLMCTL_STATE_DIR, then $XDG_STATE_HOME/llmctl, then ~/.local/state/llmctl)")
	fs.StringVar(&f.modelSHA, "model-sha", "", "model file sha256 to bind the profile to (default: the catalog's single model file)")
	fs.StringVar(&f.templateHash, "template-hash", "", "prompt-template hash to bind the profile to (default: the catalog's decision.template_hash)")
	fs.BoolVar(&f.unbound, "unbound", false, "write an UNBOUND profile (<profile>.unbound.json; the gateway never applies it) when a binding cannot be resolved")
	fs.BoolVar(&f.assumeUncal, "assume-uncalibrated", false, "read the confidence of rows that carry a calibration marker as if it were raw (they were collected from CALIBRATED answers and have no p_pred / confidence_raw: fitting on them double-calibrates)")
	fs.BoolVar(&f.dryRun, "dry-run", false, "compute and print everything, write nothing")
	fs.BoolVar(&f.asJSON, "json", false, "machine-readable report")
	if rc, ok := fs.parse(args, stderr); !ok {
		return rc
	}
	usage := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "llmctl-decide calibrate: "+format+"\n", a...)
		return 2
	}
	switch {
	case f.profile == "":
		return usage("--profile is required (the decision profile id, e.g. decide-tiny)")
	case !calibrate.ValidProfileName(f.profile):
		return usage("invalid --profile %q: lowercase letters, digits and '-' only", askShorten(f.profile))
	case f.labels == "":
		return usage("--labels is required (a CSV or the JSON result file of scripts/golden/run_golden.py)")
	}
	okMethod := false
	for _, m := range calibrate.Methods {
		okMethod = okMethod || m == f.method
	}
	if !okMethod {
		return usage("unknown --method %q (temperature|platt|isotonic)", askShorten(f.method))
	}
	if f.unbound && (f.modelSHA != "" || f.templateHash != "") {
		return usage("--unbound cannot be combined with --model-sha/--template-hash: give the bindings or write an unbound profile, not both")
	}
	for name, v := range map[string]string{"--model-sha": f.modelSHA, "--template-hash": f.templateHash} {
		if v != "" && !calHexRE.MatchString(v) {
			return usage("%s must be 64 lowercase hex characters (a sha256)", name)
		}
	}
	data, err := calReadFile(f.labels)
	if err != nil {
		return usage("%v", err)
	}
	loaded, err := calibrate.LoadOpts(data, f.labels, calibrate.Options{AssumeUncalibrated: f.assumeUncal})
	if err != nil {
		return usage("labels file %s: %v", filepath.Base(f.labels), err)
	}
	env := askEnviron()
	sum := sha256.Sum256(data)
	rep := buildCalReport(&f, loaded, hex.EncodeToString(sum[:]))
	pairs := calibrate.Pairs(loaded.Records)

	var cal calibrate.Calibrator
	switch {
	case rep.Calibration.Status != calibrate.StatusOK:
		rep.Notes = append(rep.Notes, fmt.Sprintf("%s (n=%d, need %d): no calibration claim is made and no calibration profile written", calibrate.Insufficient, rep.Calibration.N, calibrate.MinLabels))
	case f.method == calibrate.MethodIsotonic && len(pairs) < calibrate.MinIsotonic:
		rep.Notes = append(rep.Notes, fmt.Sprintf("isotonic needs at least %d labels (have %d): no calibration profile written; use --method temperature or platt, or collect more labels", calibrate.MinIsotonic, len(pairs)))
	default:
		c, err := calibrate.Fit(f.method, pairs)
		switch {
		case errors.Is(err, calibrate.ErrSingleClass):
			rep.Notes = append(rep.Notes, "every labelled answer has the same outcome (all correct or all wrong): nothing to fit, no calibration profile written")
		case err != nil:
			return usage("%v", err)
		default:
			cal = c
			rep.Fit = fitSummary(c, pairs, f.method)
		}
	}
	rc := 0
	var prof *calibrate.Profile
	if cal != nil {
		prof = &calibrate.Profile{Version: calibrate.ProfileVersion, Profile: f.profile, Method: f.method, Params: cal.Params(),
			NSamples: len(pairs), LabelsSource: filepath.Base(f.labels), LabelsSHA256: rep.LabelsSHA256}
		prof.Metrics = profileMetrics(rep)
		if f.unbound {
			prof.Note = "UNBOUND: not tied to a model checksum or template hash; the gateway must never apply this profile"
		} else {
			ms, th, warn, berr := resolveCalBindings(&f, env)
			if warn != "" {
				fmt.Fprintf(stderr, "llmctl-decide calibrate: warning: %s\n", warn)
			}
			if berr != nil {
				rep.Notes = append(rep.Notes, "no calibration profile written: "+berr.Error())
				defer fmt.Fprintf(stderr, "llmctl-decide calibrate: cannot write a bound profile: %v (use --model-sha/--template-hash to give the bindings explicitly, or --unbound for a profile the gateway will never apply)\n", berr)
				rc = 2
				prof = nil
			} else {
				prof.Bound, prof.ModelSHA256, prof.TemplateHash = true, ms, th
				rep.Bound, rep.ModelSHA256, rep.TemplateHash = true, ms, th
			}
		}
	}
	if prof != nil {
		prof.FittedAt = calNow().UTC().Format(time.RFC3339)
		rep.DryRun = f.dryRun
		if !f.dryRun {
			dir, derr := calStateDir(&f, env)
			if derr != nil {
				return usage("%v", derr)
			}
			path, werr := calibrate.WriteProfile(filepath.Join(dir, "decide", "calibration"), prof)
			if werr != nil {
				fmt.Fprintf(stderr, "llmctl-decide calibrate: cannot write the profile: %v\n", werr)
				return 1
			}
			rep.ProfileWritten, rep.ProfilePath = true, path
		}
	}
	if f.asJSON {
		out, _ := json.Marshal(rep)
		fmt.Fprintf(stdout, "%s\n", out)
	} else {
		renderCalReport(stdout, rep, prof)
	}
	return rc
}

func calReadFile(path string) ([]byte, error) {
	fh, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read --labels %s: %s", path, strings.TrimPrefix(err.Error(), "open "+path+": "))
	}
	defer fh.Close()
	b, err := io.ReadAll(io.LimitReader(fh, calMaxLabelBytes+1))
	if err != nil {
		return nil, fmt.Errorf("cannot read --labels %s: %v", path, err)
	}
	if len(b) > calMaxLabelBytes {
		return nil, fmt.Errorf("cannot read --labels %s: larger than %d MiB", path, calMaxLabelBytes>>20)
	}
	return b, nil
}

func buildCalReport(f *calFlags, l *calibrate.Loaded, labelsSHA string) *calReport {
	rep := &calReport{Profile: f.profile, LabelsSource: filepath.Base(f.labels), LabelsSHA256: labelsSHA, Format: l.Format,
		Records: len(l.Records), SkippedVariant: l.SkippedVariant, SkippedNoLabel: l.SkippedUnlabelled,
		All: calibrate.AccuracyAll(l.Records), ByType: calibrate.AccuracyByType(l.Records), Method: f.method, Notes: []string{}}
	for _, r := range l.Records {
		if r.Labelled() && !r.HasP {
			rep.NoConfidence++
		}
	}
	rep.CalibratedRows, rep.RawSourceRows, rep.Assumed = l.CalibratedRows, l.RawFromCalibrated, l.AssumedUncalibrated
	if l.RawFromCalibrated > 0 {
		rep.Notes = append(rep.Notes, fmt.Sprintf("%d of %d calibrated rows were fitted on their raw probability (p_pred / confidence_raw), not on the calibrated confidence", l.RawFromCalibrated, l.CalibratedRows))
	}
	if l.AssumedUncalibrated {
		rep.Notes = append(rep.Notes, "--assume-uncalibrated: rows marked calibrated were read through their calibrated confidence; the fit below calibrates an already-calibrated value")
	}
	rep.Calibration = calibrate.Metrics(calibrate.Pairs(l.Records))
	return rep
}

func fitSummary(c calibrate.Calibrator, pairs []calibrate.Pair, method string) *calFit {
	after := calibrate.Metrics(calibrate.ApplyAll(c, pairs))
	fit := &calFit{Method: method, Params: c.Params(), AfterIn: calAfter{ECE: after.ECE, MCE: after.MCE, Brier: after.Brier},
		InSampleNot: "fitted and measured on the same labels: optimistic; after_held_out is the 5-fold estimate"}
	if cf, ok := calibrate.CrossFit(pairs, method, 5); ok {
		fit.AfterHeld = &calAfter{ECE: cf.ECE, MCE: cf.MCE, Brier: cf.Brier, Folds: 5}
	}
	return fit
}

func profileMetrics(rep *calReport) calibrate.ProfileMetrics {
	m := calibrate.ProfileMetrics{Accuracy: rep.All.Accuracy, CILow: rep.All.WilsonLow, CIHigh: rep.All.WilsonHigh,
		ECEBefore: rep.Calibration.ECE, MCEBefore: rep.Calibration.MCE, BrierBefore: rep.Calibration.Brier}
	if rep.All.BaselineAvailable {
		b := rep.All.Baseline
		m.BaselineAccuracy = &b
	}
	if rep.Fit != nil {
		m.ECEAfter, m.MCEAfter, m.BrierAfter = rep.Fit.AfterIn.ECE, rep.Fit.AfterIn.MCE, rep.Fit.AfterIn.Brier
		if rep.Fit.AfterHeld != nil {
			e, b := rep.Fit.AfterHeld.ECE, rep.Fit.AfterHeld.Brier
			m.ECEHeldOut, m.BrierHeldOut = &e, &b
		}
	}
	return m
}

// calStateDir: --state-dir, $LLMCTL_STATE_DIR, $XDG_STATE_HOME/llmctl, $HOME/.local/state/llmctl.
func calStateDir(f *calFlags, env keyring.Environ) (string, error) {
	switch {
	case f.stateDir != "":
		return f.stateDir, nil
	case env["LLMCTL_STATE_DIR"] != "":
		return env["LLMCTL_STATE_DIR"], nil
	case env["XDG_STATE_HOME"] != "":
		return filepath.Join(env["XDG_STATE_HOME"], "llmctl"), nil
	case env["HOME"] != "":
		return filepath.Join(env["HOME"], ".local", "state", "llmctl"), nil
	}
	return "", errors.New("cannot determine the state directory: use --state-dir or set LLMCTL_STATE_DIR")
}

// resolveCalBindings returns the model sha256 and template hash the profile is bound to: explicit
// flags first, then the catalog. The model sha256 is files[role=model].sha256 (exactly one, the
// rule the gateway applies too: gateway.SingleModelSHA). The template hash is decision.template_hash
// when the catalog publishes one; otherwise it is COMPUTED by gateway.TemplateHash from the entry's
// decision block and the effective LLMCTL_DECIDE_TEMPERATURE - the very value the gateway checks at
// load, so a profile written here is never refused for a binding this command could have computed.
// warn is non-empty when a catalog template_hash disagrees with the computed one (the gateway would
// refuse a profile bound to it).
func resolveCalBindings(f *calFlags, env keyring.Environ) (modelSHA, tmplHash, warn string, err error) {
	modelSHA, tmplHash = f.modelSHA, f.templateHash
	if modelSHA != "" && tmplHash != "" {
		return modelSHA, tmplHash, "", nil
	}
	path := f.catalog
	switch {
	case path != "":
	case env["LLMCTL_CATALOG"] != "":
		path = env["LLMCTL_CATALOG"]
	default:
		path = filepath.Join(installationRoot(), "models", "catalog.json")
	}
	b, rerr := os.ReadFile(path)
	if rerr != nil {
		return "", "", "", fmt.Errorf("cannot read the catalog %s to resolve the model sha256 / template hash (%s)", path, strings.TrimPrefix(rerr.Error(), "open "+path+": "))
	}
	var cat struct {
		Profiles map[string]struct {
			Files []struct {
				Role   string `json:"role"`
				SHA256 string `json:"sha256"`
			} `json:"files"`
			Decision *struct {
				TemplateHash string `json:"template_hash"`
			} `json:"decision"`
		} `json:"profiles"`
	}
	if json.Unmarshal(b, &cat) != nil {
		return "", "", "", fmt.Errorf("the catalog %s is not valid JSON", path)
	}
	p, ok := cat.Profiles[f.profile]
	if !ok {
		return "", "", "", fmt.Errorf("cannot resolve the model sha256: profile %q is not in the catalog %s", f.profile, path)
	}
	if modelSHA == "" {
		var shas []string
		for _, fl := range p.Files {
			if fl.Role == "model" {
				shas = append(shas, fl.SHA256)
			}
		}
		sha, serr := gateway.SingleModelSHA(shas)
		switch {
		case errors.Is(serr, gateway.ErrManyModelSHA):
			return "", "", "", fmt.Errorf("cannot resolve the model sha256: profile %q lists more than one model file; name the one with --model-sha", f.profile)
		case serr != nil:
			return "", "", "", fmt.Errorf("cannot resolve the model sha256: profile %q has no model file with a sha256 in the catalog", f.profile)
		}
		modelSHA = sha
	}
	computed := computedTemplateHash(b, f.profile, env)
	if tmplHash == "" && p.Decision != nil {
		tmplHash = p.Decision.TemplateHash
	}
	if tmplHash != "" && computed != "" && tmplHash != computed && f.templateHash == "" {
		warn = fmt.Sprintf("the catalog's decision.template_hash (%s) differs from the hash the gateway computes (%s); the gateway will refuse a profile bound to it - remove the catalog field or pass --template-hash %s", short(tmplHash), short(computed), computed)
	}
	if tmplHash == "" {
		tmplHash = computed
	}
	if !calHexRE.MatchString(tmplHash) {
		return "", "", "", fmt.Errorf("cannot resolve the prompt template hash: the catalog entry of %q has no decision.template_hash, the gateway cannot compute one for it, and --template-hash was not given", f.profile)
	}
	return modelSHA, tmplHash, warn, nil
}

func short(h string) string {
	if len(h) > 12 {
		return h[:12]
	}
	return h
}

// computedTemplateHash is gateway.TemplateHash of the catalog entry under the effective readout
// temperature, "" when the entry is not a decision profile the gateway can parse.
func computedTemplateHash(catalog []byte, profile string, env keyring.Environ) string {
	specs, err := gateway.ParseCatalog(catalog)
	if err != nil {
		return ""
	}
	temp := 0.0
	if v := strings.TrimSpace(env["LLMCTL_DECIDE_TEMPERATURE"]); v != "" {
		if t, perr := strconv.ParseFloat(v, 64); perr == nil && t > 0 && !math.IsInf(t, 0) {
			temp = t
		}
	}
	for _, sp := range specs {
		if sp.ID == profile {
			h, herr := gateway.TemplateHash(sp, temp)
			if herr == nil {
				return h
			}
		}
	}
	return ""
}

func calF(x float64) string { return fmt.Sprintf("%.4f", x) }

func renderRow(w io.Writer, label string, r calibrate.Row) {
	fmt.Fprintf(w, "%-8s accuracy %s (%d/%d)  Wilson 95%% [%s, %s]", label, calF(r.Accuracy), r.Correct, r.N, calF(r.WilsonLow), calF(r.WilsonHigh))
	if r.BaselineAvailable {
		fmt.Fprintf(w, "  baseline %s (%s)  lower bound > baseline: %s", calF(r.Baseline), r.BaselineKind, map[bool]string{true: "yes", false: "no"}[r.LowerExceedsBaseline])
	} else {
		fmt.Fprint(w, "  baseline unavailable (no expected labels)")
	}
	fmt.Fprintln(w)
}

func renderCalReport(w io.Writer, rep *calReport, prof *calibrate.Profile) {
	fmt.Fprintf(w, "calibrate: profile %s, labels %s (%s, sha256 %s), %d labelled records\n", rep.Profile, rep.LabelsSource, rep.Format, rep.LabelsSHA256[:12], rep.Records)
	if rep.SkippedVariant+rep.SkippedNoLabel+rep.NoConfidence > 0 {
		fmt.Fprintf(w, "  not counted: %d permuted-variant, %d unlabelled; %d labelled without a confidence (accuracy only)\n", rep.SkippedVariant, rep.SkippedNoLabel, rep.NoConfidence)
	}
	renderRow(w, "all", rep.All)
	types := make([]string, 0, len(rep.ByType))
	for t := range rep.ByType {
		types = append(types, t)
	}
	sort.Strings(types)
	for _, t := range types {
		renderRow(w, t, rep.ByType[t])
	}
	if rep.Calibration.Status != calibrate.StatusOK {
		fmt.Fprintf(w, "calibration: %s (n=%d, need %d)\n", calibrate.Insufficient, rep.Calibration.N, rep.Calibration.Required)
	} else {
		c := rep.Calibration
		fmt.Fprintf(w, "calibration (n=%d): ECE %s  MCE %s  Brier %s\n", c.N, calF(c.ECE), calF(c.MCE), calF(c.Brier))
		fmt.Fprintln(w, "  reliability (10 equal-width bins):    n  confidence  accuracy")
		for _, b := range c.Bins {
			if b.N > 0 {
				fmt.Fprintf(w, "    [%.1f, %.1f%s %6d  %s      %s\n", b.Lo, b.Hi, map[bool]string{true: "]", false: ")"}[b.Hi >= 1], b.N, calF(b.Conf), calF(b.Accuracy))
			}
		}
	}
	if rep.Fit != nil {
		fmt.Fprintf(w, "method %s: %s\n", rep.Fit.Method, calParams(rep.Fit.Params))
		fmt.Fprintf(w, "  after (in-sample, optimistic): ECE %s  MCE %s  Brier %s\n", calF(rep.Fit.AfterIn.ECE), calF(rep.Fit.AfterIn.MCE), calF(rep.Fit.AfterIn.Brier))
		if h := rep.Fit.AfterHeld; h != nil {
			fmt.Fprintf(w, "  after (held-out, %d-fold):      ECE %s  MCE %s  Brier %s\n", h.Folds, calF(h.ECE), calF(h.MCE), calF(h.Brier))
		}
	}
	for _, n := range rep.Notes {
		fmt.Fprintf(w, "note: %s\n", n)
	}
	switch {
	case rep.ProfileWritten:
		state := "UNBOUND: the gateway will never apply it"
		if rep.Bound {
			state = "bound to model sha256 " + rep.ModelSHA256[:12] + " and template hash " + rep.TemplateHash[:12]
		}
		fmt.Fprintf(w, "profile written: %s (mode 0600, %s)\n", rep.ProfilePath, state)
	case rep.DryRun && prof != nil:
		fmt.Fprintln(w, "dry-run: no profile written")
	case rep.Fit == nil || prof == nil:
		fmt.Fprintln(w, "no calibration profile written")
	}
}

func calParams(p map[string]any) string {
	keys := make([]string, 0, len(p))
	for k := range p {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		switch v := p[k].(type) {
		case float64:
			parts = append(parts, fmt.Sprintf("%s=%.6g", k, v))
		case []float64:
			parts = append(parts, fmt.Sprintf("%s=[%d values]", k, len(v)))
		default:
			parts = append(parts, fmt.Sprintf("%s=%v", k, v))
		}
	}
	return strings.Join(parts, " ")
}
