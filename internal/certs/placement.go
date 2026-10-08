package certs

import (
	"os"
	"path/filepath"
	"syscall"

	"github.com/vasic-digital/llmctl/internal/placement"
)

// CheckPlacement implements FR-087: creating the certificate directory inside a git work tree is
// refused unless git ignores it. It uses the shared fail-closed guard (internal/placement): a git
// error, timeout, "dubious ownership" or corrupt repository REFUSES instead of allowing (review A-04).
func CheckPlacement(certDir string) error {
	if err := placement.Check(placement.Spec{
		Path:  certDir,
		IsDir: true,
		What:  "the private keys",
		Fix: "add 'cert/' to .gitignore or pick a home directory outside the repository " +
			"(LLMCTL_HOME or --home)",
	}); err != nil {
		return &Error{Msg: err.Error()}
	}
	return nil
}

// prepareDir enforces the placement guard and creates <home>/cert (0700).
func prepareDir(home string) (string, error) {
	if home == "" {
		return "", errf("no home directory given")
	}
	certDir := filepath.Join(home, "cert")
	// The directory itself is guarded when it does not exist yet (any Lstat answer other than
	// "exists" keeps the guard armed, fail closed). That is NOT sufficient for FR-087 (a pre-existing
	// empty/.gitkeep/symlinked directory skips it): key creation is guarded separately by
	// guardKeyCreation, which is what lets a provisioned installation survive a git fault (A2-05).
	if _, err := os.Lstat(certDir); err != nil {
		if err := CheckPlacement(certDir); err != nil {
			return "", err
		}
	}
	if err := os.MkdirAll(home, 0o755); err != nil {
		return "", err
	}
	if err := os.MkdirAll(certDir, 0o700); err != nil {
		return "", err
	}
	return certDir, os.Chmod(certDir, 0o700)
}

// guardKeyCreation is the FR-087 guard for KEY CREATION (review A3-01). It must hold whenever Ensure or
// Renew is about to generate private-key material, regardless of whether <home>/cert already exists
// (an empty directory, a directory kept alive by a .gitkeep, or a symlink all skip prepareDir's
// existence-keyed check). The installation counts as provisioned - and its keys as placed-validated
// when they were created - once `current` resolves to a version directory; only then is the guard
// skipped, so a transient git fault cannot stop a restart, a SIGHUP reload or a renewal (review
// A2-05). A symlinked cert directory is resolved first so git is asked about the real location.
func guardKeyCreation(certDir string) error {
	if currentDir(certDir) != "" {
		return nil
	}
	p := certDir
	if r, err := filepath.EvalSymlinks(certDir); err == nil {
		p = r
	}
	return CheckPlacement(p)
}

// lock serialises ensure/renew across goroutines and processes via flock(2)
// on cert/.lock (separate open file descriptions conflict even in-process).
type lock struct{ f *os.File }

func acquire(certDir string) (*lock, error) {
	f, err := os.OpenFile(filepath.Join(certDir, ".lock"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, err
	}
	return &lock{f: f}, nil
}

func (l *lock) release() {
	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	_ = l.f.Close()
}
