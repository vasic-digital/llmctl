package gateway

import (
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/server"
)

const matCat = `{"profiles":{"decide-x":{"engine":"llama","port":8199,"capability":["decide"],
 "decision":{"protocol":"letter-logit"},
 "maturity":{
  "noul":{"status":"measured","evidence":"e.txt","lower_bound":0.7,"baseline":0.6,"n":60},
  "choice":{"status":"experimental","evidence":"e.txt","lower_bound":0.2,"baseline":0.3,"n":41},
  "score":{"status":"unmeasured","reason":"not yet measured"}}}}}`

// T138: the catalog maturity object reaches /v1/models and the answer label (production wiring, not a test double).
func TestCatalogMaturityReachesModelsAndAnswerLabels(t *testing.T) {
	specs, err := ParseCatalog([]byte(matCat))
	if err != nil || len(specs) != 1 {
		t.Fatalf("parse: %v %v", specs, err)
	}
	res := NewStaticResolver()
	res.Set(KindDecide, "decide-x", Endpoint{URL: "http://127.0.0.1:1", Healthy: true, Key: "k"})
	r, err := NewRouter(RouterConfig{Specs: specs, Resolver: res, Drivers: DefaultDrivers(Deterministic, false)})
	if err != nil {
		t.Fatal(err)
	}
	ms := r.Models()
	if len(ms) != 1 || ms[0].Maturity["choice"].Status != "experimental" || ms[0].Maturity["noul"].Status != "measured" ||
		ms[0].Maturity["score"].Reason != "not yet measured" {
		t.Fatalf("Models() maturity = %+v", ms)
	}
	var mr server.MaturityReporter = r
	if got := mr.Maturity("decide-x", "choice"); got != "experimental" {
		t.Errorf("choice label = %q", got)
	}
	if got := mr.Maturity("decide-x", "score"); got != "experimental" {
		t.Errorf("unmeasured score label = %q", got)
	}
	if got := mr.Maturity("decide-x", "noul"); got != "" {
		t.Errorf("golden-false: measured noul must carry no label, got %q", got)
	}
	if got := mr.Maturity("nope", "noul"); got != "" {
		t.Errorf("unknown profile must carry no label, got %q", got)
	}
}

// A type missing from a profile's maturity object is unmeasured, i.e. experimental - the same rule as the planner.
func TestMissingMaturityTypeIsExperimental(t *testing.T) {
	cat := `{"profiles":{"decide-x":{"engine":"llama","port":8199,"capability":["decide"],"decision":{"protocol":"letter-logit"},
 "maturity":{"noul":{"status":"measured","lower_bound":0.7,"baseline":0.6,"n":60}}}}}`
	specs, err := ParseCatalog([]byte(cat))
	if err != nil {
		t.Fatal(err)
	}
	r, err := NewRouter(RouterConfig{Specs: specs, Resolver: NewStaticResolver(), Drivers: DefaultDrivers(Deterministic, false)})
	if err != nil {
		t.Fatal(err)
	}
	if got := r.Maturity("decide-x", "choice"); got != "experimental" {
		t.Errorf("missing choice label = %q, want experimental", got)
	}
	if got := r.Maturity("decide-x", "noul"); got != "" {
		t.Errorf("golden-false: measured noul label = %q", got)
	}
}

// Validation and fields of the parsed entries (kills mutants that drop them).
func TestParseCatalogMaturityFieldsAndStatusValidation(t *testing.T) {
	cat := `{"profiles":{"decide-x":{"engine":"llama","port":8199,"capability":["decide"],"decision":{"protocol":"letter-logit"},
 "maturity":{"noul":{"status":"measured","lower_bound":0.7,"baseline":0.6,"n":60}}}}}`
	specs, err := ParseCatalog([]byte(cat))
	if err != nil {
		t.Fatal(err)
	}
	m := specs[0].Maturity["noul"]
	if m.LowerBound == nil || *m.LowerBound != 0.7 || m.Baseline == nil || *m.Baseline != 0.6 || m.N != 60 {
		t.Errorf("fields not carried: %+v", m)
	}
	bad := strings.Replace(cat, `"measured"`, `"bogus"`, 1)
	if _, err := ParseCatalog([]byte(bad)); err == nil || !strings.Contains(err.Error(), "maturity.noul.status") {
		t.Errorf("bogus status must be refused, got %v", err)
	}
}
