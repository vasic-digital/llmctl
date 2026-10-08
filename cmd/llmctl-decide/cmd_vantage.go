package main

import (
	"io"
	"os"

	"github.com/vasic-digital/llmctl/internal/vantage"
)

// `llmctl-decide vantage` boots and drives the second network location
// (FR-064/FR-069/FR-073) through the Containers submodule; see internal/vantage.
func init() {
	register("vantage", func(args []string, stdout, stderr io.Writer) int {
		return vantage.Run(args, os.Getenv, nil, stdout, stderr)
	})
}
