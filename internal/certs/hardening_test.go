package certs

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/placement"
)

func fakeGitBin(t *testing.T, script string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "fakegit")
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := placement.GitCommand
	placement.GitCommand = p
	t.Cleanup(func() { placement.GitCommand = old })
}

// A-04 / FR-087: the placement guard fails CLOSED on a git error.
func TestPlacementFailsClosedOnGitErrors(t *testing.T) {
	for name, script := range map[string]string{
		"dubious ownership":  `echo "fatal: detected dubious ownership in repository" >&2; exit 128`,
		"corrupt repo":       `echo "fatal: bad object" >&2; exit 128`,
		"check-ignore fatal": `case "$1" in rev-parse) echo true;; *) exit 128;; esac`,
	} {
		t.Run(name, func(t *testing.T) {
			fakeGitBin(t, script)
			home := newHome(t)
			_, err := Ensure(opts(home))
			var ce *Error
			if err == nil || !asError(err, &ce) {
				t.Fatalf("Ensure must refuse when git errors: %v", err)
			}
			if _, e := os.Stat(filepath.Join(home, "cert")); e == nil {
				t.Error("the certificate directory was created despite the refusal")
			}
			if CheckPlacement(filepath.Join(home, "cert")) == nil {
				t.Error("CheckPlacement must return the refusal")
			}
		})
	}
	// control: "not a git repository" is the allowed answer
	fakeGitBin(t, `echo "fatal: not a git repository" >&2; exit 128`)
	if _, err := Ensure(opts(newHome(t))); err != nil {
		t.Fatalf("not a git repository must be allowed: %v", err)
	}
}

func TestPlacementIgnoresAmbientGitDir(t *testing.T) {
	repo := gitInit(t)
	outside := newHome(t)
	t.Setenv("GIT_DIR", filepath.Join(repo, ".git"))
	t.Setenv("GIT_WORK_TREE", repo)
	if _, err := Ensure(opts(outside)); err != nil {
		t.Fatalf("an ambient GIT_DIR must not make an outside path look like it is inside that repository: %v", err)
	}
}

func pemKey(t *testing.T, k any) []byte {
	t.Helper()
	d, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: d})
}

// A-10: the start enforces owner-only private keys and refuses symlinks / foreign owners.
func TestLeafKeyModeOwnerAndSymlinkAreEnforcedAtStart(t *testing.T) {
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	// 1. loose mode: refused with the remedy, and accepted again once fixed
	if err := os.Chmod(info.LeafKey, 0o640); err != nil {
		t.Fatal(err)
	}
	_, err := Ensure(opts(home))
	if err == nil || !strings.Contains(err.Error(), "chmod 600") || !strings.Contains(err.Error(), info.LeafKey) {
		t.Fatalf("a group-readable leaf.key must be refused with the remedy: %v", err)
	}
	if err := os.Chmod(info.LeafKey, 0o666); err != nil {
		t.Fatal(err)
	}
	if _, err := Ensure(opts(home)); err == nil {
		t.Fatal("a world-writable leaf.key must be refused")
	}
	if err := os.Chmod(info.LeafKey, 0o600); err != nil {
		t.Fatal(err)
	}
	mustEnsure(t, opts(home))
	// 2. doctor (read-only) still reports instead of refusing
	if err := os.Chmod(info.LeafKey, 0o644); err != nil {
		t.Fatal(err)
	}
	rep, err := Doctor(opts(home))
	if err != nil || rep.OK {
		t.Fatalf("doctor must report the loose key: %v %+v", err, rep)
	}
	_ = os.Chmod(info.LeafKey, 0o600)
	// 3. foreign owner (the euid seam stands in for another user)
	old := geteuid
	geteuid = func() int { return os.Geteuid() + 1 }
	_, err = Ensure(opts(home))
	geteuid = old
	if err == nil || !strings.Contains(err.Error(), "owned by uid") || !strings.Contains(err.Error(), "chown") {
		t.Fatalf("a foreign-owned key must be refused with the remedy: %v", err)
	}
	// 4. a symlinked leaf key is refused, never followed
	real := filepath.Join(t.TempDir(), "real.key")
	b, _ := os.ReadFile(info.LeafKey)
	if err := os.WriteFile(real, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(info.LeafKey); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, info.LeafKey); err != nil {
		t.Fatal(err)
	}
	if _, err := Ensure(opts(home)); err == nil || !strings.Contains(err.Error(), "symbolic link") {
		t.Fatalf("a symlinked key must be refused: %v", err)
	}
}

func TestReadPrivateDoesNotHangOnAFIFO(t *testing.T) {
	p := filepath.Join(t.TempDir(), "fifo.key")
	if err := syscall.Mkfifo(p, 0o600); err != nil {
		t.Skip("mkfifo unavailable: ", err)
	}
	done := make(chan error, 1)
	go func() { _, err := readPrivate(p, true); done <- err }()
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Fatalf("a FIFO must be refused as not a regular file: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("readPrivate hung on a FIFO")
	}
}

func byoPair(t *testing.T, home string, key any, pub any, ca bool, eku []x509.ExtKeyUsage) {
	t.Helper()
	dir := filepath.Join(home, "cert", "byo")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	_ = os.Chmod(filepath.Join(home, "cert"), 0o700)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(5), Subject: pkix.Name{CommonName: "byo.local"},
		DNSNames: []string{"byo.local"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(48 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: eku, BasicConstraintsValid: true, IsCA: ca}
	var signer any = key
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, pub, signer)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "key.pem"), pemKey(t, key), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cert.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestBYOValidationWeakKeysRefusedCAAndEKUWarned(t *testing.T) {
	t.Run("RSA-1024 refused", func(t *testing.T) {
		home := newHome(t)
		k, err := rsa.GenerateKey(rand.Reader, 1024) //nolint:gosec // the weak key is the fixture
		if err != nil {
			t.Fatal(err)
		}
		byoPair(t, home, k, &k.PublicKey, false, []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth})
		o := opts(home)
		o.Mode = ModeBYO
		if _, err := Ensure(o); err == nil || !strings.Contains(err.Error(), "1024 bits") {
			t.Fatalf("a 1024-bit RSA BYO key must be refused: %v", err)
		}
		// doctor reports it as a warning instead of failing the whole read-only check
		if rep, err := Doctor(o); err != nil || rep == nil {
			t.Fatalf("doctor: %v", err)
		}
	})
	t.Run("RSA-2048 accepted", func(t *testing.T) {
		home := newHome(t)
		k, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			t.Fatal(err)
		}
		byoPair(t, home, k, &k.PublicKey, false, []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth})
		o := opts(home)
		o.Mode = ModeBYO
		if _, err := Ensure(o); err != nil {
			t.Fatalf("2048-bit RSA is fine: %v", err)
		}
	})
	t.Run("CA:TRUE and a client-only EKU warn", func(t *testing.T) {
		home := newHome(t)
		k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		byoPair(t, home, k, &k.PublicKey, true, []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth})
		o := opts(home)
		o.Mode = ModeBYO
		info, err := Ensure(o)
		if err != nil {
			t.Fatalf("a usable pair must not be refused for these: %v", err)
		}
		w := strings.Join(info.Warnings, "\n")
		if !strings.Contains(w, "CA:TRUE") || !strings.Contains(w, "serverAuth") {
			t.Errorf("warnings must name both problems: %q", w)
		}
	})
	t.Run("clean pair has no warnings", func(t *testing.T) {
		home := newHome(t)
		k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		byoPair(t, home, k, &k.PublicKey, false, []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth})
		o := opts(home)
		o.Mode = ModeBYO
		info := mustEnsure(t, o)
		for _, w := range info.Warnings {
			if strings.Contains(w, "BYO") {
				t.Errorf("unexpected BYO warning: %s", w)
			}
		}
	})
	t.Run("symlinked BYO key refused", func(t *testing.T) {
		home := newHome(t)
		k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		byoPair(t, home, k, &k.PublicKey, false, []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth})
		kp := filepath.Join(home, "cert", "byo", "key.pem")
		real := filepath.Join(t.TempDir(), "k.pem")
		b, _ := os.ReadFile(kp)
		_ = os.WriteFile(real, b, 0o600)
		_ = os.Remove(kp)
		if err := os.Symlink(real, kp); err != nil {
			t.Fatal(err)
		}
		o := opts(home)
		o.Mode = ModeBYO
		if _, err := Ensure(o); err == nil || !strings.Contains(err.Error(), "symbolic link") {
			t.Fatalf("%v", err)
		}
	})
}

// A-11: the offline CA key export never follows a symlink and never overwrites silently.
func TestOfflineExportRefusesExistingDestinationAndSymlinks(t *testing.T) {
	t.Run("existing file is refused and untouched", func(t *testing.T) {
		home := newHome(t)
		dest := filepath.Join(t.TempDir(), "backup.key")
		if err := os.WriteFile(dest, []byte("precious previous backup"), 0o644); err != nil {
			t.Fatal(err)
		}
		o := opts(home)
		o.OfflineCAKeyTo = dest
		if _, err := Ensure(o); err == nil || !strings.Contains(err.Error(), "--force-overwrite-ca-export") {
			t.Fatalf("an existing destination must be refused with the explicit flag named: %v", err)
		}
		got, _ := os.ReadFile(dest)
		if string(got) != "precious previous backup" {
			t.Fatalf("the existing file was modified: %q", got)
		}
		if modeOf(t, dest) != 0o644 {
			t.Error("mode of the existing file changed")
		}
		// the CA key is still on the host (nothing was removed after a refused export)
		if _, err := os.Stat(filepath.Join(home, "cert", "ca", "ca.key")); err != nil {
			t.Error("the CA key must stay on the host when the export was refused")
		}
	})
	t.Run("symlink destination is not followed", func(t *testing.T) {
		home := newHome(t)
		dir := t.TempDir()
		target := filepath.Join(dir, "victim")
		if err := os.WriteFile(target, []byte("victim"), 0o644); err != nil {
			t.Fatal(err)
		}
		dest := filepath.Join(dir, "ca.key")
		if err := os.Symlink(target, dest); err != nil {
			t.Fatal(err)
		}
		o := opts(home)
		o.OfflineCAKeyTo = dest
		if _, err := Ensure(o); err == nil {
			t.Fatal("a symlink destination must be refused without --force-overwrite-ca-export")
		}
		if b, _ := os.ReadFile(target); string(b) != "victim" {
			t.Fatalf("the symlink target was written through: %q", b)
		}
	})
	t.Run("force replaces the entry itself, never the symlink target", func(t *testing.T) {
		home := newHome(t)
		dir := t.TempDir()
		target := filepath.Join(dir, "victim")
		if err := os.WriteFile(target, []byte("victim"), 0o644); err != nil {
			t.Fatal(err)
		}
		dest := filepath.Join(dir, "ca.key")
		if err := os.Symlink(target, dest); err != nil {
			t.Fatal(err)
		}
		o := opts(home)
		o.OfflineCAKeyTo = dest
		o.ForceOverwriteCAExport = true
		mustEnsure(t, o)
		if b, _ := os.ReadFile(target); string(b) != "victim" {
			t.Fatalf("force must not write through the symlink: %q", b)
		}
		st, err := os.Lstat(dest)
		if err != nil || st.Mode()&os.ModeSymlink != 0 || st.Mode().Perm() != 0o600 {
			t.Fatalf("dest must now be a regular 0600 file: %v %v", st, err)
		}
		if _, err := os.Stat(filepath.Join(home, "cert", "ca", "ca.key")); err == nil {
			t.Error("the CA key must be gone from the host after a successful export")
		}
	})
	t.Run("force over a directory is refused", func(t *testing.T) {
		home := newHome(t)
		dest := t.TempDir() // an existing directory
		o := opts(home)
		o.OfflineCAKeyTo = dest
		o.ForceOverwriteCAExport = true
		if _, err := Ensure(o); err == nil || !strings.Contains(err.Error(), "directory") {
			t.Fatalf("%v", err)
		}
	})
	t.Run("a fresh destination is created 0600 with no temp file left", func(t *testing.T) {
		home := newHome(t)
		dir := filepath.Join(t.TempDir(), "usb")
		dest := filepath.Join(dir, "ca.key")
		o := opts(home)
		o.OfflineCAKeyTo = dest
		mustEnsure(t, o)
		if modeOf(t, dest) != 0o600 {
			t.Errorf("mode %o", modeOf(t, dest))
		}
		ents, _ := os.ReadDir(dir)
		if len(ents) != 1 {
			t.Errorf("leftover files in the destination directory: %v", ents)
		}
		if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
			t.Errorf("a created export directory must be private: %o", st.Mode().Perm())
		}
	})
}

// The no-overwrite guarantee does not rest on the earlier Lstat alone: a destination that appears
// between that check and the publish step (a race) is still refused by the atomic link(2).
func TestExportSecretLosesNoRaceAgainstAConcurrentCreate(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "ca.key")
	old := beforePublish
	beforePublish = func() { _ = os.WriteFile(dest, []byte("created by someone else"), 0o644) }
	defer func() { beforePublish = old }()
	err := exportSecret(dest, []byte("CA PRIVATE KEY"), false)
	if err == nil || !strings.Contains(err.Error(), "--force-overwrite-ca-export") {
		t.Fatalf("a destination created in the race window must be refused: %v", err)
	}
	if b, _ := os.ReadFile(dest); string(b) != "created by someone else" {
		t.Fatalf("the racing file was overwritten: %q", b)
	}
	ents, _ := os.ReadDir(filepath.Dir(dest))
	if len(ents) != 1 {
		t.Errorf("temporary file left behind: %v", ents)
	}
}

func TestCLIForceOverwriteFlagIsWired(t *testing.T) {
	if !strings.Contains(usageText, "--force-overwrite-ca-export") {
		t.Error("usage text must document the flag")
	}
	home := newHome(t)
	dest := filepath.Join(t.TempDir(), "ca.key")
	if err := os.WriteFile(dest, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	rc, _, e := run(t, home, "ensure", "--offline-ca-key", dest)
	if rc != ExitCert || !strings.Contains(e, "--force-overwrite-ca-export") {
		t.Fatalf("existing destination without the flag: rc=%d %q", rc, e)
	}
	if b, _ := os.ReadFile(dest); string(b) != "old" {
		t.Fatal("destination modified")
	}
	home2 := newHome(t)
	rc, _, e = run(t, home2, "ensure", "--offline-ca-key", dest, "--force-overwrite-ca-export")
	if rc != 0 {
		t.Fatalf("with the flag: rc=%d %q", rc, e)
	}
	if b, _ := os.ReadFile(dest); string(b) == "old" {
		t.Fatal("the flag did not replace the destination")
	}
}

// A2-05: the placement guard governs CREATION of <home>/cert (FR-087 "never created inside"). Once
// the directory exists, a transient git fault (timeout, "dubious ownership") must not stop a
// restart, a SIGHUP reload (Ensure) or a renewal; a missing directory is still guarded.
func TestPlacementGuardRunsOnlyWhenTheCertDirIsCreated(t *testing.T) {
	home := newHome(t)
	if _, err := Ensure(opts(home)); err != nil { // creation, real (or absent) git: allowed
		t.Fatal(err)
	}
	fakeGitBin(t, `echo "fatal: detected dubious ownership in repository" >&2; exit 128`)
	if _, err := Ensure(opts(home)); err != nil {
		t.Fatalf("restart/reload with an existing cert dir must not be stopped by a git fault: %v", err)
	}
	if _, err := Renew(opts(home)); err != nil {
		t.Fatalf("renew with an existing cert dir must not be stopped by a git fault: %v", err)
	}
	// the guard is still armed for a directory that does not exist yet
	fresh := newHome(t)
	if _, err := Ensure(opts(fresh)); err == nil {
		t.Fatal("creation under a git fault must still be refused")
	}
	if _, e := os.Stat(filepath.Join(fresh, "cert")); e == nil {
		t.Fatal("cert dir created despite the refusal")
	}
}

// A2-06: removable media (vfat, exFAT) have no hard links: link(2) fails EPERM. The export must fall
// back to an exclusive-create write (still no overwrite, no symlink following) instead of failing
// with a raw error that nudges the operator toward --force-overwrite-ca-export.
func TestExportSecretFallsBackWhereLinkIsUnsupported(t *testing.T) {
	for _, en := range []syscall.Errno{syscall.EPERM, syscall.ENOTSUP, syscall.EXDEV, syscall.ENOSYS} {
		old := linkFn
		linkFn = func(string, string) error { return &os.LinkError{Op: "link", Err: en} }
		dest := filepath.Join(t.TempDir(), "ca.key")
		err := exportSecret(dest, []byte("CA PRIVATE KEY"), false)
		linkFn = old
		if err != nil {
			t.Fatalf("%v: fallback export failed: %v", en, err)
		}
		if b, _ := os.ReadFile(dest); string(b) != "CA PRIVATE KEY" {
			t.Fatalf("%v: content %q", en, b)
		}
		if modeOf(t, dest) != 0o600 {
			t.Errorf("%v: mode %o", en, modeOf(t, dest))
		}
		if ents, _ := os.ReadDir(filepath.Dir(dest)); len(ents) != 1 {
			t.Errorf("%v: temporary file left behind: %v", en, ents)
		}
	}
}

// An unrelated link failure (permission denied) is NOT papered over by the fallback.
func TestExportSecretDoesNotFallBackOnOtherLinkErrors(t *testing.T) {
	old := linkFn
	linkFn = func(string, string) error { return &os.LinkError{Op: "link", Err: syscall.EACCES} }
	defer func() { linkFn = old }()
	dest := filepath.Join(t.TempDir(), "ca.key")
	if err := exportSecret(dest, []byte("k"), false); err == nil {
		t.Fatal("EACCES must surface")
	}
	if _, err := os.Lstat(dest); err == nil {
		t.Fatal("the destination exists after the failure")
	}
}

// The fallback keeps the no-overwrite guarantee: a destination created in the race window wins.
func TestExportSecretFallbackStillRefusesAnExistingDestination(t *testing.T) {
	old, oldB := linkFn, beforePublish
	dest := filepath.Join(t.TempDir(), "ca.key")
	linkFn = func(string, string) error { return &os.LinkError{Op: "link", Err: syscall.EPERM} }
	beforePublish = func() { _ = os.Symlink("/etc/hostname", dest) } // a symlink must never be written through
	defer func() { linkFn, beforePublish = old, oldB }()
	err := exportSecret(dest, []byte("CA PRIVATE KEY"), false)
	if err == nil || !strings.Contains(err.Error(), "--force-overwrite-ca-export") {
		t.Fatalf("must refuse: %v", err)
	}
	if st, e := os.Lstat(dest); e != nil || st.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the racing symlink was replaced or followed: %v", e)
	}
}

// A2-06: when the read-back verification fails, the copy of the CA private key already written to the
// medium is removed (and the message says so); the source key stays on the host.
func TestExportOfflineRemovesTheCopyWhenVerificationFails(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	certDir := filepath.Join(home, "cert")
	dest := filepath.Join(t.TempDir(), "ca.key")
	old := readBack
	readBack = func(string) ([]byte, error) { return []byte("tampered"), nil }
	defer func() { readBack = old }()
	err := exportOffline(certDir, dest, false)
	if err == nil || !strings.Contains(err.Error(), "NOT removed from the host") || !strings.Contains(err.Error(), "copy was removed") {
		t.Fatalf("verification failure must be reported with the copy's fate: %v", err)
	}
	if _, e := os.Lstat(dest); e == nil {
		t.Fatal("a full copy of the CA private key was left on the medium")
	}
	if _, e := os.Stat(filepath.Join(certDir, "ca", "ca.key")); e != nil {
		t.Fatal("the source key must remain on the host")
	}
}

// The medium's mode bits are not meaningful (vfat reports mount-derived modes): verification is by
// content, so a 0755-looking destination does not fail an otherwise identical copy.
func TestExportOfflineVerifiesByContentNotByMediumMode(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	certDir := filepath.Join(home, "cert")
	dest := filepath.Join(t.TempDir(), "ca.key")
	old := readBack
	real := readBack // the production verification, wrapped so the medium "reports" 0755 first
	readBack = func(p string) ([]byte, error) {
		_ = os.Chmod(p, 0o755) // what a mount-derived mode looks like
		return real(p)
	}
	defer func() { readBack = old }()
	if err := exportOffline(certDir, dest, false); err != nil {
		t.Fatalf("content-identical copy on a medium reporting 0755 must verify: %v", err)
	}
	if _, e := os.Stat(filepath.Join(certDir, "ca", "ca.key")); e == nil {
		t.Fatal("the source key must be removed after a verified copy")
	}
}

// A2-08: the key served by TLS is the key that was validated on the descriptor, not a second
// open-by-path that a same-uid swap between the two reads could redirect.
func TestTLSCertificateUsesTheValidatedKeyBytesNotARereadByPath(t *testing.T) {
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	// swap the key file for a different (valid) key AFTER validation
	other, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(other)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(info.LeafKey, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := info.TLSCertificate()
	if err != nil {
		t.Fatalf("the validated bytes must still pair with the certificate: %v", err)
	}
	leaf, _ := x509.ParseCertificate(c.Certificate[0])
	signer, ok := c.PrivateKey.(*ecdsa.PrivateKey)
	if !ok || !signer.PublicKey.Equal(leaf.PublicKey) || signer.PublicKey.Equal(&other.PublicKey) {
		t.Fatal("the served key is not the validated one")
	}
}

// A3-01: the placement guard keys on KEY CREATION, not on directory existence. A pre-existing
// <home>/cert (empty, with a .gitkeep, or a symlink) inside an unignored work tree must not let the
// CA / leaf private keys be created there.
func TestKeyCreationIsRefusedWhenCertDirPreExistsInAnUnignoredWorkTree(t *testing.T) {
	cases := map[string]func(t *testing.T, repo, home string){
		"empty dir": func(t *testing.T, repo, home string) {
			if err := os.MkdirAll(filepath.Join(home, "cert"), 0o700); err != nil {
				t.Fatal(err)
			}
		},
		"dir with .gitkeep": func(t *testing.T, repo, home string) {
			if err := os.MkdirAll(filepath.Join(home, "cert"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(home, "cert", ".gitkeep"), nil, 0o644); err != nil {
				t.Fatal(err)
			}
		},
		"symlink to a dir in the tree": func(t *testing.T, repo, home string) {
			real := filepath.Join(repo, "realcert")
			if err := os.MkdirAll(real, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(home, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(real, filepath.Join(home, "cert")); err != nil {
				t.Fatal(err)
			}
		},
	}
	for name, setup := range cases {
		for _, op := range []string{"ensure", "renew-first"} {
			t.Run(name+"/"+op, func(t *testing.T) {
				repo := gitInit(t)
				home := filepath.Join(repo, "llmctl")
				setup(t, repo, home)
				var err error
				if op == "ensure" {
					_, err = Ensure(opts(home))
				} else {
					o := opts(home)
					o.Mode = ModeSelfSigned
					_, err = Renew(o)
				}
				if err == nil || !strings.Contains(strings.ToLower(err.Error()), "git work tree") {
					t.Fatalf("expected a placement refusal, got %v", err)
				}
				out, _ := exec.Command("git", "-C", repo, "status", "--porcelain", "-uall").CombinedOutput()
				if strings.Contains(string(out), ".key") {
					t.Fatalf("a private key was created in the work tree:\n%s", out)
				}
				filepath.WalkDir(repo, func(p string, d os.DirEntry, _ error) error {
					if d != nil && !d.IsDir() && strings.HasSuffix(p, ".key") {
						t.Errorf("key file exists: %s", p)
					}
					return nil
				})
			})
		}
	}
}

// A2-05 stays true: with keys already provisioned (and validated at creation), a git fault does not
// stop start / reload / renew; and a provisioned installation whose cert dir pre-exists is not
// re-guarded either.
func TestProvisionedInstallationIgnoresGitFaultOnReloadAndRenew(t *testing.T) {
	home := newHome(t)
	if _, err := Ensure(opts(home)); err != nil {
		t.Fatal(err)
	}
	fakeGitBin(t, `echo "fatal: detected dubious ownership in repository" >&2; exit 128`)
	for i := 0; i < 2; i++ {
		if _, err := Ensure(opts(home)); err != nil {
			t.Fatalf("reload %d: %v", i, err)
		}
	}
	if _, err := Renew(opts(home)); err != nil {
		t.Fatalf("renew: %v", err)
	}
	// ...but generating a key where none exists is still guarded under the same fault.
	empty := newHome(t)
	if err := os.MkdirAll(filepath.Join(empty, "cert"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := Ensure(opts(empty)); err == nil {
		t.Fatal("key creation under a git fault must be refused even with a pre-existing cert dir")
	}
}
