package keyring

import (
	"errors"
	"github.com/vasic-digital/llmctl/internal/placement"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPlacementOutsideGitAllowed(t *testing.T) {
	f := newFixture(t)
	if err := CheckPlacement(f.file); err != nil {
		t.Fatal(err)
	}
}

func TestPlacementInsideGitNotIgnoredRefused(t *testing.T) {
	f := newFixture(t)
	mustGit(t, f.dir, "init", "-q")
	_, err := f.resolve(Environ{})
	if !errors.Is(err, ErrUnsafePlacement) || !contains(err.Error(), f.file) || !contains(err.Error(), ".gitignore") {
		t.Fatalf("%v", err)
	}
	if _, e := os.Stat(f.file); e == nil {
		t.Fatal("file created despite refusal")
	}
}

func TestPlacementInsideGitIgnoredAllowed(t *testing.T) {
	f := newFixture(t)
	mustGit(t, f.dir, "init", "-q")
	os.WriteFile(filepath.Join(f.dir, ".gitignore"), []byte(".env\n"), 0o644)
	r, err := f.resolve(Environ{})
	if err != nil || r.Source != "generated" {
		t.Fatalf("%v", err)
	}
	if f.mode() != 0o600 {
		t.Error("mode")
	}
}

func TestPlacementMissingParentCheckedViaAncestor(t *testing.T) {
	f := newFixture(t)
	mustGit(t, f.dir, "init", "-q")
	if err := CheckPlacement(filepath.Join(f.dir, "a", "b", ".env")); !errors.Is(err, ErrUnsafePlacement) {
		t.Fatalf("%v", err)
	}
}

func TestPlacementGitAbsentAllows(t *testing.T) {
	f := newFixture(t)
	old := placement.GitCommand
	placement.GitCommand = "definitely-no-such-git-binary"
	defer func() { placement.GitCommand = old }()
	if err := CheckPlacement(f.file); err != nil {
		t.Fatal(err)
	}
}

func fakeGit(t *testing.T, script string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "fakegit")
	os.WriteFile(p, []byte("#!/bin/sh\n"+script+"\n"), 0o755)
	old := placement.GitCommand
	placement.GitCommand = p
	t.Cleanup(func() { placement.GitCommand = old })
}

func TestPlacementGitTimeoutRefuses(t *testing.T) {
	f := newFixture(t)
	fakeGit(t, "exec sleep 5")
	oldT := placement.GitTimeout
	placement.GitTimeout = 200 * time.Millisecond
	defer func() { placement.GitTimeout = oldT }()
	start := time.Now()
	err := CheckPlacement(f.file)
	if !errors.Is(err, ErrUnsafePlacement) || !contains(err.Error(), "timed out") {
		t.Fatalf("%v", err)
	}
	if time.Since(start) > 3*time.Second {
		t.Fatal("timeout not enforced")
	}
}

func TestPlacementCheckIgnoreTimeoutRefuses(t *testing.T) {
	f := newFixture(t)
	fakeGit(t, `case "$1" in rev-parse) echo true;; *) exec sleep 5;; esac`)
	oldT := placement.GitTimeout
	placement.GitTimeout = 200 * time.Millisecond
	defer func() { placement.GitTimeout = oldT }()
	if err := CheckPlacement(f.file); !errors.Is(err, ErrUnsafePlacement) {
		t.Fatalf("%v", err)
	}
}

func TestPlacementCheckIgnoreUnexpectedExitRefuses(t *testing.T) {
	// check-ignore exit 128 (fatal) must not be read as "not ignored => fine"
	f := newFixture(t)
	fakeGit(t, `case "$1" in rev-parse) echo true;; *) exit 128;; esac`)
	if err := CheckPlacement(f.file); !errors.Is(err, ErrUnsafePlacement) {
		t.Fatalf("%v", err)
	}
}

func TestPlacementNotWorkTreeAllowed(t *testing.T) {
	f := newFixture(t)
	fakeGit(t, `echo false`)
	if err := CheckPlacement(f.file); err != nil {
		t.Fatal(err)
	}
}

func TestPlacementStripsInheritedGitEnv(t *testing.T) {
	f := newFixture(t)
	other := t.TempDir()
	mustGit(t, other, "init", "-q")
	t.Setenv("GIT_DIR", filepath.Join(other, ".git"))
	t.Setenv("GIT_WORK_TREE", other)
	if err := CheckPlacement(f.file); err != nil { // f.dir is NOT in any repo
		t.Fatalf("inherited GIT_DIR leaked into the check: %v", err)
	}
}

func TestRotatePlacementGuard(t *testing.T) {
	f := newFixture(t)
	mustGit(t, f.dir, "init", "-q")
	if _, err := Rotate(f.dir, Environ{}, 0, time.Now()); !errors.Is(err, ErrUnsafePlacement) {
		t.Fatalf("%v", err)
	}
}
