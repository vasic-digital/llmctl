package mtls

import (
	"crypto/x509"
	"net"
	"os"
	"testing"
)

func resetSANs(t *testing.T) {
	t.Helper()
	SetExtraSANs()
	t.Cleanup(func() { SetExtraSANs() })
}

func hasIP(c *x509.Certificate, s string) bool {
	for _, ip := range c.IPAddresses {
		if ip.Equal(net.ParseIP(s)) {
			return true
		}
	}
	return false
}

func hasDNS(c *x509.Certificate, s string) bool {
	for _, d := range c.DNSNames {
		if d == s {
			return true
		}
	}
	return false
}

// G-106: the default SAN set (what curl validates against).
func TestIssueNodeCert_CarriesLoopbackAndHostnameSANs(t *testing.T) {
	resetSANs(t)
	ca, _ := GenerateCA()
	nc, err := ca.IssueNodeCert("n1-api")
	if err != nil {
		t.Fatal(err)
	}
	leaf := parseCertPEM(t, nc.CertPEM)
	for _, ip := range []string{"127.0.0.1", "::1"} {
		if !hasIP(leaf, ip) {
			t.Errorf("IP SAN %s missing: %v", ip, leaf.IPAddresses)
		}
	}
	if !hasDNS(leaf, "localhost") {
		t.Errorf("DNS SAN localhost missing: %v", leaf.DNSNames)
	}
	if h, err := os.Hostname(); err == nil && validDNSName(h) && !hasDNS(leaf, h) {
		t.Errorf("hostname SAN %q missing: %v", h, leaf.DNSNames)
	}
	// strict verification, by name, against only this CA: what curl does
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca.CertPEM)
	for _, name := range []string{"127.0.0.1", "::1", "localhost"} {
		if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: name, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}); err != nil {
			t.Errorf("verify as %q: %v", name, err)
		}
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: "evil.example", KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}); err == nil {
		t.Error("certificate verified for a name outside its SAN set")
	}
}

func TestSetExtraSANs_ClassifiesIPsAndDNSAndDropsWildcards(t *testing.T) {
	resetSANs(t)
	SetExtraSANs("cluster.example.test", "10.9.8.7", "[fd00::5]", "0.0.0.0", "::", "", "  ", "bad_name!", "-bad.example")
	ca, _ := GenerateCA()
	nc, _ := ca.IssueNodeCert("n")
	leaf := parseCertPEM(t, nc.CertPEM)
	if !hasDNS(leaf, "cluster.example.test") || !hasIP(leaf, "10.9.8.7") || !hasIP(leaf, "fd00::5") {
		t.Errorf("extras not applied: dns=%v ips=%v", leaf.DNSNames, leaf.IPAddresses)
	}
	if hasIP(leaf, "0.0.0.0") || hasIP(leaf, "::") {
		t.Errorf("wildcard address leaked into SANs: %v", leaf.IPAddresses)
	}
	for _, d := range leaf.DNSNames {
		if d == "bad_name!" || d == "-bad.example" || d == "" {
			t.Errorf("invalid DNS name %q accepted", d)
		}
	}
	// replacing clears the previous extras
	SetExtraSANs("other.example.test")
	nc2, _ := ca.IssueNodeCert("n")
	leaf2 := parseCertPEM(t, nc2.CertPEM)
	if hasDNS(leaf2, "cluster.example.test") || !hasDNS(leaf2, "other.example.test") {
		t.Errorf("SetExtraSANs did not replace: %v", leaf2.DNSNames)
	}
}

func TestSANs_NoDuplicates(t *testing.T) {
	resetSANs(t)
	SetExtraSANs("127.0.0.1", "LOCALHOST", "localhost")
	dns, ips := currentSANs()
	seenD, seenI := map[string]bool{}, map[string]bool{}
	for _, d := range dns {
		if seenD[d] {
			t.Errorf("duplicate DNS SAN %q", d)
		}
		seenD[d] = true
	}
	for _, ip := range ips {
		if seenI[ip.String()] {
			t.Errorf("duplicate IP SAN %s", ip)
		}
		seenI[ip.String()] = true
	}
}

func TestIssueClientCert_ClientAuthOnlyAndTrustedByCA(t *testing.T) {
	resetSANs(t)
	ca, _ := GenerateCA()
	cc, err := ca.IssueClientCert("llmctl-cli")
	if err != nil {
		t.Fatal(err)
	}
	leaf := parseCertPEM(t, cc.CertPEM)
	if len(leaf.ExtKeyUsage) != 1 || leaf.ExtKeyUsage[0] != x509.ExtKeyUsageClientAuth {
		t.Fatalf("EKU = %v, want exactly clientAuth", leaf.ExtKeyUsage)
	}
	if len(leaf.DNSNames)+len(leaf.IPAddresses) != 0 {
		t.Errorf("client cert carries server names: %v %v", leaf.DNSNames, leaf.IPAddresses)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca.CertPEM)
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err != nil {
		t.Errorf("client cert not trusted by its CA: %v", err)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}); err == nil {
		t.Error("client-only cert verified as a server certificate")
	}
	other, _ := GenerateCA()
	opool := x509.NewCertPool()
	opool.AppendCertsFromPEM(other.CertPEM)
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: opool, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err == nil {
		t.Error("client cert accepted by an unrelated CA")
	}
}
