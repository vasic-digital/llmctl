package registry

import (
	"fmt"
	"net"
	"testing"
)

// lanAddr returns a non-loopback IPv4 address of this host, or "".
func lanAddr(t *testing.T) string {
	t.Helper()
	as, err := net.InterfaceAddrs()
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range as {
		if ipn, ok := a.(*net.IPNet); ok {
			if ip4 := ipn.IP.To4(); ip4 != nil && !ip4.IsLoopback() && !ip4.IsLinkLocalUnicast() {
				return ip4.String()
			}
		}
	}
	return ""
}

func listenOn(t *testing.T, addr string) (net.Listener, int) {
	t.Helper()
	ln, err := net.Listen("tcp", net.JoinHostPort(addr, "0"))
	if err != nil {
		t.Fatalf("listen %s: %v", addr, err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln, ln.Addr().(*net.TCPAddr).Port
}

// G-007: the bind test must see a listener on ANY address of the host, not only 127.0.0.1.
func TestBindTestDetectsListenerOnLANAddress(t *testing.T) {
	lan := lanAddr(t)
	if lan == "" {
		t.Skip("this host has no non-loopback IPv4 address; the LAN case cannot be exercised here")
	}
	_, port := listenOn(t, lan)
	if err := bindTest(port); err == nil {
		t.Fatalf("port %d is held by a listener on %s but bindTest said it is free", port, lan)
	}
}

func TestBindTestDetectsListenerOnWildcard(t *testing.T) {
	_, port := listenOn(t, "0.0.0.0")
	if err := bindTest(port); err == nil {
		t.Fatalf("port %d is held by a wildcard listener but bindTest said it is free", port)
	}
}

func TestBindTestDetectsListenerOnLoopback(t *testing.T) {
	_, port := listenOn(t, "127.0.0.1")
	if err := bindTest(port); err == nil {
		t.Fatal("loopback listener not detected")
	}
}

func TestBindTestDetectsListenerOnIPv6Wildcard(t *testing.T) {
	ln, err := net.Listen("tcp", "[::]:0")
	if err != nil {
		t.Skipf("no IPv6 on this host: %v", err)
	}
	defer ln.Close()
	if err := bindTest(ln.Addr().(*net.TCPAddr).Port); err == nil {
		t.Fatal("IPv6 wildcard listener not detected")
	}
}

func TestBindTestFreePortPasses(t *testing.T) {
	ln, port := listenOn(t, "127.0.0.1")
	ln.Close()
	if err := bindTest(port); err != nil {
		t.Fatalf("a free port must pass: %v", err)
	}
}

func TestBindTestRangeCheck(t *testing.T) {
	for _, p := range []int{0, -1, 65536} {
		if bindTest(p) == nil {
			t.Errorf("port %d must be rejected", p)
		}
	}
}

// An address that is not assigned to this host (EADDRNOTAVAIL) says nothing about the port:
// it must be skipped, not treated as "taken".
func TestBindTestIgnoresAddressesNotOnThisHost(t *testing.T) {
	old := localBindAddrs
	localBindAddrs = func() []string { return []string{"203.0.113.77"} } // TEST-NET-3, never local
	defer func() { localBindAddrs = old }()
	ln, port := listenOn(t, "127.0.0.1")
	ln.Close()
	if err := bindTest(port); err != nil {
		t.Fatalf("unassignable address must not make a free port look taken: %v", err)
	}
}

// The allocator must therefore never hand out a port a LAN-address listener holds.
func TestAllocateSkipsPortHeldOnLANAddress(t *testing.T) {
	lan := lanAddr(t)
	if lan == "" {
		t.Skip("no non-loopback IPv4 address on this host")
	}
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	lo, hi := freePortBlock(t, 4)
	cfg.RangeLo, cfg.RangeHi = lo, hi
	ln, err := net.Listen("tcp", fmt.Sprintf("%s:%d", lan, lo))
	if err != nil {
		t.Skipf("cannot hold %s:%d: %v", lan, lo, err)
	}
	defer ln.Close()
	res, err := NewPorts(cfg, noEnv).Allocate(PortRequest{Name: "svc"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Port == lo {
		t.Fatalf("allocator handed out %d, which %s is listening on", lo, lan)
	}
}
