package mtls

import (
	"net"
	"os"
	"strings"
	"sync"
)

// Certificate name policy (G-106 / OD-21 / T131).
//
// Every leaf this package issues carries Subject Alternative Names, because
// the client side of the opt-in cluster CLI (lib/cluster.sh -> curl --http3
// --cacert ...) verifies the daemon's certificate against the host in the
// URL and curl, like every standards-conforming TLS client, ignores the
// subject CN entirely. The policy is:
//
//   - always:   IP 127.0.0.1, IP ::1, DNS localhost, and the machine
//     hostname (os.Hostname) when it is a valid DNS name;
//   - on top:   the extras registered with SetExtraSANs (the daemon feeds
//     in its bind host and every -advertise value), each classified as an
//     IP SAN when it parses as an IP address and as a DNS SAN otherwise.
//
// The policy lives here, inside IssueNodeCert, deliberately - not in the
// call sites - so that EVERY issuance path (bootstrap, join, the renew
// handler and CA rotation in api/routes_mtls.go) produces certificates with
// the same names; a renewed API certificate can therefore never silently
// lose the SANs the CLI depends on. The extras are process-wide state
// because the daemon is one process serving one node identity.
//
// Single source of truth note: the root module's internal/certs package
// (spec 009, decision-gateway TLS) cannot be imported from this separate Go
// module, so llmctld keeps its own - deliberately small - implementation of
// the same name policy (loopback + hostname + operator-supplied names).
// The two policies are kept aligned by tests that assert the same SAN set;
// see docs/llmctld-cluster-tls.md.

var (
	sanMu    sync.RWMutex
	extraDNS []string
	extraIPs []net.IP
)

// SetExtraSANs replaces the set of operator-configured names added to every
// subsequently issued certificate. Empty strings and wildcard addresses
// (0.0.0.0, ::) are ignored - a wildcard bind address is not a name any
// client can validate. Calling it with no arguments clears the extras.
func SetExtraSANs(names ...string) {
	var dns []string
	var ips []net.IP
	for _, n := range names {
		n = strings.TrimSpace(n)
		if n == "" {
			continue
		}
		if ip := net.ParseIP(strings.Trim(n, "[]")); ip != nil {
			if ip.IsUnspecified() {
				continue
			}
			ips = append(ips, ip)
			continue
		}
		if validDNSName(n) {
			dns = append(dns, n)
		}
	}
	sanMu.Lock()
	extraDNS, extraIPs = dns, ips
	sanMu.Unlock()
}

// currentSANs returns the full name set for a new leaf certificate.
func currentSANs() (dns []string, ips []net.IP) {
	dns = []string{"localhost"}
	ips = []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback}
	if h, err := os.Hostname(); err == nil && validDNSName(h) {
		dns = append(dns, h)
	}
	sanMu.RLock()
	dns = append(dns, extraDNS...)
	ips = append(ips, extraIPs...)
	sanMu.RUnlock()
	return dedupDNS(dns), dedupIPs(ips)
}

func dedupDNS(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		k := strings.ToLower(s)
		if !seen[k] {
			seen[k] = true
			out = append(out, s)
		}
	}
	return out
}

func dedupIPs(in []net.IP) []net.IP {
	seen := map[string]bool{}
	var out []net.IP
	for _, ip := range in {
		k := ip.String()
		if !seen[k] {
			seen[k] = true
			out = append(out, ip)
		}
	}
	return out
}

// validDNSName is a conservative RFC 1123 hostname check: labels of
// letters/digits/hyphen, 1-63 chars, no leading/trailing hyphen, total <=253.
func validDNSName(s string) bool {
	if s == "" || len(s) > 253 {
		return false
	}
	for _, label := range strings.Split(s, ".") {
		if label == "" || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, r := range label {
			ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-'
			if !ok {
				return false
			}
		}
	}
	return true
}
