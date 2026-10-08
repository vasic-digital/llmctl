package main

import (
	"math"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/gateway"
)

// B-06 / B-07: the readout settings are validated at start.
func TestParseReadoutEnvRefusesSettingsThatBreakEveryRequest(t *testing.T) {
	bad := []struct {
		env  map[string]string
		mode gateway.Mode
		want string
	}{
		{map[string]string{"LLMCTL_DECIDE_TEMPERATURE": "NaN"}, gateway.Deterministic, "LLMCTL_DECIDE_TEMPERATURE"},
		{map[string]string{"LLMCTL_DECIDE_TEMPERATURE": "Inf"}, gateway.Deterministic, "LLMCTL_DECIDE_TEMPERATURE"},
		{map[string]string{"LLMCTL_DECIDE_TEMPERATURE": "-1"}, gateway.Deterministic, "LLMCTL_DECIDE_TEMPERATURE"},
		{map[string]string{"LLMCTL_DECIDE_TEMPERATURE": "0"}, gateway.Deterministic, "LLMCTL_DECIDE_TEMPERATURE"},
		{map[string]string{"LLMCTL_DECIDE_TEMPERATURE": "warm"}, gateway.Deterministic, "LLMCTL_DECIDE_TEMPERATURE"},
		{map[string]string{"LLMCTL_DECIDE_MASS_THRESHOLD": "5"}, gateway.Deterministic, "LLMCTL_DECIDE_MASS_THRESHOLD"},
		{map[string]string{"LLMCTL_DECIDE_MASS_THRESHOLD": "0"}, gateway.Deterministic, "LLMCTL_DECIDE_MASS_THRESHOLD"},
		{map[string]string{"LLMCTL_DECIDE_MASS_THRESHOLD": "-0.2"}, gateway.Deterministic, "LLMCTL_DECIDE_MASS_THRESHOLD"},
		{map[string]string{"LLMCTL_DECIDE_MASS_THRESHOLD": "NaN"}, gateway.Deterministic, "LLMCTL_DECIDE_MASS_THRESHOLD"},
		{map[string]string{"LLMCTL_SEED": "-1"}, gateway.Deterministic, "LLMCTL_SEED"},
		{map[string]string{"LLMCTL_SEED": "1.5"}, gateway.Deterministic, "LLMCTL_SEED"},
		{map[string]string{"LLMCTL_DECIDE_SLOTS": "0"}, gateway.Throughput, "LLMCTL_DECIDE_SLOTS"},
		{map[string]string{"LLMCTL_DECIDE_SLOTS": "x"}, gateway.Throughput, "LLMCTL_DECIDE_SLOTS"},
		{map[string]string{"LLMCTL_DECIDE_SLOTS": "4"}, gateway.Deterministic, "throughput"},
		{map[string]string{"LLMCTL_DECIDE_MAX_PAIRS": "0"}, gateway.Deterministic, "LLMCTL_DECIDE_MAX_PAIRS"},
		{map[string]string{"LLMCTL_DECIDE_MAX_PAIRS": "9999"}, gateway.Deterministic, "LLMCTL_DECIDE_MAX_PAIRS"},
	}
	for _, c := range bad {
		_, err := parseReadoutEnv(c.env, c.mode, contract.DefaultLimits())
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%v (%s): want an error naming %q, got %v", c.env, c.mode, c.want, err)
		}
	}
	over := contract.DefaultLimits()
	over.MaxOptions = 300
	if _, err := parseReadoutEnv(nil, gateway.Deterministic, over); err == nil || !strings.Contains(err.Error(), "LLMCTL_DECIDE_MAX_OPTIONS") {
		t.Errorf("limits that fail Validate must be refused at start: %v", err)
	}
}

func TestParseReadoutEnvAcceptsGoodSettingsAndDefaults(t *testing.T) {
	r, err := parseReadoutEnv(nil, gateway.Deterministic, contract.DefaultLimits())
	if err != nil || r.Seed != gateway.DefaultSeed || r.Slots != 1 || r.MaxPairs != 64 || r.Threshold != 0 || r.Temperature != 0 {
		t.Fatalf("defaults: %+v %v", r, err)
	}
	r, err = parseReadoutEnv(map[string]string{"LLMCTL_DECIDE_TEMPERATURE": "0.5", "LLMCTL_DECIDE_MASS_THRESHOLD": "1", "LLMCTL_SEED": "7",
		"LLMCTL_DECIDE_SLOTS": "4", "LLMCTL_DECIDE_MAX_PAIRS": "128"}, gateway.Throughput, contract.DefaultLimits())
	if err != nil || r.Temperature != 0.5 || r.Threshold != 1 || r.Seed != 7 || r.Slots != 4 || r.MaxPairs != 128 {
		t.Fatalf("%+v %v", r, err)
	}
	if math.IsNaN(r.Temperature) {
		t.Fatal("nan")
	}
}

// B3-08: LLMCTL_SEED=0 is a valid fixed seed (llama.cpp: only a negative seed is random); it must reach
// the driver as 0, not as the default seed 1, and an unset variable still means the default.
func TestSeedZeroIsAValidFixedSeed(t *testing.T) {
	r, err := parseReadoutEnv(map[string]string{"LLMCTL_SEED": "0"}, gateway.Deterministic, contract.DefaultLimits())
	if err != nil || gateway.ResolveSeed(r.Seed) != 0 {
		t.Fatalf("LLMCTL_SEED=0: %v seed=%d resolved=%d", err, r.Seed, gateway.ResolveSeed(r.Seed))
	}
	r, err = parseReadoutEnv(map[string]string{}, gateway.Deterministic, contract.DefaultLimits())
	if err != nil || gateway.ResolveSeed(r.Seed) != gateway.DefaultSeed {
		t.Fatalf("unset: %v %d", err, r.Seed)
	}
	r, _ = parseReadoutEnv(map[string]string{"LLMCTL_SEED": "  "}, gateway.Deterministic, contract.DefaultLimits())
	if gateway.ResolveSeed(r.Seed) != gateway.DefaultSeed {
		t.Fatalf("blank = unset: %d", r.Seed)
	}
	if _, err := parseReadoutEnv(map[string]string{"LLMCTL_SEED": "-1"}, gateway.Deterministic, contract.DefaultLimits()); err == nil {
		t.Fatal("a negative seed is random to llama-server and stays refused")
	}
}
