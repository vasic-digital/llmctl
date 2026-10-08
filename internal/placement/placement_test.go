package placement

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func mustGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func fakeGit(t *testing.T, script string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "fakegit")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := GitCommand
	GitCommand = p
	t.Cleanup(func() { GitCommand = old })
}

func spec(p string) Spec {
	return Spec{Path: p, What: "the secret", Fix: "ignore it or move it outside the repository"}
}

func isRefusal(err error) bool {
	var r *Refusal
	return errors.As(err, &r)
}

func TestOutsideAnyRepositoryIsAllowed(t *testing.T) {
	if err := Check(spec(filepath.Join(t.TempDir(), "x", "secret"))); err != nil {
		t.Fatal(err)
	}
}

func TestInsideAnUnignoredWorkTreeIsRefusedFileAndDir(t *testing.T) {
	d := t.TempDir()
	mustGit(t, d, "init", "-q")
	err := Check(spec(filepath.Join(d, "sub", "secret")))
	if !isRefusal(err) || !strings.Contains(err.Error(), "not ignored") || !strings.Contains(err.Error(), "ignore it") {
		t.Fatalf("file: %v", err)
	}
	s := spec(filepath.Join(d, "cert"))
	s.IsDir = true
	if err := Check(s); !isRefusal(err) {
		t.Fatalf("dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(d, ".gitignore"), []byte("secret\ncert/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Check(spec(filepath.Join(d, "secret"))); err != nil {
		t.Fatalf("ignored file must be allowed: %v", err)
	}
	if err := Check(s); err != nil {
		t.Fatalf("ignored dir must be allowed: %v", err)
	}
}

// A-04: every git failure other than "git is not installed" and "not a git repository" REFUSES.
func TestFailsClosedOnEveryGitError(t *testing.T) {
	for name, script := range map[string]string{
		"dubious ownership":           `echo "fatal: detected dubious ownership in repository at '/x'" >&2; exit 128`,
		"corrupt repository":          `echo "fatal: bad object HEAD" >&2; exit 128`,
		"any other nonzero rev-parse": `exit 3`,
		"check-ignore fatal":          `case "$1" in rev-parse) echo true;; *) exit 128;; esac`,
		"check-ignore odd code":       `case "$1" in rev-parse) echo true;; *) exit 2;; esac`,
		"check-ignore not ignored":    `case "$1" in rev-parse) echo true;; *) exit 1;; esac`,
	} {
		t.Run(name, func(t *testing.T) {
			fakeGit(t, script)
			if err := Check(spec(filepath.Join(t.TempDir(), "secret"))); !isRefusal(err) {
				t.Fatalf("must refuse, got %v", err)
			}
		})
	}
	t.Run("git cannot be started", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "notexec")
		if err := os.WriteFile(p, []byte("#!/bin/sh\n"), 0o644); err != nil { // not executable
			t.Fatal(err)
		}
		old := GitCommand
		GitCommand = p
		defer func() { GitCommand = old }()
		if err := Check(spec(filepath.Join(t.TempDir(), "secret"))); !isRefusal(err) {
			t.Fatalf("an unstartable git must refuse, got %v", err)
		}
	})
	t.Run("timeout", func(t *testing.T) {
		fakeGit(t, `exec sleep 5`)
		old := GitTimeout
		GitTimeout = 200 * time.Millisecond
		defer func() { GitTimeout = old }()
		start := time.Now()
		if err := Check(spec(filepath.Join(t.TempDir(), "secret"))); !isRefusal(err) || !strings.Contains(err.Error(), "timed out") {
			t.Fatalf("%v", err)
		}
		if time.Since(start) > 3*time.Second {
			t.Fatal("timeout not enforced")
		}
	})
	t.Run("check-ignore timeout", func(t *testing.T) {
		fakeGit(t, `case "$1" in rev-parse) echo true;; *) exec sleep 5;; esac`)
		old := GitTimeout
		GitTimeout = 200 * time.Millisecond
		defer func() { GitTimeout = old }()
		if err := Check(spec(filepath.Join(t.TempDir(), "secret"))); !isRefusal(err) {
			t.Fatalf("%v", err)
		}
	})
}

func TestAllowedOutcomes(t *testing.T) {
	t.Run("git not installed", func(t *testing.T) {
		old := GitCommand
		GitCommand = "definitely-no-such-git-binary"
		defer func() { GitCommand = old }()
		if err := Check(spec(filepath.Join(t.TempDir(), "s"))); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("not a git repository", func(t *testing.T) {
		fakeGit(t, `echo "fatal: not a git repository (or any of the parent directories): .git" >&2; exit 128`)
		if err := Check(spec(filepath.Join(t.TempDir(), "s"))); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("not a work tree", func(t *testing.T) {
		fakeGit(t, `echo false`)
		if err := Check(spec(filepath.Join(t.TempDir(), "s"))); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("ignored", func(t *testing.T) {
		fakeGit(t, `case "$1" in rev-parse) echo true;; *) exit 0;; esac`)
		if err := Check(spec(filepath.Join(t.TempDir(), "s"))); err != nil {
			t.Fatal(err)
		}
	})
}

// The caller's GIT_* environment must not redirect git to another repository.
func TestAmbientGitEnvironmentIsScrubbed(t *testing.T) {
	outside := t.TempDir()
	other := t.TempDir()
	repo := t.TempDir()
	mustGit(t, other, "init", "-q") // created BEFORE the ambient variables are set
	mustGit(t, repo, "init", "-q")
	t.Setenv("GIT_DIR", filepath.Join(other, ".git"))
	t.Setenv("GIT_WORK_TREE", other)
	t.Setenv("GIT_INDEX_FILE", filepath.Join(other, "idx"))
	t.Setenv("GIT_CEILING_DIRECTORIES", "/")
	if err := Check(spec(filepath.Join(outside, "secret"))); err != nil {
		t.Fatalf("inherited GIT_* leaked into the check: %v", err)
	}
	// and the reverse: a hostile GIT_DIR pointing at a clean repository must not make a path that IS
	// inside an unignored work tree look fine
	if err := Check(spec(filepath.Join(repo, "secret"))); !isRefusal(err) {
		t.Fatalf("a path in an unignored work tree must be refused whatever GIT_DIR says: %v", err)
	}
}

func TestEnvScrubListCoversTheRedirectingVariables(t *testing.T) {
	t.Setenv("GIT_CONFIG_COUNT", "1")
	t.Setenv("GIT_CONFIG_KEY_0", "core.hooksPath")
	t.Setenv("GIT_CONFIG_VALUE_0", "/tmp/x")
	env := strings.Join(gitEnv(), "\n")
	for _, v := range []string{"GIT_CONFIG_COUNT=", "GIT_CONFIG_KEY_0=", "GIT_CONFIG_VALUE_0="} {
		if strings.Contains(env, v) {
			t.Errorf("%s leaked into git's environment", v)
		}
	}
	if !strings.Contains(env, "LC_ALL=C") {
		t.Error("LC_ALL=C is required for the 'not a git repository' match")
	}
}
