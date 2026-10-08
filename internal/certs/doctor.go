package certs

import (
	"crypto/x509"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Check is one doctor finding; Status is ok, warn or fail.
type Check struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Detail string `json:"detail"`
}

// Report is the result of Doctor.
type Report struct {
	OK     bool    `json:"ok"`
	Checks []Check `json:"checks"`
	Crypto string  `json:"crypto"`
	Mode   string  `json:"mode,omitempty"`
}

// Doctor checks key/cert match, chain, expiry (warn <= 30 days), SAN drift and
// permissions. It never modifies anything.
func Doctor(o Options) (*Report, error) {
	rep := &Report{Crypto: "go crypto/x509 (" + runtime.Version() + ")"}
	add := func(name, status, detail string) { rep.Checks = append(rep.Checks, Check{name, status, detail}) }
	add("crypto", "ok", rep.Crypto)
	certDir := filepath.Join(o.Home, "cert")
	mode := o.Mode
	if mode == "" {
		mode = o.getenv("LLMCTL_TLS_MODE")
	}
	now := o.now()
	info, err := load(certDir, mode, now, false)
	if err != nil {
		name := "certificates"
		if strings.Contains(err.Error(), "match") {
			name = "key_matches_cert"
		}
		add(name, "fail", err.Error())
		return rep, nil
	}
	rep.Mode = info.Mode
	add("key_matches_cert", "ok", "private key matches "+info.LeafCert)
	left := info.NotAfter.Sub(now)
	switch {
	case left < 0:
		add("expiry", "fail", "expired on "+dateOf(info.NotAfter))
	case left <= WarnDays*24*time.Hour:
		add("expiry", "warn", fmt.Sprintf("expires in %d days (%s)", daysBetween(left), dateOf(info.NotAfter)))
	default:
		add("expiry", "ok", fmt.Sprintf("valid for %d more days", daysBetween(left)))
	}
	if info.CACert != "" {
		n, s, d := chainStatus(info)
		add(n, s, d)
	}
	if in, err := resolveInputs(o); err != nil {
		add("san_drift", "warn", err.Error())
	} else {
		dns, ips, _ := desiredSANs(in)
		if dr := drift(info, dns, ips); len(dr) > 0 {
			add("san_drift", "warn", fmt.Sprintf("names/addresses not in the certificate: %s (run 'llmctl cert renew')", strings.Join(dr, ", ")))
		} else {
			add("san_drift", "ok", "certificate covers the current names and addresses")
		}
	}
	var bad []string
	loose := func(p string, allowed os.FileMode) {
		if st, err := os.Stat(p); err == nil && st.Mode().Perm()&^allowed != 0 {
			bad = append(bad, fmt.Sprintf("%s is mode %o (want %o or stricter)", p, st.Mode().Perm(), allowed))
		}
	}
	loose(certDir, 0o700)
	loose(info.LeafKey, 0o600)
	loose(filepath.Join(certDir, "ca", "ca.key"), 0o600)
	if len(bad) > 0 {
		add("permissions", "fail", strings.Join(bad, "; "))
	} else {
		add("permissions", "ok", "directory 0700, keys 0600")
	}
	if info.Mode == ModeCALeaf && info.CAKey == "" {
		add("ca_key", "ok", "CA key is not on this host (offline-CA-key mode)")
	}
	rep.OK = true
	for _, c := range rep.Checks {
		if c.Status == "fail" {
			rep.OK = false
		}
	}
	return rep, nil
}

// chainStatus verifies the leaf against the CA at a moment inside its validity,
// so expiry (reported separately) does not make the chain check fail twice.
func chainStatus(info *CertInfo) (name, status, detail string) {
	name = "chain"
	leaf, err1 := parseCertFile(info.LeafCert)
	ca, err2 := parseCertFile(info.CACert)
	if err1 != nil || err2 != nil {
		return name, "fail", "cannot read the leaf or the CA certificate"
	}
	pool := x509.NewCertPool()
	pool.AddCert(ca)
	at := leaf.NotBefore.Add(time.Minute)
	if at.Before(ca.NotBefore) {
		at = ca.NotBefore.Add(time.Minute)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, CurrentTime: at}); err != nil {
		return name, "fail", err.Error()
	}
	return name, "ok", "leaf verifies against the CA"
}
