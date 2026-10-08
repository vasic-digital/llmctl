package gateway

import (
	"errors"
	"regexp"
	"strings"
	"testing"
)

var hex64 = regexp.MustCompile(`^[0-9a-f]{64}$`)

func letterSpec() ProfileSpec {
	return ProfileSpec{ID: "decide-tiny", Protocol: ProtoLetter,
		Readout: ReadoutSpec{NProbs: 32, MassThreshold: 0.5, Spellings: []string{"A", " A"}}}
}

func mustHash(t *testing.T, s ProfileSpec, temp float64) string {
	t.Helper()
	h, err := TemplateHash(s, temp)
	if err != nil {
		t.Fatal(err)
	}
	if !hex64.MatchString(h) {
		t.Fatalf("hash %q is not 64 lowercase hex", h)
	}
	return h
}

func TestTemplateHashDeterministicAndPerProtocol(t *testing.T) {
	l1, l2 := mustHash(t, letterSpec(), 1), mustHash(t, letterSpec(), 1)
	if l1 != l2 {
		t.Fatal("hash is not deterministic")
	}
	nat := mustHash(t, ProfileSpec{ID: "x", Protocol: ProtoNative}, 1)
	nli := mustHash(t, ProfileSpec{ID: "y", Protocol: ProtoNLI}, 1)
	if l1 == nat || l1 == nli || nat == nli {
		t.Fatalf("protocols must hash differently: %s %s %s", l1, nat, nli)
	}
	// the profile id is NOT part of the hash: two profiles sharing a template share the hash
	other := letterSpec()
	other.ID = "decide-pro"
	if mustHash(t, other, 1) != l1 {
		t.Error("profile id leaked into the template hash")
	}
}

func TestTemplateHashCoversEveryReadoutParameterThatMovesProbabilities(t *testing.T) {
	base := mustHash(t, letterSpec(), 1)
	chg := map[string]func(*ProfileSpec){
		"spellings": func(s *ProfileSpec) { s.Readout.Spellings = []string{"A", " A", "▁A"} },
		"n_probs":   func(s *ProfileSpec) { s.Readout.NProbs = 64 },
	}
	for name, f := range chg {
		s := letterSpec()
		f(&s)
		if mustHash(t, s, 1) == base {
			t.Errorf("changing %s did not change the hash", name)
		}
	}
	if mustHash(t, letterSpec(), 2) == base {
		t.Error("the global temperature moves the probabilities but is not in the hash")
	}
	if mustHash(t, letterSpec(), 0) != base {
		t.Error("temperature 0 means 1 (unset), exactly like the readout")
	}
	// mass threshold and cache_prompt only decide whether an answer exists / its speed, not its value
	s := letterSpec()
	s.Readout.MassThreshold = 0.9
	s.Readout.CachePrompt = true
	if mustHash(t, s, 1) != base {
		t.Error("mass_threshold / cache_prompt must not invalidate a calibration profile")
	}
}

func TestTemplateHashRefusesUnknownProtocol(t *testing.T) {
	if _, err := TemplateHash(ProfileSpec{Protocol: "bogus"}, 1); err == nil {
		t.Fatal("unknown protocol accepted")
	}
}

// The pinned values make an accidental prompt-template or hypothesis change loud: such a change
// invalidates every calibration profile (by design), so it must be a deliberate edit of this table.
func TestTemplateHashPinned(t *testing.T) {
	want := map[string]string{
		"letter": "a9fe279e594629b9b26645f4b67f500b7f1373bfc77cf99c30d223b11275a83a",
		"native": "e213a1cfc589b64f45c21a4d85291f3518182ec252382816687fe8f3e774720c",
		"nli":    "2b80870d1fe8a93876684d80b8a575422877805a78f62fb1c9ac7a1ef7402a21",
	}
	got := map[string]string{
		"letter": mustHash(t, letterSpec(), 1),
		"native": mustHash(t, ProfileSpec{Protocol: ProtoNative}, 1),
		"nli":    mustHash(t, ProfileSpec{Protocol: ProtoNLI}, 1),
	}
	for k := range want {
		if got[k] != want[k] {
			t.Errorf("%s template hash = %s (pinned %s): the template changed - every calibration profile bound to the old hash is now refused; update the pin deliberately", k, got[k], want[k])
		}
	}
}

func TestSingleModelSHA(t *testing.T) {
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	if got, err := SingleModelSHA([]string{a}); err != nil || got != a {
		t.Fatalf("one sha: %v %v", got, err)
	}
	if _, err := SingleModelSHA(nil); !errors.Is(err, ErrNoModelSHA) {
		t.Errorf("none: %v", err)
	}
	if _, err := SingleModelSHA([]string{"nothex"}); !errors.Is(err, ErrNoModelSHA) {
		t.Errorf("non-hex: %v", err)
	}
	if _, err := SingleModelSHA([]string{a, b}); !errors.Is(err, ErrManyModelSHA) {
		t.Errorf("two: %v", err)
	}
	if _, err := SingleModelSHA([]string{strings.ToUpper(a)}); !errors.Is(err, ErrNoModelSHA) {
		t.Errorf("uppercase must be refused (the profile stores lowercase): %v", err)
	}
}

func TestParseCatalogPublishesModelSHAExactlyOne(t *testing.T) {
	sha := strings.Repeat("c", 64)
	mk := func(files string) []byte {
		return []byte(`{"profiles":{"decide-tiny":{"capability":["decide"],"files":` + files +
			`,"decision":{"protocol":"letter-logit"}}}}`)
	}
	specs, err := ParseCatalog(mk(`[{"role":"model","sha256":"` + sha + `"},{"role":"tokenizer","sha256":"` + strings.Repeat("d", 64) + `"}]`))
	if err != nil || len(specs) != 1 || specs[0].ModelSHA256 != sha {
		t.Fatalf("one model file: %+v %v", specs, err)
	}
	for name, files := range map[string]string{
		"none":  `[{"role":"tokenizer","sha256":"` + sha + `"}]`,
		"two":   `[{"role":"model","sha256":"` + sha + `"},{"role":"model","sha256":"` + strings.Repeat("e", 64) + `"}]`,
		"null":  `[{"role":"model","sha256":null}]`,
		"empty": `[]`,
	} {
		specs, err := ParseCatalog(mk(files))
		if err != nil || len(specs) != 1 {
			t.Fatalf("%s: catalog must still parse: %v", name, err)
		}
		if specs[0].ModelSHA256 != "" {
			t.Errorf("%s: ModelSHA256 = %q, want empty (unresolvable, never guessed)", name, specs[0].ModelSHA256)
		}
	}
}
