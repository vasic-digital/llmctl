package calibrate

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sampleProfile() *Profile {
	return &Profile{
		Version: ProfileVersion, Profile: "decide-tiny", ModelSHA256: strings.Repeat("a", 64),
		TemplateHash: strings.Repeat("b", 64), Method: MethodTemperature, Params: map[string]any{"temperature": 1.7},
		NSamples: 250, FittedAt: "2026-10-08T10:00:00Z", Bound: true,
	}
}

func TestWriteProfileModeAtomicAndNoTempLeft(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "decide", "calibration")
	path, err := WriteProfile(dir, sampleProfile())
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(path) != "decide-tiny.json" {
		t.Errorf("path = %s", path)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v err %v, want 0600", st.Mode().Perm(), err)
	}
	ds, _ := os.Stat(dir)
	if ds.Mode().Perm() != 0o700 {
		t.Errorf("created dir mode = %v, want 0700", ds.Mode().Perm())
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 1 {
		t.Errorf("leftover files: %v", ents)
	}
}

func TestWriteProfileOverwritesAtomically(t *testing.T) {
	dir := t.TempDir()
	p := sampleProfile()
	if _, err := WriteProfile(dir, p); err != nil {
		t.Fatal(err)
	}
	p.NSamples = 999
	path, err := WriteProfile(dir, p)
	if err != nil {
		t.Fatal(err)
	}
	got, err := LoadProfile(path, p.ModelSHA256, p.TemplateHash)
	if err != nil || got.NSamples != 999 {
		t.Fatalf("got %+v err %v", got, err)
	}
}

func TestUnboundProfileUsesADistinctFileName(t *testing.T) {
	p := sampleProfile()
	p.Bound, p.ModelSHA256, p.TemplateHash = false, "", ""
	path, err := WriteProfile(t.TempDir(), p)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(path) != "decide-tiny.unbound.json" {
		t.Errorf("an unbound profile must never occupy the bound file name: %s", path)
	}
}

func TestLoadProfileRefusesMismatchedBindings(t *testing.T) {
	path, _ := WriteProfile(t.TempDir(), sampleProfile())
	p := sampleProfile()
	if _, err := LoadProfile(path, strings.Repeat("c", 64), p.TemplateHash); !errors.Is(err, ErrBindingMismatch) {
		t.Errorf("model sha mismatch accepted: %v", err)
	}
	if _, err := LoadProfile(path, p.ModelSHA256, strings.Repeat("c", 64)); !errors.Is(err, ErrBindingMismatch) {
		t.Errorf("template hash mismatch accepted: %v", err)
	}
	if _, err := LoadProfile(path, p.ModelSHA256, p.TemplateHash); err != nil {
		t.Errorf("matching bindings refused: %v", err)
	}
}

func TestLoadProfileRefusesUnboundAndBadFiles(t *testing.T) {
	p := sampleProfile()
	p.Bound, p.ModelSHA256, p.TemplateHash = false, "", ""
	path, _ := WriteProfile(t.TempDir(), p)
	if _, err := LoadProfile(path, "x", "y"); err == nil {
		t.Error("an unbound profile must never load as bound")
	}
	bad := filepath.Join(t.TempDir(), "bad.json")
	os.WriteFile(bad, []byte("{"), 0o600)
	if _, err := LoadProfile(bad, "", ""); err == nil {
		t.Error("garbage loaded")
	}
}

func TestProfileNameValidation(t *testing.T) {
	for _, n := range []string{"", "../x", "a/b", "A", "a.b", "x y"} {
		p := sampleProfile()
		p.Profile = n
		if _, err := WriteProfile(t.TempDir(), p); err == nil {
			t.Errorf("profile name %q accepted", n)
		}
	}
}
