package main

import (
	"io"
	"os"
	"path/filepath"

	"github.com/vasic-digital/llmctl/internal/keyring"
)

func init() { register("key", cmdKey) }

// cmdKey implements `llmctl key doctor|show|path|rotate|export`
// (contracts/cli.md). Exit codes: 0 ok, 2 usage, 4 key problem.
func cmdKey(args []string, stdout, stderr io.Writer) int {
	return keyring.Run(args, keyring.OSEnviron(), installationRoot(), stdout, stderr)
}

// installationRoot is $LLMCTL_ROOT when set, else the parent of the directory
// holding the executable when that directory is named "bin" (the installed
// layout), else the current directory. `key --root DIR` overrides all three.
func installationRoot() string {
	if r := os.Getenv("LLMCTL_ROOT"); r != "" {
		return r
	}
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		if d := filepath.Dir(exe); filepath.Base(d) == "bin" {
			return filepath.Dir(d)
		}
	}
	if wd, err := os.Getwd(); err == nil {
		return wd
	}
	return "."
}
