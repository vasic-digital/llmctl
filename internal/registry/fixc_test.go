package registry

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ---- C-01: liveness binds to the SPECIFIC process --------------------------------

// `tail -f /var/log/llama-server` and `vim ~/llama-server` carry the token as the BASENAME of a
// path ARGUMENT: they are not the service.
func TestC01TailAndEditorCarriersAreNotTheService(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "llama-server")
	if err := os.WriteFile(f, []byte("x\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("tail", "-f", f)
	if err := cmd.Start(); err != nil {
		t.Skip("no tail: ", err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() })
	time.Sleep(100 * time.Millisecond)
	if OSIdentity(cmd.Process.Pid, "llama-server") {
		t.Fatal("`tail -f .../llama-server` was treated as the llama-server service")
	}
}

// The interpreter + script form (python onnx_server.py) is how onnx engines launch: argv[1].
func TestC01InterpreterScriptMatches(t *testing.T) {
	dir := t.TempDir()
	sc := filepath.Join(dir, "onnx_server.sh")
	if err := os.WriteFile(sc, []byte("#!/bin/sh\nsleep 300\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sh", sc)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() })
	time.Sleep(100 * time.Millisecond)
	if !OSIdentity(cmd.Process.Pid, "onnx_server.sh") {
		t.Fatal("`sh <dir>/onnx_server.sh` must be the onnx_server.sh service")
	}
}

// A pid recycled to ANOTHER instance of the same program (same token, same argv) is not the
// registered service: the start-time fingerprint recorded at registration no longer matches.
func TestC01RecycledPidOfSameProgramIsNotAlive(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	a := spawn(t, "hold", "llama-server") // the service that was registered ...
	fpA := ProcFingerprint(a.pid())
	if fpA == "" {
		t.Fatal("no fingerprint for a live process")
	}
	time.Sleep(1100 * time.Millisecond)   // a and b must start in DIFFERENT clock ticks: the sleep goes BETWEEN the spawns
	b := spawn(t, "hold", "llama-server") // ... and an identical program that now owns "its" pid
	if fpB := ProcFingerprint(b.pid()); fpB == fpA {
		t.Fatalf("test premise broken: two spawns share one fingerprint %q", fpA)
	}
	port := freePort(t)
	e := Entry{Name: "svc", Host: "127.0.0.1", Port: port, Protocol: "tcp", PID: b.pid(), CmdToken: "llama-server", ProcFP: fpA}
	if err := r.Register(e); err != nil {
		t.Fatal(err)
	}
	rep, err := r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Removed) != 1 || !strings.Contains(rep.Removed[0].Reason, "identity") {
		t.Fatalf("a recycled pid running the SAME program was accepted as the registered service: %+v", rep)
	}
	// the control: the same process registered with its own fingerprint is alive
	e.ProcFP = ""
	if err := r.Register(e); err != nil {
		t.Fatal(err)
	}
	got, _, _ := r.Get("svc")
	if got.ProcFP != ProcFingerprint(b.pid()) || got.ProcFP == "" {
		t.Fatalf("Register must record the live process fingerprint: %q", got.ProcFP)
	}
	rep, _ = r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if len(rep.Removed) != 0 {
		t.Fatalf("a correctly fingerprinted live service was removed: %+v", rep)
	}
}

func TestC01FingerprintShape(t *testing.T) {
	if ProcFingerprint(os.Getpid()) == "" || ProcFingerprint(0) != "" || ProcFingerprint(1) != "" || ProcFingerprint(os.Getpid()+9999999) != "" {
		t.Fatal("fingerprint must exist for a live process and never for pid<=1 or a missing pid")
	}
	if ProcFingerprint(os.Getpid()) != ProcFingerprint(os.Getpid()) {
		t.Fatal("fingerprint must be stable for one process")
	}
}

// ---- C-09: the stale-snapshot guard in Reconcile -----------------------------------

// A service re-registers (new pid) while a reconcile pass is still probing the OLD pid: the pass
// must not remove the fresh row.
func TestC09ReconcileDoesNotRemoveRowReRegisteredDuringProbe(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	oldPID, newPID := 41001, 41002
	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	var armed atomic.Bool // Register now proves identity too (C2-07): only the reconcile pass may block on the old pid
	r.Identity = func(pid int, token string) bool {
		if pid == oldPID && armed.Load() {
			once.Do(func() { close(started) })
			<-release
			return false // the old process is gone
		}
		return true
	}
	r.Fingerprint = func(int) string { return "" }
	r.Prober = nil
	e := Entry{Name: "svc", Host: "127.0.0.1", Port: freePort(t), Protocol: "tcp", PID: oldPID, CmdToken: "tok"}
	if err := r.Register(e); err != nil {
		t.Fatal(err)
	}
	armed.Store(true)
	var rep ReconcileReport
	done := make(chan error, 1)
	go func() {
		var err error
		rep, err = r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
		done <- err
	}()
	<-started
	e.PID = newPID
	e.Started = time.Now().Add(time.Second)
	if err := r.Register(e); err != nil { // the restart re-registers while the pass is probing
		t.Fatal(err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	for _, rm := range rep.Removed {
		if rm.Name == "svc" {
			t.Fatalf("the pass removed a row that was re-registered since its snapshot: %+v", rep)
		}
	}
	got, ok, _ := r.Get("svc")
	if !ok || got.PID != newPID {
		t.Fatalf("the fresh registration was lost: %+v ok=%v", got, ok)
	}
}

// ---- C-10: Watch notices a same-size rewrite -----------------------------------------

func TestC10WatchDetectsSameSizeRewrite(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	r.Identity = func(int, string) bool { return true }
	r.Fingerprint = func(int) string { return "" }
	e := Entry{Name: "svc", Host: "127.0.0.1", Port: 40123, Protocol: "tcp", PID: 12345, CmdToken: "tok", Started: time.Unix(1700000000, 0)}
	if err := r.Register(e); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := r.Watch(ctx, 20*time.Millisecond)
	s0, ok := recv(t, ch, time.Second)
	if !ok || len(s0.Entries) != 1 || s0.Entries[0].PID != 12345 {
		t.Fatalf("initial snapshot: %v %+v", ok, s0)
	}
	before, _ := os.Stat(filepath.Join(cfg.Dir(), "services.json"))
	// Rewrite the entry with another 5-digit pid until the file keeps its EXACT size: the stored
	// document also carries fields whose rendered length can vary by a byte between writes, so the
	// test searches for a same-size rewrite instead of assuming one (the premise is asserted, never
	// skipped: if no same-size rewrite exists in 200 tries the test fails loudly).
	want := 0
	for pid := 54321; pid < 54321+200; pid++ {
		e.PID = pid
		if err := r.Register(e); err != nil {
			t.Fatal(err)
		}
		after, _ := os.Stat(filepath.Join(cfg.Dir(), "services.json"))
		if before.Size() == after.Size() {
			want = pid
			break
		}
		// size differs: this write is a size change (announced by any detector); let the watcher
		// drain it and compare against the NEW size on the next attempt
		before = after
		drain(ch)
	}
	if want == 0 {
		t.Fatal("test premise broken: no same-size rewrite found in 200 attempts")
	}
	s1, ok := recvPID(t, ch, 3*time.Second, want)
	if !ok {
		t.Fatalf("a same-size rewrite (pid -> %d) was not announced", want)
	}
	_ = s1
}

// ---- C-24: a corrupt registry stays reported ------------------------------------------

func TestC24CorruptRegistryIsReportedUntilAcknowledged(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	_ = os.MkdirAll(cfg.Dir(), 0o700)
	_ = os.WriteFile(filepath.Join(cfg.Dir(), "services.json"), []byte("{broken"), 0o600)
	if _, err := New(cfg).List(); err == nil {
		t.Fatal("first operation must error")
	}
	// the submodule moved the file aside: the NEXT operation sees an empty registry - and must
	// still say the registry was corrupt
	if _, err := New(cfg).List(); err != nil {
		t.Fatalf("later operations work on the fresh empty registry: %v", err)
	}
	if n := r.CorruptNotice(); n == "" {
		t.Fatal("the corruption note vanished after the first error: later operations look like 'no services'")
	}
	rep, err := r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if err != nil || rep.Corrupt == "" {
		t.Fatalf("reconcile must report the unacknowledged corruption: %+v %v", rep, err)
	}
	rep, _ = r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if rep.Corrupt == "" {
		t.Fatal("not reported on the SECOND reconcile")
	}
	var out, errw bytes.Buffer
	env := func(k string) string {
		if k == "LLMCTL_STATE_DIR" {
			return cfg.StateDir
		}
		return ""
	}
	if code := RunRegistry([]string{"diff", "--live", ""}, env, &out, &errw); code != ExitFailure || !strings.Contains(errw.String(), "corrupt") {
		t.Fatalf("diff must fail while the corruption is unacknowledged: %d %q", code, errw.String())
	}
	out.Reset()
	if code := RunRegistry([]string{"reconcile", "--strict"}, env, &out, &errw); code != ExitFailure {
		t.Fatalf("reconcile --strict must fail on corruption: %d", code)
	}
	out.Reset()
	if code := RunRegistry([]string{"ack-corrupt"}, env, &out, &errw); code != ExitOK || !strings.Contains(out.String(), "acknowledged") {
		t.Fatalf("ack: %d %q", code, out.String())
	}
	if r.CorruptNotice() != "" {
		t.Fatal("ack did not clear the note")
	}
	errw.Reset()
	if code := RunRegistry([]string{"diff", "--live", ""}, env, &out, &errw); code != ExitOK {
		t.Fatalf("after ack the diff is clean: %d %q", code, errw.String())
	}
	// a second corruption keeps BOTH sets of bytes
	_ = os.WriteFile(filepath.Join(cfg.Dir(), "services.json"), []byte("{broken-2"), 0o600)
	_, _ = New(cfg).List()
	m, _ := filepath.Glob(filepath.Join(cfg.Dir(), "services.json.corrupt*"))
	if len(m) < 2 {
		t.Fatalf("the first corrupt copy was overwritten by the second corruption: %v", m)
	}
}

// ---- G-074: --prune-unknown-after ---------------------------------------------------------

func TestG074PruneUnknownAfter(t *testing.T) {
	pki := newTestPKI(t, time.Time{}, time.Time{})
	h, p := tlsServer(t, pki, 200)
	cfg := testCfg(t)
	cfg.CACert = "" // no CA anywhere: the https row is "unknown"
	r := New(cfg)
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	r.Now = func() time.Time { return now }
	if err := r.Register(selfHTTPS(h, p)); err != nil {
		t.Fatal(err)
	}
	// default (off): unknown for a week, still kept
	for _, d := range []time.Duration{0, time.Hour, 7 * 24 * time.Hour} {
		now = now.Add(d)
		rep, err := r.Reconcile(context.Background(), ReconcileOptions{Grace: 0})
		if err != nil || len(rep.Removed) != 0 || len(rep.Unknown) != 1 {
			t.Fatalf("default must never remove an unknown row (+%s): %+v %v", d, rep, err)
		}
	}
	// opted in: kept before D, removed at D
	rep, _ := r.Reconcile(context.Background(), ReconcileOptions{PruneUnknownAfter: 30 * 24 * time.Hour})
	if len(rep.Removed) != 0 {
		t.Fatalf("removed before the prune-unknown window elapsed: %+v", rep)
	}
	now = now.Add(31 * 24 * time.Hour)
	rep, _ = r.Reconcile(context.Background(), ReconcileOptions{PruneUnknownAfter: 30 * 24 * time.Hour})
	if len(rep.Removed) != 1 || !strings.Contains(rep.Removed[0].Reason, "prune-unknown-after") {
		t.Fatalf("an unknown row older than D must be removed with the reason: %+v", rep)
	}
	if l, _ := r.List(); len(l) != 0 {
		t.Fatalf("row still listed: %+v", l)
	}
}

// ---- C-11: a port hold outlives a cold model load ---------------------------------------------

func TestC11PortHoldSurvivesDefaultGraceButNotForever(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 6)
	r := New(cfg)
	ref := time.Now()
	loading := NewPorts(cfg, func(string) string { return "" })
	loading.now = func() time.Time { return ref.Add(-120 * time.Second) } // allocated 2 minutes ago, still loading its model
	res, err := loading.Allocate(PortRequest{Name: "onnx-loading"})
	if err != nil {
		t.Fatal(err)
	}
	abandoned := NewPorts(cfg, func(string) string { return "" })
	abandoned.now = func() time.Time { return ref.Add(-2 * DefaultPortGrace) }
	if _, err := abandoned.Allocate(PortRequest{Name: "abandoned"}); err != nil {
		t.Fatal(err)
	}
	rep, err := r.Reconcile(context.Background(), ReconcileOptions{})
	if err != nil {
		t.Fatal(err)
	}
	held, _ := NewPorts(cfg, nil).Held()
	if held["onnx-loading"] != res.Port {
		t.Fatalf("a hold of an engine still loading its model (2 min) was pruned: held=%v", held)
	}
	if _, ok := held["abandoned"]; ok || rep.PortsPruned != 1 {
		t.Fatalf("a hold abandoned for 2x the model-load grace must be pruned: held=%v pruned=%d", held, rep.PortsPruned)
	}
}

// C-11 (CLI): `registry reconcile` defaults --port-grace to 600s and to LLMCTL_REGISTER_WAIT when larger.
func TestC11CLIPortGraceFollowsRegisterWait(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 6)
	old := NewPorts(cfg, func(string) string { return "" })
	old.now = func() time.Time { return time.Now().Add(-700 * time.Second) } // 11m40s old, port never bound
	if _, err := old.Allocate(PortRequest{Name: "loading"}); err != nil {
		t.Fatal(err)
	}
	run := func(wait string) int {
		var out, errw bytes.Buffer
		env := func(k string) string {
			switch k {
			case "LLMCTL_STATE_DIR":
				return cfg.StateDir
			case "LLMCTL_REGISTER_WAIT":
				return wait
			}
			return ""
		}
		if c := RunRegistry([]string{"reconcile"}, env, &out, &errw); c != ExitOK {
			t.Fatalf("reconcile: %d %s", c, errw.String())
		}
		h, _ := NewPorts(cfg, nil).Held()
		return len(h)
	}
	if n := run("1800"); n != 1 {
		t.Fatalf("with LLMCTL_REGISTER_WAIT=1800 a 700s-old hold of a loading engine must be kept, holds=%d", n)
	}
	if n := run(""); n != 0 {
		t.Fatalf("with the default grace (600s) a 700s-old unbound hold is pruned, holds=%d", n)
	}
}

// drain empties pending snapshots without blocking.
func drain(ch <-chan Snapshot) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

// recvPID waits until a snapshot with exactly one entry carrying the wanted pid arrives.
func recvPID(t *testing.T, ch <-chan Snapshot, d time.Duration, pid int) (Snapshot, bool) {
	t.Helper()
	deadline := time.After(d)
	for {
		select {
		case s, ok := <-ch:
			if !ok {
				return Snapshot{}, false
			}
			if len(s.Entries) == 1 && s.Entries[0].PID == pid {
				return s, true
			}
		case <-deadline:
			return Snapshot{}, false
		}
	}
}
