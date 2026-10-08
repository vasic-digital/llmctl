package vantage

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"digital.vasic.containers/pkg/runtime"

	"github.com/vasic-digital/llmctl/internal/vantage/probecore"
)

var (
	cachedProbe string
	probeErr    error
)

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "vantage-test-probe-")
	if err != nil {
		panic(err)
	}
	cachedProbe, probeErr = BuildProbe(context.Background(), dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

func probe(t *testing.T) string {
	t.Helper()
	if probeErr != nil {
		t.Skipf("cannot build the static probe here: %v", probeErr)
	}
	return cachedProbe
}

func newMgr(t *testing.T, f *fakeRT, mut ...func(*Options)) *Manager {
	t.Helper()
	o := Options{Runtime: f, StateDir: t.TempDir(), ProbeBin: probe(t), HostIP: "192.168.1.115", Images: []string{"img-a", "img-b"}}
	for _, m := range mut {
		m(&o)
	}
	return New(o)
}

func TestUpBootsThroughRuntimeWithSafeFlags(t *testing.T) {
	f := newFake()
	m := newMgr(t, f)
	st, err := m.Up(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(st.Name, NamePrefix) || st.IP != "10.0.2.100" || st.Gateway != "10.0.2.2" || st.HostIP != "192.168.1.115" || st.Network != NetSlirp || st.ID != "deadbeef" {
		t.Fatalf("state: %+v", st)
	}
	args := strings.Join(f.lastArgs(), " ")
	for _, want := range []string{"--rm", "-d", "--network slirp4netns", "--memory 64m", "--cap-drop all", "--read-only", "--pids-limit 64", "--pull=never", "--name " + st.Name, "--entrypoint /vantage/vantage-probe", ":/vantage:ro", "--label llmctl.vantage=1"} {
		if !strings.Contains(args, want) {
			t.Errorf("run argv lacks %q: %s", want, args)
		}
	}
	// state file persisted and 0600
	b, err := os.ReadFile(filepath.Join(m.o.StateDir, "vantage", "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	var disk State
	if json.Unmarshal(b, &disk) != nil || disk.Name != st.Name || disk.IP != "10.0.2.100" {
		t.Fatalf("disk state: %s", b)
	}
	if fi, _ := os.Stat(filepath.Join(m.o.StateDir, "vantage", "state.json")); fi.Mode().Perm() != 0o600 {
		t.Fatalf("state mode %v", fi.Mode())
	}
	// staged probe is executable and static
	if fi, err := os.Stat(filepath.Join(st.ProbeDir, ProbeName)); err != nil || fi.Mode().Perm() != 0o755 {
		t.Fatalf("staged probe: %v %v", fi, err)
	}
	// idempotent: second Up runs nothing new
	n := len(f.runs)
	st2, err := m.Up(context.Background())
	if err != nil || st2.Name != st.Name || len(f.runs) != n {
		t.Fatalf("second up must reuse: %v %+v runs=%d->%d", err, st2, n, len(f.runs))
	}
}

func TestUpFallsBackAcrossMissingImagesAndReportsAll(t *testing.T) {
	f := newFake()
	f.missing["img-a"] = true
	st, err := newMgr(t, f).Up(context.Background())
	if err != nil || st.Image != "img-b" {
		t.Fatalf("%v %+v", err, st)
	}
	f2 := newFake()
	f2.missing["img-a"], f2.missing["img-b"] = true, true
	m := newMgr(t, f2)
	_, err = m.Up(context.Background())
	if err == nil || !strings.Contains(err.Error(), "img-a") || !strings.Contains(err.Error(), "img-b") || !strings.Contains(err.Error(), "image not known") {
		t.Fatalf("error must list every candidate: %v", err)
	}
	if s, _ := m.Load(); s != nil {
		t.Fatal("no state may be left after a failed up")
	}
}

func TestUpUnavailableAndBadInputs(t *testing.T) {
	f := newFake()
	f.unavailable = true
	if _, err := newMgr(t, f).Up(context.Background()); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("want ErrUnavailable, got %v", err)
	}
	if _, err := newMgr(t, newFake(), func(o *Options) { o.Network = "pasta" }).Up(context.Background()); err == nil || !strings.Contains(err.Error(), "pasta") {
		t.Fatalf("pasta must be refused: %v", err)
	}
	if _, err := newMgr(t, newFake(), func(o *Options) { o.StateDir = "" }).Up(context.Background()); err == nil {
		t.Fatal("state dir required")
	}
	if _, err := newMgr(t, newFake(), func(o *Options) { o.ProbeBin = "/etc/hostname" }).Up(context.Background()); err == nil || !strings.Contains(err.Error(), "ELF") {
		t.Fatalf("non-ELF probe must be refused: %v", err)
	}
}

func TestUpCleansUpWhenContainerNeverReady(t *testing.T) {
	f := newFake()
	f.execExit = 1
	m := newMgr(t, f)
	m.o.Runtime = f
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // do not wait 6 s of retries
	if _, err := m.Up(ctx); err == nil {
		t.Fatal("expected failure")
	}
	if len(f.removed) == 0 || len(f.containers) != 0 {
		t.Fatalf("container leaked: removed=%v left=%v", f.removed, f.containers)
	}
	if s, _ := m.Load(); s != nil {
		t.Fatal("state leaked")
	}
}

func TestDownIsIdempotentAndOnlyTouchesOwnPrefix(t *testing.T) {
	f := newFake()
	f.containers["someone-elses-db"] = runtime.StateRunning
	m := newMgr(t, f)
	st, err := m.Up(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Down(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, ok := f.containers[st.Name]; ok {
		t.Fatal("vantage container not removed")
	}
	if _, ok := f.containers["someone-elses-db"]; !ok {
		t.Fatal("down touched a container that is not ours")
	}
	if _, err := os.Stat(filepath.Join(m.o.StateDir, "vantage")); !os.IsNotExist(err) {
		t.Fatal("state dir must be gone")
	}
	if err := m.Down(context.Background()); err != nil {
		t.Fatalf("second down must succeed: %v", err)
	}
	if err := m.removeContainer(context.Background(), "someone-elses-db"); err == nil {
		t.Fatal("removeContainer must refuse foreign names")
	}
}

func TestDownSweepsUntrackedLabelledStragglersAndReportsRemoveFailure(t *testing.T) {
	f := newFake()
	m := newMgr(t, f)
	f.containers[NamePrefix+"orphan"] = runtime.StateRunning // crash between run and save
	f.labels[NamePrefix+"orphan"] = map[string]string{LabelKey: "1", LabelOwner: m.ownerID()}
	if err := m.Down(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(f.containers) != 0 {
		t.Fatalf("orphan survived: %v", f.containers)
	}
	f.containers[NamePrefix+"stuck"] = runtime.StateRunning
	f.labels[NamePrefix+"stuck"] = map[string]string{LabelKey: "1", LabelOwner: m.ownerID()}
	f.removeErr = errors.New("device busy")
	if err := m.Down(context.Background()); err == nil || !strings.Contains(err.Error(), "device busy") {
		t.Fatalf("a failing removal must be reported, not hidden: %v", err)
	}
	if s, _ := m.Load(); s != nil {
		t.Log("state kept on failure is acceptable")
	}
}

func TestStaleStateIsCleanedByUp(t *testing.T) {
	f := newFake()
	m := newMgr(t, f)
	st, _ := m.Up(context.Background())
	f.containers[st.Name] = runtime.StateStopped // died behind our back
	st2, err := m.Up(context.Background())
	if err != nil || st2.Name == st.Name {
		t.Fatalf("a dead vantage must be replaced: %v %+v", err, st2)
	}
}

func TestExecProbeProbePortsRequireRunningVantage(t *testing.T) {
	f := newFake()
	m := newMgr(t, f)
	ctx := context.Background()
	if _, err := m.Exec(ctx, []string{"id"}); err == nil || !strings.Contains(err.Error(), "not up") {
		t.Fatalf("%v", err)
	}
	if _, err := m.Probe(ctx, ProbeRequest{URL: "https://x"}); err == nil {
		t.Fatal("probe without vantage")
	}
	if _, err := m.ProbePorts(ctx, "1.2.3.4", []int{1}); err == nil {
		t.Fatal("probe-ports without vantage")
	}
	st, _ := m.Up(ctx)
	f.execOut["http"] = `{"url":"u","tls":true,"status":200,"tls_verified":true}`
	ca := filepath.Join(t.TempDir(), "ca.pem")
	os.WriteFile(ca, []byte("PEM"), 0o600)
	r, err := m.Probe(ctx, ProbeRequest{URL: "u", CAFile: ca, Method: "GET", Headers: []string{"A:b"}, Body: "x", ServerName: "n", Timeout: 1})
	if err != nil || r.Status != 200 || !r.TLSVerified {
		t.Fatalf("%v %+v", err, r)
	}
	if _, err := m.Probe(ctx, ProbeRequest{URL: "u", CAFile: "/nonexistent"}); err == nil {
		t.Fatal("missing cacert must be an error")
	}
	f.execOut["dial"] = `{"host":"h","results":[],"reachable":[12]}`
	d, err := m.ProbePorts(ctx, "h", []int{12, 13})
	if err != nil || len(d.Reachable) != 1 || d.Reachable[0] != 12 {
		t.Fatalf("%v %+v", err, d)
	}
	f.execExit = 3
	if _, err := m.ProbePorts(ctx, "h", []int{1}); err == nil {
		t.Fatal("non-zero probe exit must be an error")
	}
	f.execExit = 0
	f.execOut["dial"] = "not json"
	if _, err := m.ProbePorts(ctx, "h", []int{1}); err == nil {
		t.Fatal("non-JSON must be an error")
	}
	f.containers[st.Name] = runtime.StateStopped
	if _, err := m.Exec(ctx, []string{"id"}); err == nil || !strings.Contains(err.Error(), "not running") {
		t.Fatalf("%v", err)
	}
	s, err := m.Status(ctx)
	if err != nil || s.Up || s.State == nil {
		t.Fatalf("status: %+v %v", s, err)
	}
}

func TestEvaluateSelfCheckCatchesWrongAddresses(t *testing.T) {
	all := func(cs []Check) bool {
		for _, c := range cs {
			if !c.OK {
				return false
			}
		}
		return true
	}
	good := EvaluateSelfCheck("192.168.1.115", "10.0.2.100", "192.168.1.115:5000", "10.0.2.100:4000", "192.168.1.115:5000")
	if !all(good) {
		t.Fatalf("good observation must pass: %+v", good)
	}
	bad := map[string][]string{
		"peer is loopback":            {"192.168.1.115", "10.0.2.100", "127.0.0.1:5000", "10.0.2.100:4000", "127.0.0.1:5000"},
		"container source loopback":   {"192.168.1.115", "127.0.0.1", "192.168.1.115:5000", "127.0.0.1:4000", "192.168.1.115:5000"},
		"container uses the host IP":  {"192.168.1.115", "10.0.2.100", "192.168.1.115:5000", "192.168.1.115:4000", "192.168.1.115:5000"},
		"source is not container IP":  {"192.168.1.115", "10.0.2.100", "192.168.1.115:5000", "10.0.2.77:4000", "192.168.1.115:5000"},
		"echo disagrees with server":  {"192.168.1.115", "10.0.2.100", "192.168.1.115:5000", "10.0.2.100:4000", "192.168.1.115:5001"},
		"server never saw connection": {"192.168.1.115", "10.0.2.100", "", "10.0.2.100:4000", ""},
	}
	for name, a := range bad {
		if all(EvaluateSelfCheck(a[0], a[1], a[2], a[3], a[4])) {
			t.Errorf("%s: self-check must FAIL", name)
		}
	}
}

func TestSelfCheckEndToEndWithFake(t *testing.T) {
	f := newFake()
	m := newMgr(t, f, func(o *Options) { o.HostIP = "127.0.0.1" })
	if _, err := m.Up(context.Background()); err != nil {
		t.Fatal(err)
	}
	// the fake "container" does not really dial: the probe must fail to reach the
	// echo server's body -> selfcheck must not claim success
	f.execOut["http"] = `{"url":"u","status":200,"local_addr":"10.0.2.100:1","body":"x"}`
	res, err := m.SelfCheck(context.Background())
	if err == nil && res.OK {
		t.Fatalf("selfcheck must not pass when the server never saw the container: %+v", res)
	}
	f.execOut["http"] = `{"url":"u","error":"dial refused","error_class":"connect"}`
	if _, err := m.SelfCheck(context.Background()); err == nil || !strings.Contains(err.Error(), "could not reach") {
		t.Fatalf("%v", err)
	}
}

func TestProbeMeets(t *testing.T) {
	ok := probecore.HTTPResult{TLS: true, TLSVerified: true, Status: 200}
	cases := []struct {
		r       probecore.HTTPResult
		status  int
		tlsFail bool
		want    bool
	}{
		{ok, 0, false, true},
		{ok, 200, false, true},
		{ok, 401, false, false},
		{probecore.HTTPResult{TLS: true, TLSVerified: false, ErrorClass: "tls_verify", Error: "x"}, 0, false, false},
		{probecore.HTTPResult{TLS: true, TLSVerified: false, ErrorClass: "tls_verify", Error: "x"}, 0, true, true},
		{probecore.HTTPResult{TLS: true, TLSVerified: false, ErrorClass: "connect", Error: "x"}, 0, true, false},
		{ok, 0, true, false},
		{probecore.HTTPResult{Status: 200, Error: "boom"}, 0, false, false},
		{probecore.HTTPResult{Status: 200}, 200, false, true}, // plain http
	}
	for i, c := range cases {
		if got := ProbeMeets(c.r, c.status, c.tlsFail); got != c.want {
			t.Errorf("case %d: got %v want %v", i, got, c.want)
		}
	}
}

func TestHostIPIsNotLoopback(t *testing.T) {
	ip, err := HostIP()
	if err != nil {
		t.Skip("no non-loopback address on this host")
	}
	if isLoopback(ip) || ip == "" {
		t.Fatal(ip)
	}
}

func TestRequireStatic(t *testing.T) {
	if err := RequireStatic(probe(t)); err != nil {
		t.Fatal(err)
	}
	exe, _ := os.Executable() // the go test binary: dynamically linked with cgo net? only assert it is judged, not crash
	_ = RequireStatic(exe)
	if err := RequireStatic("/nonexistent"); err == nil {
		t.Fatal()
	}
	if _, err := findModuleRoot(); err != nil {
		t.Fatalf("module root must be found from the test cwd: %v", err)
	}
}

func TestCLI(t *testing.T) {
	run := func(f *fakeRT, args ...string) (int, string, string) {
		var o, e bytes.Buffer
		env := map[string]string{"LLMCTL_STATE_DIR": t.TempDir(), "LLMCTL_VANTAGE_PROBE": probe(t)}
		return Run(args, func(k string) string { return env[k] }, f, &o, &e), o.String(), e.String()
	}
	if c, _, e := run(newFake()); c != ExitUsage || !strings.Contains(e, "usage") {
		t.Fatal(c, e)
	}
	if c, _, _ := run(newFake(), "bogus"); c != ExitUsage {
		t.Fatal(c)
	}
	if c, _, _ := run(newFake(), "probe"); c != ExitUsage {
		t.Fatal("probe needs --url")
	}
	if c, _, _ := run(newFake(), "probe-ports", "--ports", "1"); c != ExitUsage {
		t.Fatal("probe-ports needs --host-ip")
	}
	if c, _, _ := run(newFake(), "exec"); c != ExitUsage {
		t.Fatal("exec needs argv")
	}
	if c, _, _ := run(newFake(), "--nope"); c != ExitUsage {
		t.Fatal("bad flag")
	}
	un := newFake()
	un.unavailable = true
	if c, _, e := run(un, "up", "--host-ip", "192.168.1.115"); c != ExitUnavailable || !strings.Contains(e, "unavailable") {
		t.Fatalf("%d %s", c, e)
	}
	f := newFake()
	// one shared state dir across invocations
	dir := t.TempDir()
	env := map[string]string{"LLMCTL_STATE_DIR": dir, "LLMCTL_VANTAGE_PROBE": probe(t)}
	call := func(args ...string) (int, string, string) {
		var o, e bytes.Buffer
		c := Run(args, func(k string) string { return env[k] }, f, &o, &e)
		return c, o.String(), e.String()
	}
	if c, o, e := call("up", "--host-ip", "192.168.1.115", "--image", "img-z"); c != ExitOK || !strings.Contains(o, `"ip":"10.0.2.100"`) {
		t.Fatal(c, o, e)
	}
	if c, o, _ := call("status"); c != ExitOK || !strings.Contains(o, `"up":true`) {
		t.Fatal(c, o)
	}
	f.execOut["id"] = "uid=0\n"
	if c, o, _ := call("exec", "--", "id"); c != ExitOK || o != "uid=0\n" {
		t.Fatal(c, o)
	}
	f.execOut["http"] = `{"url":"u","tls":true,"status":200,"tls_verified":true}`
	if c, _, _ := call("probe", "--url", "u", "--expect-status", "200", "--header", "A:b"); c != ExitOK {
		t.Fatal(c)
	}
	if c, _, _ := call("probe", "--url", "u", "--expect-status", "500"); c != ExitFailure {
		t.Fatal(c)
	}
	f.execOut["dial"] = `{"host":"h","results":[],"reachable":[]}`
	if c, _, e := call("probe-ports", "--host-ip", "h", "--ports", "1,2"); c != ExitOK {
		t.Fatal(c, e)
	}
	if c, _, _ := call("down"); c != ExitOK {
		t.Fatal(c)
	}
	if c, o, _ := call("status"); c != ExitOK || strings.Contains(o, `"up":true`) {
		t.Fatal(c, o)
	}
	if c, _, _ := call("exec", "--", "id"); c != ExitFailure {
		t.Fatal("exec after down must fail")
	}
}
