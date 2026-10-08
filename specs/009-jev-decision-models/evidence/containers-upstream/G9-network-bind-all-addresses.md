# Containers upstream change G9 - `network.isPortAvailable` must test every local address

Target repository: `vasic-digital/Containers`, package `pkg/network`.
Pinned base: `4a8f04e05f3535d77c48f69b89687f9fcc896fbf` (the submodule was NOT edited - FR-091).
Register rows: llmctl G-007 (gap-fix pass B/W3), Containers gap G9 in `../containers-gaps.md`.

## Problem (measured)

`isPortAvailable` binds `127.0.0.1:<port>` only. A listener on one specific address
(`192.168.x.y:<port>`) does not conflict with that bind, so `PortAllocator.Allocate` hands the port out and
a service that binds the wildcard then fails. llmctl reproduced this on its LAN address
(`internal/registry` test `TestBindTestDetectsListenerOnLANAddress`, host interface enp5s0).

## Change

`isPortAvailable` keeps the loopback bind, then also binds `0.0.0.0`, `::` and every unicast interface
address. Only EADDRINUSE / EACCES mean "taken"; an address the host cannot bind (EADDRNOTAVAIL, family
unsupported) is skipped, so IPv4-only hosts and containers behave as before. The address list is a package
variable so tests can inject it.

Verified against a throw-away copy of the submodule: new tests (listener on 0.0.0.0, 127.0.0.1 and the LAN
address are all seen; an unassignable TEST-NET address does not make a free port look taken) and the package's
existing tests pass with `-race`.

llmctl's `internal/registry/ports.go` (`bindTest`, `localBindAddrs`, and the extra `bindTest` in
`pickFromRange`) is the workaround; delete it when this lands.

## Patch (unified diff, apply with `patch -p1` at the repository root)

```diff
diff -ruN a/pkg/network/bind_all_addresses_test.go b/pkg/network/bind_all_addresses_test.go
--- a/pkg/network/bind_all_addresses_test.go	1970-01-01 01:00:00.000000000 +0100
+++ b/pkg/network/bind_all_addresses_test.go	2026-10-07 18:53:02.965290448 +0200
@@ -0,0 +1,48 @@
+package network
+
+import (
+	"net"
+	"testing"
+)
+
+func TestIsPortAvailableSeesWildcardAndLANListeners(t *testing.T) {
+	for _, addr := range append([]string{"0.0.0.0", "127.0.0.1"}, lanIPv4s()...) {
+		ln, err := net.Listen("tcp", net.JoinHostPort(addr, "0"))
+		if err != nil {
+			t.Fatalf("listen %s: %v", addr, err)
+		}
+		port := ln.Addr().(*net.TCPAddr).Port
+		if isPortAvailable(port) {
+			t.Errorf("port %d is held by a listener on %s but reported free", port, addr)
+		}
+		ln.Close()
+		if !isPortAvailable(port) {
+			t.Errorf("port %d is free again but reported taken", port)
+		}
+	}
+}
+
+func TestIsPortAvailableIgnoresUnassignableAddresses(t *testing.T) {
+	old := localBindAddrs
+	localBindAddrs = func() []string { return []string{"203.0.113.77"} } // TEST-NET-3, never local
+	defer func() { localBindAddrs = old }()
+	ln, _ := net.Listen("tcp", "127.0.0.1:0")
+	port := ln.Addr().(*net.TCPAddr).Port
+	ln.Close()
+	if !isPortAvailable(port) {
+		t.Fatal("an address this host does not own must not make a free port look taken")
+	}
+}
+
+func lanIPv4s() []string {
+	var out []string
+	as, _ := net.InterfaceAddrs()
+	for _, a := range as {
+		if ipn, ok := a.(*net.IPNet); ok {
+			if ip := ipn.IP.To4(); ip != nil && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() {
+				out = append(out, ip.String())
+			}
+		}
+	}
+	return out
+}
diff -ruN a/pkg/network/port_allocator.go b/pkg/network/port_allocator.go
--- a/pkg/network/port_allocator.go	2026-10-07 18:52:37.123723850 +0200
+++ b/pkg/network/port_allocator.go	2026-10-07 18:52:48.299375776 +0200
@@ -1,9 +1,12 @@
 package network
 
 import (
+	"errors"
 	"fmt"
 	"net"
+	"strconv"
 	"sync"
+	"syscall"
 	"time"
 )
 
@@ -124,15 +127,48 @@
 	a.next = a.start
 }
 
-// isPortAvailable checks if a TCP port is free by attempting to
-// listen on it.
+// isPortAvailable checks if a TCP port is free by attempting to listen on it on 127.0.0.1,
+// on the IPv4/IPv6 wildcards and on every unicast address of every local interface. A listener
+// bound to one specific address (e.g. 192.168.1.5:P) does not conflict with a 127.0.0.1 bind, so
+// testing loopback alone hands out a port that fails when the service binds a wildcard.
+// Only a conflict (address in use / permission denied) means "taken"; an address this host cannot
+// bind (not assigned, family unsupported) says nothing about the port and is skipped.
 func isPortAvailable(port int) bool {
-	ln, err := net.Listen("tcp",
-		fmt.Sprintf("127.0.0.1:%d", port),
-	)
+	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
 	if err != nil {
 		return false
 	}
 	_ = ln.Close()
+	for _, addr := range localBindAddrs() {
+		l, err := net.Listen("tcp", net.JoinHostPort(addr, strconv.Itoa(port)))
+		if err == nil {
+			_ = l.Close()
+			continue
+		}
+		if errors.Is(err, syscall.EADDRINUSE) || errors.Is(err, syscall.EACCES) {
+			return false
+		}
+	}
 	return true
 }
+
+// localBindAddrs lists the wildcards and the unicast addresses of the local interfaces
+// (a variable so tests can inject).
+var localBindAddrs = func() []string {
+	out := []string{"0.0.0.0", "::"}
+	as, err := net.InterfaceAddrs()
+	if err != nil {
+		return out
+	}
+	for _, a := range as {
+		ipn, ok := a.(*net.IPNet)
+		if !ok || ipn.IP.IsLoopback() || ipn.IP.IsMulticast() {
+			continue
+		}
+		if ipn.IP.To4() == nil && ipn.IP.IsLinkLocalUnicast() {
+			continue // needs a zone to bind
+		}
+		out = append(out, ipn.IP.String())
+	}
+	return out
+}
```
