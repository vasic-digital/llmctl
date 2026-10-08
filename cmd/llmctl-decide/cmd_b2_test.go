package main

import (
	"os"
	"strings"
	"testing"
)

// B2-16: contracts/cli.md must not present a command the binary does not have as shipped.
func TestCLIContractMarksUnshippedCommandsAsPlanned(t *testing.T) {
	b, err := os.ReadFile("../../specs/009-jev-decision-models/contracts/cli.md")
	if err != nil {
		t.Fatal(err)
	}
	doc := string(b)
	// `scale` shipped in 3.1.0 as a shell front-end command (lib/decide.sh -> sched_decision_scale),
	// not as a Go subcommand: it must be dispatched by the front-end, and cli.md must no longer call
	// it planned. (If it were planned again this test must be flipped back, never silently passed.)
	front, err := os.ReadFile("../../lib/decide.sh")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(front), "scale)       decide_scale") && !strings.Contains(string(front), "scale) decide_scale") {
		t.Errorf("cli.md documents \"scale\" as shipped but lib/decide.sh does not dispatch it")
	}
	scaleDocumented := false
	for _, line := range strings.Split(doc, "\n") {
		if (strings.HasPrefix(line, "## ") || strings.HasPrefix(line, "|")) && strings.Contains(line, "scale") && !strings.Contains(line, "Delta") {
			scaleDocumented = true
			if strings.Contains(line, "planned, not in 3.1.0") {
				t.Errorf("\"scale\" is implemented (lib/decide.sh) but cli.md still marks it planned: %q", line)
			}
		}
	}
	if !scaleDocumented {
		t.Errorf("cli.md no longer mentions \"scale\"")
	}
	// OD-23: calibrate, probe-order and completions are implemented; cli.md must say so (no
	// "planned" marker on a line about them) and the binary must have them.
	for _, name := range []string{"ask", "batch", "schema", "serve", "key", "cert", "mcp", "smoke", "calibrate", "probe-order", "completions"} {
		if _, ok := commands[name]; !ok {
			t.Errorf("cli.md describes %q but the binary does not register it", name)
		}
	}
	for _, name := range []string{"calibrate", "probe-order", "completions"} {
		mentioned := false
		for _, line := range strings.Split(doc, "\n") {
			if (strings.HasPrefix(line, "## ") || strings.HasPrefix(line, "|")) && strings.Contains(line, name) {
				mentioned = true
				if strings.Contains(line, "planned, not in 3.1.0") {
					t.Errorf("cli.md still marks the implemented %q as planned: %q", name, line)
				}
			}
		}
		if !mentioned {
			t.Errorf("cli.md has no section or table row for the implemented %q", name)
		}
	}
}
