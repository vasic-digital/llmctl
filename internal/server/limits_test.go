package server

import (
	"strings"
	"testing"
	"time"
)

func TestDefaultLimitsMatchEnvContract(t *testing.T) {
	d := DefaultLimits()
	want := map[string]any{
		"MaxConns": 64, "MaxConnsPerSource": 8, "Queue": 64, "AuthFailLimit": 10,
		"HandshakeTimeout": 3 * time.Second, "ReadDeadline": 10 * time.Second,
		"Timeout": 8 * time.Second, "DrainGrace": 15 * time.Second, "MaxBody": int64(262144),
	}
	got := map[string]any{
		"MaxConns": d.MaxConns, "MaxConnsPerSource": d.MaxConnsPerSource, "Queue": d.Queue,
		"AuthFailLimit": d.AuthFailLimit, "HandshakeTimeout": d.HandshakeTimeout,
		"ReadDeadline": d.ReadDeadline, "Timeout": d.Timeout, "DrainGrace": d.DrainGrace, "MaxBody": d.MaxBody,
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s = %v, want %v", k, got[k], w)
		}
	}
	if err := d.Validate(); err != nil {
		t.Fatalf("defaults must validate: %v", err)
	}
}

func TestFromEnvOverrides(t *testing.T) {
	env := map[string]string{
		"LLMCTL_DECIDE_MAX_CONNS": "100", "LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE": "5",
		"LLMCTL_DECIDE_QUEUE": "0", "LLMCTL_DECIDE_HANDSHAKE_TIMEOUT": "1.5",
		"LLMCTL_DECIDE_READ_DEADLINE": "20", "LLMCTL_DECIDE_TIMEOUT": "30",
		"LLMCTL_DECIDE_MAX_BODY": "1024", "LLMCTL_DECIDE_DRAIN_GRACE": "2",
		"LLMCTL_DECIDE_AUTH_FAIL_LIMIT": "3", "LLMCTL_DECIDE_CONCURRENCY": "2",
		"UNRELATED": "x",
	}
	l, err := FromEnv(env)
	if err != nil {
		t.Fatal(err)
	}
	if l.MaxConns != 100 || l.MaxConnsPerSource != 5 || l.Queue != 0 || l.AuthFailLimit != 3 || l.Concurrency != 2 ||
		l.HandshakeTimeout != 1500*time.Millisecond || l.ReadDeadline != 20*time.Second ||
		l.Timeout != 30*time.Second || l.MaxBody != 1024 || l.DrainGrace != 2*time.Second {
		t.Fatalf("overrides not applied: %+v", l)
	}
	// unset => defaults
	l2, err := FromEnv(map[string]string{})
	if err != nil || l2 != DefaultLimits() {
		t.Fatalf("empty env must give defaults: %+v %v", l2, err)
	}
}

func TestFromEnvRejectsBadValues(t *testing.T) {
	vars := []string{
		"LLMCTL_DECIDE_MAX_CONNS", "LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE", "LLMCTL_DECIDE_QUEUE",
		"LLMCTL_DECIDE_HANDSHAKE_TIMEOUT", "LLMCTL_DECIDE_READ_DEADLINE", "LLMCTL_DECIDE_TIMEOUT",
		"LLMCTL_DECIDE_MAX_BODY", "LLMCTL_DECIDE_DRAIN_GRACE", "LLMCTL_DECIDE_AUTH_FAIL_LIMIT",
		"LLMCTL_DECIDE_CONCURRENCY",
	}
	bad := []string{"abc", "-1", "", " ", "1e999", "NaN", "Inf", "-0.5", "3s", "0x10", "5 5", "99999999999999999999999"}
	for _, v := range vars {
		for _, b := range bad {
			func() {
				defer func() {
					if r := recover(); r != nil {
						t.Errorf("%s=%q panicked: %v", v, b, r)
					}
				}()
				_, err := FromEnv(map[string]string{v: b})
				if err == nil {
					t.Errorf("%s=%q must be rejected", v, b)
					return
				}
				if !strings.Contains(err.Error(), v) {
					t.Errorf("%s=%q: error must name the variable: %v", v, b, err)
				}
			}()
		}
	}
}

func TestFromEnvRejectsZerosWhereMeaningless(t *testing.T) {
	for _, kv := range [][2]string{
		{"LLMCTL_DECIDE_MAX_CONNS", "0"}, {"LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE", "0"},
		{"LLMCTL_DECIDE_MAX_BODY", "0"}, {"LLMCTL_DECIDE_AUTH_FAIL_LIMIT", "0"},
		{"LLMCTL_DECIDE_TIMEOUT", "0"}, {"LLMCTL_DECIDE_READ_DEADLINE", "0"},
		{"LLMCTL_DECIDE_HANDSHAKE_TIMEOUT", "0"}, {"LLMCTL_DECIDE_CONCURRENCY", "0"},
	} {
		if _, err := FromEnv(map[string]string{kv[0]: kv[1]}); err == nil {
			t.Errorf("%s=%s must be rejected", kv[0], kv[1])
		}
	}
	// Queue 0 (no waiting room) is legal, DrainGrace 0 is not.
	if _, err := FromEnv(map[string]string{"LLMCTL_DECIDE_QUEUE": "0"}); err != nil {
		t.Errorf("QUEUE=0 is legal: %v", err)
	}
	if _, err := FromEnv(map[string]string{"LLMCTL_DECIDE_DRAIN_GRACE": "0"}); err == nil {
		t.Error("DRAIN_GRACE=0 must be rejected")
	}
}

func TestFromEnvPerSourceMustNotExceedGlobal(t *testing.T) {
	_, err := FromEnv(map[string]string{"LLMCTL_DECIDE_MAX_CONNS": "4", "LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE": "9"})
	if err == nil {
		t.Fatal("per-source cap above the global cap must be rejected")
	}
}

func TestFromLookupFunc(t *testing.T) {
	l, err := FromLookup(func(k string) (string, bool) {
		if k == "LLMCTL_DECIDE_MAX_CONNS" {
			return "7", true
		}
		return "", false
	})
	if err != nil || l.MaxConns != 7 || l.MaxConnsPerSource != 7 {
		// default per-source (8) above the overridden global (7) is clamped, not an error:
		// only EXPLICIT inconsistent values are rejected.
		t.Fatalf("lookup: %+v %v", l, err)
	}
}

func TestValidateRejectsInconsistentProgrammaticLimits(t *testing.T) {
	d := DefaultLimits()
	d.MaxConnsPerSource = d.MaxConns + 1
	if d.Validate() == nil {
		t.Error("per-source above global must fail Validate")
	}
	d = DefaultLimits()
	d.Timeout = 0
	if d.Validate() == nil {
		t.Error("zero timeout must fail Validate")
	}
}

// Review A-01: the admission knobs are env-tunable, strictly validated, and must nest.
func TestAdmissionLimitsDefaultsAndEnv(t *testing.T) {
	d := DefaultLimits()
	if d.MaxUnauthConns != 32 || d.MaxUnauthPerSource != 8 || d.MaxUnauthPerAggregate != 16 || d.PreAuthTimeout != 3*time.Second {
		t.Fatalf("defaults: %+v", d)
	}
	if d.MaxUnauthConns >= d.MaxConns {
		t.Error("capacity must be reserved for authenticated connections: unauth budget < MaxConns")
	}
	l, err := FromEnv(map[string]string{
		"LLMCTL_DECIDE_MAX_UNAUTH_CONNS": "10", "LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE": "2",
		"LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX": "5", "LLMCTL_DECIDE_PREAUTH_TIMEOUT": "1.5",
		"LLMCTL_DECIDE_IDLE_TIMEOUT": "20",
	})
	if err != nil {
		t.Fatal(err)
	}
	if l.MaxUnauthConns != 10 || l.MaxUnauthPerSource != 2 || l.MaxUnauthPerAggregate != 5 ||
		l.PreAuthTimeout != 1500*time.Millisecond || l.IdleTimeout != 20*time.Second {
		t.Fatalf("overrides not applied: %+v", l)
	}
}

func TestAdmissionLimitsRejectBadAndInconsistentValues(t *testing.T) {
	bad := []map[string]string{
		{"LLMCTL_DECIDE_MAX_UNAUTH_CONNS": "0"},
		{"LLMCTL_DECIDE_MAX_UNAUTH_CONNS": "abc"},
		{"LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE": "-1"},
		{"LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX": ""},
		{"LLMCTL_DECIDE_PREAUTH_TIMEOUT": "0"},
		{"LLMCTL_DECIDE_PREAUTH_TIMEOUT": "3s"},
		{"LLMCTL_DECIDE_IDLE_TIMEOUT": "NaN"},
		{"LLMCTL_DECIDE_MAX_UNAUTH_CONNS": "100"},                                                // > MAX_CONNS 64
		{"LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE": "9"},                                             // > per-source 8
		{"LLMCTL_DECIDE_MAX_UNAUTH_CONNS": "4", "LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE": "5"},      // per source > pool
		{"LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX": "99"},                                            // > pool
		{"LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE": "6", "LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX": "5"}, // prefix < source
	}
	for _, env := range bad {
		if _, err := FromEnv(env); err == nil {
			t.Errorf("%v must be refused", env)
		}
	}
	// a smaller explicit MAX_CONNS clamps the defaults instead of failing
	l, err := FromEnv(map[string]string{"LLMCTL_DECIDE_MAX_CONNS": "10"})
	if err != nil || l.MaxUnauthConns != 10 || l.MaxUnauthPerAggregate > l.MaxUnauthConns {
		t.Fatalf("defaults must clamp under a smaller MAX_CONNS: %+v %v", l, err)
	}
	if err := (Limits{}).Validate(); err == nil {
		t.Error("zero Limits must not validate")
	}
	z := DefaultLimits()
	z.PreAuthTimeout = 0
	if z.Validate() == nil {
		t.Error("PreAuthTimeout must be positive")
	}
	z = DefaultLimits()
	z.MaxUnauthConns = 0
	if z.Validate() == nil {
		t.Error("MaxUnauthConns must be positive")
	}
}
