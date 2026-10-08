package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/certs"
	"github.com/vasic-digital/llmctl/internal/keyring"
)

const serveCatalog = `{"profiles":{"fast":{"capability":["chat"],"port":8080},
"decide-tiny":{"engine":"llama","port":8092,"capability":["decide"],
 "decision":{"protocol":"letter-logit","max_options":20,"score_levels":[2,10],
  "readout":{"n_probs":32,"mass_threshold":0.5,"spellings":["A"," A"],"cache_prompt":false}}}}}`

func TestResolveBind(t *testing.T) {
	cases := []struct {
		name string
		flag string
		env  map[string]string
		want string
	}{
		{"default", "", nil, "0.0.0.0"},
		{"global", "", map[string]string{"LLMCTL_BIND_HOST": "127.0.0.1"}, "127.0.0.1"},
		{"decide beats global", "", map[string]string{"LLMCTL_BIND_HOST": "127.0.0.1", "LLMCTL_DECIDE_BIND": "10.1.2.3"}, "10.1.2.3"},
		{"flag beats env", "192.168.0.9", map[string]string{"LLMCTL_DECIDE_BIND": "10.1.2.3"}, "192.168.0.9"},
		{"blank decide falls through", "", map[string]string{"LLMCTL_DECIDE_BIND": " ", "LLMCTL_BIND_HOST": "127.0.0.1"}, "127.0.0.1"},
	}
	for _, c := range cases {
		if got := resolveBind(c.flag, c.env); got != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestResolvePort(t *testing.T) {
	if p, err := resolvePort(0, nil); err != nil || p != 8095 {
		t.Fatalf("%v %v", p, err)
	}
	if p, _ := resolvePort(0, map[string]string{"LLMCTL_DECIDE_PORT": "9000"}); p != 9000 {
		t.Fatal(p)
	}
	if p, _ := resolvePort(7000, map[string]string{"LLMCTL_DECIDE_PORT": "9000"}); p != 7000 {
		t.Fatal("flag wins")
	}
	for _, bad := range []string{"0", "70000", "x", "-1"} {
		if _, err := resolvePort(0, map[string]string{"LLMCTL_DECIDE_PORT": bad}); err == nil {
			t.Errorf("%q must be refused", bad)
		}
	}
}

func TestServeUsageErrors(t *testing.T) {
	for _, args := range [][]string{{"--nope"}, {"--port", "x"}, {"positional"}, {"--status", "--stop"}} {
		var o, e bytes.Buffer
		if rc := run(append([]string{"serve"}, args...), &o, &e); rc != 2 {
			t.Errorf("%v: rc=%d stderr=%s", args, rc, e.String())
		}
	}
}

type serveEnvT struct {
	env  map[string]string
	home string
	dir  string
}

// setupServeEnv builds an isolated environment (home, state, .env file, catalog) for in-process serve runs.
func setupServeEnv(t *testing.T) *serveEnvT {
	t.Helper()
	d := t.TempDir()
	cat := filepath.Join(d, "catalog.json")
	if err := os.WriteFile(cat, []byte(serveCatalog), 0o600); err != nil {
		t.Fatal(err)
	}
	e := &serveEnvT{dir: d, home: filepath.Join(d, "home"), env: map[string]string{
		"LLMCTL_HOME":        filepath.Join(d, "home"),
		"LLMCTL_STATE_DIR":   filepath.Join(d, "state"),
		"LLMCTL_ENV_FILE":    filepath.Join(d, "root", ".env"),
		"LLMCTL_ROOT":        filepath.Join(d, "root"),
		"LLMCTL_CATALOG":     cat,
		"LLMCTL_TLS_SAN":     "ip:127.0.0.1",
		"LLMCTL_DECIDE_BIND": "127.0.0.1",
	}}
	_ = os.MkdirAll(filepath.Join(d, "root"), 0o700)
	prev := serveEnv
	serveEnv = func() keyring.Environ { return e.env }
	t.Cleanup(func() { serveEnv = prev })
	return e
}

func (e *serveEnvT) pidfile() string {
	return filepath.Join(e.env["LLMCTL_STATE_DIR"], "decide", "gateway.pid")
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func TestServeStatusAndStopWithoutPidfile(t *testing.T) {
	setupServeEnv(t)
	var o, e bytes.Buffer
	if rc := run([]string{"serve", "--status"}, &o, &e); rc != 1 || !strings.Contains(o.String(), "not running") {
		t.Fatalf("status rc=%d out=%q", rc, o.String())
	}
	o.Reset()
	if rc := run([]string{"serve", "--stop"}, &o, &e); rc != 0 || !strings.Contains(o.String(), "not running") {
		t.Fatalf("stop rc=%d out=%q err=%q", rc, o.String(), e.String())
	}
}

// Helix §11.4.263: --stop must never signal a process it has not verified as the gateway.
func TestServeStopNeverSignalsUnrelatedProcess(t *testing.T) {
	se := setupServeEnv(t)
	c := exec.Command("sleep", "300")
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Process.Kill(); _, _ = c.Process.Wait() })
	if err := os.MkdirAll(filepath.Dir(se.pidfile()), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(se.pidfile(), []byte(itoa(c.Process.Pid)+" 1700000000\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var o, e bytes.Buffer
	if rc := run([]string{"serve", "--stop"}, &o, &e); rc != 1 {
		t.Fatalf("stop rc=%d out=%q err=%q", rc, o.String(), e.String())
	}
	if err := syscall.Kill(c.Process.Pid, 0); err != nil {
		t.Fatalf("the unrelated process was signalled/killed: %v", err)
	}
	o.Reset()
	if rc := run([]string{"serve", "--status"}, &o, &e); rc != 1 || strings.Contains(o.String(), "running pid") {
		t.Fatalf("status must not call an unverified pid running: rc=%d %q", rc, o.String())
	}
	// pid 1 is refused outright
	_ = os.WriteFile(se.pidfile(), []byte("1 1700000000\n"), 0o600)
	e.Reset()
	if rc := run([]string{"serve", "--stop"}, &o, &e); rc != 1 {
		t.Fatalf("pid 1: rc=%d", rc)
	}
}

func itoa(i int) string { b, _ := json.Marshal(i); return string(b) }

func TestServeRefusesWithoutValidKey(t *testing.T) {
	se := setupServeEnv(t)
	se.env["LLMCTL_API_KEY"] = "short"
	var o, e bytes.Buffer
	if rc := run([]string{"serve", "--foreground", "--port", itoa(freePort(t))}, &o, &e); rc != 4 {
		t.Fatalf("rc=%d err=%q", rc, e.String())
	}
	if strings.Contains(o.String()+e.String(), "short") && strings.Contains(o.String()+e.String(), "LLMCTL_API_KEY=short") {
		t.Fatal("key value echoed")
	}
}

func TestServeRefusesWithoutValidCertificate(t *testing.T) {
	se := setupServeEnv(t)
	se.env["LLMCTL_TLS_MODE"] = "byo" // operator-supplied pair that does not exist
	var o, e bytes.Buffer
	if rc := run([]string{"serve", "--foreground", "--port", itoa(freePort(t))}, &o, &e); rc != 5 {
		t.Fatalf("rc=%d err=%q", rc, e.String())
	}
}

func TestServeCatalogProblems(t *testing.T) {
	se := setupServeEnv(t)
	se.env["LLMCTL_CATALOG"] = filepath.Join(se.dir, "missing.json")
	var o, e bytes.Buffer
	if rc := run([]string{"serve", "--foreground", "--port", itoa(freePort(t))}, &o, &e); rc != 1 {
		t.Fatalf("missing catalog rc=%d", rc)
	}
	empty := filepath.Join(se.dir, "empty.json")
	_ = os.WriteFile(empty, []byte(`{"profiles":{"fast":{"capability":["chat"]}}}`), 0o600)
	e.Reset()
	if rc := run([]string{"serve", "--foreground", "--catalog", empty, "--port", itoa(freePort(t))}, &o, &e); rc != 1 || !strings.Contains(e.String(), "no decision profiles") {
		t.Fatalf("empty catalog rc=%d err=%q", rc, e.String())
	}
}

func TestServeEndToEndInProcess(t *testing.T) {
	se := setupServeEnv(t)
	// fake llama-server (unit tier only)
	llama := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer internal-key-1" {
			w.WriteHeader(401)
			return
		}
		_, _ = io.WriteString(w, `{"choices":[{"logprobs":{"top_logprobs":[[{"token":" A","logprob":-0.1},{"token":" B","logprob":-2.3}]]}}]}`)
	}))
	defer llama.Close()
	se.env["LLMCTL_DECIDE_ENDPOINT_DECIDE_TINY"] = llama.URL
	ikf := filepath.Join(se.dir, "internal.key")
	if err := os.WriteFile(ikf, []byte("internal-key-1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	se.env["LLMCTL_DECIDE_INTERNAL_KEY_FILE"] = ikf // G-040: a file, never the environment
	port := freePort(t)

	sigs := make(chan os.Signal, 1)
	prev := sigSource
	sigSource = func() (<-chan os.Signal, func()) { return sigs, func() {} }
	defer func() { sigSource = prev }()

	var out, errb syncBuf
	done := make(chan int, 1)
	go func() { done <- run([]string{"serve", "--foreground", "--port", itoa(port)}, &out, &errb) }()

	addr := "127.0.0.1:" + itoa(port)
	deadline := time.Now().Add(15 * time.Second)
	for {
		if c, err := net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
			c.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("gateway did not start: out=%q err=%q", out.String(), errb.String())
		}
		select {
		case rc := <-done:
			t.Fatalf("serve exited early rc=%d err=%q", rc, errb.String())
		default:
		}
		time.Sleep(50 * time.Millisecond)
	}

	// trust the generated CA, read the generated key from the env file (never from output)
	pem, err := os.ReadFile(filepath.Join(se.home, "cert", "ca", "ca.crt"))
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(pem)
	cli := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
	kr, err := keyring.Resolve(se.env["LLMCTL_ROOT"], se.env, false)
	if err != nil || kr.Source == "none" {
		t.Fatalf("key not generated: %v %+v", err, kr)
	}
	key := kr.Key.Reveal()

	do := func(method, path, body string) (int, string) {
		req, _ := http.NewRequest(method, "https://"+addr+path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+key)
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		resp, err := cli.Do(req)
		if err != nil {
			t.Fatalf("%s %s: %v", method, path, err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	if st, _ := do("GET", "/healthz", ""); st != 200 {
		t.Fatalf("healthz %d", st)
	}
	if st, _ := do("GET", "/readyz", ""); st != 200 {
		t.Fatalf("readyz %d", st)
	}
	st, body := do("POST", "/v1/systemone", `{"model":"jev-latest","state":"fire","questions":{"q":{"type":"noul","instructions":"urgent?"}}}`)
	if st != 200 || !strings.Contains(body, `"noul":0.9`) {
		t.Fatalf("systemone %d %s", st, body)
	}
	if st, body := do("GET", "/v1/models", ""); st != 200 || !strings.Contains(body, "decide-tiny") {
		t.Fatalf("models %d %s", st, body)
	}

	// status sees the verified process (this test process is the gateway: cmdline is the test binary,
	// so use the pidfile content check instead of the cmdline-verified status)
	if _, err := os.Stat(se.pidfile()); err != nil {
		t.Fatalf("pidfile: %v", err)
	}
	if fi, _ := os.Stat(se.pidfile()); fi.Mode().Perm() != 0o600 {
		t.Fatalf("pidfile mode %v", fi.Mode())
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
	if _, err := os.Stat(se.pidfile()); !os.IsNotExist(err) {
		t.Fatal("pidfile must be removed on shutdown")
	}
	all := out.String() + errb.String()
	if strings.Contains(all, key) {
		t.Fatal("the access key was printed")
	}
	for _, want := range []string{"https://", "127.0.0.1:" + itoa(port), ".env", "CA", "SHA-256"} {
		if !strings.Contains(all, want) {
			t.Errorf("start-up banner lacks %q:\n%s", want, all)
		}
	}
	// the request log exists with mode 0600 and no state text
	logp := filepath.Join(se.env["LLMCTL_STATE_DIR"], "logs", "decide-requests.jsonl")
	lb, err := os.ReadFile(logp)
	if err != nil || len(lb) == 0 {
		t.Fatalf("audit log: %v", err)
	}
	if strings.Contains(string(lb), "fire") || strings.Contains(string(lb), key) {
		t.Fatal("audit log leaked state or key")
	}
	if fi, _ := os.Stat(logp); fi.Mode().Perm() != 0o600 {
		t.Fatalf("log mode %v", fi.Mode())
	}
}

// syncBuf is a goroutine-safe buffer for the concurrently running serve.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

func TestCertHolderReload(t *testing.T) {
	se := setupServeEnv(t)
	var o, e bytes.Buffer
	_ = o
	_ = e
	p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e)
	if p == nil {
		t.Fatalf("prepare rc=%d err=%s", code, e.String())
	}
	defer p.close()
	before := p.certs.cert.Load()
	if err := p.certs.reload(certs.Options{Home: p.dirs.home, Env: p.env}); err != nil {
		t.Fatal(err)
	}
	if p.certs.cert.Load() == nil || before == nil {
		t.Fatal("certificate lost on reload")
	}
	if _, err := p.certs.get(nil); err != nil {
		t.Fatal(err)
	}
}

func TestServeRefusesAnUnacceptableGlobalInternalKeyFileAtStart(t *testing.T) {
	se := setupServeEnv(t)
	for name, mk := range map[string]func(string){
		"missing":   func(p string) {},
		"too-loose": func(p string) { _ = os.WriteFile(p, []byte("k"), 0o644); _ = os.Chmod(p, 0o644) },
		"symlink": func(p string) {
			real := p + ".real"
			_ = os.WriteFile(real, []byte("k"), 0o600)
			_ = os.Symlink(real, p)
		},
	} {
		p := filepath.Join(se.dir, "ik-"+name)
		mk(p)
		se.env["LLMCTL_DECIDE_INTERNAL_KEY_FILE"] = p
		var o, e bytes.Buffer
		if rc := run([]string{"serve", "--foreground", "--port", itoa(freePort(t))}, &o, &e); rc == 0 || !strings.Contains(e.String(), "LLMCTL_DECIDE_INTERNAL_KEY_FILE") {
			t.Errorf("%s: rc=%d err=%q", name, rc, e.String())
		}
		if strings.Contains(e.String(), "k\n") && name != "missing" {
			t.Errorf("%s: leak %q", name, e.String())
		}
	}
}

// The removed env var is not honoured: it is scrubbed (and said so, without its value).
func TestServeIgnoresTheRemovedInternalKeyEnvVar(t *testing.T) {
	var e bytes.Buffer
	in := keyring.Environ{legacyKeyVar: "must-not-be-used", "OTHER": "x"}
	out := scrubLegacyKeyEnv(in, &e)
	if _, ok := out[legacyKeyVar]; ok || out["OTHER"] != "x" {
		t.Fatalf("%v", out)
	}
	if _, ok := in[legacyKeyVar]; !ok {
		t.Fatal("the caller's map must stay untouched")
	}
	if !strings.Contains(e.String(), "no longer read") || strings.Contains(e.String(), "must-not-be-used") {
		t.Fatalf("%q", e.String())
	}
	e.Reset()
	if o := scrubLegacyKeyEnv(keyring.Environ{"A": "b"}, &e); len(o) != 1 || e.Len() != 0 {
		t.Fatalf("%v %q", o, e.String())
	}
}
