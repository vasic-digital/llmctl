package certs

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha1" //nolint:gosec // RFC 5280 key identifier, not a security hash
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func genKey() (*ecdsa.PrivateKey, error) { return ecdsa.GenerateKey(elliptic.P256(), rand.Reader) }

func keyPEM(k crypto.PrivateKey) ([]byte, error) {
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), nil
}

func certPEM(der []byte) []byte {
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func serial() (*big.Int, error) { return rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 63)) }

func keyID(pub crypto.PublicKey) []byte {
	der, _ := x509.MarshalPKIXPublicKey(pub)
	h := sha1.Sum(der) //nolint:gosec
	return h[:]
}

// writeSecret creates path with mode 0600 from the first byte (no wider window).
func writeSecret(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
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
	return os.Chmod(path, 0o600)
}

func parseCertFile(path string) (*x509.Certificate, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, errf("cannot read certificate %s: %v", path, err)
	}
	for {
		var blk *pem.Block
		blk, b = pem.Decode(b)
		if blk == nil {
			return nil, errf("%s holds no PEM certificate", path)
		}
		if blk.Type == "CERTIFICATE" {
			c, err := x509.ParseCertificate(blk.Bytes)
			if err != nil {
				return nil, errf("cannot parse certificate %s: %v", path, err)
			}
			return c, nil
		}
	}
}

// parseKeyFile reads a PKCS#8, SEC1 (EC) or PKCS#1 (RSA) private key.
// strict additionally requires the file to be owned by the caller and mode 0600 or stricter.
func parseKeyFile(path string, strict bool) (crypto.Signer, error) {
	k, _, err := parseKeyFileRaw(path, strict)
	return k, err
}

// parseKeyFileRaw is parseKeyFile that also returns the exact bytes that were read from the checked
// descriptor, so a caller that must USE the key can use these bytes instead of re-opening the path.
func parseKeyFileRaw(path string, strict bool) (crypto.Signer, []byte, error) {
	b, err := readPrivate(path, strict)
	if err != nil {
		return nil, nil, err
	}
	raw := b
	for {
		var blk *pem.Block
		blk, b = pem.Decode(b)
		if blk == nil {
			break
		}
		var k any
		switch blk.Type {
		case "PRIVATE KEY":
			k, err = x509.ParsePKCS8PrivateKey(blk.Bytes)
		case "EC PRIVATE KEY":
			k, err = x509.ParseECPrivateKey(blk.Bytes)
		case "RSA PRIVATE KEY":
			k, err = x509.ParsePKCS1PrivateKey(blk.Bytes)
		default:
			continue
		}
		if s, ok := k.(crypto.Signer); ok && err == nil {
			return s, raw, nil
		}
		break
	}
	return nil, nil, errf("cannot read private key %s (unreadable or not a private key)", path)
}

func keyMatches(k crypto.Signer, c *x509.Certificate) bool {
	pub, ok := k.Public().(interface{ Equal(crypto.PublicKey) bool })
	return ok && pub.Equal(c.PublicKey)
}

// certSANs lists a certificate's DNS and IP SANs in normalised form.
func certSANs(c *x509.Certificate) []string {
	var out []string
	for _, d := range c.DNSNames {
		out = append(out, strings.ToLower(d))
	}
	for _, ip := range c.IPAddresses {
		if a, ok := netip.AddrFromSlice(ip); ok {
			out = append(out, a.Unmap().String())
		}
	}
	return out
}

func ipNet(p netip.Prefix) *net.IPNet {
	a := p.Masked().Addr()
	return &net.IPNet{IP: net.IP(a.AsSlice()), Mask: net.CIDRMask(p.Bits(), a.BitLen())}
}

// makeCA creates cert/ca/{ca.key,ca.crt}: EC P-256, 10 years, CA:TRUE pathlen 0,
// keyCertSign+cRLSign and (unless disabled) critical name constraints (FR-066).
func makeCA(certDir string, in inputs) error {
	caDir := filepath.Join(certDir, "ca")
	if err := os.MkdirAll(caDir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(caDir, 0o700); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(certDir, ".ca-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	key, err := genKey()
	if err != nil {
		return err
	}
	sn, err := serial()
	if err != nil {
		return err
	}
	host := "host"
	if len(in.hostnames) > 0 {
		host = in.hostnames[0]
	}
	now := time.Now()
	tpl := &x509.Certificate{
		SerialNumber:          sn,
		Subject:               pkix.Name{CommonName: "llmctl local CA (" + host + ")"},
		NotBefore:             now.Add(-skew),
		NotAfter:              now.Add(CADays * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
		SubjectKeyId:          keyID(&key.PublicKey),
	}
	if in.constrained {
		tpl.PermittedDNSDomainsCritical = true
		names := []string{"localhost", ".local"}
		for _, d := range append(append([]string{}, in.hostnames...), in.extraDNS...) {
			d = strings.ToLower(d)
			if !containsStr(names, d) {
				names = append(names, d)
			}
		}
		tpl.PermittedDNSDomains = names
		for _, p := range permitted(in.extraIPs) {
			tpl.PermittedIPRanges = append(tpl.PermittedIPRanges, ipNet(p))
		}
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return errf("cannot create the CA certificate: %v", err)
	}
	kp, err := keyPEM(key)
	if err != nil {
		return err
	}
	if err := writeSecret(filepath.Join(tmp, "ca.key"), kp); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(tmp, "ca.crt"), certPEM(der), 0o644); err != nil {
		return err
	}
	if err := os.Rename(filepath.Join(tmp, "ca.key"), filepath.Join(caDir, "ca.key")); err != nil {
		return err
	}
	if err := os.Rename(filepath.Join(tmp, "ca.crt"), filepath.Join(caDir, "ca.crt")); err != nil {
		return err
	}
	if err := os.Chmod(filepath.Join(caDir, "ca.key"), 0o600); err != nil {
		return err
	}
	return os.Chmod(filepath.Join(caDir, "ca.crt"), 0o644)
}

// checkCAKey verifies that keyPath is the private key of cert/ca/ca.crt.
func checkCAKey(certDir, keyPath string) error {
	caCrt := filepath.Join(certDir, "ca", "ca.crt")
	ca, err := parseCertFile(caCrt)
	if err != nil {
		return err
	}
	k, err := parseKeyFile(keyPath, true)
	if err != nil {
		return err
	}
	if !keyMatches(k, ca) {
		return errf("the supplied CA key does not match %s", caCrt)
	}
	return nil
}

// exportOffline moves the CA key to an operator-chosen path (FR-087 offline-key
// mode). The source is removed only after the copy is verified byte for byte.
func exportOffline(certDir, dest string, force bool) error {
	if inside(certDir, dest) {
		return errf("the offline CA key destination must be outside %s", certDir)
	}
	src := filepath.Join(certDir, "ca", "ca.key")
	b, err := readPrivate(src, true)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
		return err
	}
	if err := exportSecret(dest, b, force); err != nil {
		return err
	}
	// Verify by CONTENT only: the mode bits of a removable medium (vfat/exFAT report mount-derived
	// modes) say nothing about who can read the copy (review A2-06).
	got, err := readBack(dest)
	if err != nil || string(got) != string(b) {
		fate := "the copy was removed from " + dest
		if rmErr := os.Remove(dest); rmErr != nil && !os.IsNotExist(rmErr) {
			fate = "the copy at " + dest + " could NOT be removed - delete it yourself, it is a full copy of the CA private key"
		}
		return errf("offline CA key copy verification failed (%s); the key was NOT removed from the host", fate)
	}
	return os.Remove(src)
}

// readBack re-reads the exported copy for verification; a variable so tests can fail it.
var readBack = func(dest string) ([]byte, error) { return readPrivate(dest, false) }

// inside reports whether path resolves to a location under dir (following
// symlinks of the nearest existing ancestor).
func inside(dir, path string) bool {
	d, p := resolveLoose(dir), resolveLoose(path)
	return p == d || strings.HasPrefix(p, d+string(os.PathSeparator))
}

func resolveLoose(p string) string {
	p, _ = filepath.Abs(p)
	rest := ""
	for {
		if r, err := filepath.EvalSymlinks(p); err == nil {
			return filepath.Join(r, rest)
		}
		parent := filepath.Dir(p)
		if parent == p {
			return filepath.Join(p, rest)
		}
		rest = filepath.Join(filepath.Base(p), rest)
		p = parent
	}
}
