package main

import (
	"io"

	"github.com/vasic-digital/llmctl/internal/certs"
)

// `llmctl-decide cert` manages the gateway's CA and server certificate
// (FR-066..FR-072, FR-087); the implementation lives in internal/certs.
func init() {
	register("cert", func(args []string, stdout, stderr io.Writer) int {
		return certs.Run(args, stdout, stderr)
	})
}
