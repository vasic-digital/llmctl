package registry

import (
	"context"
	"strings"
	"testing"
	"time"

	"digital.vasic.containers/pkg/serviceregistry"
)

// ---- C3-02: a row whose fingerprint is unavailable must never be routable, not even before the first Reconcile -----

func TestC302UnavailableFingerprintIsNotRoutableRightAfterRegister(t *testing.T) {
	r := New(testCfg(t))
	r.Identity = func(int, string) bool { return true }
	fp := ""
	r.Fingerprint = func(int) string { return fp } // procfs hides /proc/<pid>/stat from this user
	ln := listener(t, freePort(t))
	if err := r.Register(Entry{Name: "svc", Host: "127.0.0.1", Port: tcpPort(ln), Protocol: "tcp", PID: 5001, CmdToken: "tok"}); err != nil {
		t.Fatal(err)
	}
	// NO Reconcile has run: the window the reviewer measured (Healthy=true, routable until the first pass)
	if res, err := r.Resolve(nil); err != nil || len(res) != 0 {
		t.Fatalf("a row with an unavailable fingerprint must not be routable between Register and the first Reconcile: %+v %v", res, err)
	}
	got, _, _ := r.Get("svc")
	if got.Healthy || got.UnknownSince.IsZero() {
		t.Fatalf("the row must be recorded unknown (Healthy=false, UnknownSince set): %+v", got)
	}
	// control: once the fingerprint is determinable a Reconcile adopts it and the row becomes routable
	fp = "fp:5001"
	if _, err := r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute}); err != nil {
		t.Fatal(err)
	}
	if res, _ := r.Resolve(nil); len(res) != 1 {
		t.Fatalf("control: after the fingerprint was adopted the row must be routable: %+v", res)
	}
	// a normal registration (fingerprint available) is routable immediately (not a blanket refusal)
	r2 := regWith(t)
	regRow(t, r2, "ok", 5002)
	if res, _ := r2.Resolve(nil); len(res) != 1 {
		t.Fatalf("control: a row with a fingerprint must be routable right after Register: %+v", res)
	}
}

func TestC302ResolveNeverReturnsAnUnavailableFingerprintRowEvenIfStoredHealthy(t *testing.T) {
	r := regWith(t)
	regRow(t, r, "legacy", 5003)
	// a row written by an older build: Healthy=true with the unavailable marker
	err := r.write(func(sr *serviceregistry.ServiceRegistry) error {
		s, _ := sr.Get("legacy")
		e := fromService(*s)
		e.ProcFP, e.Healthy = FPUnavailable, true
		return put(sr, e)
	})
	if err != nil {
		t.Fatal(err)
	}
	if res, _ := r.Resolve(nil); len(res) != 0 {
		t.Fatalf("Resolve must treat the unavailable-fingerprint marker as not routable on its own: %+v", res)
	}
}

// ---- C3-08: the row-name grammar: "<tenant>--<profile>", neither side holding "--" nor touching the separator ---------

func TestC308RegisterRefusesAmbiguousRowNames(t *testing.T) {
	r := regWith(t)
	bad := []string{"acme---small", "acme--eu--small", "a--b--c", "acme--", "x--", "acme---", "--x"}
	for i, n := range bad {
		err := r.Register(Entry{Name: n, Host: "127.0.0.1", Port: freePort(t), Protocol: "tcp", PID: 6000 + i, CmdToken: "tok"})
		if _, ok := err.(*UsageError); !ok || !strings.Contains(err.Error(), "--") {
			t.Errorf("name %q must be refused as ambiguous (usage error naming the grammar), got %v", n, err)
		}
	}
	for i, n := range []string{"acme--small", "acme-eu--small", "decide-gateway", "qwen-7b-q4", "a.b--c_d", "x"} {
		if err := r.Register(Entry{Name: n, Host: "127.0.0.1", Port: freePort(t), Protocol: "tcp", PID: 6100 + i, CmdToken: "tok"}); err != nil {
			t.Errorf("control: well-formed name %q must be accepted: %v", n, err)
		}
	}
}

// rows an OLDER build may have written (it accepted any name): they must not leak across tenants
func injectLegacy(t *testing.T, r *Registry, name string, pid int) {
	t.Helper()
	e := Entry{Name: name, Host: "127.0.0.1", Port: freePort(t), Protocol: "tcp", PID: pid, CmdToken: "tok", Healthy: true, ProcFP: "fp:x", Started: time.Now()}
	if err := r.write(func(sr *serviceregistry.ServiceRegistry) error { return put(sr, e) }); err != nil {
		t.Fatal(err)
	}
}

func TestC308TenantScopeNeverLeaksAcrossNeighbouringTenants(t *testing.T) {
	r := regWith(t)
	regRow(t, r, "acme--small", 5001)
	regRow(t, r, "acme-eu--small", 5002)
	injectLegacy(t, r, "acme---small", 5003)    // tenant "acme-" of an older build
	injectLegacy(t, r, "acme--eu--small", 5004) // tenant "acme--eu"
	scope := DiffScope{Prefix: "acme--"}
	d, err := r.DiffScoped([]LiveService{{"acme--small", 5001}}, scope)
	if err != nil || !d.Empty() {
		t.Fatalf("tenant acme's diff must not report neighbouring tenants' rows (acme-eu, acme-, acme--eu): %+v %v", d, err)
	}
	d, _ = r.DiffScoped([]LiveService{{"acme-eu--small", 5002}}, DiffScope{Prefix: "acme-eu--"})
	if !d.Empty() {
		t.Fatalf("tenant acme-eu's diff must be clean: %+v", d)
	}
	// control: the tenant's OWN missing row is still reported
	d, _ = r.DiffScoped(nil, scope)
	if len(d.RegistryOnly) != 1 || d.RegistryOnly[0] != "acme--small" {
		t.Fatalf("control: an own row without a live service must still be reported: %+v", d)
	}
}

func TestC308NoTenantScopeKeepsAmbiguousRowsVisible(t *testing.T) {
	r := regWith(t)
	regRow(t, r, "acme--small", 5001)
	regRow(t, r, "decide-gateway", 5005)
	injectLegacy(t, r, "qwen--7b--x", 5006) // not a well-formed tenant row: must NOT be silently dropped
	d, _ := r.DiffScoped([]LiveService{{"decide-gateway", 5005}}, DiffScope{NoTenantRows: true})
	if len(d.RegistryOnly) != 1 || d.RegistryOnly[0] != "qwen--7b--x" {
		t.Fatalf("a non-tenant scope drops well-formed tenant rows only; the malformed row must be reported: %+v", d)
	}
}

// ---- C3-15 (G5): the live side of DiffScoped is scoped too --------------------------------------------------------

func TestC315DiffScopedFiltersTheLiveSideToo(t *testing.T) {
	r := regWith(t)
	regRow(t, r, "acme--small", 5001)
	d, _ := r.DiffScoped([]LiveService{{"acme--small", 5001}, {"other--big", 5009}}, DiffScope{Prefix: "acme--"})
	if !d.Empty() {
		t.Fatalf("another tenant's live service is not this scope's LiveOnly: %+v", d)
	}
	d, _ = r.DiffScoped([]LiveService{{"acme--small", 5001}, {"acme--big", 5009}}, DiffScope{Prefix: "acme--"})
	if len(d.LiveOnly) != 1 || d.LiveOnly[0] != "acme--big" {
		t.Fatalf("control: an own live service without a row is reported: %+v", d)
	}
}
