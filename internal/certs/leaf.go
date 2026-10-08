package certs

import (
	"crypto"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"
)

// leafTemplate builds the serverAuth-only, CA:FALSE end-entity template.
func leafTemplate(dns, ips []string, key crypto.PublicKey) (*x509.Certificate, error) {
	sn, err := serial()
	if err != nil {
		return nil, err
	}
	cn := "localhost"
	if len(dns) > 0 {
		cn = dns[0]
	}
	now := time.Now()
	t := &x509.Certificate{
		SerialNumber:          sn,
		Subject:               pkix.Name{CommonName: cn},
		NotBefore:             now.Add(-skew),
		NotAfter:              now.Add(LeafDays * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  false,
		DNSNames:              dns,
		SubjectKeyId:          keyID(key),
	}
	for _, s := range ips {
		ip := net.ParseIP(s)
		if ip == nil {
			return nil, errf("invalid address %q", s)
		}
		if v4 := ip.To4(); v4 != nil {
			ip = v4
		}
		t.IPAddresses = append(t.IPAddresses, ip)
	}
	return t, nil
}

// leafKey returns the key for a new leaf: a fresh one, or a copy of reuseFrom.
func leafKey(tmp, reuseFrom string) (crypto.Signer, error) {
	path := filepath.Join(tmp, "leaf.key")
	if reuseFrom != "" {
		b, err := readPrivate(reuseFrom, true)
		if err != nil {
			return nil, err
		}
		if err := writeSecret(path, b); err != nil {
			return nil, err
		}
		return parseKeyFile(path, false)
	}
	k, err := genKey()
	if err != nil {
		return nil, err
	}
	kp, err := keyPEM(k)
	if err != nil {
		return nil, err
	}
	return k, writeSecret(path, kp)
}

// stage creates a private staging dir next to the final one; the caller
// renames it into place only after everything verified (all-or-nothing).
func stage(certDir string) (string, error) {
	tmp, err := os.MkdirTemp(certDir, ".v-")
	if err != nil {
		return "", err
	}
	return tmp, os.Chmod(tmp, 0o700)
}

func publish(tmp, final string) error {
	if err := os.Rename(tmp, final); err != nil {
		return err
	}
	return os.Chmod(final, 0o700)
}

// issueLeaf signs a leaf with the CA key at caKey and publishes it as final.
// The new leaf is verified against the CA (name constraints included) before
// anything becomes visible; a failure leaves no trace.
func issueLeaf(certDir, final string, dns, ips []string, caKey string, in inputs, reuseFrom string) error {
	tmp, err := stage(certDir)
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp) // no-op after a successful publish
	key, err := leafKey(tmp, reuseFrom)
	if err != nil {
		return err
	}
	caCrtPath := filepath.Join(certDir, "ca", "ca.crt")
	ca, err := parseCertFile(caCrtPath)
	if err != nil {
		return err
	}
	signer, err := parseKeyFile(caKey, true)
	if err != nil {
		return err
	}
	tpl, err := leafTemplate(dns, ips, key.Public())
	if err != nil {
		return err
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, ca, key.Public(), signer)
	if err != nil {
		return errf("cannot sign the leaf certificate: %v", err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return err
	}
	pool := x509.NewCertPool()
	pool.AddCert(ca)
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		CurrentTime: time.Now()}); err != nil {
		return errf("the new leaf does not verify against the CA (%v). A name outside the CA's name "+
			"constraints was requested; the constraints were fixed when the CA was created. "+
			"Remove %s to start a new CA (clients must re-trust it), or set "+
			"LLMCTL_CA_NAME_CONSTRAINTS=off before creating it.", err, filepath.Join(certDir, "ca"))
	}
	if err := os.WriteFile(filepath.Join(tmp, "leaf.crt"), certPEM(der), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(tmp, "chain.pem"), append(certPEM(der), certPEM(ca.Raw)...), 0o644); err != nil {
		return err
	}
	if err := writeMeta(tmp, ModeCALeaf, in.extraDNS, in.extraIPs); err != nil {
		return err
	}
	return publish(tmp, final)
}

// issueSelfSigned publishes a single self-signed serverAuth certificate.
func issueSelfSigned(certDir, final string, dns, ips []string, in inputs, reuseFrom string) error {
	tmp, err := stage(certDir)
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	key, err := leafKey(tmp, reuseFrom)
	if err != nil {
		return err
	}
	tpl, err := leafTemplate(dns, ips, key.Public())
	if err != nil {
		return err
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, key.Public(), key)
	if err != nil {
		return errf("cannot create the self-signed certificate: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tmp, "leaf.crt"), certPEM(der), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(tmp, "chain.pem"), certPEM(der), 0o644); err != nil {
		return err
	}
	if err := writeMeta(tmp, ModeSelfSigned, in.extraDNS, in.extraIPs); err != nil {
		return err
	}
	return publish(tmp, final)
}

// swapCurrent points `current` at v-<version> with an atomic rename, so a
// reader never sees the link missing.
func swapCurrent(certDir string, version int) error {
	tmp := filepath.Join(certDir, fmt.Sprintf(".current.%d.%d", os.Getpid(), time.Now().UnixNano()))
	if err := os.Symlink(fmt.Sprintf("v-%d", version), tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(certDir, "current")); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
