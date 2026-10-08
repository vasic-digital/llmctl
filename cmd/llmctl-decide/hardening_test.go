package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/gateway"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/metrics"
)

const hkey1 = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AB"
const hkey2 = "ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210_-ZY"

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

// A-13: a key source that stops yielding a usable set keeps the last good keys only for a short
// bounded time, then the gateway fails closed; the problem is counted and reported once.
func TestKeyCacheFailsClosedAfterTheGraceAndReports(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	var errOut bytes.Buffer
	reg := metrics.New("p")
	var next func() ([]keyring.Secret, error)
	c := newKeyCache([]keyring.Secret{keyring.NewSecret(hkey1)}, func() ([]keyring.Secret, error) { return next() }, clk.now, &errOut, reg)

	next = func() ([]keyring.Secret, error) { return []keyring.Secret{keyring.NewSecret(hkey1)}, nil }
	if ks := c.keys(); len(ks) != 1 {
		t.Fatalf("healthy: %d", len(ks))
	}

	// the file becomes unsafe / unreadable
	next = func() ([]keyring.Secret, error) { return nil, os.ErrPermission }
	clk.t = clk.t.Add(2 * time.Second)
	if ks := c.keys(); len(ks) != 1 {
		t.Fatalf("within the grace the last good set is kept: %d", len(ks))
	}
	if reg.Count(metrics.KeySourceError) != 1 || strings.Count(errOut.String(), "access-key source") != 1 {
		t.Fatalf("first failure must be counted and reported once: %d %q", reg.Count(metrics.KeySourceError), errOut.String())
	}
	clk.t = clk.t.Add(2 * time.Second)
	c.keys() // still within grace of the last GOOD refresh? (good at t0, now t0+4s)
	clk.t = clk.t.Add(2 * time.Second)
	if ks := c.keys(); len(ks) != 0 {
		t.Fatalf("past the grace the gateway must fail closed, still serving %d keys", len(ks))
	}
	if strings.Count(errOut.String(), "cannot be used") != 1 {
		t.Errorf("the same problem must be reported once, not per refresh: %q", errOut.String())
	}
	if reg.Count(metrics.KeySourceError) < 3 {
		t.Errorf("every failed refresh is counted: %d", reg.Count(metrics.KeySourceError))
	}
	if strings.Contains(errOut.String(), hkey1) {
		t.Error("no key in the diagnostic")
	}
	// recovery: usable again -> accepted again, with a message
	next = func() ([]keyring.Secret, error) { return []keyring.Secret{keyring.NewSecret(hkey2)}, nil }
	clk.t = clk.t.Add(2 * time.Second)
	if ks := c.keys(); len(ks) != 1 || ks[0].Reveal() != hkey2 {
		t.Fatalf("recovery: %v", ks)
	}
	if !strings.Contains(errOut.String(), "usable again") {
		t.Errorf("recovery must be reported: %q", errOut.String())
	}
}

func TestKeyCacheEmptySetIsTreatedAsAFailure(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	var errOut bytes.Buffer
	c := newKeyCache([]keyring.Secret{keyring.NewSecret(hkey1)},
		func() ([]keyring.Secret, error) { return nil, nil }, clk.now, &errOut, nil)
	c.keys()
	clk.t = clk.t.Add(keyStaleGrace + 2*time.Second)
	if ks := c.keys(); len(ks) != 0 {
		t.Fatalf("an emptied key source must fail closed: %d", len(ks))
	}
	if !strings.Contains(errOut.String(), "no usable key") {
		t.Errorf("%q", errOut.String())
	}
}

func TestKeyCacheServesFromCacheWithinOneSecond(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	n := 0
	c := newKeyCache(nil, func() ([]keyring.Secret, error) { n++; return []keyring.Secret{keyring.NewSecret(hkey1)}, nil }, clk.now, nil, nil)
	c.keys()
	c.keys()
	clk.t = clk.t.Add(500 * time.Millisecond)
	c.keys()
	if n != 1 {
		t.Fatalf("reads within a second: %d", n)
	}
	clk.t = clk.t.Add(600 * time.Millisecond)
	c.keys()
	if n != 2 {
		t.Fatalf("refresh after a second: %d", n)
	}
}

// End to end against the real keyring: removing the key from the file (revocation) stops the old key
// from being accepted once the grace has passed - no restart needed.
func TestRevokingTheFileKeyStopsItBeingAccepted(t *testing.T) {
	root := t.TempDir()
	env := filepath.Join(root, ".env")
	if err := os.WriteFile(env, []byte("LLMCTL_API_KEY="+hkey1+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	clk := &fakeClock{t: time.Unix(1000, 0)}
	var errOut bytes.Buffer
	c := newKeyCache([]keyring.Secret{keyring.NewSecret(hkey1)}, func() ([]keyring.Secret, error) {
		return keyring.AcceptedKeys(root, keyring.Environ{}, clk.t)
	}, clk.now, &errOut, metrics.New())
	if !keyring.KeyMatches(hkey1, c.keys()) {
		t.Fatal("the file key must be accepted")
	}
	// the operator replaces the file with a symlink (or edits the key out): the source becomes unusable
	if err := os.Remove(env); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "elsewhere"), env); err != nil {
		t.Fatal(err)
	}
	clk.t = clk.t.Add(2 * time.Second)
	c.keys()
	clk.t = clk.t.Add(keyStaleGrace + time.Second)
	if keyring.KeyMatches(hkey1, c.keys()) {
		t.Fatal("the revoked key is still accepted after the grace")
	}
	if !strings.Contains(errOut.String(), "symlink") {
		t.Errorf("the operator must be told why: %q", errOut.String())
	}
}

// A-15
func TestRemoveOwnPidfileOnlyWhenItNamesThisProcess(t *testing.T) {
	dir := t.TempDir()
	pf := filepath.Join(dir, "gateway.pid")
	if err := gateway.WritePidfile(pf, 424242, time.Now()); err != nil {
		t.Fatal(err)
	}
	removeOwnPidfile(pf, os.Getpid())
	if _, err := os.Stat(pf); err != nil {
		t.Fatal("a pidfile naming another process must be left alone")
	}
	if err := gateway.WritePidfile(pf, os.Getpid(), time.Now()); err != nil {
		t.Fatal(err)
	}
	removeOwnPidfile(pf, os.Getpid())
	if _, err := os.Stat(pf); err == nil {
		t.Fatal("a pidfile naming this process must be removed")
	}
	removeOwnPidfile(pf, os.Getpid()) // absent: no panic, no error
}

func TestDetachedChildEnvironmentLacksTheLegacyKeyVariable(t *testing.T) {
	t.Setenv(legacyKeyVar, "legacy-internal-key-value-0123456789abcdef")
	t.Setenv("LLMCTL_KEEP_ME", "yes")
	lf, err := os.CreateTemp(t.TempDir(), "log")
	if err != nil {
		t.Fatal(err)
	}
	defer lf.Close()
	cmd := detachedCmd("/bin/true", []string{"serve"}, lf)
	joined := strings.Join(cmd.Env, "\n")
	if strings.Contains(joined, legacyKeyVar) || strings.Contains(joined, "legacy-internal-key-value") {
		t.Fatal("the detached child's environment carries the legacy internal-key variable")
	}
	if !strings.Contains(joined, "LLMCTL_KEEP_ME=yes") || !strings.Contains(joined, "PATH=") {
		t.Fatal("the rest of the environment must be preserved")
	}
	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.Setsid {
		t.Error("the child must run in its own session")
	}
	if cmd.Stdout != lf || cmd.Stderr != lf {
		t.Error("output must go to the log file")
	}
}

// A2-02: with an environment-sourced key, an unusable .env (here a symlink) must neither stop the
// start nor, later, take the environment key down: the key source the cache re-reads every second
// must keep yielding the environment key.
func TestEnvKeyKeepsWorkingWithAnUnusableEnvFile(t *testing.T) {
	se := setupServeEnv(t)
	root := se.env["LLMCTL_ROOT"]
	target := filepath.Join(se.dir, "elsewhere")
	if err := os.WriteFile(target, []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(root, ".env")); err != nil {
		t.Fatal(err)
	}
	se.env["LLMCTL_API_KEY"] = hkey1
	var e bytes.Buffer
	p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e)
	if p == nil {
		t.Fatalf("env key + symlinked .env must start: rc=%d %s", code, e.String())
	}
	defer p.close()
	ks, err := p.readKeys()
	if err != nil || len(ks) != 1 || ks[0].Reveal() != hkey1 {
		t.Fatalf("the env key must keep being served: %d keys, err %v", len(ks), err)
	}
}

// A2-02: a configuration that cannot keep serving must fail at start (exit 4), not 5 s into
// production.
func TestPrepareRefusesToStartWhenTheAcceptedKeySetCannotBeRead(t *testing.T) {
	se := setupServeEnv(t)
	prev := acceptedKeys
	acceptedKeys = func(string, keyring.Environ, time.Time) ([]keyring.Secret, error) {
		return nil, os.ErrPermission
	}
	t.Cleanup(func() { acceptedKeys = prev })
	var e bytes.Buffer
	p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e)
	if p != nil || code != keyring.ExitCode || keyring.ExitCode != 4 {
		t.Fatalf("must refuse with exit 4, got p=%v rc=%d err=%s", p != nil, code, e.String())
	}
	if !strings.Contains(e.String(), "accepted") {
		t.Fatalf("message must say what failed: %s", e.String())
	}
}

// A3-T3: an EMPTY accepted-key set (no error) must also refuse the start, with exit 4 and a message
// saying that no key is accepted - the second half of the start check.
func TestPrepareRefusesToStartWhenNoKeyIsAccepted(t *testing.T) {
	se := setupServeEnv(t)
	prev := acceptedKeys
	acceptedKeys = func(string, keyring.Environ, time.Time) ([]keyring.Secret, error) {
		return nil, nil
	}
	t.Cleanup(func() { acceptedKeys = prev })
	var e bytes.Buffer
	p, code := prepare(serveFlags{port: 9}, se.env, resolveDirs(se.env), &e)
	if p != nil || code != keyring.ExitCode {
		t.Fatalf("must refuse with exit %d, got p=%v rc=%d err=%s", keyring.ExitCode, p != nil, code, e.String())
	}
	if !strings.Contains(e.String(), "no key is accepted") {
		t.Fatalf("message must say that no key is accepted: %s", e.String())
	}
}
