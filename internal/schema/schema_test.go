package schema

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

var update = flag.Bool("update", false, "rewrite the golden files")

func TestGolden(t *testing.T) {
	for _, f := range Formats() {
		t.Run(string(f), func(t *testing.T) {
			got, err := Emit(f)
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join("testdata", string(f)+".golden.json")
			if *update {
				if err := os.WriteFile(path, got, 0o644); err != nil {
					t.Fatal(err)
				}
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("missing golden %s (run with -update): %v", path, err)
			}
			if !bytes.Equal(got, want) {
				t.Fatalf("%s differs from its golden file; rerun with -update only if the contract changed on purpose", f)
			}
		})
	}
}

func TestDeterministic(t *testing.T) {
	for _, f := range Formats() {
		first, _ := Emit(f)
		for i := 0; i < 25; i++ {
			again, _ := Emit(f)
			if !bytes.Equal(first, again) {
				t.Fatalf("%s: emission %d differs", f, i)
			}
		}
	}
}

func TestEmitRejectsUnknownFormat(t *testing.T) {
	if _, err := Emit("yaml"); err == nil {
		t.Fatal("unknown format accepted")
	}
	if _, err := ParseFormat("openai"); err == nil {
		t.Fatal("ParseFormat accepted a non-format")
	}
	for _, f := range Formats() {
		if g, err := ParseFormat(string(f)); err != nil || g != f {
			t.Fatalf("ParseFormat(%q) = %v, %v", f, g, err)
		}
	}
}

func decode(t *testing.T, b []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestShapes(t *testing.T) {
	js, _ := Emit(FormatJSONSchema)
	oa, _ := Emit(FormatOpenAITool)
	mc, _ := Emit(FormatMCP)
	in := decode(t, js)
	if in["type"] != "object" {
		t.Fatalf("json-schema type %v", in["type"])
	}
	// openai: {"type":"function","function":{"name","description","parameters"}} and parameters == the schema
	o := decode(t, oa)
	fn := o["function"].(map[string]any)
	if o["type"] != "function" || fn["name"] != ToolName {
		t.Fatalf("openai tool header %v", o)
	}
	pj, _ := json.Marshal(fn["parameters"])
	sj, _ := json.Marshal(in)
	if !bytes.Equal(pj, sj) {
		t.Fatal("openai parameters differ from the json-schema")
	}
	// mcp: name, description, inputSchema (== schema), annotations
	m := decode(t, mc)
	if m["name"] != ToolName {
		t.Fatalf("mcp name %v", m["name"])
	}
	ij, _ := json.Marshal(m["inputSchema"])
	if !bytes.Equal(ij, sj) {
		t.Fatal("mcp inputSchema differs from the json-schema")
	}
	ann := m["annotations"].(map[string]any)
	if ann["readOnlyHint"] != true || ann["openWorldHint"] != false {
		t.Fatalf("mcp annotations %v", ann)
	}
}

// The schema is generated from internal/contract: its constants must show up in it.
func TestDerivedFromContract(t *testing.T) {
	in := InputSchema()
	props := in["properties"].(map[string]any)
	qs := props["questions"].(map[string]any)
	if got := qs["maxProperties"]; got != contract.DefaultLimits().MaxQuestions {
		t.Fatalf("maxProperties %v", got)
	}
	b, _ := json.Marshal(in)
	for _, want := range []string{contract.TypeNoul, contract.TypeChoice, contract.TypeScore} {
		if !bytes.Contains(b, []byte(`"`+want+`"`)) {
			t.Fatalf("type %q missing from the schema", want)
		}
	}
	s := string(b)
	for _, frag := range []string{`"maxProperties":255`, `"minItems":2`, `"maxItems":10`, `"required":["state","questions"]`, `"additionalProperties":false`} {
		if !bytes.Contains(b, []byte(frag)) {
			t.Fatalf("fragment %s missing:\n%s", frag, s)
		}
	}
}

func TestInputSchemaIsACopy(t *testing.T) {
	a := InputSchema()
	a["type"] = "mutated"
	if InputSchema()["type"] != "object" {
		t.Fatal("InputSchema returned shared state")
	}
}

func TestMCPToolMatchesEmission(t *testing.T) {
	m, err := MCPTool()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := Emit(FormatMCP)
	want := decode(t, b)
	g, _ := json.Marshal(m)
	w, _ := json.Marshal(want)
	if !bytes.Equal(g, w) {
		t.Fatal("MCPTool differs from the mcp emission")
	}
}

// B-15 / FR-015: the agent-facing text must never promise calibration.
func TestDescriptionDoesNotClaimCalibratedProbabilities(t *testing.T) {
	d := strings.ToLower(Description)
	for i := strings.Index(d, "calibrated"); i >= 0; i = nextIndex(d, i) {
		before := d[max(0, i-40):i]
		if !strings.Contains(before, "not ") && !strings.Contains(before, "not a ") {
			t.Fatalf("the tool description claims calibration: %q", Description)
		}
	}
	if !strings.Contains(d, "not calibrated") {
		t.Fatal("the description must say the scores are not calibrated")
	}
	if !strings.Contains(Description, "option_missing") {
		t.Fatal("the description must explain flagged answers")
	}
}

func nextIndex(s string, from int) int {
	j := strings.Index(s[from+1:], "calibrated")
	if j < 0 {
		return -1
	}
	return from + 1 + j
}

// B2-04: the schema must not promise more than the neutralisation delivers.
func TestStateDescriptionDoesNotOverpromise(t *testing.T) {
	for _, f := range Formats() {
		got, err := Emit(f)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(got, []byte("never as instructions")) {
			t.Errorf("%s: the state description promises \"never as instructions\"; neutralisation is best effort", f)
		}
		if !bytes.Contains(got, []byte("delimited and neutralised")) {
			t.Errorf("%s: the state description must say the state is delimited and neutralised (best effort)", f)
		}
	}
}
