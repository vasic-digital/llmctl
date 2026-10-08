package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/registry"
)

func selfToken() string { return filepath.Base(os.Args[0]) }

func regOf(t *testing.T, se *serveEnvT) *registry.Registry {
	t.Helper()
	cfg, err := registry.ConfigFromEnv(func(k string) string { return se.env[k] })
	if err != nil {
		t.Fatal(err)
	}
	return registry.New(cfg)
}

func registerEngine(t *testing.T, reg *registry.Registry, name, profile string, srv *httptest.Server, keyFile string) {
	t.Helper()
	_, p, _ := net.SplitHostPort(srv.Listener.Addr().String())
	port, _ := strconv.Atoi(p)
	l := map[string]string{registry.LabelKind: "decide", registry.LabelProfile: profile}
	if keyFile != "" {
		l[registry.LabelKeyFile] = keyFile
	}
	if err := reg.Register(registry.Entry{Name: name, Host: "127.0.0.1", Port: port, Protocol: "http", HealthPath: "/health",
		Labels: l, PID: os.Getpid(), CmdToken: selfToken(), LoopbackOnly: true}); err != nil {
		t.Fatal(err)
	}
}

func prep(t *testing.T, se *serveEnvT) *prepared {
	t.Helper()
	var e bytes.Buffer
	p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e)
	if p == nil {
		t.Fatalf("prepare rc=%d err=%s", code, e.String())
	}
	t.Cleanup(p.close)
	return p
}

func TestResolverModeAutoFallsBackToStaticOnEmptyRegistry(t *testing.T) {
	se := setupServeEnv(t)
	if m := prep(t, se).resolverMode(); m != "static" {
		t.Fatalf("auto with no registry entries must use the static resolver, got %s", m)
	}
}

func TestResolverModeAutoUsesTheRegistryWhenItHasEntries(t *testing.T) {
	se := setupServeEnv(t)
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer engine.Close()
	registerEngine(t, regOf(t, se), "decide-tiny", "decide-tiny", engine, "")
	if m := prep(t, se).resolverMode(); m != "registry" {
		t.Fatalf("auto with entries must use the registry resolver, got %s", m)
	}
}

func TestResolverModeStaticIgnoresTheRegistry(t *testing.T) {
	se := setupServeEnv(t)
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer engine.Close()
	registerEngine(t, regOf(t, se), "decide-tiny", "decide-tiny", engine, "")
	se.env[resolverVar] = "static"
	if m := prep(t, se).resolverMode(); m != "static" {
		t.Fatalf("got %s", m)
	}
}

func TestResolverModeRegistryForcedEvenWhenEmpty(t *testing.T) {
	se := setupServeEnv(t)
	se.env[resolverVar] = "registry"
	if m := prep(t, se).resolverMode(); m != "registry" {
		t.Fatalf("got %s", m)
	}
}

func TestResolverBadValuesAreUsageErrors(t *testing.T) {
	for k, v := range map[string]string{resolverVar: "dns", registryIntervalVar: "fast"} {
		se := setupServeEnv(t)
		se.env[k] = v
		var e bytes.Buffer
		if p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e); p != nil || code != exitUsage || !strings.Contains(e.String(), k) {
			t.Fatalf("%s=%s: p=%v code=%d err=%q", k, v, p, code, e.String())
		}
	}
}

// The gateway publishes itself at ready (kind=gateway, https, healthy by a REAL TLS handshake against the
// llmctl CA), routes to a registry engine with that engine's own key file, and unregisters on drain.
func TestServePublishesItselfAndRoutesViaRegistry(t *testing.T) {
	se := setupServeEnv(t)
	dir := t.TempDir()
	keyFile := filepath.Join(dir, "engine.key")
	if err := os.WriteFile(keyFile, []byte("engine-key-7\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			return
		}
		if r.Header.Get("Authorization") != "Bearer engine-key-7" {
			w.WriteHeader(401)
			return
		}
		_, _ = io.WriteString(w, `{"choices":[{"logprobs":{"top_logprobs":[[{"token":" A","logprob":-0.1},{"token":" B","logprob":-2.3}]]}}]}`)
	}))
	defer engine.Close()
	reg := regOf(t, se)
	registerEngine(t, reg, "decide-tiny", "decide-tiny", engine, keyFile)
	se.env[registryIntervalVar] = "20ms"
	port := freePort(t)

	sigs := make(chan os.Signal, 1)
	prev := sigSource
	sigSource = func() (<-chan os.Signal, func()) { return sigs, func() {} }
	defer func() { sigSource = prev }()
	var out, errb syncBuf
	done := make(chan int, 1)
	go func() { done <- run([]string{"serve", "--foreground", "--port", itoa(port)}, &out, &errb) }()

	addr := "127.0.0.1:" + itoa(port)
	waitUntil(t, 15*time.Second, "gateway listening", func() bool {
		select {
		case rc := <-done:
			t.Fatalf("serve exited rc=%d err=%q", rc, errb.String())
		default:
		}
		c, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			c.Close()
		}
		return err == nil
	})

	// published, discoverable by kind
	waitUntil(t, 5*time.Second, "gateway entry in the registry", func() bool {
		es, _ := reg.Resolve(map[string]string{registry.LabelKind: "gateway"})
		return len(es) == 1 && es[0].Port == port && es[0].Protocol == "https"
	})
	// healthy through the registry's own probe: TLS handshake verified against the llmctl CA + GET /healthz
	rep, err := reg.Reconcile(context.Background(), registry.ReconcileOptions{Grace: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	healthy := strings.Join(rep.Healthy, ",")
	if !strings.Contains(healthy, "decide-gateway") || !strings.Contains(healthy, "decide-tiny") {
		t.Fatalf("both the gateway (TLS probe) and the engine must reconcile healthy: %+v", rep)
	}

	// routes to the registry engine with ITS key file's key
	pem, _ := os.ReadFile(filepath.Join(se.home, "cert", "ca", "ca.crt"))
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(pem)
	cli := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
	kr, _ := keyring.Resolve(se.env["LLMCTL_ROOT"], se.env, false)
	req, _ := http.NewRequest("POST", "https://"+addr+"/v1/systemone",
		strings.NewReader(`{"model":"jev-latest","state":"fire","questions":{"q":{"type":"noul","instructions":"urgent?"}}}`))
	req.Header.Set("Authorization", "Bearer "+kr.Key.Reveal())
	req.Header.Set("Content-Type", "application/json")
	resp, err := cli.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(b), `"noul":0.9`) {
		t.Fatalf("registry-routed request: %d %s", resp.StatusCode, b)
	}

	sigs <- syscall.SIGTERM
	select {
	case rc := <-done:
		if rc != 0 {
			t.Fatalf("rc=%d err=%q", rc, errb.String())
		}
	case <-time.After(20 * time.Second):
		t.Fatal("no clean shutdown")
	}
	if _, ok, _ := reg.Get("decide-gateway"); ok {
		t.Fatal("the gateway must unregister on drain")
	}
}

func waitUntil(t *testing.T, d time.Duration, what string, cond func() bool) {
	t.Helper()
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out: %s", what)
}

// C-23: auto mode must not switch to the registry on rows that are no decision engine (a stale
// gateway row from a previous run) or on an unhealthy engine; the static endpoints still work.
func TestC23AutoIgnoresStaleGatewayRowAndUnhealthyEngines(t *testing.T) {
	se := setupServeEnv(t)
	reg := regOf(t, se)
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer engine.Close()
	gw := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer gw.Close()
	_, ps, _ := net.SplitHostPort(gw.Listener.Addr().String())
	port, _ := strconv.Atoi(ps)
	if err := reg.Register(registry.Entry{Name: "decide-gateway", Host: "127.0.0.1", Port: port, Protocol: "http", HealthPath: "/health",
		Labels: map[string]string{registry.LabelKind: "gateway", registry.LabelProfile: "decide"}, PID: os.Getpid(), CmdToken: selfToken(), LoopbackOnly: true}); err != nil {
		t.Fatal(err)
	}
	if m := prep(t, se).resolverMode(); m != "static" {
		t.Fatalf("a registry holding only a stale gateway row must not switch auto to registry mode, got %s", m)
	}
	registerEngine(t, reg, "decide-tiny", "decide-tiny", engine, "")
	if m := prep(t, se).resolverMode(); m != "registry" {
		t.Fatalf("a healthy decide engine must select registry mode, got %s", m)
	}
}

// C-11: the gateway's in-process reconciler keeps a port hold at least as long as the unit hooks wait
// for a loading engine (LLMCTL_REGISTER_WAIT): longer waits raise the grace, shorter ones keep the default.
func TestC11GatewayPortGraceFollowsRegisterWait(t *testing.T) {
	se := setupServeEnv(t)
	if g := prep(t, se).regs.reconcileOpts.PortGrace; g != 0 { // 0 = registry.DefaultPortGrace (600s)
		t.Fatalf("default: PortGrace=%v, want the registry default (0)", g)
	}
	se.env["LLMCTL_REGISTER_WAIT"] = "120"
	if g := prep(t, se).regs.reconcileOpts.PortGrace; g != 0 {
		t.Fatalf("a wait below the default must not shrink the grace: %v", g)
	}
	se.env["LLMCTL_REGISTER_WAIT"] = "1800"
	if g := prep(t, se).regs.reconcileOpts.PortGrace; g != 1800*time.Second {
		t.Fatalf("LLMCTL_REGISTER_WAIT=1800 must raise the port grace to 1800s, got %v", g)
	}
}

// C2-13: auto mode is not a one-way decision made at startup. A gateway that started on an empty
// registry serves the static endpoints, and switches to the registry as soon as a healthy decision
// engine registers (and reports it), exactly as if it had started after the engine.
func TestC213AutoSwitchesToRegistryWhenAnEngineRegistersLater(t *testing.T) {
	se := setupServeEnv(t)
	se.env[registryIntervalVar] = "100ms"
	reg := regOf(t, se)
	p := prep(t, se)
	if m := p.resolverMode(); m != "static" {
		t.Fatalf("empty registry: want static at start, got %s", m)
	}
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer engine.Close()
	registerEngine(t, reg, "decide-late", "decide-late", engine, "")
	waitUntil(t, 5*time.Second, "auto resolver to switch to the registry", func() bool { return p.resolverMode() == "registry" })
	// and back when the registry empties again
	if _, err := reg.Unregister("decide-late"); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, 5*time.Second, "auto resolver to fall back to static", func() bool { return p.resolverMode() == "static" })
}
