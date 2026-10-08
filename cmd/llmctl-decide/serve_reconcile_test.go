package main

import (
	"bytes"
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/registry"
)

func TestReconcileEnvIsStrictlyValidated(t *testing.T) {
	bad := []string{"0", "-1", "abc", "1e2", "0x10", "inf", "NaN", "1s", " 5", "5 ", "3601", "+5", ".5", "5."}
	for _, v := range bad {
		se := setupServeEnv(t)
		se.env[reconcileIntervalVar] = v
		var e bytes.Buffer
		if p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e); p != nil || code != exitUsage || !strings.Contains(e.String(), reconcileIntervalVar) {
			t.Errorf("%s=%q must be a usage error naming the variable: p=%v code=%d err=%q", reconcileIntervalVar, v, p, code, e.String())
		}
	}
	for _, v := range []string{"-1", "x", "1m", "86401"} {
		se := setupServeEnv(t)
		se.env[reconcileGraceVar] = v
		var e bytes.Buffer
		if p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e); p != nil || code != exitUsage || !strings.Contains(e.String(), reconcileGraceVar) {
			t.Errorf("%s=%q must be a usage error: p=%v code=%d err=%q", reconcileGraceVar, v, p, code, e.String())
		}
	}
	for v, want := range map[string]time.Duration{"": 5 * time.Second, "1": time.Second, "0.25": 250 * time.Millisecond, "3600": time.Hour} {
		se := setupServeEnv(t)
		if v != "" {
			se.env[reconcileIntervalVar] = v
		}
		p := prep(t, se)
		if p.regs.reconcileEvery != want {
			t.Errorf("interval %q -> %s, want %s", v, p.regs.reconcileEvery, want)
		}
	}
	se := setupServeEnv(t)
	if p := prep(t, se); p.regs.reconcileOpts.Grace != 30*time.Second {
		t.Errorf("default grace %s", p.regs.reconcileOpts.Grace)
	}
	se = setupServeEnv(t)
	se.env[reconcileGraceVar] = "0"
	if p := prep(t, se); p.regs.reconcileOpts.Grace != 0 {
		t.Errorf("grace 0 must be accepted: %s", p.regs.reconcileOpts.Grace)
	}
}

// the ask client and the registry resolve the CA by the same function (G-068)
func TestAskAndRegistryResolveTheSameCA(t *testing.T) {
	for name, env := range map[string]map[string]string{
		"explicit":         {"HOME": "/h", "LLMCTL_HOME": "/lh", "LLMCTL_CACERT": "/c/ca.crt"},
		"non-default home": {"HOME": "/h", "LLMCTL_HOME": "/srv/x"},
		"default home":     {"HOME": "/h"},
		"none":             {},
	} {
		ce := &askClientEnv{env: env, cacert: env["LLMCTL_CACERT"]}
		want := registry.ResolveCA(func(k string) string { return env[k] })
		if got := ce.resolveCA(""); got != want {
			t.Errorf("%s: ask=%q registry=%q", name, got, want)
		}
	}
}

// two gateways on one registry run exactly one reconciler between them
func TestTwoGatewaysShareOneReconciler(t *testing.T) {
	se := setupServeEnv(t)
	se.env[reconcileIntervalVar] = "0.02"
	p1, p2 := prep(t, se), prep(t, se)
	var n1, n2 atomic.Int64
	p1.regs.onPass, p2.regs.onPass = func() { n1.Add(1) }, func() { n2.Add(1) }
	var e1, e2 bytes.Buffer
	stop1 := p1.publishSelf(&e1)
	waitUntil(t, 5*time.Second, "first gateway reconciler passes", func() bool { return n1.Load() >= 2 })
	stop2 := p2.publishSelf(&e2)
	defer stop2()
	time.Sleep(400 * time.Millisecond)
	if n2.Load() != 0 {
		t.Fatalf("the second gateway must not run a second reconciler (passes: first=%d second=%d)", n1.Load(), n2.Load())
	}
	stop1() // drain of the owner: the reconciler stops with it and the other takes the role over
	after := n1.Load()
	waitUntil(t, 5*time.Second, "the standby gateway to take over", func() bool { return n2.Load() >= 2 })
	time.Sleep(100 * time.Millisecond)
	if n1.Load() != after {
		t.Fatalf("a drained gateway must stop reconciling (%d -> %d)", after, n1.Load())
	}
}

// G-057 + G-068 end to end: a real gateway reconciles on its own (a killed engine disappears with
// no external reconcile call) and publishes its CA so an env-less reconciler keeps it healthy.
func TestGatewayReconcilesItselfAndPublishesItsCA(t *testing.T) {
	se := setupServeEnv(t)
	se.env[registryIntervalVar] = "20ms"
	se.env[reconcileIntervalVar] = "0.05"
	se.env[reconcileGraceVar] = "0.3"
	engine := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer engine.Close()
	victim := exec.Command("sleep", "300")
	if err := victim.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = victim.Process.Kill(); _, _ = victim.Process.Wait() }()
	_, ps, _ := net.SplitHostPort(engine.Listener.Addr().String())
	port, _ := strconv.Atoi(ps)
	reg := regOf(t, se)
	registerAfterExec(t, reg, registry.Entry{Name: "decide-victim", Host: "127.0.0.1", Port: port, Protocol: "http", HealthPath: "/health",
		Labels: map[string]string{registry.LabelKind: "decide", registry.LabelProfile: "decide-victim"}, PID: victim.Process.Pid, CmdToken: "sleep", LoopbackOnly: true})

	sigs := make(chan os.Signal, 1)
	prev := sigSource
	sigSource = func() (<-chan os.Signal, func()) { return sigs, func() {} }
	defer func() { sigSource = prev }()
	var out, errb syncBuf
	done := make(chan int, 1)
	gwPort := freePort(t)
	go func() { done <- run([]string{"serve", "--foreground", "--port", itoa(gwPort)}, &out, &errb) }()

	waitUntil(t, 15*time.Second, "gateway entry in the registry", func() bool {
		select {
		case rc := <-done:
			t.Fatalf("serve exited rc=%d err=%q", rc, errb.String())
		default:
		}
		_, ok, _ := reg.Get("decide-gateway")
		return ok
	})
	gw, _, _ := reg.Get("decide-gateway")
	wantCA := filepath.Join(se.home, "cert", "ca", "ca.crt")
	if gw.Labels[registry.LabelCAFile] != wantCA {
		t.Fatalf("the gateway must publish its CA path: labels=%v want ca_file=%s", gw.Labels, wantCA)
	}

	// no external reconcile is ever called: the engine's process dies and its row goes away
	_ = victim.Process.Signal(syscall.SIGKILL)
	_, _ = victim.Process.Wait()
	waitUntil(t, 10*time.Second, "the gateway's own reconciler to remove the dead engine", func() bool {
		_, ok, _ := reg.Get("decide-victim")
		return !ok
	})

	// an env-less reconciler (no LLMCTL_CACERT, another home) certifies the gateway through the label
	cfg, _ := registry.ConfigFromEnv(func(k string) string {
		return map[string]string{"LLMCTL_STATE_DIR": se.env["LLMCTL_STATE_DIR"], "HOME": t.TempDir()}[k]
	})
	rep, err := registry.New(cfg).Reconcile(context.Background(), registry.ReconcileOptions{Grace: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(rep.Healthy, ",") != "decide-gateway" || len(rep.Removed)+len(rep.Unknown)+len(rep.Unhealthy) != 0 {
		t.Fatalf("an env-less reconciler must keep the gateway healthy via its ca_file label: %+v", rep)
	}

	sigs <- syscall.SIGTERM
	select {
	case rc := <-done:
		if rc != 0 {
			t.Fatalf("rc=%d err=%q", rc, errb.String())
		}
	case <-time.After(20 * time.Second):
		t.Fatal("no clean shutdown (reconciler must stop on drain)")
	}
	if _, ok, _ := reg.Get("decide-gateway"); ok {
		t.Fatal("the gateway must unregister on drain")
	}
}

// registerAfterExec registers a freshly started helper process. Register proves that the pid really
// runs the named program and refuses a child that still shows its parent's command line, so the
// test waits (bounded) until the exec has happened - exactly what the shell side does.
func registerAfterExec(t *testing.T, reg *registry.Registry, e registry.Entry) {
	t.Helper()
	var err error
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if err = reg.Register(e); err == nil {
			return
		}
	}
	t.Fatalf("register never succeeded: %v", err)
}
