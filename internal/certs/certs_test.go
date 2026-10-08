package certs

// Tier: unit + integration with real crypto. No stand-ins: the point of the
// tests is that Go's own x509.Verify and (when installed) the independent
// `openssl verify` accept or reject what the package produces.

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

var (
	testHosts = []string{"testhost"}
	testAddrs = []string{"192.168.1.115"}
)

func newHome(t *testing.T) string {
	t.Helper()
	h := filepath.Join(t.TempDir(), "llmctl")
	if err := os.MkdirAll(h, 0o755); err != nil {
		t.Fatal(err)
	}
	return h
}

func opts(home string) Options {
	return Options{Home: home, Hostnames: testHosts, Addresses: testAddrs, Env: map[string]string{}}
}

func mustEnsure(t *testing.T, o Options) *CertInfo {
	t.Helper()
	info, err := Ensure(o)
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	return info
}

func modeOf(t *testing.T, p string) os.FileMode {
	t.Helper()
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return st.Mode().Perm()
}

func shaOf(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func needOpenSSL(t *testing.T) string {
	t.Helper()
	p, err := exec.LookPath("openssl")
	if err != nil {
		t.Skip("openssl not installed; independent-oracle part skipped")
	}
	return p
}

func osslText(t *testing.T, cert string) string {
	t.Helper()
	out, err := exec.Command(needOpenSSL(t), "x509", "-in", cert, "-noout", "-text").CombinedOutput()
	if err != nil {
		t.Fatalf("openssl x509: %v\n%s", err, out)
	}
	return string(out)
}

func osslVerify(t *testing.T, ca, leaf string) (string, int) {
	t.Helper()
	cmd := exec.Command(needOpenSSL(t), "verify", "-CAfile", ca, "-purpose", "sslserver", leaf)
	out, err := cmd.CombinedOutput()
	rc := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			rc = ee.ExitCode()
		} else {
			t.Fatal(err)
		}
	}
	return string(out), rc
}

func readCert(t *testing.T, p string) *x509.Certificate {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	blk, _ := pem.Decode(b)
	if blk == nil {
		t.Fatalf("%s: no PEM", p)
	}
	c, err := x509.ParseCertificate(blk.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// goVerify is Go's own chain validation (the stdlib oracle).
func goVerify(t *testing.T, caPath, leafPath string) error {
	t.Helper()
	pool := x509.NewCertPool()
	pool.AddCert(readCert(t, caPath))
	_, err := readCert(t, leafPath).Verify(x509.VerifyOptions{
		Roots: pool, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, CurrentTime: time.Now(),
	})
	return err
}

// foreignLeaf issues, with the REAL CA key, a leaf for arbitrary names. It
// parses the CA key with the standard library directly (not via the package
// under test) so the enforcement check is independent.
func foreignLeaf(t *testing.T, home string, dns []string, ips []net.IP) string {
	t.Helper()
	caDir := filepath.Join(home, "cert", "ca")
	kb, err := os.ReadFile(filepath.Join(caDir, "ca.key"))
	if err != nil {
		t.Fatal(err)
	}
	blk, _ := pem.Decode(kb)
	ik, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	caCert := readCert(t, filepath.Join(caDir, "ca.crt"))
	lk, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(77), Subject: pkix.Name{CommonName: "foreign"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
		DNSNames: dns, IPAddresses: ips, KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, caCert, &lk.PublicKey, ik)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "foreign.pem")
	if err := os.WriteFile(p, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// ---------------------------------------------------------------- layout ---

func TestLayoutModesAndSymlink(t *testing.T) {
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	cert := filepath.Join(home, "cert")
	if m := modeOf(t, cert); m != 0o700 {
		t.Errorf("cert dir mode %o", m)
	}
	if m := modeOf(t, filepath.Join(cert, "ca", "ca.key")); m != 0o600 {
		t.Errorf("ca.key mode %o", m)
	}
	if m := modeOf(t, filepath.Join(cert, "ca", "ca.crt")); m != 0o644 {
		t.Errorf("ca.crt mode %o", m)
	}
	tgt, err := os.Readlink(filepath.Join(cert, "current"))
	if err != nil || tgt != "v-1" {
		t.Errorf("current -> %q, %v (want relative v-1)", tgt, err)
	}
	v1 := filepath.Join(cert, "v-1")
	if m := modeOf(t, filepath.Join(v1, "leaf.key")); m != 0o600 {
		t.Errorf("leaf.key mode %o", m)
	}
	if m := modeOf(t, filepath.Join(v1, "leaf.crt")); m != 0o644 {
		t.Errorf("leaf.crt mode %o", m)
	}
	if _, err := os.Stat(filepath.Join(v1, "chain.pem")); err != nil {
		t.Error("chain.pem missing")
	}
	if info.Mode != "ca-leaf" || info.Version != 1 || !info.Created {
		t.Errorf("info %+v", info)
	}
	// the chain is leaf + CA
	cb, _ := os.ReadFile(filepath.Join(v1, "chain.pem"))
	if strings.Count(string(cb), "BEGIN CERTIFICATE") != 2 {
		t.Error("chain.pem should hold leaf+CA")
	}
}

func TestInfoFormattingHasNoKeyMaterial(t *testing.T) {
	info := mustEnsure(t, opts(newHome(t)))
	for _, s := range []string{fmt.Sprint(info), fmt.Sprintf("%v %+v %#v %s", info, info, info, info), info.String()} {
		if strings.Contains(s, "BEGIN") || strings.Contains(s, "PRIVATE") {
			t.Errorf("key material in %q", s)
		}
	}
	if !strings.Contains(info.String(), info.LeafFingerprint) {
		t.Error("String should carry the leaf fingerprint")
	}
}

func TestIdempotentSecondEnsure(t *testing.T) {
	home := newHome(t)
	a := mustEnsure(t, opts(home))
	before := listNames(t, filepath.Join(home, "cert"))
	b := mustEnsure(t, opts(home))
	after := listNames(t, filepath.Join(home, "cert"))
	if strings.Join(before, ",") != strings.Join(after, ",") {
		t.Errorf("dir changed: %v -> %v", before, after)
	}
	if a.LeafFingerprint != b.LeafFingerprint || a.CAFingerprint != b.CAFingerprint || b.Created {
		t.Errorf("second ensure not a no-op: %v %v created=%v", a, b, b.Created)
	}
}

func listNames(t *testing.T, dir string) []string {
	t.Helper()
	es, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range es {
		out = append(out, e.Name())
	}
	return out
}

func TestConcurrentEnsureSingleIssuance(t *testing.T) {
	home := newHome(t)
	const n = 8
	var wg sync.WaitGroup
	res := make([]string, n)
	errs := make([]error, n)
	start := make(chan struct{})
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			info, err := Ensure(opts(home))
			errs[i] = err
			if err == nil {
				res[i] = fmt.Sprintf("%s/%d", info.LeafFingerprint, info.Version)
			}
		}(i)
	}
	close(start)
	wg.Wait()
	seen := map[string]bool{}
	created := 0
	for i := range res {
		if errs[i] != nil {
			t.Fatalf("worker %d: %v", i, errs[i])
		}
		seen[res[i]] = true
	}
	if len(seen) != 1 {
		t.Errorf("workers saw different certs: %v", seen)
	}
	_ = created
	m, _ := filepath.Glob(filepath.Join(home, "cert", "v-*"))
	if len(m) != 1 || filepath.Base(m[0]) != "v-1" {
		t.Errorf("version dirs %v", m)
	}
	if h, _ := filepath.Glob(filepath.Join(home, "cert", ".v-*")); len(h) != 0 {
		t.Errorf("temp dirs left: %v", h)
	}
}

func TestEnsureBlocksWhileLockHeld(t *testing.T) {
	// deterministic proof of the flock guard (the goroutine race above is only probabilistic)
	home := newHome(t)
	certDir, err := prepareDir(home)
	if err != nil {
		t.Fatal(err)
	}
	lk, err := acquire(certDir)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, err := Ensure(opts(home)); done <- err }()
	select {
	case <-done:
		t.Fatal("Ensure completed while another holder owned the lock")
	case <-time.After(400 * time.Millisecond):
	}
	if _, err := os.Stat(filepath.Join(certDir, "ca")); err == nil {
		t.Error("Ensure touched the CA while the lock was held")
	}
	lk.release()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Ensure did not proceed after the lock was released")
	}
}

// ------------------------------------------------------------ CA and leaf ---

func TestCAProperties(t *testing.T) {
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	c := readCert(t, info.CACert)
	if !c.IsCA || !c.BasicConstraintsValid || c.MaxPathLen != 0 || !c.MaxPathLenZero {
		t.Errorf("CA constraints: IsCA=%v maxpath=%d zero=%v", c.IsCA, c.MaxPathLen, c.MaxPathLenZero)
	}
	if c.KeyUsage != x509.KeyUsageCertSign|x509.KeyUsageCRLSign {
		t.Errorf("CA key usage %v", c.KeyUsage)
	}
	if !c.PermittedDNSDomainsCritical {
		t.Error("name constraints must be critical")
	}
	if pk, ok := c.PublicKey.(*ecdsa.PublicKey); !ok || pk.Curve != elliptic.P256() {
		t.Error("CA key must be EC P-256")
	}
	dns := strings.Join(c.PermittedDNSDomains, ",")
	for _, w := range []string{"localhost", ".local", "testhost"} {
		if !strings.Contains(","+dns+",", ","+w+",") {
			t.Errorf("permitted DNS missing %s: %s", w, dns)
		}
	}
	var nets []string
	for _, n := range c.PermittedIPRanges {
		nets = append(nets, n.String())
	}
	for _, w := range []string{"127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7", "100.64.0.0/10"} {
		found := false
		for _, n := range nets {
			if n == w {
				found = true
			}
		}
		if !found {
			t.Errorf("permitted IP range missing %s: %v", w, nets)
		}
	}
}

func TestCAPropertiesIndependentOracleOpenSSL(t *testing.T) {
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	txt := osslText(t, info.CACert)
	if !regexp.MustCompile(`Basic Constraints: critical\s+CA:TRUE, pathlen:0`).MatchString(txt) {
		t.Error("openssl does not see CA:TRUE pathlen:0 critical")
	}
	for _, w := range []string{"prime256v1", "Certificate Sign", "CRL Sign", "Name Constraints: critical",
		"DNS:localhost", "DNS:testhost", "IP:127.0.0.0/255.0.0.0", "IP:10.0.0.0/255.0.0.0",
		"IP:172.16.0.0/255.240.0.0", "IP:192.168.0.0/255.255.0.0", "IP:100.64.0.0/255.192.0.0"} {
		if !strings.Contains(txt, w) {
			t.Errorf("openssl text lacks %q", w)
		}
	}
}

func TestCAValidityTenYears(t *testing.T) {
	info := mustEnsure(t, opts(newHome(t)))
	d := info.CANotAfter.Sub(info.CANotBefore).Hours() / 24
	if d < 3649 || d > 3651 {
		t.Errorf("CA validity %.2f days", d)
	}
}

func TestLeafProperties(t *testing.T) {
	o := opts(newHome(t))
	o.SANs = "dns:nas.local,ip:10.1.2.3"
	info := mustEnsure(t, o)
	c := readCert(t, info.LeafCert)
	if c.IsCA || !c.BasicConstraintsValid {
		t.Error("leaf must be CA:FALSE with valid basic constraints")
	}
	if len(c.ExtKeyUsage) != 1 || c.ExtKeyUsage[0] != x509.ExtKeyUsageServerAuth {
		t.Errorf("EKU %v", c.ExtKeyUsage)
	}
	if pk, ok := c.PublicKey.(*ecdsa.PublicKey); !ok || pk.Curve != elliptic.P256() {
		t.Error("leaf key must be EC P-256")
	}
	d := info.NotAfter.Sub(info.NotBefore).Hours() / 24
	if d < 396 || d > 398 {
		t.Errorf("leaf validity %.2f days", d)
	}
	want := []string{"testhost", "localhost", "nas.local", "127.0.0.1", "::1", "192.168.1.115", "10.1.2.3"}
	for _, w := range want {
		if !contains(info.SANs, w) {
			t.Errorf("SANs %v lack %s", info.SANs, w)
		}
	}
	if info.SANs[0] != "testhost" {
		t.Errorf("host name should lead the SANs: %v", info.SANs)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(info.LeafCert), "meta.json")); err != nil {
		t.Error("meta.json missing")
	}
}

func TestLeafPropertiesIndependentOracleOpenSSL(t *testing.T) {
	info := mustEnsure(t, opts(newHome(t)))
	txt := osslText(t, info.LeafCert)
	for _, w := range []string{"prime256v1", "CA:FALSE", "TLS Web Server Authentication", "DNS:testhost", "DNS:localhost",
		"IP Address:127.0.0.1", "IP Address:192.168.1.115"} {
		if !strings.Contains(txt, w) {
			t.Errorf("openssl text lacks %q", w)
		}
	}
	if strings.Contains(txt, "TLS Web Client Authentication") {
		t.Error("leaf must be serverAuth only")
	}
}

func contains(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

func TestNameConstraintsEnforced(t *testing.T) {
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	// the permitted leaf verifies, in Go and in openssl
	if err := goVerify(t, info.CACert, info.LeafCert); err != nil {
		t.Fatalf("Go rejects the package's own leaf: %v", err)
	}
	if out, rc := osslVerify(t, info.CACert, info.LeafCert); rc != 0 {
		t.Fatalf("openssl rejects the package's own leaf: %s", out)
	}
	// out-of-scope names signed with the REAL CA key must NOT verify
	for _, c := range []struct {
		name string
		dns  []string
		ips  []net.IP
	}{
		{"example.com", []string{"example.com"}, nil},
		{"8.8.8.8", nil, []net.IP{ipv4(8, 8, 8, 8)}},
	} {
		bad := foreignLeaf(t, home, c.dns, c.ips)
		err := goVerify(t, info.CACert, bad)
		if err == nil {
			t.Errorf("Go verified out-of-scope leaf %s", c.name)
		} else if !strings.Contains(err.Error(), "constraint") {
			t.Errorf("Go rejection for %s is not a name-constraint one: %v", c.name, err)
		}
		out, rc := osslVerify(t, info.CACert, bad)
		if rc == 0 {
			t.Errorf("openssl verified out-of-scope leaf %s", c.name)
		}
		if !strings.Contains(out, "permitted subtree violation") {
			t.Errorf("openssl rejection for %s: %s", c.name, out)
		}
	}
	// a name inside the constraints signed the same way still verifies
	good := foreignLeaf(t, home, []string{"nas.local"}, []net.IP{ipv4(10, 9, 8, 7)})
	if err := goVerify(t, info.CACert, good); err != nil {
		t.Errorf("in-scope foreign leaf rejected by Go: %v", err)
	}
	if out, rc := osslVerify(t, info.CACert, good); rc != 0 {
		t.Errorf("in-scope foreign leaf rejected by openssl: %s", out)
	}
}

func TestConstraintsOffIsDeliberateOptOutAndWouldBeCaught(t *testing.T) {
	// Mutation proof: with the constraints off the same out-of-scope leaf
	// verifies, so the enforcement test above genuinely depends on the extension.
	home := newHome(t)
	o := opts(home)
	o.NoConstraints = true
	info := mustEnsure(t, o)
	c := readCert(t, info.CACert)
	if len(c.PermittedDNSDomains) != 0 || len(c.PermittedIPRanges) != 0 {
		t.Error("constraints must be absent when disabled")
	}
	found := false
	for _, w := range info.Warnings {
		if strings.Contains(strings.ToLower(w), "constraints") {
			found = true
		}
	}
	if !found {
		t.Errorf("opt-out must be logged as a warning: %v", info.Warnings)
	}
	bad := foreignLeaf(t, home, []string{"example.com"}, nil)
	if err := goVerify(t, info.CACert, bad); err != nil {
		t.Errorf("Go should accept it with constraints off: %v", err)
	}
	if out, rc := osslVerify(t, info.CACert, bad); rc != 0 {
		t.Errorf("openssl should accept it with constraints off: %s", out)
	}
	if strings.Contains(osslText(t, info.CACert), "Name Constraints") {
		t.Error("openssl still sees name constraints")
	}
}

func TestConstraintsEnvOff(t *testing.T) {
	for _, v := range []string{"off", "OFF", "0", "false", "no"} {
		o := opts(newHome(t))
		o.Env = map[string]string{"LLMCTL_CA_NAME_CONSTRAINTS": v}
		info := mustEnsure(t, o)
		if c := readCert(t, info.CACert); len(c.PermittedDNSDomains) != 0 {
			t.Errorf("env %q did not disable constraints", v)
		}
	}
	o := opts(newHome(t))
	o.Env = map[string]string{"LLMCTL_CA_NAME_CONSTRAINTS": "on"}
	if c := readCert(t, mustEnsure(t, o).CACert); len(c.PermittedDNSDomains) == 0 {
		t.Error("env on must keep constraints")
	}
}

func TestPublicIPFilteredNotFatal(t *testing.T) {
	o := opts(newHome(t))
	o.Addresses = []string{"192.168.1.115", "8.8.8.8"}
	info := mustEnsure(t, o)
	if contains(info.SANs, "8.8.8.8") {
		t.Error("public address must not be a SAN under constraints")
	}
	ok := false
	for _, w := range info.Warnings {
		if strings.Contains(w, "8.8.8.8") {
			ok = true
		}
	}
	if !ok {
		t.Errorf("no warning about 8.8.8.8: %v", info.Warnings)
	}
}

func TestLaterExtraOutsideConstraintsRefusedAndStateKept(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.SANs = "dns:example.com"
	_, err := Renew(o)
	if err == nil || !strings.Contains(err.Error(), "name constraints") {
		t.Fatalf("want a name-constraints refusal, got %v", err)
	}
	vs, _ := filepath.Glob(filepath.Join(home, "cert", "v-*"))
	if len(vs) != 1 {
		t.Errorf("version dirs %v", vs)
	}
	if tgt, _ := os.Readlink(filepath.Join(home, "cert", "current")); tgt != "v-1" {
		t.Errorf("current -> %s", tgt)
	}
	if h, _ := filepath.Glob(filepath.Join(home, "cert", ".v-*")); len(h) != 0 {
		t.Errorf("leftover temp dirs %v", h)
	}
}

func TestExtraInsideFirstEnsureIsPermittedByCA(t *testing.T) {
	o := opts(newHome(t))
	o.SANs = "dns:nas.example.org,ip:203.0.113.7"
	info := mustEnsure(t, o)
	if err := goVerify(t, info.CACert, info.LeafCert); err != nil {
		t.Errorf("Go: %v", err)
	}
	if out, rc := osslVerify(t, info.CACert, info.LeafCert); rc != 0 {
		t.Errorf("openssl: %s", out)
	}
	if !contains(info.SANs, "203.0.113.7") || !contains(info.SANs, "nas.example.org") {
		t.Errorf("SANs %v", info.SANs)
	}
}

// ------------------------------------------------------ drift/expiry/renew ---

func TestSANDriftDetectedAndNotSilentlyReissued(t *testing.T) {
	home := newHome(t)
	a := mustEnsure(t, opts(home))
	o := opts(home)
	o.Addresses = append(append([]string{}, testAddrs...), "192.168.1.200")
	b := mustEnsure(t, o)
	if a.LeafFingerprint != b.LeafFingerprint || b.Version != 1 {
		t.Error("ensure must never re-issue silently")
	}
	if !contains(b.Drift, "192.168.1.200") {
		t.Errorf("drift %v", b.Drift)
	}
	found := false
	for _, w := range b.Warnings {
		if strings.Contains(w, "renew") {
			found = true
		}
	}
	if !found {
		t.Errorf("drift warning missing: %v", b.Warnings)
	}
}

func TestRenewNewVersionKeepsCA(t *testing.T) {
	home := newHome(t)
	a := mustEnsure(t, opts(home))
	caBefore, keyBefore := shaOf(t, a.CACert), shaOf(t, a.CAKey)
	o := opts(home)
	o.Addresses = append(append([]string{}, testAddrs...), "192.168.1.200")
	b, err := Renew(o)
	if err != nil {
		t.Fatal(err)
	}
	if b.Version != 2 {
		t.Errorf("version %d", b.Version)
	}
	if tgt, _ := os.Readlink(filepath.Join(home, "cert", "current")); tgt != "v-2" {
		t.Errorf("current -> %s", tgt)
	}
	if _, err := os.Stat(filepath.Join(home, "cert", "v-1", "leaf.crt")); err != nil {
		t.Error("old version must be kept")
	}
	if shaOf(t, b.CACert) != caBefore || shaOf(t, b.CAKey) != keyBefore {
		t.Error("renew touched the CA")
	}
	if a.LeafFingerprint == b.LeafFingerprint {
		t.Error("leaf unchanged")
	}
	if len(b.Drift) != 0 {
		t.Errorf("drift after renew %v", b.Drift)
	}
	if shaOf(t, filepath.Join(home, "cert", "v-1", "leaf.key")) == shaOf(t, filepath.Join(home, "cert", "v-2", "leaf.key")) {
		t.Error("key should be new without ReuseKey")
	}
	if !contains(b.SANs, "192.168.1.200") {
		t.Errorf("new address missing: %v", b.SANs)
	}
	if m := modeOf(t, filepath.Join(home, "cert", "v-2")); m != 0o700 {
		t.Errorf("v-2 mode %o", m)
	}
	if err := goVerify(t, b.CACert, b.LeafCert); err != nil {
		t.Error(err)
	}
}

func TestRenewReuseKey(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.ReuseKey = true
	b, err := Renew(o)
	if err != nil {
		t.Fatal(err)
	}
	if shaOf(t, filepath.Join(home, "cert", "v-1", "leaf.key")) != shaOf(t, filepath.Join(home, "cert", "v-2", "leaf.key")) {
		t.Error("key must be reused")
	}
	if b.Version != 2 || modeOf(t, b.LeafKey) != 0o600 {
		t.Errorf("version %d mode %o", b.Version, modeOf(t, b.LeafKey))
	}
}

func TestExpiredLeafRefused(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.Now = time.Now().Add(400 * 24 * time.Hour)
	_, err := Ensure(o)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "expired") {
		t.Fatalf("want expired refusal, got %v", err)
	}
}

func TestExpiryWarningWithin30Days(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.Now = time.Now().Add(380 * 24 * time.Hour)
	info := mustEnsure(t, o)
	if !anyContains(info.Warnings, "expires") {
		t.Errorf("no expiry warning: %v", info.Warnings)
	}
	if far := mustEnsure(t, opts(home)); anyContains(far.Warnings, "expires") {
		t.Errorf("spurious expiry warning: %v", far.Warnings)
	}
}

func anyContains(l []string, sub string) bool {
	for _, s := range l {
		if strings.Contains(strings.ToLower(s), sub) {
			return true
		}
	}
	return false
}

func TestRenewAfterExpiryWorks(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.Now = time.Now().Add(400 * 24 * time.Hour)
	b, err := Renew(o)
	if err != nil {
		t.Fatalf("renew is the sanctioned way out of expiry: %v", err)
	}
	if b.Version != 2 {
		t.Errorf("version %d", b.Version)
	}
}

func TestExpiredCARefused(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.Now = time.Now().Add(3700 * 24 * time.Hour)
	_, err := Ensure(o)
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "expired") {
		t.Fatalf("got %v", err)
	}
}

func TestClockBeforeValidityRefused(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.Now = time.Now().Add(-48 * time.Hour)
	_, err := Ensure(o)
	if err == nil || !strings.Contains(err.Error(), "not valid before") {
		t.Fatalf("got %v", err)
	}
}

func TestCurrentSwapIsAtomicForReaders(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	cur := filepath.Join(home, "cert", "current", "leaf.crt")
	stop := make(chan struct{})
	var wg sync.WaitGroup
	var bad error
	var mu sync.Mutex
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			if _, err := os.ReadFile(cur); err != nil {
				mu.Lock()
				bad = err
				mu.Unlock()
				return
			}
		}
	}()
	for i := 0; i < 3; i++ {
		if _, err := Renew(opts(home)); err != nil {
			t.Fatal(err)
		}
	}
	close(stop)
	wg.Wait()
	if bad != nil {
		t.Errorf("reader saw a missing current during renew: %v", bad)
	}
}

// ------------------------------------------------------------------- modes ---

func writeBYO(t *testing.T, home string, expired, mismatch bool, sec1 bool) (key, crt string) {
	t.Helper()
	cdir := filepath.Join(home, "cert")
	if err := os.MkdirAll(filepath.Join(cdir, "byo"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(cdir, 0o700); err != nil {
		t.Fatal(err)
	}
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	signer := k
	if mismatch {
		signer, _ = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	}
	nb, na := time.Now().Add(-time.Hour), time.Now().Add(30*24*time.Hour)
	if expired {
		nb, na = time.Date(2019, 1, 1, 0, 0, 0, 0, time.UTC), time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	}
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(9), Subject: pkix.Name{CommonName: "byo.local"}, DNSNames: []string{"byo.local"},
		NotBefore: nb, NotAfter: na, KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &signer.PublicKey, signer)
	if err != nil {
		t.Fatal(err)
	}
	var kb []byte
	if sec1 {
		d, _ := x509.MarshalECPrivateKey(k)
		kb = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: d})
	} else {
		d, _ := x509.MarshalPKCS8PrivateKey(k)
		kb = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: d})
	}
	key = filepath.Join(cdir, "byo", "key.pem")
	crt = filepath.Join(cdir, "byo", "cert.pem")
	if err := os.WriteFile(key, kb, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(crt, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		t.Fatal(err)
	}
	return key, crt
}

func TestBYOValidPairValidatedAndNeverWritten(t *testing.T) {
	for _, sec1 := range []bool{false, true} {
		home := newHome(t)
		k, c := writeBYO(t, home, false, false, sec1)
		hk, hc := shaOf(t, k), shaOf(t, c)
		o := opts(home)
		o.Mode = "byo"
		info := mustEnsure(t, o)
		if info.Mode != "byo" || info.LeafCert != c || info.LeafKey != k {
			t.Errorf("info %+v", info)
		}
		if shaOf(t, k) != hk || shaOf(t, c) != hc {
			t.Error("BYO files were modified")
		}
		if _, err := os.Stat(filepath.Join(home, "cert", "ca")); err == nil {
			t.Error("byo must not create a CA")
		}
		// auto-detected afterwards without --mode
		again := mustEnsure(t, opts(home))
		if again.Mode != "byo" {
			t.Errorf("byo not auto-detected: %s", again.Mode)
		}
	}
}

func TestBYOOpenSSLMadeSEC1KeyAccepted(t *testing.T) {
	ossl := needOpenSSL(t)
	home := newHome(t)
	cdir := filepath.Join(home, "cert", "byo")
	_ = os.MkdirAll(cdir, 0o700)
	_ = os.Chmod(filepath.Join(home, "cert"), 0o700)
	run := func(args ...string) {
		if out, err := exec.Command(ossl, args...).CombinedOutput(); err != nil {
			t.Fatalf("openssl %v: %v\n%s", args, err, out)
		}
	}
	run("ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", filepath.Join(cdir, "key.pem"))
	run("req", "-x509", "-new", "-key", filepath.Join(cdir, "key.pem"), "-subj", "/CN=byo.local",
		"-addext", "subjectAltName=DNS:byo.local", "-days", "20", "-out", filepath.Join(cdir, "cert.pem"))
	o := opts(home)
	o.Mode = "byo"
	if info := mustEnsure(t, o); info.Mode != "byo" || !contains(info.SANs, "byo.local") {
		t.Errorf("%+v", info)
	}
}

func TestBYOMismatchedExpiredMissingRefused(t *testing.T) {
	cases := []struct {
		name  string
		setup func(home string)
		want  string
	}{
		{"mismatch", func(h string) { writeBYO(t, h, false, true, false) }, "match"},
		{"expired", func(h string) { writeBYO(t, h, true, false, false) }, "expired"},
		{"missing", func(h string) {}, "byo"},
	}
	for _, c := range cases {
		home := newHome(t)
		c.setup(home)
		o := opts(home)
		o.Mode = "byo"
		_, err := Ensure(o)
		if err == nil || !strings.Contains(strings.ToLower(err.Error()), c.want) {
			t.Errorf("%s: got %v", c.name, err)
		}
	}
}

func TestBYOUnreadableKeyRefused(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads everything")
	}
	home := newHome(t)
	k, _ := writeBYO(t, home, false, false, false)
	if err := os.Chmod(k, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(k, 0o600)
	o := opts(home)
	o.Mode = "byo"
	_, err := Ensure(o)
	if err == nil || !strings.Contains(err.Error(), "readable") {
		t.Errorf("got %v", err)
	}
}

func TestBYORenewRefused(t *testing.T) {
	home := newHome(t)
	writeBYO(t, home, false, false, false)
	o := opts(home)
	o.Mode = "byo"
	mustEnsure(t, o)
	if _, err := Renew(o); err == nil {
		t.Fatal("renew in byo mode must be refused")
	}
}

func TestSelfSignedSingleCert(t *testing.T) {
	home := newHome(t)
	o := opts(home)
	o.Mode = "selfsigned"
	info := mustEnsure(t, o)
	if info.Mode != "selfsigned" || info.CACert != "" {
		t.Errorf("%+v", info)
	}
	if _, err := os.Stat(filepath.Join(home, "cert", "ca")); err == nil {
		t.Error("selfsigned must not create a CA")
	}
	if modeOf(t, info.LeafKey) != 0o600 {
		t.Error("key mode")
	}
	if err := goVerify(t, info.LeafCert, info.LeafCert); err != nil {
		t.Errorf("Go: leaf as its own root: %v", err)
	}
	if out, rc := osslVerify(t, info.LeafCert, info.LeafCert); rc != 0 {
		t.Errorf("openssl: %s", out)
	}
	// subsequent ensure keeps the mode without being told
	if again := mustEnsure(t, opts(home)); again.Mode != "selfsigned" || again.Created {
		t.Errorf("%+v", again)
	}
	// renew works in selfsigned mode, with and without key reuse
	ro := opts(home)
	ro.ReuseKey = true
	b, err := Renew(ro)
	if err != nil || b.Version != 2 {
		t.Fatalf("renew: %v %+v", err, b)
	}
	if shaOf(t, filepath.Join(home, "cert", "v-1", "leaf.key")) != shaOf(t, filepath.Join(home, "cert", "v-2", "leaf.key")) {
		t.Error("selfsigned reuse-key")
	}
}

func TestModeChangeViaEnsureRefused(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.Mode = "selfsigned"
	if _, err := Ensure(o); err == nil {
		t.Fatal("silent mode switch must be refused")
	}
}

func TestBadModeAndEnvMode(t *testing.T) {
	o := opts(newHome(t))
	o.Mode = "bogus"
	if _, err := Ensure(o); err == nil {
		t.Error("bogus mode accepted")
	}
	o = opts(newHome(t))
	o.Env = map[string]string{"LLMCTL_TLS_MODE": "selfsigned"}
	if info := mustEnsure(t, o); info.Mode != "selfsigned" {
		t.Errorf("env mode ignored: %s", info.Mode)
	}
}

func TestEnvSANsUsed(t *testing.T) {
	o := opts(newHome(t))
	o.Env = map[string]string{"LLMCTL_TLS_SAN": "dns:box.local,ip:10.0.0.9"}
	info := mustEnsure(t, o)
	if !contains(info.SANs, "box.local") || !contains(info.SANs, "10.0.0.9") {
		t.Errorf("%v", info.SANs)
	}
	o = opts(newHome(t))
	o.Env = map[string]string{"LLMCTL_TLS_SAN": "garbage"}
	if _, err := Ensure(o); err == nil {
		t.Error("invalid SAN env accepted")
	}
}

// --------------------------------------------------- placement and offline ---

func gitInit(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("git", "-C", repo, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	return repo
}

func TestRefusedInsideUnignoredGitWorkTree(t *testing.T) {
	repo := gitInit(t)
	_, err := Ensure(opts(filepath.Join(repo, "llmctl")))
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "git work tree") {
		t.Fatalf("got %v", err)
	}
	if _, err := os.Stat(filepath.Join(repo, "llmctl", "cert", "ca", "ca.key")); err == nil {
		t.Error("a CA key was written into the repository")
	}
}

func TestAllowedWhenGitIgnores(t *testing.T) {
	repo := gitInit(t)
	if err := os.WriteFile(filepath.Join(repo, ".gitignore"), []byte("cert/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	info := mustEnsure(t, opts(repo))
	if _, err := os.Stat(info.LeafCert); err != nil {
		t.Fatal(err)
	}
	out, _ := exec.Command("git", "-C", repo, "status", "--porcelain", "--untracked-files=all").CombinedOutput()
	if strings.Contains(string(out), "cert/") {
		t.Errorf("git sees cert files: %s", out)
	}
}

func TestOutsideGitOK(t *testing.T) {
	if _, err := os.Stat(mustEnsure(t, opts(newHome(t))).LeafCert); err != nil {
		t.Fatal(err)
	}
}

func TestOfflineCAKeyExportAndRemoval(t *testing.T) {
	home := newHome(t)
	dest := filepath.Join(t.TempDir(), "usb", "ca.key")
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		t.Fatal(err)
	}
	o := opts(home)
	o.OfflineCAKeyTo = dest
	info := mustEnsure(t, o)
	if modeOf(t, dest) != 0o600 {
		t.Errorf("offline key mode %o", modeOf(t, dest))
	}
	if _, err := os.Stat(filepath.Join(home, "cert", "ca", "ca.key")); err == nil {
		t.Error("CA key still on the host")
	}
	if info.CAKey != "" {
		t.Errorf("CAKey should be empty: %q", info.CAKey)
	}
	// renew without the key: refused with an actionable message
	_, err := Renew(opts(home))
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "offline") {
		t.Fatalf("got %v", err)
	}
	// ... works when the operator supplies the key for the occasion
	ro := opts(home)
	ro.CAKeyPath = dest
	b, err := Renew(ro)
	if err != nil || b.Version != 2 {
		t.Fatalf("renew with key: %v %+v", err, b)
	}
	if _, err := os.Stat(filepath.Join(home, "cert", "ca", "ca.key")); err == nil {
		t.Error("renew must not put the key back on the host")
	}
	if err := goVerify(t, b.CACert, b.LeafCert); err != nil {
		t.Errorf("leaf issued from the offline key does not verify: %v", err)
	}
	// the wrong key is rejected
	wrong := filepath.Join(t.TempDir(), "wrong.key")
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	d, _ := x509.MarshalPKCS8PrivateKey(k)
	_ = os.WriteFile(wrong, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: d}), 0o600)
	wo := opts(home)
	wo.CAKeyPath = wrong
	if _, err := Renew(wo); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Errorf("wrong CA key: %v", err)
	}
	// ensure keeps working without the key
	if c := mustEnsure(t, opts(home)); c.Created {
		t.Error("ensure re-created")
	}
}

func TestOfflineDestInsideCertDirRefused(t *testing.T) {
	home := newHome(t)
	o := opts(home)
	o.OfflineCAKeyTo = filepath.Join(home, "cert", "x.key")
	if _, err := Ensure(o); err == nil {
		t.Fatal("destination inside cert dir accepted")
	}
	// the CA key must NOT have been removed when the export failed
	if _, err := os.Stat(filepath.Join(home, "cert", "ca", "ca.key")); err != nil {
		t.Error("CA key lost after a refused export")
	}
}

// ------------------------------------------------------ show/export/doctor ---

func TestExportCAPublicOnlyMode0644(t *testing.T) {
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	dest := filepath.Join(t.TempDir(), "exported", "ca.crt")
	out, err := ExportCA(home, dest)
	if err != nil {
		t.Fatal(err)
	}
	if out != dest || modeOf(t, dest) != 0o644 || shaOf(t, dest) != shaOf(t, info.CACert) {
		t.Errorf("export result %s", out)
	}
	b, _ := os.ReadFile(dest)
	if strings.Contains(string(b), "PRIVATE") {
		t.Error("private key in export")
	}
	// overwriting a stricter pre-existing file still ends 0644
	if _, err := ExportCA(home, dest); err != nil {
		t.Error(err)
	}
}

func TestExportWithoutCAFails(t *testing.T) {
	home := newHome(t)
	o := opts(home)
	o.Mode = "selfsigned"
	mustEnsure(t, o)
	if _, err := ExportCA(home, filepath.Join(t.TempDir(), "x")); err == nil {
		t.Error("selfsigned has no CA to export")
	}
}

func TestShowContainsFingerprintsAndMode(t *testing.T) {
	home := newHome(t)
	info := mustEnsure(t, opts(home))
	d, err := Show(opts(home))
	if err != nil {
		t.Fatal(err)
	}
	if d.Mode != "ca-leaf" || d.LeafSHA256 != info.LeafFingerprint || d.CASHA256 != info.CAFingerprint {
		t.Errorf("%+v", d)
	}
	if !contains(d.SANs, "localhost") || !d.CAKeyOnHost || d.DaysLeft < 390 {
		t.Errorf("%+v", d)
	}
	if !regexp.MustCompile(`^([0-9A-F]{2}:){31}[0-9A-F]{2}$`).MatchString(info.LeafFingerprint) {
		t.Errorf("fingerprint format %s", info.LeafFingerprint)
	}
	// independent oracle: openssl computes the same fingerprint
	if _, err := exec.LookPath("openssl"); err == nil {
		out, _ := exec.Command("openssl", "x509", "-in", info.LeafCert, "-noout", "-fingerprint", "-sha256").Output()
		if !strings.Contains(string(out), info.LeafFingerprint) {
			t.Errorf("fingerprint differs from openssl: %s vs %s", out, info.LeafFingerprint)
		}
	}
}

func TestShowWithoutCertsFails(t *testing.T) {
	if _, err := Show(opts(newHome(t))); err == nil {
		t.Fatal("show on an empty home must fail")
	}
}

func checkOf(rep *Report, name string) *Check {
	for i := range rep.Checks {
		if rep.Checks[i].Name == name {
			return &rep.Checks[i]
		}
	}
	return nil
}

func TestDoctorHealthy(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	rep, err := Doctor(opts(home))
	if err != nil {
		t.Fatal(err)
	}
	if !rep.OK {
		t.Fatalf("%+v", rep)
	}
	for _, n := range []string{"crypto", "key_matches_cert", "expiry", "chain", "san_drift", "permissions"} {
		if checkOf(rep, n) == nil {
			t.Errorf("check %s missing", n)
		}
	}
	if !strings.Contains(rep.Crypto, "go") {
		t.Errorf("crypto backend %q", rep.Crypto)
	}
}

func TestDoctorDetectsDriftPermsAndKeyMismatch(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.Addresses = append(append([]string{}, testAddrs...), "192.168.1.99")
	rep, _ := Doctor(o)
	if c := checkOf(rep, "san_drift"); c == nil || c.Status != "warn" {
		t.Errorf("drift check %+v", c)
	}
	if !rep.OK {
		t.Error("drift is a warning, not a failure")
	}
	caKey := filepath.Join(home, "cert", "ca", "ca.key")
	_ = os.Chmod(caKey, 0o644)
	rep, _ = Doctor(opts(home))
	if c := checkOf(rep, "permissions"); c == nil || c.Status != "fail" || rep.OK {
		t.Errorf("permission check %+v ok=%v", c, rep.OK)
	}
	_ = os.Chmod(caKey, 0o600)
	// tamper: replace the leaf key with a different one
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	d, _ := x509.MarshalPKCS8PrivateKey(k)
	if err := os.WriteFile(filepath.Join(home, "cert", "v-1", "leaf.key"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: d}), 0o600); err != nil {
		t.Fatal(err)
	}
	rep, _ = Doctor(opts(home))
	if c := checkOf(rep, "key_matches_cert"); c == nil || c.Status != "fail" || rep.OK {
		t.Errorf("tamper check %+v", c)
	}
}

func TestDoctorExpired(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.Now = time.Now().Add(400 * 24 * time.Hour)
	rep, _ := Doctor(o)
	if c := checkOf(rep, "expiry"); c == nil || c.Status != "fail" || rep.OK {
		t.Errorf("%+v", c)
	}
}

func TestDoctorExpiringSoonWarns(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	o := opts(home)
	o.Now = time.Now().Add(380 * 24 * time.Hour)
	rep, _ := Doctor(o)
	if c := checkOf(rep, "expiry"); c == nil || c.Status != "warn" || !rep.OK {
		t.Errorf("%+v ok=%v", c, rep.OK)
	}
}

func TestDoctorNoCertsAndChainBroken(t *testing.T) {
	rep, _ := Doctor(opts(newHome(t)))
	if rep.OK {
		t.Error("no certs must not be healthy")
	}
	// leaf signed by a foreign CA: chain must fail
	home := newHome(t)
	mustEnsure(t, opts(home))
	other := newHome(t)
	oi := mustEnsure(t, opts(other))
	b, _ := os.ReadFile(oi.CACert)
	if err := os.WriteFile(filepath.Join(home, "cert", "ca", "ca.crt"), b, 0o644); err != nil {
		t.Fatal(err)
	}
	rep, _ = Doctor(opts(home))
	if c := checkOf(rep, "chain"); c == nil || c.Status != "fail" {
		t.Errorf("chain check %+v", c)
	}
}

func TestDoctorLooseCertDirFails(t *testing.T) {
	home := newHome(t)
	mustEnsure(t, opts(home))
	_ = os.Chmod(filepath.Join(home, "cert"), 0o755)
	rep, _ := Doctor(opts(home))
	if c := checkOf(rep, "permissions"); c == nil || c.Status != "fail" {
		t.Errorf("%+v", c)
	}
}

// ----------------------------------------------------------------- parsers ---

func TestParseExtraSANs(t *testing.T) {
	d, i, err := ParseExtraSANs("dns:a.example.org, ip:203.0.113.7,ip:fd00::5")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(d, ",") != "a.example.org" || strings.Join(i, ",") != "203.0.113.7,fd00::5" {
		t.Errorf("%v %v", d, i)
	}
	d, i, err = ParseExtraSANs("")
	if err != nil || len(d) != 0 || len(i) != 0 {
		t.Errorf("empty spec: %v %v %v", d, i, err)
	}
	d, _, _ = ParseExtraSANs("DNS:Mixed.Example.ORG")
	if len(d) != 1 || d[0] != "mixed.example.org" {
		t.Errorf("case: %v", d)
	}
}

func TestParseExtraSANsRejectsGarbage(t *testing.T) {
	for _, bad := range []string{"nas.example.org", "ip:not-an-ip", "dns:", "dns:bad name", "ip:fe80::1%eth0", "mail:a@b", "dns:-x.org"} {
		if _, _, err := ParseExtraSANs(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestDetectHostnamesAndAddressesSane(t *testing.T) {
	for _, h := range DetectHostnames() {
		if h != strings.ToLower(h) || h == "localhost" || strings.HasSuffix(h, ".") || !labelRE.MatchString(h) {
			t.Errorf("bad detected hostname %q", h)
		}
	}
	for _, a := range DetectAddresses() {
		ip := parseIP(t, a)
		if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() || ip.IsMulticast() {
			t.Errorf("detected address %s should have been filtered", a)
		}
	}
}

func TestDesiredSANsFiltersAndOrders(t *testing.T) {
	in := inputs{hostnames: []string{"Zed", "alpha"}, addrs: []string{"10.0.0.5", "8.8.8.8", "fd00::1", "2001:db8::1"}, constrained: true}
	dns, ips, warns := desiredSANs(in)
	if strings.Join(dns, ",") != "zed,alpha,localhost" {
		t.Errorf("dns %v", dns)
	}
	if strings.Join(ips, ",") != "127.0.0.1,::1,10.0.0.5,fd00::1" {
		t.Errorf("ips %v", ips)
	}
	if len(warns) != 2 {
		t.Errorf("warnings %v", warns)
	}
	in.constrained = false
	_, ips, warns = desiredSANs(in)
	if !contains(ips, "8.8.8.8") || len(warns) != 0 {
		t.Errorf("unconstrained: %v %v", ips, warns)
	}
}

func TestErrorTypeIsCertError(t *testing.T) {
	_, err := Show(opts(newHome(t)))
	var ce *Error
	if !asError(err, &ce) {
		t.Errorf("want *Error, got %T", err)
	}
}
