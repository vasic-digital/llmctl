package certs

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

const maxKeyFileBytes = 1 << 20

// geteuid is a test seam for the owner check.
var geteuid = os.Geteuid

// readPrivate reads a private-key file safely (review A-10, A-12): the file is opened with
// O_NOFOLLOW (a symlink is refused, never followed) and O_NONBLOCK (a FIFO cannot hang the reader),
// and every check runs on the OPENED descriptor, so there is no window between checking a path and
// using it. With strict the file must also be owned by the user running llmctl and carry no
// group/other permission bits (FR-066). The error text names the path and the remedy, never content.
func readPrivate(path string, strict bool) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		if pe, ok := err.(*os.PathError); ok && pe.Err == syscall.ELOOP {
			return nil, errf("%s is a symbolic link; private keys must be regular files (replace the link with the real file)", path)
		}
		return nil, errf("cannot read private key %s (unreadable or not a private key)", path)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, errf("cannot inspect private key %s", path)
	}
	if !st.Mode().IsRegular() {
		return nil, errf("%s is not a regular file; private keys must be regular files", path)
	}
	if st.Size() > maxKeyFileBytes {
		return nil, errf("%s is unreasonably large for a private key", path)
	}
	if strict {
		if sys, ok := st.Sys().(*syscall.Stat_t); ok && int(sys.Uid) != geteuid() {
			return nil, errf("%s is owned by uid %d, not by the user running llmctl (uid %d); fix with: chown %d %s",
				path, sys.Uid, geteuid(), geteuid(), path)
		}
		if st.Mode().Perm()&0o077 != 0 {
			return nil, errf("%s has mode %04o: a private key must be readable only by its owner; fix with: chmod 600 %s",
				path, st.Mode().Perm(), path)
		}
	}
	b, err := io.ReadAll(io.LimitReader(f, maxKeyFileBytes+1))
	if err != nil {
		return nil, errf("cannot read private key %s (unreadable or not a private key)", path)
	}
	return b, nil
}

// byoProblems judges an operator-supplied certificate beyond "the key matches". A WEAK key (RSA below
// 2048 bits, an EC curve below 256 bits) is an error: it can be broken. A CA certificate (CA:TRUE -
// what `openssl req -x509` produces by default, so common and still usable by a pinning client) and a
// missing serverAuth usage are warnings: clients that validate strictly will refuse the certificate,
// and the operator is told before they find out. An empty EKU means "any usage" and is accepted.
func byoProblems(leaf *x509.Certificate) (errs, warns []string) {
	if leaf.IsCA {
		warns = append(warns, "the BYO certificate is a CA certificate (CA:TRUE); a server certificate should be CA:FALSE, and strict clients may refuse it")
	}
	if len(leaf.ExtKeyUsage) > 0 {
		ok := false
		for _, u := range leaf.ExtKeyUsage {
			if u == x509.ExtKeyUsageServerAuth || u == x509.ExtKeyUsageAny {
				ok = true
			}
		}
		if !ok {
			warns = append(warns, "the BYO certificate's extended key usage does not allow TLS server authentication (serverAuth); clients will refuse it")
		}
	}
	switch pub := leaf.PublicKey.(type) {
	case *rsa.PublicKey:
		if pub.N.BitLen() < 2048 {
			errs = append(errs, fmt.Sprintf("the RSA key is only %d bits; use at least 2048", pub.N.BitLen()))
		}
	case *ecdsa.PublicKey:
		if pub.Curve.Params().BitSize < 256 {
			errs = append(errs, fmt.Sprintf("the EC key uses a %d-bit curve; use P-256 or stronger", pub.Curve.Params().BitSize))
		}
	}
	return errs, warns
}

// beforePublish is a test seam: called after the temporary file is complete and before it is published,
// so a test can create the destination in exactly the window a racing process would use.
var beforePublish = func() {}

// linkFn is link(2); a variable so tests can simulate a filesystem without hard links.
var linkFn = os.Link

// linkUnsupported reports whether err means "this filesystem/medium cannot hard-link" (vfat and
// exFAT answer EPERM, some network and FUSE mounts ENOTSUP/EXDEV/ENOSYS) as opposed to a real
// failure such as EACCES or EEXIST.
func linkUnsupported(err error) bool {
	var errno syscall.Errno
	if !errors.As(err, &errno) {
		return false
	}
	switch errno {
	case syscall.EPERM, syscall.ENOTSUP, syscall.EXDEV, syscall.ENOSYS, syscall.EMLINK:
		return true
	}
	return false
}

// exportSecret writes data to dest without ever following a symlink or truncating an existing file
// (review A-11): the bytes go to a temporary file created O_EXCL|O_NOFOLLOW with mode 0600 in the
// destination directory, are fsynced, and are then published with link(2) (fails if dest exists -
// atomic no-overwrite) or, with force, rename(2) (replaces the directory entry itself, even a
// symlink, without writing through it). The directory is fsynced. Where the medium cannot hard-link
// (vfat/exFAT: the usual "offline" USB stick) the no-overwrite publish falls back to creating dest
// with O_EXCL|O_NOFOLLOW and writing it in place - the same no-overwrite, no-symlink guarantee - and
// a partially written destination is removed again on failure (review A2-06).
func exportSecret(dest string, data []byte, force bool) error {
	dir := filepath.Dir(dest)
	if st, err := os.Lstat(dest); err == nil {
		if !force {
			return errf("refusing to overwrite the existing %s with the CA private key; choose a new destination "+
				"or pass --force-overwrite-ca-export to replace it explicitly", dest)
		}
		if st.IsDir() {
			return errf("%s is a directory; give the destination as a file path", dest)
		}
	}
	var rnd [6]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		return err
	}
	tmp := filepath.Join(dir, "."+filepath.Base(dest)+".tmp-"+hex.EncodeToString(rnd[:]))
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	defer os.Remove(tmp) // after a rename this is a harmless ENOENT
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	beforePublish()
	if force {
		err = os.Rename(tmp, dest)
	} else {
		err = linkFn(tmp, dest)
		if os.IsExist(err) {
			return errf("refusing to overwrite the existing %s with the CA private key; choose a new destination "+
				"or pass --force-overwrite-ca-export to replace it explicitly", dest)
		}
		if err != nil && linkUnsupported(err) {
			err = createExclusive(dest, data)
			if os.IsExist(err) {
				return errf("refusing to overwrite the existing %s with the CA private key; choose a new destination "+
					"or pass --force-overwrite-ca-export to replace it explicitly", dest)
			}
		}
	}
	if err != nil {
		return err
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

// createExclusive writes data to dest, which must not exist: O_EXCL (atomic no-overwrite) and
// O_NOFOLLOW (a symlink at dest is never written through), mode 0600, fsynced. A destination that
// this call created but could not complete is removed again.
func createExclusive(dest string, data []byte) error {
	f, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	fail := func(err error) error {
		_ = f.Close()
		_ = os.Remove(dest)
		return err
	}
	if _, err := f.Write(data); err != nil {
		return fail(err)
	}
	if err := f.Sync(); err != nil {
		return fail(err)
	}
	return f.Close()
}
