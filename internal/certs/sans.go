package certs

import (
	"context"
	"net"
	"net/netip"
	"os"
	"regexp"
	"strings"
	"time"
)

// permittedNets are the CA name-constraint IP ranges (FR-066): loopback, RFC 1918,
// ULA and the CGNAT / overlay range.
var permittedNets = []string{
	"127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7", "100.64.0.0/10",
}

var labelRE = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$`)

// inputs are the resolved names, addresses and constraint switch of one call.
type inputs struct {
	extraDNS, extraIPs []string
	hostnames, addrs   []string
	constrained        bool
}

func resolveInputs(o Options) (inputs, error) {
	spec := o.SANs
	if spec == "" {
		spec = o.getenv("LLMCTL_TLS_SAN")
	}
	d, i, err := ParseExtraSANs(spec)
	if err != nil {
		return inputs{}, err
	}
	in := inputs{extraDNS: d, extraIPs: i, hostnames: o.Hostnames, addrs: o.Addresses}
	if in.hostnames == nil {
		in.hostnames = DetectHostnames()
	}
	if in.addrs == nil {
		in.addrs = DetectAddresses()
	}
	in.constrained = !o.NoConstraints
	switch strings.ToLower(strings.TrimSpace(o.getenv("LLMCTL_CA_NAME_CONSTRAINTS"))) {
	case "off", "0", "false", "no":
		in.constrained = false
	}
	return in, nil
}

// ParseExtraSANs parses "dns:a.example,ip:1.2.3.4" (LLMCTL_TLS_SAN syntax).
func ParseExtraSANs(spec string) (dns, ips []string, err error) {
	for _, it := range strings.Split(spec, ",") {
		it = strings.TrimSpace(it)
		if it == "" {
			continue
		}
		kind, val, _ := strings.Cut(it, ":")
		switch strings.ToLower(kind) {
		case "dns":
			v := strings.ToLower(val)
			if v == "" || !labelRE.MatchString(v) {
				return nil, nil, errf("invalid LLMCTL_TLS_SAN item %q (use dns:NAME or ip:ADDR)", it)
			}
			dns = append(dns, v)
		case "ip":
			a, perr := netip.ParseAddr(strings.TrimSpace(val))
			if perr != nil || a.Zone() != "" {
				return nil, nil, errf("invalid IP address in LLMCTL_TLS_SAN item %q", it)
			}
			ips = append(ips, a.Unmap().String())
		default:
			return nil, nil, errf("invalid LLMCTL_TLS_SAN item %q (use dns:NAME or ip:ADDR)", it)
		}
	}
	return dns, ips, nil
}

// DetectHostnames returns the host name and, when resolvable quickly, its FQDN.
func DetectHostnames() []string {
	var names []string
	add := func(n string) {
		n = strings.TrimRight(strings.ToLower(strings.TrimSpace(n)), ".")
		if n != "" && n != "localhost" && labelRE.MatchString(n) && !containsStr(names, n) {
			names = append(names, n)
		}
	}
	h, err := os.Hostname()
	if err == nil {
		add(h)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if cn, err := net.DefaultResolver.LookupCNAME(ctx, h); err == nil {
			add(cn)
		}
	}
	return names
}

// DetectAddresses returns the interface addresses worth putting in a server
// certificate (loopback, link-local, unspecified and multicast are skipped).
func DetectAddresses() []string {
	var out []string
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		ipn, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		ad, ok := netip.AddrFromSlice(ipn.IP)
		if !ok {
			continue
		}
		ad = ad.Unmap()
		if ad.IsLoopback() || ad.IsLinkLocalUnicast() || ad.IsLinkLocalMulticast() || ad.IsUnspecified() || ad.IsMulticast() {
			continue
		}
		if s := ad.String(); !containsStr(out, s) {
			out = append(out, s)
		}
	}
	return out
}

func permitted(extraIPs []string) []netip.Prefix {
	var nets []netip.Prefix
	for _, n := range permittedNets {
		nets = append(nets, netip.MustParsePrefix(n))
	}
	for _, ip := range extraIPs {
		a := netip.MustParseAddr(ip)
		nets = append(nets, netip.PrefixFrom(a, a.BitLen()))
	}
	return nets
}

func ipPermitted(a netip.Addr, nets []netip.Prefix) bool {
	for _, n := range nets {
		if n.Addr().Is4() == a.Is4() && n.Contains(a) {
			return true
		}
	}
	return false
}

// desiredSANs returns the DNS names, IP addresses and warnings for a leaf.
// Host names lead; localhost, 127.0.0.1 and ::1 are always present. Under name
// constraints, addresses the CA could not sign are left out with a warning.
func desiredSANs(in inputs) (dns, ips, warnings []string) {
	for _, n := range in.hostnames {
		n = strings.ToLower(n)
		if n != "localhost" && !containsStr(dns, n) {
			dns = append(dns, n)
		}
	}
	dns = append(dns, "localhost")
	for _, n := range in.extraDNS {
		if !containsStr(dns, n) {
			dns = append(dns, n)
		}
	}
	ips = []string{"127.0.0.1", "::1"}
	nets := permitted(in.extraIPs)
	for _, s := range append(append([]string{}, in.addrs...), in.extraIPs...) {
		a, err := netip.ParseAddr(s)
		if err != nil {
			continue
		}
		s = a.Unmap().String()
		if containsStr(ips, s) {
			continue
		}
		if in.constrained && !ipPermitted(a.Unmap(), nets) {
			warnings = append(warnings, "address "+s+" is outside the CA name constraints and was left out of the "+
				"certificate (add it via LLMCTL_TLS_SAN before the CA is created, or set LLMCTL_CA_NAME_CONSTRAINTS=off)")
			continue
		}
		ips = append(ips, s)
	}
	return dns, ips, warnings
}
