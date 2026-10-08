package gateway

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

const catJSON = `{"version":3,"notes":"x","future_field":{"a":1},"ports":{"decide-tiny":8092},
"profiles":{
 "fast":{"engine":"llama","port":8080,"capability":["chat"]},
 "decide-tiny":{"engine":"llama","port":8092,"capability":["decide"],"unknown_new":true,
   "decision":{"protocol":"letter-logit","max_options":12,"score_levels":[2,5],
     "readout":{"n_probs":16,"mass_threshold":0.6,"spellings":["A"," A"],"cache_prompt":false},"extra":1}},
 "decide-nli":{"engine":"onnx","port":8096,"capability":["decide"],
   "decision":{"protocol":"nli-onnx","experimental":["choice","score"],"tier_note":"slow"}},
 "decide-laya":{"engine":"llama","capability":["decide"],"decision":{"protocol":"systemone-native","max_options":255}}
}}`

func TestParseCatalogDecisionProfilesOnly(t *testing.T) {
	specs, err := ParseCatalog([]byte(catJSON))
	if err != nil {
		t.Fatal(err)
	}
	if len(specs) != 3 {
		t.Fatalf("want 3 decision profiles (chat profile skipped), got %d", len(specs))
	}
	got := map[string]ProfileSpec{}
	for _, s := range specs {
		got[s.ID] = s
	}
	tiny := got["decide-tiny"]
	if tiny.Protocol != ProtoLetter || tiny.Port != 8092 || tiny.MaxOptions != 12 || tiny.ScoreLevels != [2]int{2, 5} {
		t.Fatalf("tiny: %+v", tiny)
	}
	if tiny.Readout.NProbs != 16 || tiny.Readout.MassThreshold != 0.6 || len(tiny.Readout.Spellings) != 2 {
		t.Fatalf("readout: %+v", tiny.Readout)
	}
	nli := got["decide-nli"]
	if nli.MaxOptions != 20 || nli.ScoreLevels != [2]int{2, 10} {
		t.Fatalf("defaults not applied: %+v", nli)
	}
	if len(nli.Experimental) != 2 || !strings.Contains(nli.Notes, "slow") {
		t.Fatalf("nli: %+v", nli)
	}
	if got["decide-laya"].MaxOptions != 255 {
		t.Fatal("native max options")
	}
}

func TestParseCatalogOrderIsDeterministic(t *testing.T) {
	a, _ := ParseCatalog([]byte(catJSON))
	b, _ := ParseCatalog([]byte(catJSON))
	for i := range a {
		if a[i].ID != b[i].ID {
			t.Fatal("order differs between parses")
		}
	}
	for i := 1; i < len(a); i++ {
		if a[i-1].ID > a[i].ID {
			t.Fatalf("not sorted: %v", a)
		}
	}
}

func TestParseCatalogRejectsBadProtocolAndNames(t *testing.T) {
	for name, j := range map[string]string{
		"protocol":  `{"profiles":{"d":{"capability":["decide"],"decision":{"protocol":"magic"}}}}`,
		"dot":       `{"profiles":{"d.x":{"capability":["decide"],"decision":{"protocol":"nli-onnx"}}}}`,
		"upper":     `{"profiles":{"Dx":{"capability":["decide"],"decision":{"protocol":"nli-onnx"}}}}`,
		"badjson":   `{`,
		"threshold": `{"profiles":{"d":{"capability":["decide"],"decision":{"protocol":"letter-logit","readout":{"mass_threshold":1.5}}}}}`,
		"maxopts":   `{"profiles":{"d":{"capability":["decide"],"decision":{"protocol":"letter-logit","max_options":300}}}}`,
	} {
		if _, err := ParseCatalog([]byte(j)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestParseCatalogNoDecisionProfilesIsEmptyNotError(t *testing.T) {
	specs, err := ParseCatalog([]byte(`{"profiles":{"fast":{"capability":["chat"]}}}`))
	if err != nil || len(specs) != 0 {
		t.Fatalf("%v %v", specs, err)
	}
}

func TestLoadCatalogReadsFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "catalog.json")
	if err := os.WriteFile(p, []byte(catJSON), 0o600); err != nil {
		t.Fatal(err)
	}
	specs, err := LoadCatalog(p)
	if err != nil || len(specs) != 3 {
		t.Fatalf("%v %v", specs, err)
	}
	if _, err := LoadCatalog(filepath.Join(t.TempDir(), "missing.json")); err == nil {
		t.Fatal("missing file must be an error")
	}
}

func TestBuildProfilesCarriesPerProfileLimits(t *testing.T) {
	specs, _ := ParseCatalog([]byte(catJSON))
	p, err := BuildProfiles(specs, "decide-tiny", contract.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	if p.Default() != "decide-tiny" || len(p.IDs()) != 3 {
		t.Fatal("profiles")
	}
	l := p.LimitsFor("decide-tiny", contract.DefaultLimits())
	if l.MaxOptions != 12 || l.MinScale != 2 || l.MaxScale != 5 {
		t.Fatalf("limits %+v", l)
	}
	if _, err := BuildProfiles(nil, "", contract.DefaultLimits()); err == nil {
		t.Fatal("no profiles must fail")
	}
	if _, err := BuildProfiles(specs, "nope", contract.DefaultLimits()); err == nil {
		t.Fatal("unknown default must fail")
	}
}

func TestBuildProfilesCapsAtGlobalMaxOptions(t *testing.T) {
	specs, _ := ParseCatalog([]byte(catJSON))
	base := contract.DefaultLimits()
	base.MaxOptions = 8 // LLMCTL_DECIDE_MAX_OPTIONS lowers the practical cap
	p, _ := BuildProfiles(specs, "decide-tiny", base)
	if got := p.LimitsFor("decide-tiny", base).MaxOptions; got != 8 {
		t.Fatalf("global cap must win over a larger profile cap, got %d", got)
	}
	// native profiles may exceed the global practical cap (hosted maximum applies)
	if got := p.LimitsFor("decide-laya", base).MaxOptions; got != 255 {
		t.Fatalf("native cap %d", got)
	}
}
