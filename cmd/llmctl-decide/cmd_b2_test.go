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
	for _, name := range []string{"scale"} {
		if _, shipped := commands[name]; shipped {
			t.Errorf("%q is now a registered subcommand: update the planned marker in cli.md", name)
			continue
		}
		found := false
		for _, line := range strings.Split(doc, "\n") {
			if (strings.HasPrefix(line, "## ") || strings.HasPrefix(line, "|")) && strings.Contains(line, name) && !strings.Contains(line, "Delta") {
				found = true
				if !strings.Contains(line, "planned, not in 3.1.0") {
					t.Errorf("cli.md documents %q as available without marking it \"planned, not in 3.1.0\": %q", name, line)
				}
			}
		}
		if !found {
			t.Errorf("cli.md no longer mentions %q", name)
		}
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
