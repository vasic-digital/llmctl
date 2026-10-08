package certs

import (
	"errors"
	"net"
	"net/netip"
	"testing"
)

func ipv4(a, b, c, d byte) net.IP { return net.IPv4(a, b, c, d).To4() }

func parseIP(t *testing.T, s string) net.IP {
	t.Helper()
	a, err := netip.ParseAddr(s)
	if err != nil {
		t.Fatalf("bad ip %q: %v", s, err)
	}
	return net.IP(a.AsSlice())
}

func asError(err error, target **Error) bool { return errors.As(err, target) }
