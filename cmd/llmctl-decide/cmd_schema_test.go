package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/schema"
)

func TestSchemaFormats(t *testing.T) {
	for _, f := range schema.Formats() {
		var o, e bytes.Buffer
		if rc := run([]string{"schema", "--format", string(f)}, &o, &e); rc != 0 {
			t.Fatalf("%s rc=%d stderr=%s", f, rc, e.String())
		}
		want, _ := schema.Emit(f)
		if !bytes.Equal(o.Bytes(), want) {
			t.Fatalf("%s output differs from schema.Emit", f)
		}
		if !json.Valid(o.Bytes()) {
			t.Fatalf("%s output is not JSON", f)
		}
	}
}

func TestSchemaDefaultIsJSONSchema(t *testing.T) {
	var a, b, e bytes.Buffer
	if run([]string{"schema"}, &a, &e) != 0 || run([]string{"schema", "--format=json-schema"}, &b, &e) != 0 {
		t.Fatal(e.String())
	}
	if !bytes.Equal(a.Bytes(), b.Bytes()) {
		t.Fatal("default format is not json-schema")
	}
}

func TestSchemaUsageErrors(t *testing.T) {
	for _, args := range [][]string{{"schema", "--format", "yaml"}, {"schema", "extra"}, {"schema", "--bogus"}, {"schema", "--format"}} {
		var o, e bytes.Buffer
		if rc := run(args, &o, &e); rc != 2 {
			t.Fatalf("%v rc=%d", args, rc)
		}
		if o.Len() != 0 {
			t.Fatalf("%v wrote to stdout: %q", args, o.String())
		}
	}
	var o, e bytes.Buffer
	run([]string{"schema", "--format", "yaml"}, &o, &e)
	if !strings.Contains(e.String(), "json-schema|openai-tool|mcp") {
		t.Fatalf("stderr %q", e.String())
	}
}

func TestMCPNoKeyIsFailClosedPerCall(t *testing.T) {
	// no key, no CA: the server must still start and answer every call with isError (never a default answer)
	old := askEnviron
	defer func() { askEnviron = old }()
	t.Setenv("LLMCTL_ROOT", t.TempDir())
	tmp := t.TempDir()
	askEnviron = func() keyring.Environ { return keyring.Environ{"HOME": tmp} }
	oldIn := mcpStdin
	defer func() { mcpStdin = oldIn }()
	mcpStdin = strings.NewReader(
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}` + "\n" +
			`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"decide","arguments":{"state":"x","questions":{"q":{"type":"noul","instructions":"ok?"}}}}}` + "\n")
	var o, e bytes.Buffer
	if rc := run([]string{"mcp"}, &o, &e); rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, e.String())
	}
	lines := strings.Split(strings.TrimSpace(o.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("stdout: %q", o.String())
	}
	if !strings.Contains(lines[1], `"isError":true`) || strings.Contains(lines[1], "structuredContent") {
		t.Fatalf("call did not fail closed: %s", lines[1])
	}
	if !strings.Contains(e.String(), "no access key") {
		t.Fatalf("stderr should explain: %q", e.String())
	}
}

func TestMCPUsage(t *testing.T) {
	var o, e bytes.Buffer
	if rc := run([]string{"mcp", "--bogus"}, &o, &e); rc != 2 {
		t.Fatalf("rc=%d", rc)
	}
	if rc := run([]string{"mcp", "extra"}, &o, &e); rc != 2 {
		t.Fatalf("rc=%d", rc)
	}
}
