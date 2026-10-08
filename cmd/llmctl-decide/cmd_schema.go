package main

import (
	"fmt"
	"io"

	"github.com/vasic-digital/llmctl/internal/schema"
)

// `llmctl-decide schema [--format json-schema|openai-tool|mcp]` prints the decision-call schema as
// a tool definition for coding agents (FR-081, FR-086; contracts/cli.md). No network, no key.
func init() {
	register("schema", func(a []string, o, e io.Writer) int { return runSchema(a, o, e) })
}

func runSchema(args []string, stdout, stderr io.Writer) int {
	format := string(schema.FormatJSONSchema)
	fs := askNewFlagSet("schema")
	fs.StringVar(&format, "format", format, "json-schema | openai-tool | mcp")
	if rc, ok := fs.parse(args, stderr); !ok {
		return rc
	}
	f, err := schema.ParseFormat(format)
	if err != nil {
		fmt.Fprintf(stderr, "llmctl-decide schema: %v\n", err)
		return 2
	}
	out, err := schema.Emit(f)
	if err != nil {
		fmt.Fprintf(stderr, "llmctl-decide schema: %v\n", err)
		return 1
	}
	_, _ = stdout.Write(out)
	return 0
}
