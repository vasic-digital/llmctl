package registry

import (
	"bytes"
	"context"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"
)

// regWith returns a Registry whose process checks are injected: every pid "runs" its token and has the fingerprint
// "fp:<pid>" (a real procfs is not needed to test the registry's own logic).
func regWith(t *testing.T) *Registry {
	t.Helper()
	r := New(testCfg(t))
	r.Identity = func(int, string) bool { return true }
	r.Fingerprint = func(pid int) string { return "fp:" + itoa(pid) }
	return r
}

func itoa(n int) string { return strconv.Itoa(n) }

func regRow(t *testing.T, r *Registry, name string, pid int) {
	t.Helper()
	if err := r.Register(Entry{Name: name, Host: "127.0.0.1", Port: freePort(t), Protocol: "tcp", PID: pid, CmdToken: "tok"}); err != nil {
		t.Fatalf("register %s: %v", name, err)
	}
}

// ---- C2-03: the registry diff of one tenant must not report another tenant's rows ----------------------------

func TestC203DiffIsScopedToTheTenantsOwnRows(t *testing.T) {
	r := regWith(t)
	regRow(t, r, "acme--small", 5001)
	regRow(t, r, "other--small", 5002)
	regRow(t, r, "decide-gateway", 5003)
	live := []LiveService{{"acme--small", 5001}, {"decide-gateway", 5003}}

	// control (the reviewer's reproduction): without a scope, the other tenant's row is a false "row without a live service"
	d, err := r.Diff(live)
	if err != nil || len(d.RegistryOnly) != 1 || d.RegistryOnly[0] != "other--small" {
		t.Fatalf("control: the unscoped diff must show the other tenant's row (%+v, %v)", d, err)
	}
	// scoped to tenant acme (plus the shared gateway): clean
	d, err = r.DiffScoped(live, DiffScope{Prefix: "acme--", Include: []string{"decide-gateway"}})
	if err != nil || !d.Empty() {
		t.Fatalf("a tenant-scoped diff must not report another tenant's row: %+v %v", d, err)
	}
	// scoped diff still catches the tenant's OWN defects (not a blanket pass)
	d, _ = r.DiffScoped([]LiveService{{"decide-gateway", 5003}}, DiffScope{Prefix: "acme--", Include: []string{"decide-gateway"}})
	if len(d.RegistryOnly) != 1 || d.RegistryOnly[0] != "acme--small" {
		t.Fatalf("an own row without a live service must still be reported: %+v", d)
	}
	d, _ = r.DiffScoped([]LiveService{{"acme--small", 5001}, {"acme--big", 5009}, {"decide-gateway", 5003}}, DiffScope{Prefix: "acme--", Include: []string{"decide-gateway"}})
	if len(d.LiveOnly) != 1 || d.LiveOnly[0] != "acme--big" {
		t.Fatalf("an own live service without a row must still be reported: %+v", d)
	}
	// no tenant: rows named <tenant>--<profile> belong to tenants and are ignored
	d, _ = r.DiffScoped([]LiveService{{"decide-gateway", 5003}}, DiffScope{NoTenantRows: true})
	if !d.Empty() {
		t.Fatalf("without a tenant, tenant rows must be ignored: %+v", d)
	}
}

func TestC203CLIDiffPrefixAndInclude(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	r.Identity = func(int, string) bool { return true }
	r.Fingerprint = func(pid int) string { return "fp:" + itoa(pid) }
	regRow(t, r, "acme--small", 5001)
	regRow(t, r, "other--small", 5002)
	run := func(args ...string) (int, string) {
		var o, e bytes.Buffer
		rc := RunRegistry(append([]string{"diff"}, args...), func(k string) string {
			if k == "LLMCTL_STATE_DIR" {
				return cfg.StateDir
			}
			return ""
		}, &o, &e)
		return rc, o.String() + e.String()
	}
	if rc, out := run("--live", "acme--small=5001"); rc != ExitFailure || !strings.Contains(out, "other--small") {
		t.Fatalf("control: unscoped CLI diff must fail on the other tenant's row: %d %q", rc, out)
	}
	if rc, out := run("--live", "acme--small=5001", "--prefix", "acme--"); rc != ExitOK {
		t.Fatalf("--prefix acme-- must scope the diff to the tenant: %d %q", rc, out)
	}
}

// ---- C2-07: Register proves the process identity BEFORE it fingerprints --------------------------------------

func TestC207RegisterRefusesAPidThatIsNotYetTheProgram(t *testing.T) {
	r := New(testCfg(t))
	r.Identity = func(int, string) bool { return false } // the pid is still /bin/bash -c, not the engine
	fpCalls := 0
	r.Fingerprint = func(int) string { fpCalls++; return "fp:wrong-program" }
	err := r.Register(Entry{Name: "svc", Host: "127.0.0.1", Port: freePort(t), Protocol: "tcp", PID: 5001, CmdToken: "llama-server"})
	if err == nil {
		t.Fatal("Register must refuse a pid that does not (yet) run the registered program")
	}
	if _, ok := err.(*UsageError); !ok || !strings.Contains(err.Error(), "llama-server") {
		t.Fatalf("want a usage error naming the program, got %T %v", err, err)
	}
	if fpCalls != 0 {
		t.Fatalf("the fingerprint was taken %d time(s) of a pid whose identity is unproven (it would pin the wrong program)", fpCalls)
	}
	if l, _ := r.List(); len(l) != 0 {
		t.Fatalf("a refused registration left a row: %+v", l)
	}
}

// ---- C2-08: an undeterminable fingerprint fails CLOSED ---------------------------------------------------------

func TestC208UndeterminableFingerprintIsUnknownNeverTrusted(t *testing.T) {
	r := New(testCfg(t))
	r.Identity = func(int, string) bool { return true }
	fp := ""
	r.Fingerprint = func(int) string { return fp } // e.g. hidepid: stat unreadable
	ln := listener(t, freePort(t))
	e := Entry{Name: "svc", Host: "127.0.0.1", Port: tcpPort(ln), Protocol: "tcp", PID: 5001, CmdToken: "tok"}
	if err := r.Register(e); err != nil {
		t.Fatal(err)
	}
	got, _, _ := r.Get("svc")
	if got.ProcFP != FPUnavailable {
		t.Fatalf("an undeterminable fingerprint must be recorded as %q, not as 'none recorded' (%q)", FPUnavailable, got.ProcFP)
	}
	rep, err := r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Unknown) != 1 || !strings.Contains(rep.Unknown[0].Reason, "fingerprint") {
		t.Fatalf("the row must be reported unknown (fingerprint unavailable): %+v", rep)
	}
	if res, _ := r.Resolve(nil); len(res) != 0 {
		t.Fatalf("an unknown row must never be routable: %+v", res)
	}
	// retry: once the fingerprint can be determined it is ADOPTED and the row becomes healthy
	fp = "fp:5001"
	rep, err = r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if err != nil || len(rep.Healthy) != 1 {
		t.Fatalf("a later reconcile must adopt the fingerprint and mark the row healthy: %+v %v", rep, err)
	}
	got, _, _ = r.Get("svc")
	if got.ProcFP != "fp:5001" {
		t.Fatalf("fingerprint not adopted: %q", got.ProcFP)
	}
	// and from then on a CHANGED fingerprint is a different process
	fp = "fp:other"
	rep, _ = r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if len(rep.Removed) != 1 {
		t.Fatalf("after adoption a different fingerprint must remove the row: %+v", rep)
	}
}

// ---- C2-14: pruning an unknown row must not free the port of a LIVE process -------------------------------------

func TestC214PruneUnknownKeepsThePortHoldOfALiveProcess(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	cfg := testCfg(t)
	cfg.CACert = "" // no CA: the https row is unknown (and its process, this test binary, is alive)
	r := New(cfg)
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	r.Now = func() time.Time { return now }
	e := selfHTTPS(h, p)
	e.Name = "gw"
	if err := r.Register(e); err != nil {
		t.Fatal(err)
	}
	ports := NewPorts(cfg, func(string) string { return "" })
	// the hold was taken before the engine bound its port; write it directly (Allocate would refuse a port already bound)
	if err := ports.mutate(func(st *portState) error { st.Held["gw"] = heldPort{Port: p, At: now}; return nil }); err != nil {
		t.Fatalf("seed hold: %v", err)
	}
	opts := ReconcileOptions{PruneUnknownAfter: time.Hour}
	_, _ = r.Reconcile(context.Background(), opts)
	now = now.Add(2 * time.Hour)
	rep, err := r.Reconcile(context.Background(), opts)
	if err != nil || len(rep.Removed) != 1 {
		t.Fatalf("the unknown row must be pruned: %+v %v", rep, err)
	}
	held, _ := ports.Held()
	if held["gw"] != p {
		t.Fatalf("pruning the row released the port hold of a process that still listens on %d (held=%v)", p, held)
	}
	// control: a row removed because its PROCESS is gone does release the hold (not a blanket keep)
	e2 := Entry{Name: "dead", Host: "127.0.0.1", Port: freePort(t), Protocol: "tcp", PID: 5001, CmdToken: "tok"}
	r.Identity = func(int, string) bool { return true }
	r.Fingerprint = func(int) string { return "fp:5001" }
	if err := r.Register(e2); err != nil {
		t.Fatal(err)
	}
	if err := ports.mutate(func(st *portState) error { st.Held["dead"] = heldPort{Port: e2.Port, At: now}; return nil }); err != nil {
		t.Fatal(err)
	}
	r.Identity = func(pid int, tok string) bool { return pid != 5001 }
	if _, err := r.Reconcile(context.Background(), ReconcileOptions{}); err != nil {
		t.Fatal(err)
	}
	if held, _ := ports.Held(); held["dead"] != 0 {
		t.Fatalf("a gone process must release its hold: %v", held)
	}
}

func tcpPort(ln net.Listener) int { return ln.Addr().(*net.TCPAddr).Port }
