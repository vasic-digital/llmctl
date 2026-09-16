package replication

import (
	"net"
	"net/http"
	"testing"
	"time"
)

// TestLag_ZeroWhenCaughtUp proves a replica that has genuinely
// acknowledged every forwarded append reports Lag=0 (SC-002/SC-005:
// "every reported 'caught up' state is real") - fed EXCLUSIVELY through
// forwarder.go's real ForwardAppend call (T008's existing forwarding-
// acknowledgment traffic: a real HTTP 200 response from a replica's own
// /v1/replication/append route), never a hand-fed LagTracker call - this
// test also proves lag.go is genuinely wired FROM forwarder.go rather
// than fed by an independent, parallel mechanism (T018's own task text:
// "updated from real forwarding-acknowledgment traffic (T008)").
func TestLag_ZeroWhenCaughtUp(t *testing.T) {
	baseURL, _, _ := startForwardTargetServer(t) // always answers 200 OK

	roles := RoleResolver(func(string) (string, []string, bool) {
		return "node-a", []string{"node-a", "node-b"}, true
	})
	addrs := AddrResolver(func(string) (string, bool) { return baseURL, true })

	fwd := NewForwarder("node-a", roles, addrs, http.DefaultClient)
	if err := fwd.ForwardAppend("tenant-a", fixtureAuthToken, []WALEntry{{Seq: 1}, {Seq: 2}}); err != nil {
		t.Fatalf("ForwardAppend: unexpected error %v", err)
	}

	rec, ok := fwd.LagTracker().Lag("tenant-a", "node-b")
	if !ok {
		t.Fatalf("expected a recorded lag entry for node-b after a real forward attempt")
	}
	if rec.Lag != 0 {
		t.Fatalf("Lag = %d, want 0 (fully caught up): record=%+v", rec.Lag, rec)
	}
	if rec.PrimarySeq != 2 || rec.LastConfirmedSeq != 2 {
		t.Fatalf("record = %+v, want PrimarySeq=2 LastConfirmedSeq=2", rec)
	}
	if rec.TenantID != "tenant-a" || rec.ReplicaNodeID != "node-b" {
		t.Fatalf("record = %+v, want TenantID=tenant-a ReplicaNodeID=node-b", rec)
	}
}

// TestLag_ReflectsRealGapWhenBehind proves a replica that genuinely fails
// to acknowledge a forwarded append (a real, closed TCP listener - not a
// mock - matching TestForwarder_UnreachableReplica_BoundedNotIndefinite's
// own real-network-failure convention) shows a real, non-zero Lag equal
// to exactly how far behind it is - spec.md's Edge Cases: "the replica's
// lag must become visible ... rather than silently dropped."
func TestLag_ReflectsRealGapWhenBehind(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen: %v", err)
	}
	deadAddr := "http://" + ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatalf("close listener: %v", err)
	}

	roles := RoleResolver(func(string) (string, []string, bool) {
		return "node-a", []string{"node-b"}, true
	})
	addrs := AddrResolver(func(string) (string, bool) { return deadAddr, true })

	fwd := NewForwarder("node-a", roles, addrs, &http.Client{Timeout: 500 * time.Millisecond})
	entries := []WALEntry{{Seq: 1}, {Seq: 2}, {Seq: 3}, {Seq: 4}, {Seq: 5}}
	if err := fwd.ForwardAppend("tenant-a", fixtureAuthToken, entries); err == nil {
		t.Fatalf("ForwardAppend to a genuinely unreachable replica: expected an error, got nil")
	}

	rec, ok := fwd.LagTracker().Lag("tenant-a", "node-b")
	if !ok {
		t.Fatalf("expected a recorded lag entry for node-b even though its forward attempt failed (FR-010: lag must be visible, never silently dropped)")
	}
	if rec.PrimarySeq != 5 {
		t.Fatalf("PrimarySeq = %d, want 5 (the primary's own current highest Seq, even though forwarding it failed)", rec.PrimarySeq)
	}
	if rec.LastConfirmedSeq != 0 {
		t.Fatalf("LastConfirmedSeq = %d, want 0 (nothing was ever genuinely acknowledged)", rec.LastConfirmedSeq)
	}
	if rec.Lag != 5 {
		t.Fatalf("Lag = %d, want 5 (PrimarySeq=5 - LastConfirmedSeq=0): record=%+v", rec.Lag, rec)
	}

	// TenantLag must surface the SAME record for the tenant's replica set.
	all := fwd.LagTracker().TenantLag("tenant-a")
	if len(all) != 1 || all[0].ReplicaNodeID != "node-b" || all[0].Lag != 5 {
		t.Fatalf("TenantLag(%q) = %+v, want exactly one record for node-b with Lag=5", "tenant-a", all)
	}
}
