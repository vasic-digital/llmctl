package audit

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/placement"
)

func gitRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	d := t.TempDir()
	if out, err := exec.Command("git", "-C", d, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	return d
}

// A-05 / FR-087: the log key is never CREATED inside an unignored git work tree.
func TestLogKeyPlacementGuard(t *testing.T) {
	repo := gitRepo(t)
	dir := filepath.Join(repo, "state", "decide")
	_, err := LoadOrCreateLogKey(dir)
	var le *LogKeyError
	if err == nil || !asLogKeyError(err, &le) || !strings.Contains(err.Error(), "not ignored") || !strings.Contains(err.Error(), "LLMCTL_STATE_DIR") {
		t.Fatalf("a log key in an unignored work tree must be refused with the remedy: %v", err)
	}
	if _, e := os.Stat(dir); e == nil {
		t.Error("the key directory was created despite the refusal")
	}
	// ignored: allowed and created 0600
	if err := os.WriteFile(filepath.Join(repo, ".gitignore"), []byte("state/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	k, err := LoadOrCreateLogKey(dir)
	if err != nil || len(k) != KeyBytes {
		t.Fatalf("ignored location must be allowed: %v", err)
	}
	st, _ := os.Stat(filepath.Join(dir, KeyFile))
	if st.Mode().Perm() != 0o600 {
		t.Errorf("mode %o", st.Mode().Perm())
	}
}

func TestLogKeyPlacementFailsClosedOnGitError(t *testing.T) {
	p := filepath.Join(t.TempDir(), "fakegit")
	if err := os.WriteFile(p, []byte("#!/bin/sh\necho 'fatal: detected dubious ownership' >&2\nexit 128\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := placement.GitCommand
	placement.GitCommand = p
	defer func() { placement.GitCommand = old }()
	dir := filepath.Join(t.TempDir(), "decide")
	if _, err := LoadOrCreateLogKey(dir); err == nil {
		t.Fatal("a git error must refuse creation (fail closed)")
	}
	if _, e := os.Stat(filepath.Join(dir, KeyFile)); e == nil {
		t.Error("key created despite the git error")
	}
}

// An EXISTING key is read without consulting git (the guard is about creation).
func TestExistingLogKeyIsReadWithoutThePlacementCheck(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "decide")
	if _, err := LoadOrCreateLogKey(dir); err != nil {
		t.Fatal(err)
	}
	old := placement.GitCommand
	placement.GitCommand = "/definitely/not/executable"
	defer func() { placement.GitCommand = old }()
	if _, err := LoadOrCreateLogKey(dir); err != nil {
		t.Fatalf("existing key: %v", err)
	}
}

// A-12: a FIFO in place of the key neither hangs the start nor is overwritten.
func TestLogKeyFIFONeverHangs(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, KeyFile)
	if err := syscall.Mkfifo(p, 0o600); err != nil {
		t.Skip("mkfifo unavailable: ", err)
	}
	done := make(chan error, 1)
	go func() { _, err := LoadOrCreateLogKey(dir); done <- err }()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Fatalf("a FIFO must be refused as not a regular file: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("LoadOrCreateLogKey hung on a FIFO")
	}
}

func asLogKeyError(err error, target **LogKeyError) bool {
	le, ok := err.(*LogKeyError)
	if ok {
		*target = le
	}
	return ok
}
