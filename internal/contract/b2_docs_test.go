package contract_test

import (
	"os"
	"strings"
	"testing"
)

func readDoc(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// B2-06/B2-01/B2-08/B2-11/B2-05: the documents say what the code does.
func TestOpenAPIAndDocsStateTheRealBehaviour(t *testing.T) {
	api := readDoc(t, "../../specs/009-jev-decision-models/contracts/openapi.yaml")
	gw := readDoc(t, "../../docs/decide-gateway.md")
	env := readDoc(t, "../../specs/009-jev-decision-models/contracts/env-vars.md")
	need := map[string][]string{
		"openapi": {
			"retry every 5xx", "RetryPolicy", // B2-06: the hosted SDK retries 500
			"x-llmctl-decide-instance", // B2-11
			"three spellings",          // B2-01: the bound covers all spellings
			"same scale",               // B2-02: bound is comparable with probabilities
			"stale registry",           // B2-08: engine 404 is a 502
		},
		"gateway doc": {"retry every 5xx", "x-llmctl-decide-instance", "LLMCTL_CTX_", "/props", "best effort"},
		"env vars":    {"LLMCTL_CTX_", "0 or more", "per profile on every request", "4_096", "before the first completion"},
	}
	docs := map[string]string{"openapi": api, "gateway doc": gw, "env vars": env}
	for name, phrases := range need {
		for _, p := range phrases {
			if !strings.Contains(docs[name], p) {
				t.Errorf("%s must mention %q", name, p)
			}
		}
	}
	// B3-01/B3-11: the exact guarantee, not "CONSERVATIVE"; no stale auto-mode claims
	if !strings.Contains(api, "min(3 * p_min, U)") || strings.Contains(api, "are CONSERVATIVE") {
		t.Error("openapi must state the exact bound min(3 * p_min, U) and not claim a CONSERVATIVE distribution")
	}
	reg := readDoc(t, "../../docs/registry-discovery.md")
	if strings.Contains(reg, "not re-evaluated") || strings.Contains(gw, "decides once") || strings.Contains(env, "when the registry already lists services") {
		t.Error("a document still claims that auto mode decides once / globally")
	}
	if strings.Contains(api, "an unlisted alternative cannot exceed it") {
		t.Error("openapi still claims the single-token floor is an upper bound for a letter that sums several spellings")
	}
}
