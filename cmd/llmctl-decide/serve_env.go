package main

import (
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/gateway"
)

// readoutEnv is the validated readout/serving configuration of `serve` (review-2 B-06/B-07): a
// setting that could only make every request fail, or that silently breaks the determinism the
// gateway claims, is refused at start with a precise message (exit 2) instead of booting a gateway
// that answers every request with an error.
type readoutEnv struct {
	Threshold   float64 // LLMCTL_DECIDE_MASS_THRESHOLD in (0,1]; 0 = the profile's own
	Temperature float64 // LLMCTL_DECIDE_TEMPERATURE finite > 0; 0 = 1
	Seed        int     // LLMCTL_SEED >= 0 (gateway.SeedZero carries an explicit 0)
	Slots       int     // LLMCTL_DECIDE_SLOTS >= 1; exactly 1 in deterministic mode
	MaxPairs    int     // LLMCTL_DECIDE_MAX_PAIRS 1..4096, default 64
}

func finiteNumber(env map[string]string, name string) (float64, bool, error) {
	s := strings.TrimSpace(env[name])
	if s == "" {
		return 0, false, nil
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, false, fmt.Errorf("%s must be a finite number", name)
	}
	return v, true, nil
}

func wholeNumber(env map[string]string, name string, def int) (int, error) {
	s := strings.TrimSpace(env[name])
	if s == "" {
		return def, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("%s must be a whole number", name)
	}
	return n, nil
}

// parseReadoutEnv validates the readout environment against the serving mode and the base limits.
func parseReadoutEnv(env map[string]string, mode gateway.Mode, base contract.Limits) (readoutEnv, error) {
	var r readoutEnv
	if v, set, err := finiteNumber(env, "LLMCTL_DECIDE_MASS_THRESHOLD"); err != nil {
		return r, err
	} else if set {
		if !(v > 0 && v <= 1) {
			return r, fmt.Errorf("LLMCTL_DECIDE_MASS_THRESHOLD must be above 0 and at most 1 (got %s)", strings.TrimSpace(env["LLMCTL_DECIDE_MASS_THRESHOLD"]))
		}
		r.Threshold = v
	}
	if v, set, err := finiteNumber(env, "LLMCTL_DECIDE_TEMPERATURE"); err != nil {
		return r, err
	} else if set {
		if !(v > 0) {
			return r, fmt.Errorf("LLMCTL_DECIDE_TEMPERATURE must be above 0 (got %s)", strings.TrimSpace(env["LLMCTL_DECIDE_TEMPERATURE"]))
		}
		r.Temperature = v
	}
	seed, err := wholeNumber(env, "LLMCTL_SEED", gateway.DefaultSeed)
	if err != nil {
		return r, err
	}
	if seed < 0 {
		return r, fmt.Errorf("LLMCTL_SEED must be 0 or more (a negative seed means random to llama-server and would break determinism)")
	}
	if seed == 0 && strings.TrimSpace(env["LLMCTL_SEED"]) != "" {
		seed = gateway.SeedZero // an explicit 0 is a valid fixed seed, not "unset" (B3-08)
	}
	r.Seed = seed
	if r.Slots, err = wholeNumber(env, "LLMCTL_DECIDE_SLOTS", 1); err != nil {
		return r, err
	}
	if r.Slots < 1 {
		return r, fmt.Errorf("LLMCTL_DECIDE_SLOTS must be a positive integer")
	}
	if mode == gateway.Deterministic && r.Slots > 1 {
		return r, fmt.Errorf("LLMCTL_DECIDE_SLOTS=%d needs LLMCTL_DECIDE_MODE=throughput: deterministic mode serves one request per instance at a time, because batching concurrent requests changes the logits", r.Slots)
	}
	if r.MaxPairs, err = wholeNumber(env, "LLMCTL_DECIDE_MAX_PAIRS", gateway.DefaultMaxPairs); err != nil {
		return r, err
	}
	if r.MaxPairs < 1 || r.MaxPairs > 4096 {
		return r, fmt.Errorf("LLMCTL_DECIDE_MAX_PAIRS must be between 1 and 4096")
	}
	if err := base.Validate(); err != nil {
		return r, fmt.Errorf("the request limits (LLMCTL_DECIDE_MAX_OPTIONS / MAX_STATE_CHARS / MAX_QUESTIONS) are unusable: %v", err)
	}
	return r, nil
}
