package registry

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func httpEntry(name string, port int, p *proc, token string) Entry {
	return Entry{
		Name: name, Host: "127.0.0.1", Port: port, Protocol: "http", HealthPath: "/health",
		Labels: map[string]string{"kind": "decision", "profile": name, "protocol": "http", "instance": "1"},
		PID:    p.pid(), CmdToken: token, LoopbackOnly: true,
	}
}

func startSvc(t *testing.T, name string, sick bool) (*proc, Entry) {
	t.Helper()
	port := freePort(t)
	token := "tok-" + name
	args := []string{"listen", fmt.Sprint(port), token}
	if sick {
		args = append(args, "sick")
	}
	p := spawn(t, args...)
	return p, httpEntry(name, port, p, token)
}

func TestRegisterListGetUnregisterRoundTrip(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	p, e := startSvc(t, "decide-nli", false)
	before := time.Now()
	if err := r.Register(e); err != nil {
		t.Fatal(err)
	}
	got, ok, err := r.Get("decide-nli")
	if err != nil || !ok {
		t.Fatalf("get: %v %v", ok, err)
	}
	if got.Port != e.Port || got.PID != p.pid() || got.CmdToken != "tok-decide-nli" || !got.LoopbackOnly || !got.Healthy {
		t.Fatalf("round trip lost data: %+v", got)
	}
	if got.Labels["kind"] != "decision" || got.Labels["instance"] != "1" || got.Labels["profile"] != "decide-nli" {
		t.Fatalf("labels: %v", got.Labels)
	}
	for k := range got.Labels {
		if strings.HasPrefix(k, "llmctl.") {
			t.Fatalf("internal key %q leaked into Labels", k)
		}
	}
	if got.Started.Before(before.Add(-time.Second)) || got.Started.After(time.Now().Add(time.Second)) {
		t.Fatalf("started %v", got.Started)
	}
	if got.URL() != fmt.Sprintf("http://127.0.0.1:%d", e.Port) {
		t.Fatalf("url %q", got.URL())
	}
	list, _ := New(cfg).List() // a fresh handle (another process) sees it
	if len(list) != 1 || list[0].Name != "decide-nli" {
		t.Fatalf("list %+v", list)
	}
	if ok, err := r.Unregister("decide-nli"); !ok || err != nil {
		t.Fatalf("unregister %v %v", ok, err)
	}
	if ok, err := r.Unregister("decide-nli"); ok || err != nil {
		t.Fatalf("second unregister must be a no-op: %v %v", ok, err)
	}
	if list, _ := r.List(); len(list) != 0 {
		t.Fatalf("not removed: %+v", list)
	}
}

func TestHTTPSURLScheme(t *testing.T) {
	e := Entry{Host: "127.0.0.1", Port: 8095, Protocol: "https"}
	if e.URL() != "https://127.0.0.1:8095" {
		t.Fatal(e.URL())
	}
	e6 := Entry{Host: "::1", Port: 8095, Protocol: "http"}
	if e6.URL() != "http://[::1]:8095" {
		t.Fatal(e6.URL())
	}
}

func TestRegisterValidation(t *testing.T) {
	r := New(testCfg(t))
	cases := map[string]Entry{
		"empty name":         {Port: 8000, PID: 4242, CmdToken: "x"},
		"port 0":             {Name: "a", Port: 0, PID: 4242, CmdToken: "x"},
		"port too big":       {Name: "a", Port: 70000, PID: 4242, CmdToken: "x"},
		"pid 0":              {Name: "a", Port: 8000, PID: 0, CmdToken: "x"},
		"pid 1":              {Name: "a", Port: 8000, PID: 1, CmdToken: "x"},
		"negative pid":       {Name: "a", Port: 8000, PID: -3, CmdToken: "x"},
		"no token":           {Name: "a", Port: 8000, PID: 4242},
		"bad protocol":       {Name: "a", Port: 8000, PID: 4242, CmdToken: "x", Protocol: "ftp"},
		"reserved label key": {Name: "a", Port: 8000, PID: 4242, CmdToken: "x", Labels: map[string]string{"llmctl.pid": "1"}},
		"name with slash":    {Name: "a/b", Port: 8000, PID: 4242, CmdToken: "x"},
	}
	for n, e := range cases {
		if err := r.Register(e); err == nil {
			t.Errorf("%s: accepted %+v", n, e)
		}
	}
	if l, _ := r.List(); len(l) != 0 {
		t.Fatalf("invalid entries persisted: %+v", l)
	}
}

func TestRegisterRefusesLivePortCollisionButReapsDeadHolder(t *testing.T) {
	r := New(testCfg(t))
	p1, e1 := startSvc(t, "one", false)
	if err := r.Register(e1); err != nil {
		t.Fatal(err)
	}
	p2 := spawn(t, "hold", "tok-two")
	e2 := Entry{Name: "two", Host: "127.0.0.1", Port: e1.Port, Protocol: "tcp", PID: p2.pid(), CmdToken: "tok-two"}
	if err := r.Register(e2); err == nil || !strings.Contains(err.Error(), "one") {
		t.Fatalf("live holder: want refusal naming 'one', got %v", err)
	}
	p1.kill() // the holder dies without unregistering
	if err := r.Register(e2); err != nil {
		t.Fatalf("dead holder must be reaped at register: %v", err)
	}
	l, _ := r.List()
	if len(l) != 1 || l[0].Name != "two" {
		t.Fatalf("%+v", l)
	}
}

func TestReRegisterSameNameUpdates(t *testing.T) {
	r := New(testCfg(t))
	p, e := startSvc(t, "svc", false)
	_ = r.Register(e)
	first, _, _ := r.Get("svc")
	e.Labels["instance"] = "2"
	if err := r.Register(e); err != nil {
		t.Fatal(err)
	}
	second, _, _ := r.Get("svc")
	if second.Labels["instance"] != "2" || !second.Started.Equal(first.Started) && second.Started.Before(first.Started) {
		t.Fatalf("%+v", second)
	}
	_ = p
}

func TestResolveHealthyOnlyAndLabelMatch(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	_, a := startSvc(t, "a", false)
	_, b := startSvc(t, "b", false)
	b.Labels["kind"] = "encoder"
	_, c := startSvc(t, "c", false)
	for _, e := range []Entry{a, b, c} {
		if err := r.Register(e); err != nil {
			t.Fatal(err)
		}
	}
	got, err := r.Resolve(map[string]string{"kind": "decision"})
	if err != nil || len(got) != 2 || got[0].Name != "a" || got[1].Name != "c" {
		t.Fatalf("resolve decision: %v %+v", err, got)
	}
	got, _ = r.Resolve(map[string]string{"kind": "encoder", "profile": "b"})
	if len(got) != 1 || got[0].Name != "b" {
		t.Fatalf("%+v", got)
	}
	if got, _ := r.Resolve(map[string]string{"kind": "nope"}); len(got) != 0 {
		t.Fatalf("%+v", got)
	}
	// make "a" unhealthy: it must vanish from Resolve but stay in List
	_ = r.markHealth("a", false, time.Now())
	got, _ = r.Resolve(map[string]string{"kind": "decision"})
	if len(got) != 1 || got[0].Name != "c" {
		t.Fatalf("unhealthy entry still routable: %+v", got)
	}
	if all, _ := r.List(); len(all) != 3 {
		t.Fatalf("list must show unhealthy entries too: %+v", all)
	}
}

// ---- liveness from the REAL process identity -------------------------------

func TestOSIdentity(t *testing.T) {
	p := spawn(t, "hold", "my-token")
	if !OSIdentity(p.pid(), "my-token") {
		t.Fatal("live process with its token must be alive")
	}
	if OSIdentity(p.pid(), "other-token") {
		t.Fatal("wrong token must not match")
	}
	if OSIdentity(p.pid(), "") {
		t.Fatal("empty token must never match")
	}
	for _, pid := range []int{0, 1, -1, -100} {
		if OSIdentity(pid, "my-token") {
			t.Fatalf("pid %d must never be considered", pid)
		}
	}
	if OSIdentity(os.Getpid()+9999999, "my-token") {
		t.Fatal("nonexistent pid alive")
	}
	pid := p.pid()
	p.kill()
	if OSIdentity(pid, "my-token") {
		t.Fatal("killed process still alive")
	}
}

// A process that merely MENTIONS the token inside a longer argument (a shell
// quoting it, a launcher, a log tailer) is not the service (never a bare
// substring match).
func TestOSIdentityRejectsCarriers(t *testing.T) {
	cmd := exec.Command("sh", "-c", "sleep 300; : supervising tok-svc forever")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() })
	time.Sleep(100 * time.Millisecond)
	if OSIdentity(cmd.Process.Pid, "tok-svc") {
		t.Fatal("a carrier whose argument merely contains the token was treated as the service")
	}
	// but a real argv element equal to the token, a basename, or --flag=token matches
	cmd2 := exec.Command("sleep", "300")
	cmd2.Args[0] = "/opt/llmctl/bin/llama-server"
	if err := cmd2.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd2.Process.Kill(); _, _ = cmd2.Process.Wait() })
	time.Sleep(100 * time.Millisecond)
	if !OSIdentity(cmd2.Process.Pid, "llama-server") {
		t.Fatal("basename of argv[0] must match")
	}
}

func TestOSIdentityZombieIsDead(t *testing.T) {
	cmd := exec.Command(os.Args[0], "__helper", "hold", "zz-token")
	out, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 6)
	_, _ = out.Read(buf)
	_ = cmd.Process.Kill() // not waited: becomes a zombie
	time.Sleep(200 * time.Millisecond)
	if OSIdentity(cmd.Process.Pid, "zz-token") {
		t.Fatal("a zombie (killed, unreaped) must not count as alive")
	}
	_, _ = cmd.Process.Wait()
}

// ---- reconcile ---------------------------------------------------------------

func TestReconcileRemovesKilledWithinOneCall(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	p1, e1 := startSvc(t, "alive", false)
	p2, e2 := startSvc(t, "doomed", false)
	_ = p1
	_ = r.Register(e1)
	_ = r.Register(e2)
	p2.kill()
	rep, err := r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	if len(rep.Removed) != 1 || rep.Removed[0].Name != "doomed" || !strings.Contains(rep.Removed[0].Reason, "process") {
		t.Fatalf("report %+v", rep)
	}
	l, _ := r.List()
	if len(l) != 1 || l[0].Name != "alive" || !l[0].Healthy {
		t.Fatalf("%+v", l)
	}
}

func TestReconcileDetectsPidReuseByDifferentProgram(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	port := freePort(t)
	impostor := spawn(t, "hold", "something-else") // alive pid, but not our service
	e := Entry{Name: "svc", Host: "127.0.0.1", Port: port, Protocol: "tcp", PID: impostor.pid(), CmdToken: "tok-svc"}
	// Register itself now refuses a pid that does not run the program (C2-07) ...
	if err := r.Register(e); err == nil {
		t.Fatal("Register accepted a pid that runs another program")
	}
	// ... so model pid reuse the way it happens: the row was registered while the pid WAS the service
	// (injected identity), and the pid is later handed to a different program (the real identity check).
	r.Identity = func(int, string) bool { return true }
	if err := r.Register(e); err != nil {
		t.Fatal(err)
	}
	r.Identity = nil
	rep, _ := r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if len(rep.Removed) != 1 || !strings.Contains(rep.Removed[0].Reason, "identity") {
		t.Fatalf("pid reuse not detected: %+v", rep)
	}
}

func TestReconcileHealthGraceThenRemoval(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	r.Now = func() time.Time { return now }
	_, e := startSvc(t, "sick", true) // alive process, /health answers 500
	_ = r.Register(e)
	opt := ReconcileOptions{Grace: 30 * time.Second}

	rep, _ := r.Reconcile(context.Background(), opt)
	if len(rep.Unhealthy) != 1 || len(rep.Removed) != 0 {
		t.Fatalf("first failed probe: mark unhealthy, keep: %+v", rep)
	}
	got, _, _ := r.Get("sick")
	if got.Healthy || got.UnhealthySince.IsZero() {
		t.Fatalf("not marked: %+v", got)
	}
	if res, _ := r.Resolve(map[string]string{"kind": "decision"}); len(res) != 0 {
		t.Fatalf("unhealthy entry routable: %+v", res)
	}

	now = now.Add(20 * time.Second) // inside grace
	rep, _ = r.Reconcile(context.Background(), opt)
	if len(rep.Removed) != 0 {
		t.Fatalf("removed inside grace: %+v", rep)
	}
	got, _, _ = r.Get("sick")
	if !got.UnhealthySince.Equal(time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)) {
		t.Fatalf("grace clock reset: %v", got.UnhealthySince)
	}

	now = now.Add(15 * time.Second) // 35s > grace
	rep, _ = r.Reconcile(context.Background(), opt)
	if len(rep.Removed) != 1 || !strings.Contains(rep.Removed[0].Reason, "health") {
		t.Fatalf("not removed past grace: %+v", rep)
	}
	if l, _ := r.List(); len(l) != 0 {
		t.Fatalf("%+v", l)
	}
}

func TestReconcileRecoveryClearsUnhealthy(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	now := time.Now()
	r.Now = func() time.Time { return now }
	_, e := startSvc(t, "flap", false)
	_ = r.Register(e)
	_ = r.markHealth("flap", false, now.Add(-5*time.Second)) // pretend an earlier failure
	rep, _ := r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if len(rep.Healthy) != 1 {
		t.Fatalf("%+v", rep)
	}
	got, _, _ := r.Get("flap")
	if !got.Healthy || !got.UnhealthySince.IsZero() {
		t.Fatalf("recovery not recorded: %+v", got)
	}
}

func TestReconcileTCPProbeForTCPEntries(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	port := freePort(t)
	p := spawn(t, "listen", fmt.Sprint(port), "tok-tcp") // a "tcp" entry is certified by a TCP dial (https now needs a TLS handshake, see tlsprobe_test.go)
	e := Entry{Name: "gw", Host: "127.0.0.1", Port: port, Protocol: "tcp", PID: p.pid(), CmdToken: "tok-tcp"}
	_ = r.Register(e)
	rep, _ := r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if len(rep.Healthy) != 1 {
		t.Fatalf("%+v", rep)
	}
	// a registered port nobody listens on is unhealthy although the pid is alive
	idle := spawn(t, "hold", "tok-idle")
	e2 := Entry{Name: "idle", Host: "127.0.0.1", Port: freePort(t), Protocol: "tcp", PID: idle.pid(), CmdToken: "tok-idle"}
	_ = r.Register(e2)
	rep, _ = r.Reconcile(context.Background(), ReconcileOptions{Grace: time.Minute})
	if len(rep.Unhealthy) != 1 || rep.Unhealthy[0] != "idle" {
		t.Fatalf("%+v", rep)
	}
}

func TestReconcileReleasesPortOfRemovedEntry(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 12)
	ports := NewPorts(cfg, noEnv)
	res, _ := ports.Allocate(PortRequest{Name: "svc"})
	p := spawn(t, "listen", fmt.Sprint(res.Port), "tok-svc")
	r := New(cfg)
	_ = r.Register(Entry{Name: "svc", Host: "127.0.0.1", Port: res.Port, Protocol: "http", HealthPath: "/health", PID: p.pid(), CmdToken: "tok-svc"})
	p.kill()
	if _, err := r.Reconcile(context.Background(), ReconcileOptions{}); err != nil {
		t.Fatal(err)
	}
	if h, _ := ports.Held(); len(h) != 0 {
		t.Fatalf("port hold of a dead service survived reconcile: %v", h)
	}
}

// ---- diff: registry rows must equal the live set -------------------------------

func TestDiff(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	pa, ea := startSvc(t, "a", false)
	pb, eb := startSvc(t, "b", false)
	_ = r.Register(ea)
	_ = r.Register(eb)
	d, err := r.Diff([]LiveService{{"a", pa.pid()}, {"b", pb.pid()}})
	if err != nil || len(d.RegistryOnly)+len(d.LiveOnly)+len(d.PIDMismatch) != 0 {
		t.Fatalf("equal sets reported different: %v %+v", err, d)
	}
	d, _ = r.Diff([]LiveService{{"a", pa.pid()}, {"c", 4242}, {"b", 999999}})
	if len(d.LiveOnly) != 1 || d.LiveOnly[0] != "c" || len(d.PIDMismatch) != 1 || d.PIDMismatch[0] != "b" || len(d.RegistryOnly) != 0 {
		t.Fatalf("%+v", d)
	}
	d, _ = r.Diff([]LiveService{{"a", pa.pid()}})
	if len(d.RegistryOnly) != 1 || d.RegistryOnly[0] != "b" {
		t.Fatalf("%+v", d)
	}
}

// ---- concurrency / crash safety ------------------------------------------------

func TestConcurrentRegistersFromProcessesAndGoroutines(t *testing.T) {
	cfg := testCfg(t)
	gofile := filepath.Join(t.TempDir(), "go")
	const nproc, ngo = 6, 6
	var wg sync.WaitGroup
	for i := 0; i < nproc; i++ {
		cmd := exec.Command(os.Args[0], "__helper", "register", cfg.StateDir, fmt.Sprintf("proc%d", i), fmt.Sprint(41000+i), gofile)
		wg.Add(1)
		go func() {
			defer wg.Done()
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Errorf("register helper: %v %s", err, out)
			}
		}()
	}
	for i := 0; i < ngo; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				if _, err := os.Stat(gofile); err == nil {
					break
				}
				time.Sleep(time.Millisecond)
			}
			// goroutines register the test process itself ("__helper" is not in our argv; use a real token)
			err := New(cfg).Register(Entry{Name: fmt.Sprintf("go%d", i), Port: 42000 + i, Protocol: "tcp", PID: os.Getpid(), CmdToken: filepath.Base(os.Args[0])})
			if err != nil {
				t.Error(err)
			}
		}()
	}
	time.Sleep(200 * time.Millisecond)
	_ = os.WriteFile(gofile, nil, 0o600)
	wg.Wait()
	l, err := New(cfg).List()
	if err != nil {
		t.Fatal(err)
	}
	if len(l) != nproc+ngo {
		t.Fatalf("lost update: %d of %d entries survived", len(l), nproc+ngo)
	}
}

func TestRegistryFileIsAlwaysValidJSONUnderChurn(t *testing.T) {
	cfg := testCfg(t)
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		r := New(cfg)
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			n := fmt.Sprintf("n%d", i%5)
			_ = r.Register(Entry{Name: n, Port: 43000 + i%5, Protocol: "tcp", PID: os.Getpid(), CmdToken: filepath.Base(os.Args[0])})
			_, _ = r.Unregister(n)
		}
	}()
	file := filepath.Join(cfg.Dir(), "services.json")
	deadline := time.Now().Add(1500 * time.Millisecond)
	for time.Now().Before(deadline) {
		b, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		var v map[string]any
		if err := json.Unmarshal(b, &v); err != nil {
			close(stop)
			t.Fatalf("torn/corrupt registry file observed: %v (%q)", err, b)
		}
	}
	close(stop)
	wg.Wait()
}

func TestOrphanTempFilesAndCorruptFile(t *testing.T) {
	cfg := testCfg(t)
	r := New(cfg)
	p, e := startSvc(t, "svc", false)
	_ = p
	_ = r.Register(e)
	// a crashed writer left a temp file behind
	orphan := filepath.Join(cfg.Dir(), "services-123.json.tmp")
	_ = os.WriteFile(orphan, []byte("{"), 0o600)
	if _, err := New(cfg).List(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatal("orphan temp file not reaped")
	}
	// a corrupt registry is surfaced, never silently read as empty
	_ = os.WriteFile(filepath.Join(cfg.Dir(), "services.json"), []byte("{broken"), 0o600)
	if _, err := New(cfg).List(); err == nil || !strings.Contains(err.Error(), "corrupt") {
		t.Fatalf("corrupt registry read as empty: %v", err)
	}
	if _, err := os.Stat(filepath.Join(cfg.Dir(), "services.json.corrupt")); err != nil {
		t.Fatalf("corrupt bytes not preserved: %v", err)
	}
}

// Entry.URL is built by the Containers endpoint package, not re-implemented here (G11).
func TestEntryURLShapes(t *testing.T) {
	for _, c := range []struct {
		e    Entry
		want string
	}{
		{Entry{Host: "127.0.0.1", Port: 8092, Protocol: "http"}, "http://127.0.0.1:8092"},
		{Entry{Host: "127.0.0.1", Port: 8095, Protocol: "https"}, "https://127.0.0.1:8095"},
		{Entry{Host: "::1", Port: 8095, Protocol: "https"}, "https://[::1]:8095"},
		{Entry{Host: "::1", Port: 80, Protocol: "http"}, "http://[::1]:80"},
		{Entry{Host: "box.lan", Port: 9, Protocol: "tcp"}, "http://box.lan:9"},
	} {
		if got := c.e.URL(); got != c.want {
			t.Errorf("%+v: %q want %q", c.e, got, c.want)
		}
	}
}
