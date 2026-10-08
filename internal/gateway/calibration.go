package gateway

import (
	"errors"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/vasic-digital/llmctl/internal/calibrate"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/server"
)

// Closed reason codes of a calibration profile the gateway did not apply (reported on /v1/models
// and logged once per change on stderr).
const (
	CalMismatch        = "mismatch"         // bound to another model file, prompt template or readout temperature
	CalUnbound         = "unbound"          // the file says bound=false (or carries no bindings)
	CalInvalid         = "invalid"          // unreadable, not JSON, unknown method, malformed parameters
	CalInsecure        = "insecure"         // symlink, not a regular file, or writable by group/others
	CalModelUnresolved = "model_unresolved" // the catalog names no single model checksum to compare with
)

// appliedCal is one profile's live calibrator.
type appliedCal struct {
	cal  calibrate.Calibrator
	info contract.Calibration
}

type calState struct {
	applied map[string]*appliedCal
	status  map[string]server.CalibrationInfo // every profile that HAS a calibration file
}

// CalibrationSet holds the calibration profiles the gateway applies. It is safe for concurrent use:
// Reload builds a complete new state and swaps it atomically, so a request sees either the old or
// the new set, never a half-loaded one. A nil *CalibrationSet applies nothing.
type CalibrationSet struct {
	state atomic.Pointer[calState]
	mu    sync.Mutex // serialises Reload (and guards logged)
	// logged remembers the last reported status per profile, so an unchanged refusal is logged once
	// rather than on every reload.
	logged map[string]string
}

// NewCalibrationSet returns an empty set.
func NewCalibrationSet() *CalibrationSet {
	s := &CalibrationSet{logged: map[string]string{}}
	s.state.Store(&calState{applied: map[string]*appliedCal{}, status: map[string]server.CalibrationInfo{}})
	return s
}

// Reload (re)reads <dir>/<profile>.json for every decision profile and installs the result.
//
// A profile file is applied only when ALL hold: it is a regular, non-symlink file not writable by
// group or others; calibrate.LoadProfile accepts it (bound, and bound to the live model checksum -
// spec.ModelSHA256, the catalog's single model file - and the live prompt-template hash of
// TemplateHash(spec, temperature)); and calibrate.FromProfile accepts its parameters. Anything else
// leaves that profile uncalibrated, records the reason code, and logs ONE line through logf naming
// the profile and the code (again only when the code changes). A profile with no file is silent. An
// <id>.unbound.json file is never looked at: only the bound name can be applied.
func (s *CalibrationSet) Reload(dir string, specs []ProfileSpec, temperature float64, logf func(format string, a ...any)) {
	if s == nil {
		return
	}
	next := &calState{applied: map[string]*appliedCal{}, status: map[string]server.CalibrationInfo{}}
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := map[string]bool{}
	for _, spec := range specs {
		path := filepath.Join(dir, spec.ID+".json")
		ac, st, present := loadOne(path, spec, temperature)
		if !present {
			continue
		}
		seen[spec.ID] = true
		next.status[spec.ID] = st
		key := "applied"
		if ac != nil {
			next.applied[spec.ID] = ac
		} else {
			key = st.Reason
			if s.logged[spec.ID] != key && logf != nil {
				logf("llmctl decide: calibration profile for %s NOT applied (%s): %s - answers keep their uncalibrated confidence", spec.ID, st.Reason, reasonText(st.Reason))
			}
		}
		s.logged[spec.ID] = key
	}
	for id := range s.logged {
		if !seen[id] {
			delete(s.logged, id) // the file went away: a later reappearance is news again
		}
	}
	s.state.Store(next)
}

func reasonText(code string) string {
	switch code {
	case CalMismatch:
		return "it is bound to a different model file, prompt template or readout temperature than the live ones; refit with `llmctl-decide calibrate`"
	case CalUnbound:
		return "the profile is not bound to a model checksum and template hash"
	case CalInsecure:
		return "the file is a symlink, not a regular file, or writable by group/others (mode must be 0600)"
	case CalModelUnresolved:
		return "the catalog does not name exactly one model file sha256 to compare it with"
	}
	return "the file is unreadable or its parameters are malformed"
}

// loadOne returns the applied calibrator (nil when refused), its status and whether a file exists.
func loadOne(path string, spec ProfileSpec, temperature float64) (*appliedCal, server.CalibrationInfo, bool) {
	fi, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, server.CalibrationInfo{}, false
		}
		return nil, server.CalibrationInfo{Reason: CalInvalid}, true
	}
	refuse := func(code string) (*appliedCal, server.CalibrationInfo, bool) {
		return nil, server.CalibrationInfo{Reason: code}, true
	}
	if !fi.Mode().IsRegular() || fi.Mode().Perm()&0o022 != 0 {
		return refuse(CalInsecure)
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Geteuid() && os.Geteuid() != 0 {
		return refuse(CalInsecure) // someone else owns the file that decides our confidence
	}
	if spec.ModelSHA256 == "" {
		return refuse(CalModelUnresolved)
	}
	th, err := TemplateHash(spec, temperature)
	if err != nil {
		return refuse(CalInvalid)
	}
	p, err := calibrate.LoadProfile(path, spec.ModelSHA256, th)
	if err != nil {
		switch {
		case errors.Is(err, calibrate.ErrBindingMismatch) && strings.Contains(err.Error(), "unbound"):
			return refuse(CalUnbound)
		case errors.Is(err, calibrate.ErrBindingMismatch):
			return refuse(CalMismatch)
		}
		return refuse(CalInvalid)
	}
	cal, err := calibrate.FromProfile(p)
	if err != nil {
		return refuse(CalInvalid)
	}
	id := p.Profile
	if id == "" {
		id = spec.ID
	}
	info := contract.Calibration{Method: p.Method, N: p.NSamples, ProfileID: id}
	return &appliedCal{cal: cal, info: info},
		server.CalibrationInfo{Applied: true, Method: p.Method, N: p.NSamples, ProfileID: id}, true
}

// Status reports the calibration state of a profile; ok is false when it has no calibration file.
func (s *CalibrationSet) Status(profile string) (server.CalibrationInfo, bool) {
	if s == nil {
		return server.CalibrationInfo{}, false
	}
	st, ok := s.state.Load().status[profile]
	return st, ok
}

// Apply returns a with its confidence replaced by the calibrated probability that the answer is
// correct, when the profile has an applied calibration; otherwise a unchanged.
//
// What changes: ONLY Confidence (and the audit pair ConfidenceRaw/Calibration are added). The
// probabilities, the choice, the score, the flags and the bounds are never touched. The calibrator
// is fitted on, and applied to, the winner's own probability (the p_pred of the labelled data): the
// largest probability among the options the readout LISTED (a bounded option holds worst-case mass,
// never a measurement, so it is not the winner). The result is clamped to [0,1] and rounded like
// every probability; a non-finite calibrator output leaves the answer untouched.
//
// Worst-case rule: an answer flagged option_missing carries the CONSERVATIVE distribution (the
// absent options hold the mass that leaves the winner the smallest share). Calibration may lower
// such an answer's confidence but never raise it above that worst-case share - an answer whose
// readout lacked an option must not claim more certainty than its worst case supported. A fully
// listed answer is not capped (calibration may raise an under-confident model).
func (s *CalibrationSet) Apply(profile string, a contract.Answer) contract.Answer {
	if s == nil || a.Type == contract.TypeNoul || len(a.Probabilities) == 0 {
		return a
	}
	ac := s.state.Load().applied[profile]
	if ac == nil {
		return a
	}
	bounded := map[string]bool{}
	for _, u := range a.UpperBounds {
		bounded[u.Key] = true
	}
	pmax, found := 0.0, false
	for _, p := range a.Probabilities {
		if bounded[p.Key] {
			continue
		}
		if !found || p.Value > pmax {
			pmax, found = p.Value, true
		}
	}
	if !found {
		return a
	}
	v := ac.cal.Apply(pmax)
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return a
	}
	v = math.Max(0, math.Min(1, v))
	if len(a.Flags) > 0 && v > pmax {
		v = pmax
	}
	info := ac.info
	a.ConfidenceRaw = a.Confidence
	a.Confidence = contract.Round9(v)
	a.Calibration = &info
	return a
}
