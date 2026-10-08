package main

import (
	"io"
	"os"

	"github.com/vasic-digital/llmctl/internal/registry"
)

func init() {
	register("port", func(a []string, o, e io.Writer) int { return registry.RunPort(a, os.Getenv, o, e) })
	register("registry", func(a []string, o, e io.Writer) int { return registry.RunRegistry(a, os.Getenv, o, e) })
	register("discover", func(a []string, o, e io.Writer) int { return registry.RunDiscover(a, os.Getenv, o, e) })
}
