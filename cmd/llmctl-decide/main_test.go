package main

import (
	"bytes"
	"testing"
)

func TestRunNoArgsIsUsageError(t *testing.T) {
	var o, e bytes.Buffer
	if rc := run(nil, &o, &e); rc != 2 {
		t.Fatalf("rc=%d want 2", rc)
	}
}

func TestRunUnknownSubcommand(t *testing.T) {
	var o, e bytes.Buffer
	if rc := run([]string{"nope"}, &o, &e); rc != 2 {
		t.Fatalf("rc=%d want 2", rc)
	}
}
