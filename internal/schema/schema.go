// Package schema emits the Typed Question / decision-call schema as tool definitions for coding
// agents (FR-081, FR-086): a plain JSON Schema, an OpenAI function tool and an MCP tool.
//
// Everything is derived from internal/contract (question types, option and scale limits) and the
// output is deterministic: encoding/json sorts map keys and the emitter adds nothing time- or
// host-dependent, so golden files pin it byte for byte. The schema describes the arguments of ONE
// decision call (the /v1/systemone request body plus the tool-level min_confidence); it implies no
// chat route (a decision model is never a chat model).
package schema

import (
	"bytes"
	"encoding/json"
	"fmt"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// ToolName is the name of the decision tool in every emitted definition.
const ToolName = "decide"

// Format is an emitter format.
type Format string

// The emitted formats (`llmctl-decide schema --format ...`).
const (
	FormatJSONSchema Format = "json-schema"
	FormatOpenAITool Format = "openai-tool"
	FormatMCP        Format = "mcp"
)

// Formats lists the formats in documentation order.
func Formats() []Format { return []Format{FormatJSONSchema, FormatOpenAITool, FormatMCP} }

// ParseFormat validates a --format value.
func ParseFormat(s string) (Format, error) {
	for _, f := range Formats() {
		if string(f) == s {
			return f, nil
		}
	}
	return "", fmt.Errorf("unknown format %q (json-schema|openai-tool|mcp)", s)
}

// Description is the tool description every format carries.
const Description = "Ask the local decision model ONE typed question about a piece of state and get probability-shaped " +
	"scores back (NOT calibrated probabilities of being right; no free text is generated). Types: noul (yes/no), choice (pick one named option), " +
	"score (ordinal 0..N-1). Use it for gating and routing decisions; answers carry a confidence (a shaping convention), and " +
	"min_confidence withholds an answer that is not confident enough. An answer with flags " +
	"[\"option_missing\"] had an option absent from the model's readout: its upper_bounds say how likely " +
	"that option could still be, and it is only as confident as that bound allows. The decision model is not a chat model."

func question() map[string]any {
	lim := contract.DefaultLimits()
	desc := map[string]any{"type": "string", "description": "free text; may be empty"}
	return map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"type", "instructions"},
		"properties": map[string]any{
			"type": map[string]any{"enum": []string{contract.TypeNoul, contract.TypeChoice, contract.TypeScore},
				"description": "noul: yes/no; choice: one of the named options; score: ordinal level"},
			"instructions": map[string]any{"type": "string", "minLength": 1, "description": "the question to answer about the state"},
			"criteria": map[string]any{
				"description": "noul: optional {\"true\":text,\"false\":text}; choice: {\"option\":description,...} with 2.." +
					fmt.Sprint(contract.HostedMaxOptions) + " options (a gateway may allow fewer, default " + fmt.Sprint(lim.MaxOptions) + "); " +
					"score: array of " + fmt.Sprint(lim.MinScale) + ".." + fmt.Sprint(lim.MaxScale) + " level descriptions",
				"anyOf": []any{
					map[string]any{"type": "object", "additionalProperties": desc, "minProperties": 2, "maxProperties": contract.HostedMaxOptions},
					map[string]any{"type": "object", "additionalProperties": false, "properties": map[string]any{"true": desc, "false": desc}},
					map[string]any{"type": "array", "items": desc, "minItems": lim.MinScale, "maxItems": lim.MaxScale},
				},
			},
		},
	}
}

// InputSchema returns a fresh copy of the JSON Schema of the tool arguments.
func InputSchema() map[string]any {
	lim := contract.DefaultLimits()
	return map[string]any{
		"$schema":              "https://json-schema.org/draft/2020-12/schema",
		"title":                "llmctl decision call",
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"state", "questions"},
		"properties": map[string]any{
			"state": map[string]any{
				"description": "what the question is about: text, or any JSON object or array (delimited and neutralised as data - best effort, not a guarantee)",
				"type":        []string{"string", "object", "array"},
			},
			"questions": map[string]any{
				"type":                 "object",
				"description":          "question name -> typed question; the names key the answers",
				"minProperties":        1,
				"maxProperties":        lim.MaxQuestions,
				"additionalProperties": question(),
			},
			"model": map[string]any{"type": "string", "description": "decision profile id; omit for the gateway default"},
			"min_confidence": map[string]any{"type": "number", "minimum": 0, "maximum": 1,
				"description": "tool-level, not sent to the gateway: when any answer's confidence is lower (a flagged answer is capped at 1 - its largest upper bound) the answer is withheld and the call is reported as an error (fail closed)"},
		},
	}
}

// Emit renders one format as indented JSON with a trailing newline.
func Emit(f Format) ([]byte, error) {
	var v any
	switch f {
	case FormatJSONSchema:
		v = InputSchema()
	case FormatOpenAITool:
		v = map[string]any{"type": "function", "function": map[string]any{
			"name": ToolName, "description": Description, "parameters": InputSchema()}}
	case FormatMCP:
		v = map[string]any{
			"name": ToolName, "title": "Typed decision call", "description": Description,
			"inputSchema": InputSchema(),
			"annotations": map[string]any{"readOnlyHint": true, "idempotentHint": true, "destructiveHint": false, "openWorldHint": false},
		}
	default:
		return nil, fmt.Errorf("unknown format %q (json-schema|openai-tool|mcp)", string(f))
	}
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

// MCPTool returns the MCP tool definition as a generic value for the stdio server's tools/list.
func MCPTool() (map[string]any, error) {
	b, err := Emit(FormatMCP)
	if err != nil {
		return nil, err
	}
	var m map[string]any
	return m, json.Unmarshal(b, &m)
}
