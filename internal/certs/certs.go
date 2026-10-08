// Package certs manages the TLS material of the decision gateway
// (spec 009 FR-066..FR-072, FR-087) using only the Go standard library
// (crypto/x509, crypto/ecdsa, encoding/pem, net, syscall.Flock).
//
// Nothing here prints, logs or returns private key material; CertInfo carries
// paths, fingerprints and public facts only.
//
// Directory layout (Options.Home defaults to $LLMCTL_HOME or $HOME/llmctl)::
//
//	<home>/cert/                 0700
//	    .lock                    flock() target, serialises ensure/renew
//	    ca/ca.key                0600  (absent in offline-CA-key mode)
//	    ca/ca.crt                0644
//	    v-<n>/leaf.key           0600
//	    v-<n>/leaf.crt           0644
//	    v-<n>/chain.pem          0644  (leaf + CA; leaf only for selfsigned)
//	    v-<n>/meta.json          mode, extras, creation time
//	    current -> v-<n>         relative symlink, swapped atomically
//	    byo/key.pem, byo/cert.pem  operator-supplied pair (mode byo);
//	                             validated, never written over.
//
// Modes: ca-leaf (default: EC P-256 CA, 10 years, pathlen 0, name constraints
// ON, signing an EC P-256 leaf valid 397 days for serverAuth only), selfsigned
// (one self-signed certificate) and byo (the operator's own pair).
//
// Exit codes of the CLI: 0 success, 2 usage, 5 certificate/TLS problem.
package certs

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Certificate modes.
const (
	ModeCALeaf     = "ca-leaf"
	ModeSelfSigned = "selfsigned"
	ModeBYO        = "byo"
)

// Fixed parameters (documented in the user manual).
const (
	LeafDays = 397
	CADays   = 3650
	WarnDays = 30
	// skew backdates NotBefore so a client with a slightly slow clock accepts
	// a freshly issued certificate.
	skew = 5 * time.Minute
)

// Modes lists the accepted values of Options.Mode.
var Modes = []string{ModeCALeaf, ModeSelfSigned, ModeBYO}

// Error is a certificate / TLS problem (CLI exit code 5).
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func errf(format string, a ...any) error { return &Error{Msg: fmt.Sprintf(format, a...)} }

// Options are the inputs shared by Ensure, Renew, Show and Doctor. The zero
// value of every optional field means "detect / read from the environment".
type Options struct {
	Home string // directory holding cert/
	Mode string // ca-leaf | selfsigned | byo ("" = existing mode, then $LLMCTL_TLS_MODE)
	SANs string // extra names, "dns:NAME,ip:ADDR" ("" = $LLMCTL_TLS_SAN)
	// NoConstraints disables the CA name constraints when a CA is CREATED
	// (a deliberate opt-out, reported as a warning); $LLMCTL_CA_NAME_CONSTRAINTS=off does the same.
	NoConstraints bool
	// Env, when non-nil, replaces the process environment for LLMCTL_* lookups.
	Env       map[string]string
	Hostnames []string  // nil = detect
	Addresses []string  // nil = detect
	Now       time.Time // zero = time.Now(); used for validity checks, never for issuing
	// OfflineCAKeyTo (Ensure): move the CA key to this operator-chosen path once the first leaf is issued.
	OfflineCAKeyTo string
	// ReuseKey (Renew): keep the current leaf private key.
	ReuseKey bool
	// CAKeyPath (Renew): the CA key when it is offline.
	CAKeyPath string
	// ForceOverwriteCAExport (Ensure): let OfflineCAKeyTo replace an existing destination. Without it
	// an existing destination is refused (the CA private key is never written over a file).
	ForceOverwriteCAExport bool
}

func (o Options) getenv(k string) string {
	if o.Env != nil {
		return o.Env[k]
	}
	return os.Getenv(k)
}

func (o Options) now() time.Time {
	if o.Now.IsZero() {
		return time.Now()
	}
	return o.Now
}

// CertInfo describes the active certificate. It holds paths, fingerprints and
// public facts only; its formatting can never reveal key bytes.
type CertInfo struct {
	Mode            string
	CertDir         string
	LeafCert        string
	LeafKey         string
	Chain           string
	CACert          string // "" in selfsigned/byo
	CAKey           string // "" when absent (selfsigned/byo or offline CA key)
	Version         int    // 0 for byo
	LeafFingerprint string // SHA-256, upper-case colon-separated
	CAFingerprint   string
	SANs            []string
	NotBefore       time.Time
	NotAfter        time.Time
	CANotBefore     time.Time
	CANotAfter      time.Time
	Drift           []string // desired names/addresses missing from the certificate
	Warnings        []string
	Created         bool

	// keyPEM is the exact private-key content that load validated on the opened descriptor (owner,
	// mode, not a symlink, matches the certificate). TLSCertificate serves THESE bytes, never a second
	// open of LeafKey by path (review A2-08). It is unexported and the redacting Format never prints it.
	keyPEM []byte
}

// TLSCertificate builds the certificate to serve from the validated key bytes and the chain file. The
// certificate/key pairing is verified again by crypto/tls, so a chain that no longer matches the
// validated key fails closed.
func (c *CertInfo) TLSCertificate() (*tls.Certificate, error) {
	if len(c.keyPEM) == 0 {
		return nil, errf("no validated private key is held for %s; run 'llmctl cert ensure'", c.LeafCert)
	}
	chain := c.Chain
	if chain == "" {
		chain = c.LeafCert
	}
	certPEM, err := os.ReadFile(chain)
	if err != nil {
		return nil, errf("cannot read the certificate chain %s", chain)
	}
	pair, err := tls.X509KeyPair(certPEM, c.keyPEM)
	if err != nil {
		return nil, errf("the certificate chain %s and the validated private key do not form a usable pair: %v", chain, err)
	}
	return &pair, nil
}

// String is the redacting representation (also used for %v, %+v, %#v).
func (c *CertInfo) String() string {
	return fmt.Sprintf("CertInfo(mode=%s, version=%d, leaf=%s, leaf_sha256=%s, expires=%s, created=%t)",
		c.Mode, c.Version, c.LeafCert, c.LeafFingerprint, c.NotAfter.UTC().Format("2006-01-02"), c.Created)
}

// GoString keeps %#v from dumping fields.
func (c *CertInfo) GoString() string { return c.String() }

// Format makes every fmt verb print the redacting form.
func (c *CertInfo) Format(f fmt.State, _ rune) { _, _ = fmt.Fprint(f, c.String()) }

func fingerprint(c *x509.Certificate) string {
	sum := sha256.Sum256(c.Raw)
	parts := make([]string, len(sum))
	for i, b := range sum {
		parts[i] = fmt.Sprintf("%02X", b)
	}
	return strings.Join(parts, ":")
}

func dateOf(t time.Time) string { return t.UTC().Format("2006-01-02") }

func daysBetween(d time.Duration) int { return int(d.Hours() / 24) }

// ----------------------------------------------------------------- layout ---

func byoPaths(certDir string) (key, crt string) {
	return filepath.Join(certDir, "byo", "key.pem"), filepath.Join(certDir, "byo", "cert.pem")
}

// versions lists the existing v-<n> directories, ascending.
func versions(certDir string) []int {
	var out []int
	ents, _ := os.ReadDir(certDir)
	re := regexp.MustCompile(`^v-(\d+)$`)
	for _, e := range ents {
		if m := re.FindStringSubmatch(e.Name()); m != nil && e.IsDir() {
			var n int
			_, _ = fmt.Sscanf(m[1], "%d", &n)
			out = append(out, n)
		}
	}
	sort.Ints(out)
	return out
}

func nextVersion(certDir string) int {
	v := versions(certDir)
	if len(v) == 0 {
		return 1
	}
	return v[len(v)-1] + 1
}

// currentDir resolves the `current` symlink; "" when absent or dangling.
func currentDir(certDir string) string {
	tgt, err := os.Readlink(filepath.Join(certDir, "current"))
	if err != nil {
		return ""
	}
	d := filepath.Join(certDir, tgt)
	if st, err := os.Stat(d); err != nil || !st.IsDir() {
		return ""
	}
	return d
}

type meta struct {
	Mode     string   `json:"mode"`
	ExtraDNS []string `json:"extra_dns"`
	ExtraIPs []string `json:"extra_ips"`
	Created  string   `json:"created"`
}

func readMeta(vdir string) meta {
	var m meta
	if b, err := os.ReadFile(filepath.Join(vdir, "meta.json")); err == nil {
		_ = json.Unmarshal(b, &m)
	}
	return m
}

func writeMeta(vdir, mode string, extraDNS, extraIPs []string) error {
	if extraDNS == nil {
		extraDNS = []string{}
	}
	if extraIPs == nil {
		extraIPs = []string{}
	}
	b, err := json.MarshalIndent(meta{Mode: mode, ExtraDNS: extraDNS, ExtraIPs: extraIPs,
		Created: time.Now().UTC().Format(time.RFC3339)}, "", " ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(vdir, "meta.json"), b, 0o644)
}

// load reads and validates the active certificate. With enforce, an expired
// or not-yet-valid certificate is an error.
func load(certDir, modeHint string, now time.Time, enforce bool) (*CertInfo, error) {
	cur := currentDir(certDir)
	byoKey, byoCrt := byoPaths(certDir)
	mode := modeHint
	if mode == "" {
		switch {
		case cur != "":
			mode = readMeta(cur).Mode
			if mode == "" {
				mode = ModeCALeaf
			}
		case fileExists(byoCrt):
			mode = ModeBYO
		default:
			return nil, errf("no certificates in %s; run 'llmctl cert ensure'", certDir)
		}
	}
	info := &CertInfo{Mode: mode, CertDir: certDir}
	var keyPath, crtPath string
	if mode == ModeBYO {
		keyPath, crtPath = byoKey, byoCrt
		if !fileExists(keyPath) || !fileExists(crtPath) {
			return nil, errf("mode byo needs %s and %s (readable PEM files)", byoKey, byoCrt)
		}
		if !readable(keyPath) || !readable(crtPath) {
			return nil, errf("the bring-your-own pair under %s is not readable", filepath.Dir(crtPath))
		}
		info.Chain = crtPath
	} else {
		if cur == "" {
			return nil, errf("no current certificate in %s; run 'llmctl cert ensure'", certDir)
		}
		keyPath, crtPath = filepath.Join(cur, "leaf.key"), filepath.Join(cur, "leaf.crt")
		info.Chain = filepath.Join(cur, "chain.pem")
		fmt.Sscanf(filepath.Base(cur), "v-%d", &info.Version)
	}
	leaf, err := parseCertFile(crtPath)
	if err != nil {
		return nil, err
	}
	key, keyBytes, err := parseKeyFileRaw(keyPath, enforce) // enforce: owner-only, regular file, never a symlink
	if err != nil {
		return nil, err
	}
	if mode == ModeBYO {
		errs, warns := byoProblems(leaf)
		if len(errs) > 0 {
			if enforce {
				return nil, errf("the bring-your-own certificate %s is not usable: %s", crtPath, strings.Join(errs, "; "))
			}
			info.Warnings = append(info.Warnings, errs...)
		}
		info.Warnings = append(info.Warnings, warns...)
	}
	if !keyMatches(key, leaf) {
		if mode == ModeBYO {
			return nil, errf("the bring-your-own private key does not match the certificate (%s)", crtPath)
		}
		return nil, errf("leaf private key does not match the leaf certificate in %s", cur)
	}
	info.LeafCert, info.LeafKey = crtPath, keyPath
	info.keyPEM = keyBytes
	info.LeafFingerprint = fingerprint(leaf)
	info.SANs = certSANs(leaf)
	info.NotBefore, info.NotAfter = leaf.NotBefore, leaf.NotAfter
	if enforce && now.After(leaf.NotAfter) {
		if mode == ModeBYO {
			return nil, errf("certificate %s expired on %s; replace the files under %s", crtPath, dateOf(leaf.NotAfter), filepath.Dir(crtPath))
		}
		return nil, errf("certificate %s expired on %s; run 'llmctl cert renew'", crtPath, dateOf(leaf.NotAfter))
	}
	if enforce && now.Before(leaf.NotBefore.Add(-skew)) {
		return nil, errf("certificate %s is not valid before %s (check the system clock)", crtPath, leaf.NotBefore.UTC().Format(time.RFC3339))
	}
	if left := leaf.NotAfter.Sub(now); left >= 0 && left <= WarnDays*24*time.Hour {
		info.Warnings = append(info.Warnings, fmt.Sprintf("certificate expires in %d days (%s); run 'llmctl cert renew'",
			daysBetween(left), dateOf(leaf.NotAfter)))
	}
	if mode == ModeCALeaf {
		caCrt := filepath.Join(certDir, "ca", "ca.crt")
		if !fileExists(caCrt) {
			return nil, errf("CA certificate %s is missing; the certificate directory is damaged", caCrt)
		}
		ca, err := parseCertFile(caCrt)
		if err != nil {
			return nil, err
		}
		info.CACert = caCrt
		if caKey := filepath.Join(certDir, "ca", "ca.key"); fileExists(caKey) {
			info.CAKey = caKey
		}
		info.CAFingerprint = fingerprint(ca)
		info.CANotBefore, info.CANotAfter = ca.NotBefore, ca.NotAfter
		if enforce && now.After(ca.NotAfter) {
			return nil, errf("the CA certificate expired on %s; remove %s to create a new CA", dateOf(ca.NotAfter), filepath.Dir(caCrt))
		}
	}
	return info, nil
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

func readable(p string) bool {
	f, err := os.Open(p)
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}

func drift(info *CertInfo, dns, ips []string) []string {
	have := map[string]bool{}
	for _, s := range info.SANs {
		have[s] = true
	}
	var out []string
	for _, s := range append(append([]string{}, dns...), ips...) {
		if !have[s] {
			out = append(out, s)
		}
	}
	return out
}

// ----------------------------------------------------------------- public ---

// Ensure is idempotent and flock-guarded: it creates the CA and the first
// leaf when absent and otherwise only validates (never regenerating silently).
func Ensure(o Options) (*CertInfo, error) {
	requested := o.Mode
	if requested == "" {
		requested = o.getenv("LLMCTL_TLS_MODE")
	}
	if requested != "" && !validMode(requested) {
		return nil, errf("unknown TLS mode %q (use one of: %s)", requested, strings.Join(Modes, ", "))
	}
	in, err := resolveInputs(o)
	if err != nil {
		return nil, err
	}
	certDir, err := prepareDir(o.Home)
	if err != nil {
		return nil, err
	}
	lk, err := acquire(certDir)
	if err != nil {
		return nil, err
	}
	defer lk.release()

	now := o.now()
	cur := currentDir(certDir)
	existing := ""
	if cur != "" {
		if existing = readMeta(cur).Mode; existing == "" {
			existing = ModeCALeaf
		}
	}
	_, byoCrt := byoPaths(certDir)
	var eff string
	switch {
	case requested == ModeBYO:
		eff = ModeBYO
	case requested != "" && existing != "" && requested != existing:
		return nil, errf("certificates already exist in mode %s; refusing to switch to %s silently (remove %s/current to start over)",
			existing, requested, certDir)
	case requested != "":
		eff = requested
	case existing != "":
		eff = existing
	case fileExists(byoCrt):
		eff = ModeBYO
	default:
		eff = ModeCALeaf
	}
	if eff == ModeBYO {
		return load(certDir, ModeBYO, now, true)
	}
	var warnings []string
	created := false
	// guardKeyCreation decides by itself whether key material can be created here (A3-01).
	if err := guardKeyCreation(certDir); err != nil {
		return nil, err
	}
	if cur == "" {
		dns, ips, w := desiredSANs(in)
		warnings = append(warnings, w...)
		caKey := ""
		if eff == ModeCALeaf {
			if !fileExists(filepath.Join(certDir, "ca", "ca.crt")) {
				if !in.constrained {
					warnings = append(warnings, "CA name constraints are DISABLED by the operator "+
						"(LLMCTL_CA_NAME_CONSTRAINTS=off): the CA can sign certificates for any name")
				}
				if err := makeCA(certDir, in); err != nil {
					return nil, err
				}
			}
			caKey = filepath.Join(certDir, "ca", "ca.key")
			if !fileExists(caKey) {
				return nil, errf("the CA key is offline; use 'renew' with --ca-key to issue a leaf")
			}
		}
		n := nextVersion(certDir)
		final := filepath.Join(certDir, fmt.Sprintf("v-%d", n))
		if eff == ModeSelfSigned {
			err = issueSelfSigned(certDir, final, dns, ips, in, "")
		} else {
			err = issueLeaf(certDir, final, dns, ips, caKey, in, "")
		}
		if err != nil {
			return nil, err
		}
		if err := swapCurrent(certDir, n); err != nil {
			return nil, err
		}
		created = true
		if o.OfflineCAKeyTo != "" && eff == ModeCALeaf {
			if err := exportOffline(certDir, o.OfflineCAKeyTo, o.ForceOverwriteCAExport); err != nil {
				return nil, err
			}
		}
	}
	info, err := load(certDir, eff, now, true)
	if err != nil {
		return nil, err
	}
	dns, ips, w2 := desiredSANs(in)
	info.Warnings = append(info.Warnings, warnings...)
	for _, w := range w2 {
		if !containsStr(warnings, w) {
			info.Warnings = append(info.Warnings, w)
		}
	}
	if !created {
		info.Drift = drift(info, dns, ips)
	}
	if len(info.Drift) > 0 {
		info.Warnings = append(info.Warnings, fmt.Sprintf(
			"host addresses/names changed since the certificate was issued: %s; run 'llmctl cert renew'",
			strings.Join(info.Drift, ", ")))
	}
	info.Created = created
	return info, nil
}

// Renew re-issues the leaf into a new v-<n> dir and swaps `current`. It never
// touches the CA; with the CA key offline pass Options.CAKeyPath.
func Renew(o Options) (*CertInfo, error) {
	in, err := resolveInputs(o)
	if err != nil {
		return nil, err
	}
	certDir, err := prepareDir(o.Home)
	if err != nil {
		return nil, err
	}
	lk, err := acquire(certDir)
	if err != nil {
		return nil, err
	}
	defer lk.release()

	cur := currentDir(certDir)
	eff := o.Mode
	if eff == "" && cur != "" {
		if eff = readMeta(cur).Mode; eff == "" {
			eff = ModeCALeaf
		}
	}
	switch {
	case eff == ModeBYO:
		return nil, errf("mode byo is operator-managed: replace the files under cert/byo yourself (llmctl never writes them)")
	case eff == "":
		return nil, errf("nothing to renew in %s; run 'llmctl cert ensure' first", certDir)
	case !validMode(eff):
		return nil, errf("unknown TLS mode %q", eff)
	}
	if err := guardKeyCreation(certDir); err != nil {
		return nil, err
	}
	dns, ips, w := desiredSANs(in)
	n := nextVersion(certDir)
	final := filepath.Join(certDir, fmt.Sprintf("v-%d", n))
	reuse := ""
	if o.ReuseKey && cur != "" {
		reuse = filepath.Join(cur, "leaf.key")
	}
	if eff == ModeSelfSigned {
		err = issueSelfSigned(certDir, final, dns, ips, in, reuse)
	} else {
		key := o.CAKeyPath
		if key == "" {
			key = filepath.Join(certDir, "ca", "ca.key")
		}
		if !fileExists(key) {
			return nil, errf("the CA private key is offline (not in %s); supply it with --ca-key PATH "+
				"(the path you chose with --offline-ca-key)", filepath.Join(certDir, "ca"))
		}
		if err = checkCAKey(certDir, key); err == nil {
			err = issueLeaf(certDir, final, dns, ips, key, in, reuse)
		}
	}
	if err != nil {
		return nil, err
	}
	if err := swapCurrent(certDir, n); err != nil {
		return nil, err
	}
	info, err := load(certDir, eff, o.now(), false)
	if err != nil {
		return nil, err
	}
	info.Warnings = append(info.Warnings, w...)
	info.Created = true
	return info, nil
}

// ShowInfo is the machine-readable result of Show.
type ShowInfo struct {
	Mode        string   `json:"mode"`
	Dir         string   `json:"dir"`
	Version     int      `json:"version"`
	CACert      string   `json:"ca_cert"`
	LeafCert    string   `json:"leaf_cert"`
	LeafKey     string   `json:"leaf_key"`
	Chain       string   `json:"chain"`
	CASHA256    string   `json:"ca_sha256"`
	LeafSHA256  string   `json:"leaf_sha256"`
	SANs        []string `json:"sans"`
	NotBefore   string   `json:"not_before"`
	NotAfter    string   `json:"not_after"`
	DaysLeft    int      `json:"days_left"`
	CAKeyOnHost bool     `json:"ca_key_on_host"`
}

// Show reports paths, fingerprints, SANs and expiry; never key material.
func Show(o Options) (*ShowInfo, error) {
	certDir := filepath.Join(o.Home, "cert")
	if st, err := os.Stat(certDir); err != nil || !st.IsDir() {
		return nil, errf("no certificate directory at %s; run 'llmctl cert ensure'", certDir)
	}
	mode := o.Mode
	if mode == "" {
		mode = o.getenv("LLMCTL_TLS_MODE")
	}
	now := o.now()
	info, err := load(certDir, mode, now, false)
	if err != nil {
		return nil, err
	}
	days := int(floorDays(info.NotAfter.Sub(now)))
	return &ShowInfo{
		Mode: info.Mode, Dir: certDir, Version: info.Version, CACert: info.CACert,
		LeafCert: info.LeafCert, LeafKey: info.LeafKey, Chain: info.Chain,
		CASHA256: info.CAFingerprint, LeafSHA256: info.LeafFingerprint, SANs: info.SANs,
		NotBefore: info.NotBefore.UTC().Format(time.RFC3339), NotAfter: info.NotAfter.UTC().Format(time.RFC3339),
		DaysLeft: days, CAKeyOnHost: info.CAKey != "",
	}, nil
}

func floorDays(d time.Duration) float64 { return math.Floor(d.Hours() / 24) }

// ExportCA copies the PUBLIC CA certificate to dest (mode 0644).
func ExportCA(home, dest string) (string, error) {
	src := filepath.Join(home, "cert", "ca", "ca.crt")
	b, err := os.ReadFile(src)
	if err != nil {
		return "", errf("no CA certificate at %s (mode selfsigned/byo has no CA; trust the leaf certificate itself)", src)
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(dest, b, 0o644); err != nil {
		return "", err
	}
	if err := os.Chmod(dest, 0o644); err != nil {
		return "", err
	}
	return dest, nil
}

func validMode(m string) bool { return containsStr(Modes, m) }

func containsStr(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}
