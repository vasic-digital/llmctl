package client

import (
	"net"
	"strings"
	"testing"
)

// A name-resolution failure is not "unreachable": the operator must be told the NAME did not
// resolve, and for .local names (mDNS) that a static CGO_ENABLED=0 binary cannot use nss-mdns.
func TestClassifyTransportNameResolutionFailure(t *testing.T) {
	err := &net.OpError{Op: "dial", Net: "tcp", Err: &net.DNSError{Err: "no such host", Name: "nezha.local", IsNotFound: true}}
	e := classifyTransport(err)
	if e.Kind != KindUnreachable {
		t.Fatalf("kind = %v, want KindUnreachable", e.Kind)
	}
	for _, want := range []string{"name did not resolve", "mDNS", "CGO_ENABLED=0", "IP address"} {
		if !strings.Contains(e.Msg, want) {
			t.Errorf("message %q lacks %q", e.Msg, want)
		}
	}
	plain := classifyTransport(&net.OpError{Op: "dial", Err: &net.DNSError{Err: "no such host", Name: "gw.example", IsNotFound: true}})
	if !strings.Contains(plain.Msg, "name did not resolve") || strings.Contains(plain.Msg, "mDNS") {
		t.Errorf("non-.local message wrong: %q", plain.Msg)
	}
}
