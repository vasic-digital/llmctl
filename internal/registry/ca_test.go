package registry

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// selfHTTPS is an https entry whose process (this test binary) is alive, so only the CA decides.
func selfHTTPS(host string, port int) Entry {
	e := httpsEntry(host, port, "/health")
	e.PID, e.CmdToken = os.Getpid(), filepath.Base(os.Args[0])
	return e
}

func reconcileOnce(t *testing.T, r *Registry, grace time.Duration) ReconcileReport {
	t.Helper()
	rep, err := r.Reconcile(context.Background(), ReconcileOptions{Grace: grace})
	if err != nil {
		t.Fatal(err)
	}
	return rep
}

func TestResolveCA(t *testing.T) {
	cases := map[string]struct {
		env  map[string]string
		want string
	}{
		"explicit wins":         {map[string]string{"HOME": "/h", "LLMCTL_HOME": "/lh", "LLMCTL_CACERT": "/c/ca.crt"}, "/c/ca.crt"},
		"LLMCTL_HOME":           {map[string]string{"HOME": "/h", "LLMCTL_HOME": "/lh"}, "/lh/cert/ca/ca.crt"},
		"HOME default":          {map[string]string{"HOME": "/h"}, "/h/llmctl/cert/ca/ca.crt"},
		"nothing":               {map[string]string{}, ""},
		"non-default home only": {map[string]string{"HOME": "/h", "LLMCTL_HOME": "/srv/other"}, "/srv/other/cert/ca/ca.crt"},
	}
	for name, tc := range cases {
		if got := ResolveCA(func(k string) string { return tc.env[k] }); got != tc.want {
			t.Errorf("%s: %q want %q", name, got, tc.want)
		}
	}
}

// G-068, the observed failure: the reconciling process has no LLMCTL_CACERT (and its home is not
// the gateway's) - the https row was REMOVED as unhealthy-by-TLS. It must be kept, flagged unknown.
func TestReconcileWithoutCAKeepsHTTPSRowUnknown(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	for name, ca := range map[string]string{"unset": "", "missing file": "/nonexistent/other-home/ca.crt"} {
		cfg := testCfg(t)
		cfg.CACert = ca
		r := New(cfg)
		if err := r.Register(selfHTTPS(h, p)); err != nil {
			t.Fatal(err)
		}
		for i := 0; i < 3; i++ { // grace 0: a real failure would be removed at the first pass
			rep := reconcileOnce(t, r, 0)
			if len(rep.Removed) != 0 {
				t.Fatalf("%s pass %d: the https row must not be removed: %+v", name, i, rep.Removed)
			}
			if len(rep.Unknown) != 1 || rep.Unknown[0].Name != "gw" || !strings.Contains(rep.Unknown[0].Reason, "CA not found: set LLMCTL_CACERT") {
				t.Fatalf("%s pass %d: want gw reported unknown with the CA hint: %+v", name, i, rep)
			}
			if len(rep.Healthy)+len(rep.Unhealthy) != 0 {
				t.Fatalf("%s: unknown is neither healthy nor unhealthy: %+v", name, rep)
			}
		}
		e, ok, _ := r.Get("gw")
		if !ok || e.Healthy || !e.UnhealthySince.IsZero() {
			t.Fatalf("%s: row must stay, not routable, no unhealthy clock: ok=%v %+v", name, ok, e)
		}
		// the CA turns up: the same row becomes healthy again
		cfg.CACert = pki.writeCA(t)
		if rep := reconcileOnce(t, New(cfg), 0); len(rep.Healthy) != 1 {
			t.Fatalf("%s: with the CA the row must be healthy: %+v", name, rep)
		}
	}
}

// a CA that IS found but does not verify the server is still a real failure (not "unknown")
func TestReconcileWrongCAStillRemoves(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	other := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	cfg := testCfg(t)
	cfg.CACert = other.writeCA(t)
	r := New(cfg)
	_ = r.Register(selfHTTPS(h, p))
	rep := reconcileOnce(t, r, 0)
	if len(rep.Removed) != 1 || len(rep.Unknown) != 0 {
		t.Fatalf("wrong CA = failed handshake = removed: %+v", rep)
	}
}

// the entry's ca_file label lets an env-less reconciler verify against the gateway's CA
func TestReconcilePrefersTrustedCAFileLabel(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	other := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	good := pki.writeCA(t)

	for name, cfgCA := range map[string]string{"no env CA": "", "env CA is the wrong one": other.writeCA(t)} {
		cfg := testCfg(t)
		cfg.CACert = cfgCA
		r := New(cfg)
		e := selfHTTPS(h, p)
		e.Labels = map[string]string{LabelCAFile: good}
		if err := r.Register(e); err != nil {
			t.Fatal(err)
		}
		if rep := reconcileOnce(t, r, 0); len(rep.Healthy) != 1 || len(rep.Removed)+len(rep.Unknown) != 0 {
			t.Fatalf("%s: the label CA must win: %+v", name, rep)
		}
	}
}

// the label is data any local process can write: only an owned, non-world-writable regular file counts
func TestCAFileLabelTrustRules(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)

	mk := func(mode os.FileMode) string {
		f := pki.writeCA(t)
		if err := os.Chmod(f, mode); err != nil {
			t.Fatal(err)
		}
		return f
	}
	run := func(label string) ReconcileReport {
		cfg := testCfg(t) // no env CA, so an ignored label leaves nothing -> unknown
		r := New(cfg)
		e := selfHTTPS(h, p)
		e.Labels = map[string]string{LabelCAFile: label}
		if err := r.Register(e); err != nil {
			t.Fatal(err)
		}
		return reconcileOnce(t, r, 0)
	}
	if rep := run(mk(0o644)); len(rep.Healthy) != 1 {
		t.Fatalf("owned 0644 file must be trusted: %+v", rep)
	}
	if rep := run(mk(0o600)); len(rep.Healthy) != 1 {
		t.Fatalf("owned 0600 file must be trusted: %+v", rep)
	}
	if rep := run(mk(0o666)); len(rep.Unknown) != 1 || len(rep.Healthy) != 0 {
		t.Fatalf("a world-writable label file must be ignored: %+v", rep)
	}
	rep := run(mk(0o646))
	if len(rep.Unknown) != 1 || !strings.Contains(rep.Unknown[0].Reason, "world-writable") {
		t.Fatalf("world-writable (0646) ignored with the reason named: %+v", rep)
	}
	if rep := run(t.TempDir()); len(rep.Unknown) != 1 { // a directory
		t.Fatalf("a directory is not a CA file: %+v", rep)
	}
	if rep := run("/nonexistent/ca.crt"); len(rep.Unknown) != 1 {
		t.Fatalf("a missing label file is ignored: %+v", rep)
	}
	// a file owned by someone else (the process uid stands in for another user)
	prev := currentUID
	currentUID = func() int { return prev() + 1 }
	defer func() { currentUID = prev }()
	rep = run(mk(0o644))
	if len(rep.Unknown) != 1 || !strings.Contains(rep.Unknown[0].Reason, "not owned") {
		t.Fatalf("a file owned by another user must be ignored: %+v", rep)
	}
}

// an ignored (untrusted) label falls back to the env CA
func TestUntrustedLabelFallsBackToEnvCA(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	bad := pki.writeCA(t)
	_ = os.Chmod(bad, 0o666)
	cfg := testCfg(t)
	cfg.CACert = pki.writeCA(t)
	r := New(cfg)
	e := selfHTTPS(h, p)
	e.Labels = map[string]string{LabelCAFile: bad}
	_ = r.Register(e)
	if rep := reconcileOnce(t, r, 0); len(rep.Healthy) != 1 {
		t.Fatalf("untrusted label -> env CA: %+v", rep)
	}
}

// CLI: a non-default home (the CA lives under it, LLMCTL_CACERT is unset) via --home / LLMCTL_HOME
func TestRegistryReconcileCLIHomeAndStrict(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	state := t.TempDir()
	home := t.TempDir()
	caDir := filepath.Join(home, "cert", "ca")
	if err := os.MkdirAll(caDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(caDir, "ca.crt"), pki.CAPEM, 0o644); err != nil {
		t.Fatal(err)
	}
	e := selfHTTPS(h, p)
	if err := New(Config{StateDir: state}).Register(e); err != nil {
		t.Fatal(err)
	}
	// the reconciling process's own home is somewhere else and has no CA
	env := map[string]string{"HOME": t.TempDir(), "LLMCTL_STATE_DIR": state}
	get := func(k string) string { return env[k] }
	run := func(args ...string) (int, string, string) {
		var o, er bytes.Buffer
		rc := RunRegistry(append([]string{"reconcile", "--grace", "0s"}, args...), get, &o, &er)
		return rc, o.String(), er.String()
	}

	rc, out, errs := run()
	if rc != 0 || !strings.Contains(out, "unknown gw: CA not found: set LLMCTL_CACERT") || strings.Contains(out, "removed gw") {
		t.Fatalf("default: row kept + CA hint, exit 0: rc=%d out=%q err=%q", rc, out, errs)
	}
	if rc, _, errs := run("--strict"); rc != 1 || !strings.Contains(errs, "CA not found: set LLMCTL_CACERT") {
		t.Fatalf("--strict must fail non-zero naming the CA: rc=%d err=%q", rc, errs)
	}
	if rc, out, _ := run("--strict", "--json"); rc != 1 || !strings.Contains(out, `"unknown"`) {
		t.Fatalf("--strict --json: rc=%d out=%q", rc, out)
	}
	if _, ok, _ := New(Config{StateDir: state}).Get("gw"); !ok {
		t.Fatal("the gateway row must still be there after four reconciles without a CA")
	}
	if rc, out, errs := run("--home", home); rc != 0 || !strings.Contains(out, "1 healthy") {
		t.Fatalf("--home with the CA under it: healthy: rc=%d out=%q err=%q", rc, out, errs)
	}
	// LLMCTL_HOME in the environment behaves the same as --home
	env["LLMCTL_HOME"] = home
	if rc, out, _ := run("--strict"); rc != 0 || !strings.Contains(out, "1 healthy") {
		t.Fatalf("LLMCTL_HOME: healthy, strict ok: rc=%d out=%q", rc, out)
	}
}
