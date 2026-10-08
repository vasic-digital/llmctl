// Package placement is the ONE implementation of the FR-087 guard: a secret (access key, private
// key, request-log key) is never created inside a git work tree that version control does not
// ignore, because it could then be committed.
//
// The guard fails CLOSED. It allows creation only when git is not installed, or git itself says the
// location is not inside a work tree ("not a git repository"), or git says the path is ignored.
// Every other outcome - a timeout, "dubious ownership" (exit 128), a corrupt repository, a git that
// cannot be started, an unexpected answer - REFUSES, so a broken git can never be used to bypass the
// check (review A-04). The ambient GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE family is scrubbed so
// the answer is about the path, not about a repository the caller's environment points at.
//
// keyring, certs and audit all call Check; there is no second copy (§11.4.251).
package placement

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Test seams.
var (
	GitCommand = "git"
	GitTimeout = 5 * time.Second
)

// Refusal is a placement refusal; its message is operator-facing and never contains secret material.
type Refusal struct{ Msg string }

func (r *Refusal) Error() string { return r.Msg }

// Spec describes what is being created.
type Spec struct {
	// Path is the file or directory about to be created (it need not exist yet).
	Path string
	// IsDir is true when Path is a directory (git is asked about "<path>/").
	IsDir bool
	// What names the thing in the refusal text ("the key", "the private keys", "the log key").
	What string
	// Fix is the remediation sentence appended to every refusal.
	Fix string
}

// scrubbed names the git environment variables that redirect git away from the path being checked.
var scrubbed = []string{
	"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OPTIONAL_LOCKS", "GIT_COMMON_DIR",
	"GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_CEILING_DIRECTORIES",
	"GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_PREFIX", "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
	"GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_EXCLUDE_FILE", "GIT_ATTR_SOURCE", "LC_ALL", "LANGUAGE",
}

func gitEnv() []string {
	var env []string
outer:
	for _, kv := range os.Environ() {
		for _, name := range scrubbed {
			if strings.HasPrefix(kv, name+"=") {
				continue outer
			}
		}
		if strings.HasPrefix(kv, "GIT_CONFIG_KEY_") || strings.HasPrefix(kv, "GIT_CONFIG_VALUE_") {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "GIT_OPTIONAL_LOCKS=0", "LC_ALL=C")
}

type gitResult struct {
	stdout, stderr string
	code           int
	timedOut       bool
	missing        bool
	other          error
}

func runGit(dir string, args ...string) gitResult {
	ctx, cancel := context.WithTimeout(context.Background(), GitTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, GitCommand, args...)
	cmd.Dir = dir
	cmd.Env = gitEnv()
	cmd.WaitDelay = time.Second
	var so, se strings.Builder
	cmd.Stdout, cmd.Stderr = &so, &se
	err := cmd.Run()
	res := gitResult{stdout: so.String(), stderr: se.String()}
	if err == nil {
		return res
	}
	if ctx.Err() == context.DeadlineExceeded {
		res.timedOut = true
		return res
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		res.code = ee.ExitCode()
		return res
	}
	if errors.Is(err, exec.ErrNotFound) {
		res.missing = true
		return res
	}
	res.other = err
	return res
}

func nearestExistingDir(path string, isDir bool) string {
	d := path
	if !isDir {
		d = filepath.Dir(path)
	}
	for {
		if st, err := os.Stat(d); err == nil && st.IsDir() {
			return d
		}
		parent := filepath.Dir(d)
		if parent == d {
			return d
		}
		d = parent
	}
}

// Check returns nil when creating s.Path is allowed and a *Refusal otherwise.
func Check(s Spec) error {
	abs, err := filepath.Abs(s.Path)
	if err != nil {
		abs = s.Path
	}
	cwd := nearestExistingDir(abs, s.IsDir)
	what := s.What
	if what == "" {
		what = "the file"
	}
	refuse := func(format string, a ...any) error { return &Refusal{Msg: fmt.Sprintf(format, a...)} }
	r := runGit(cwd, "rev-parse", "--is-inside-work-tree")
	switch {
	case r.missing:
		return nil // git is not installed: there is no repository to commit to
	case r.timedOut:
		return refuse("could not determine whether %s is inside a git work tree (git timed out); %s", abs, s.Fix)
	case r.other != nil:
		return refuse("could not run git to check whether %s is inside a git work tree; %s", abs, s.Fix)
	case r.code != 0:
		if strings.Contains(r.stderr, "not a git repository") {
			return nil
		}
		// "dubious ownership", a corrupt repository, any fatal answer: unknown is not "safe".
		return refuse("git gave an unexpected answer (exit %d) while checking whether %s is inside a git work tree; %s",
			r.code, abs, s.Fix)
	}
	if strings.TrimSpace(r.stdout) != "true" {
		return nil // inside a .git directory or a bare repository: not a work tree
	}
	target := abs
	if s.IsDir {
		target = abs + "/"
	}
	c := runGit(cwd, "check-ignore", "-q", "--", target)
	switch {
	case c.missing:
		return nil
	case c.timedOut:
		return refuse("git check-ignore timed out for %s; %s", abs, s.Fix)
	case c.other != nil:
		return refuse("could not run git check-ignore for %s; %s", abs, s.Fix)
	case c.code == 0:
		return nil // ignored
	case c.code == 1:
		return refuse("refusing to create %s: it is inside a git work tree and not ignored by git, so %s could be committed. Fix: %s.",
			abs, what, strings.TrimSuffix(s.Fix, "."))
	}
	return refuse("git check-ignore gave an unexpected answer (exit %d) for %s; %s", c.code, abs, s.Fix)
}
