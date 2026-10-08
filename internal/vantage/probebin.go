package vantage

import (
	"bytes"
	"context"
	"debug/elf"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const modulePath = "module github.com/vasic-digital/llmctl"

// ProbeName is the file name of the probe inside the staged directory.
const ProbeName = "vantage-probe"

// stageProbe puts a STATIC vantage-probe at <dir>/vantage-probe (0755) and
// returns its path. Source order: Options.ProbeBin, $LLMCTL_VANTAGE_PROBE,
// Options.BuildProbe, then `go build` (CGO_ENABLED=0) from the llmctl module.
func (m *Manager) stageProbe(ctx context.Context, dir string) (string, error) {
	dst := filepath.Join(dir, ProbeName)
	src := m.o.ProbeBin
	if src == "" {
		src = os.Getenv("LLMCTL_VANTAGE_PROBE")
	}
	if src == "" {
		build := m.o.BuildProbe
		if build == nil {
			build = BuildProbe
		}
		tmp, err := os.MkdirTemp("", "llmctl-vantage-build-")
		if err != nil {
			return "", err
		}
		defer os.RemoveAll(tmp)
		if src, err = build(ctx, tmp); err != nil {
			return "", fmt.Errorf("vantage: no probe binary (set --probe-bin / LLMCTL_VANTAGE_PROBE, or run inside the llmctl source tree with Go): %w", err)
		}
		return dst, install(src, dst)
	}
	return dst, install(src, dst)
}

func install(src, dst string) error {
	if err := RequireStatic(src); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Chmod(dst, 0o755)
}

// RequireStatic refuses a dynamically linked ELF (it would not start in a
// libc-less image, and the failure would look like a container problem).
func RequireStatic(path string) error {
	f, err := elf.Open(path)
	if err != nil {
		return fmt.Errorf("vantage: probe %s is not an ELF binary: %w", path, err)
	}
	defer f.Close()
	for _, p := range f.Progs {
		if p.Type == elf.PT_INTERP {
			return fmt.Errorf("vantage: probe %s is dynamically linked; build with CGO_ENABLED=0", path)
		}
	}
	return nil
}

// BuildProbe compiles the probe statically into dir and returns its path.
func BuildProbe(ctx context.Context, dir string) (string, error) {
	root, err := findModuleRoot()
	if err != nil {
		return "", err
	}
	out := filepath.Join(dir, ProbeName)
	cmd := exec.CommandContext(ctx, "go", "build", "-trimpath", "-o", out, "./internal/vantage/cmd/vantage-probe")
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	var eb bytes.Buffer
	cmd.Stderr = &eb
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("go build probe: %w: %s", err, strings.TrimSpace(eb.String()))
	}
	return out, nil
}

func findModuleRoot() (string, error) {
	var starts []string
	if v := os.Getenv("LLMCTL_ROOT"); v != "" {
		starts = append(starts, v)
	}
	if wd, err := os.Getwd(); err == nil {
		starts = append(starts, wd)
	}
	if ex, err := os.Executable(); err == nil {
		starts = append(starts, filepath.Dir(ex))
	}
	for _, s := range starts {
		for d := s; ; d = filepath.Dir(d) {
			if b, err := os.ReadFile(filepath.Join(d, "go.mod")); err == nil && strings.Contains(string(b), modulePath) {
				return d, nil
			}
			if filepath.Dir(d) == d {
				break
			}
		}
	}
	return "", errors.New("llmctl module root not found")
}
