// Command vantage-probe is the static binary that runs inside the vantage
// container. Build with CGO_ENABLED=0; see internal/vantage/probecore.
package main

import (
	"encoding/json"
	"io"
	"os"

	"github.com/vasic-digital/llmctl/internal/vantage/probecore"
)

func main() {
	os.Exit(probecore.Main(os.Args[1:], os.Stdout, os.Stderr, func(w io.Writer, v any) error {
		return json.NewEncoder(w).Encode(v)
	}))
}
