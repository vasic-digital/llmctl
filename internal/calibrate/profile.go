package calibrate

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// ProfileVersion is the schema version of the calibration profile file.
const ProfileVersion = 1

// ErrBindingMismatch is returned by LoadProfile when the profile was fitted for another model
// file or prompt template than the live ones (data-model §6: the profile is refused at load).
var ErrBindingMismatch = errors.New("calibration profile is bound to a different model or prompt template")

// ProfileMetrics are the numbers recorded with a profile; all come from this package.
type ProfileMetrics struct {
	Accuracy         float64  `json:"accuracy"`
	CILow            float64  `json:"ci_low"`
	CIHigh           float64  `json:"ci_high"`
	BaselineAccuracy *float64 `json:"baseline_accuracy"`
	ECEBefore        float64  `json:"ece_before"`
	MCEBefore        float64  `json:"mce_before"`
	BrierBefore      float64  `json:"brier_before"`
	ECEAfter         float64  `json:"ece_after_in_sample"`
	MCEAfter         float64  `json:"mce_after_in_sample"`
	BrierAfter       float64  `json:"brier_after_in_sample"`
	ECEHeldOut       *float64 `json:"ece_after_held_out,omitempty"`
	BrierHeldOut     *float64 `json:"brier_after_held_out,omitempty"`
}

// Profile is the calibration profile file ($STATE/decide/calibration/<profile>.json).
type Profile struct {
	Version      int            `json:"version"`
	Profile      string         `json:"profile"`
	Bound        bool           `json:"bound"`
	ModelSHA256  string         `json:"model_sha256"`
	TemplateHash string         `json:"template_hash"`
	Method       string         `json:"method"`
	Params       map[string]any `json:"params"`
	NSamples     int            `json:"n_samples"`
	FittedAt     string         `json:"fitted_at"`
	LabelsSource string         `json:"labels_source"`
	LabelsSHA256 string         `json:"labels_sha256"`
	Metrics      ProfileMetrics `json:"metrics"`
	Note         string         `json:"note,omitempty"`
}

var profileNameRE = regexp.MustCompile(`^[a-z0-9-]+$`)

// ValidProfileName reports whether s is a legal profile id (lowercase [a-z0-9-]+).
func ValidProfileName(s string) bool { return profileNameRE.MatchString(s) }

// WriteProfile writes the profile atomically (temp file in the same directory, fsync, rename) with
// mode 0600 into dir (created 0700). A bound profile is <name>.json; an unbound one is
// <name>.unbound.json so it can never be mistaken for a bound one. It returns the final path.
func WriteProfile(dir string, p *Profile) (string, error) {
	if !ValidProfileName(p.Profile) {
		return "", fmt.Errorf("invalid profile name %q (lowercase letters, digits and '-')", p.Profile)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("cannot create %s: %v", dir, err)
	}
	name := p.Profile + ".json"
	if !p.Bound {
		name = p.Profile + ".unbound.json"
	}
	final := filepath.Join(dir, name)
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(dir, "."+name+".tmp-*")
	if err != nil {
		return "", fmt.Errorf("cannot write in %s: %v", dir, err)
	}
	ok := false
	defer func() {
		if !ok {
			tmp.Close()
			os.Remove(tmp.Name())
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		return "", err
	}
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		return "", err
	}
	if err := tmp.Sync(); err != nil {
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmp.Name(), final); err != nil {
		return "", err
	}
	ok = true
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return final, nil
}

// LoadProfile reads a profile and refuses it (ErrBindingMismatch) unless it is bound and both
// bindings equal the live model checksum and template hash. This is the function the gateway uses
// to decide whether it may apply a profile.
func LoadProfile(path, modelSHA256, templateHash string) (*Profile, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var p Profile
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, fmt.Errorf("%s is not a calibration profile: %v", path, err)
	}
	if !p.Bound || p.ModelSHA256 == "" || p.TemplateHash == "" {
		return nil, fmt.Errorf("%w: the profile is unbound", ErrBindingMismatch)
	}
	if p.ModelSHA256 != modelSHA256 || p.TemplateHash != templateHash {
		return nil, ErrBindingMismatch
	}
	return &p, nil
}
