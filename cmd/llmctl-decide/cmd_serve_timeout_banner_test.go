package main

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// G-156: the start-up banner names the effective per-request deadline and where it came from, so an
// operator who sees 502 deadline_exceeded can tell the 8 s contract default from a launcher-raised
// cpu-adaptive value from an explicit LLMCTL_DECIDE_TIMEOUT.
func TestBannerPrintsEffectiveTimeoutAndSource(t *testing.T) {
	for _, c := range []struct {
		name    string
		set     map[string]string
		want    string
		notWant string
	}{
		{"default", nil, "timeout: 8s per request (default", ""},
		{"explicit env", map[string]string{"LLMCTL_DECIDE_TIMEOUT": "300"}, "timeout: 300s per request (env", "cpu-adaptive"},
		{"cpu-adaptive", map[string]string{"LLMCTL_DECIDE_TIMEOUT": "120", "LLMCTL_DECIDE_TIMEOUT_SOURCE": "cpu-adaptive", "LLMCTL_DECIDE_TIMEOUT_NOTE": "decide-pro decide-max"},
			"timeout: 120s per request (cpu-adaptive: CPU-placed decide-pro decide-max;", ""},
		// a source label without a timeout value is meaningless: the gateway runs on the default
		{"label without value", map[string]string{"LLMCTL_DECIDE_TIMEOUT_SOURCE": "cpu-adaptive"}, "timeout: 8s per request (default", "cpu-adaptive"},
		// an unknown label is not trusted as a source
		{"unknown label", map[string]string{"LLMCTL_DECIDE_TIMEOUT": "30", "LLMCTL_DECIDE_TIMEOUT_SOURCE": "made-up"}, "timeout: 30s per request (env", "made-up"},
	} {
		t.Run(c.name, func(t *testing.T) {
			se := setupServeEnv(t)
			for k, v := range c.set {
				se.env[k] = v
			}
			var e, out bytes.Buffer
			p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e)
			if p == nil {
				t.Fatalf("prepare rc=%d err=%s", code, e.String())
			}
			defer p.close()
			p.banner(&out)
			got := out.String()
			if !strings.Contains(got, c.want) {
				t.Errorf("banner lacks %q:\n%s", c.want, got)
			}
			if c.notWant != "" && strings.Contains(got, c.notWant) {
				t.Errorf("banner must not contain %q:\n%s", c.notWant, got)
			}
		})
	}
}

func TestTimeoutSourceDefaultStaysEightSeconds(t *testing.T) {
	// contract (limits.go, contracts/env-vars.md): the Go default is unchanged by the launcher-side adaptation
	se := setupServeEnv(t)
	var e bytes.Buffer
	p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e)
	if p == nil {
		t.Fatalf("prepare rc=%d err=%s", code, e.String())
	}
	defer p.close()
	if p.sLimits.Timeout != 8*time.Second {
		t.Fatalf("Go default timeout = %v, want 8s", p.sLimits.Timeout)
	}
}
