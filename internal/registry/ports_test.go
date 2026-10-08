package registry

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func newPorts(t *testing.T, cfg Config, env map[string]string) *Ports {
	t.Helper()
	return NewPorts(cfg, envOf(env))
}

func TestFixedStrategyUsesDocumentedPort(t *testing.T) {
	cfg := testCfg(t)
	p := newPorts(t, cfg, nil)
	port := freePort(t)
	res, err := p.Allocate(PortRequest{Name: "chat-fast", Profile: "chat-fast", Documented: port})
	if err != nil {
		t.Fatal(err)
	}
	if res.Port != port || res.Strategy != "fixed" || res.Source != "documented" {
		t.Fatalf("got %+v", res)
	}
	if res.Var != "LLMCTL_PORT_CHAT_FAST" {
		t.Fatalf("override var = %q", res.Var)
	}
}

func TestFixedStrategyTakenPortFailsLoudly(t *testing.T) {
	cfg := testCfg(t)
	p := newPorts(t, cfg, nil)
	port := freePort(t)
	listener(t, port) // another program occupies the documented port
	_, err := p.Allocate(PortRequest{Name: "chat-fast", Profile: "chat-fast", Documented: port})
	var te *PortTakenError
	if !errors.As(err, &te) {
		t.Fatalf("want PortTakenError, got %v", err)
	}
	msg := err.Error()
	for _, must := range []string{strconv.Itoa(port), "LLMCTL_PORT_CHAT_FAST"} {
		if !strings.Contains(msg, must) {
			t.Errorf("message %q lacks %q", msg, must)
		}
	}
	if h, _ := p.Held(); len(h) != 0 {
		t.Fatalf("failed allocation must not be recorded: %v", h)
	}
}

func TestFixedWithoutDocumentedPortIsUsageError(t *testing.T) {
	p := newPorts(t, testCfg(t), nil)
	if _, err := p.Allocate(PortRequest{Name: "x"}); err == nil || !strings.Contains(err.Error(), "documented port") {
		t.Fatalf("got %v", err)
	}
}

func TestExplicitNumericAlwaysWins(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic // even under the dynamic strategy
	port := freePort(t)
	p := newPorts(t, cfg, map[string]string{"LLMCTL_PORT_VISION": strconv.Itoa(port)})
	res, err := p.Allocate(PortRequest{Name: "vision", Profile: "vision", Documented: 8101})
	if err != nil {
		t.Fatal(err)
	}
	if res.Port != port || res.Source != "explicit" {
		t.Fatalf("got %+v", res)
	}
}

func TestExplicitNumericTakenFails(t *testing.T) {
	port := freePort(t)
	listener(t, port)
	p := newPorts(t, testCfg(t), map[string]string{"LLMCTL_PORT_VISION": strconv.Itoa(port)})
	_, err := p.Allocate(PortRequest{Name: "vision", Profile: "vision", Documented: 8101})
	var te *PortTakenError
	if !errors.As(err, &te) || te.Port != port {
		t.Fatalf("got %v", err)
	}
}

func TestInvalidExplicitValue(t *testing.T) {
	for _, v := range []string{"abc", "0", "70000", "-5", "80x"} {
		p := newPorts(t, testCfg(t), map[string]string{"LLMCTL_PORT_VISION": v})
		if _, err := p.Allocate(PortRequest{Name: "vision", Profile: "vision", Documented: 8101}); err == nil || !strings.Contains(err.Error(), "LLMCTL_PORT_VISION") {
			t.Errorf("value %q: got %v", v, err)
		}
	}
}

func TestPerProfileAutoIsDynamicWhileGlobalIsFixed(t *testing.T) {
	cfg := testCfg(t)
	taken := freePort(t)
	listener(t, taken)
	p := newPorts(t, cfg, map[string]string{"LLMCTL_PORT_CHAT": "auto"})
	res, err := p.Allocate(PortRequest{Name: "chat", Profile: "chat", Documented: taken})
	if err != nil {
		t.Fatal(err)
	}
	if res.Strategy != "dynamic" || res.Port == taken || res.Port < cfg.RangeLo || res.Port > cfg.RangeHi {
		t.Fatalf("got %+v", res)
	}
}

func TestDynamicSkipsOccupiedDefaultPort_SC015(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 6)
	// one port of the range is occupied by another program
	listener(t, cfg.RangeLo)
	p := newPorts(t, cfg, nil)
	seen := map[int]bool{}
	for _, n := range []string{"a", "b", "c"} {
		res, err := p.Allocate(PortRequest{Name: n, Profile: n, Documented: cfg.RangeLo})
		if err != nil {
			t.Fatal(err)
		}
		if res.Port == cfg.RangeLo {
			t.Fatalf("%s got the occupied port", n)
		}
		if seen[res.Port] {
			t.Fatalf("port %d handed out twice", res.Port)
		}
		seen[res.Port] = true
		if err := bindable(res.Port); err != nil {
			t.Fatalf("allocated port %d is not bindable: %v", res.Port, err)
		}
	}
}

func TestDynamicNeverHandsSamePortToTwoNames(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 10)
	p := newPorts(t, cfg, nil)
	got := map[int]string{}
	for i := 0; i < 10; i++ {
		n := fmt.Sprintf("svc%d", i)
		res, err := p.Allocate(PortRequest{Name: n})
		if err != nil {
			t.Fatal(err)
		}
		if prev, dup := got[res.Port]; dup {
			t.Fatalf("port %d given to %s and %s", res.Port, prev, n)
		}
		got[res.Port] = n
	}
	// range exhausted: refuse with the range in the message, never reuse
	_, err := p.Allocate(PortRequest{Name: "one-too-many"})
	if err == nil || !strings.Contains(err.Error(), fmt.Sprintf("%d-%d", cfg.RangeLo, cfg.RangeHi)) {
		t.Fatalf("want exhaustion error naming the range, got %v", err)
	}
}

func TestStickyReuseAfterRelease(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 8)
	p := newPorts(t, cfg, nil)
	a, _ := p.Allocate(PortRequest{Name: "a"})
	b, _ := p.Allocate(PortRequest{Name: "b"})
	if ok, err := p.Release("a"); err != nil || !ok {
		t.Fatalf("release: %v %v", ok, err)
	}
	// another service allocates in between; "a" must still get its port back
	_, _ = p.Allocate(PortRequest{Name: "c"})
	a2, err := p.Allocate(PortRequest{Name: "a"})
	if err != nil {
		t.Fatal(err)
	}
	if a2.Port != a.Port || !a2.Sticky {
		t.Fatalf("sticky: first %+v second %+v", a, a2)
	}
	if a2.Port == b.Port {
		t.Fatal("sticky port collided with b")
	}
}

func TestStickyNotReusedWhenNowOccupied(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 8)
	p := newPorts(t, cfg, nil)
	a, _ := p.Allocate(PortRequest{Name: "a"})
	_, _ = p.Release("a")
	listener(t, a.Port) // someone else took it meanwhile
	a2, err := p.Allocate(PortRequest{Name: "a"})
	if err != nil {
		t.Fatal(err)
	}
	if a2.Port == a.Port || a2.Sticky {
		t.Fatalf("reused an occupied port: %+v", a2)
	}
}

func TestReleaseIsIdempotentAndFreesHold(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 1)
	p := newPorts(t, cfg, nil)
	if _, err := p.Allocate(PortRequest{Name: "a"}); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Allocate(PortRequest{Name: "b"}); err == nil {
		t.Fatal("range of one port must be exhausted by a")
	}
	if ok, _ := p.Release("a"); !ok {
		t.Fatal("first release should report it released")
	}
	if ok, err := p.Release("a"); ok || err != nil {
		t.Fatalf("second release: %v %v", ok, err)
	}
	if _, err := p.Allocate(PortRequest{Name: "b"}); err != nil {
		t.Fatalf("freed port must be allocatable: %v", err)
	}
}

func TestFixedPortHeldByOtherNameIsRefused(t *testing.T) {
	p := newPorts(t, testCfg(t), nil)
	port := freePort(t)
	if _, err := p.Allocate(PortRequest{Name: "a", Profile: "a", Documented: port}); err != nil {
		t.Fatal(err)
	}
	// 'a' is recorded but has not bound yet: 'b' must still not get it
	_, err := p.Allocate(PortRequest{Name: "b", Profile: "b", Documented: port})
	var te *PortTakenError
	if !errors.As(err, &te) {
		t.Fatalf("want PortTakenError, got %v", err)
	}
}

func TestFixedAllocationBlocksDynamicOnSamePort(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 12)
	p := newPorts(t, cfg, map[string]string{"LLMCTL_PORT_PINNED": strconv.Itoa(cfg.RangeLo)})
	if _, err := p.Allocate(PortRequest{Name: "pinned", Profile: "pinned"}); err != nil {
		t.Fatal(err)
	}
	res, err := p.Allocate(PortRequest{Name: "other"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Port == cfg.RangeLo {
		t.Fatal("dynamic allocation took a port held by an explicit one")
	}
}

func TestPruneDropsAbandonedHoldsOnly(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 6)
	p := newPorts(t, cfg, nil)
	dead, _ := p.Allocate(PortRequest{Name: "dead"}) // never started
	live, _ := p.Allocate(PortRequest{Name: "live"}) // really listening
	listener(t, live.Port)
	_ = dead
	// within the grace nothing is pruned
	if n, err := p.Prune(time.Hour, time.Now()); err != nil || n != 0 {
		t.Fatalf("prune within grace: %d %v", n, err)
	}
	n, err := p.Prune(time.Minute, time.Now().Add(2*time.Minute))
	if err != nil || n != 1 {
		t.Fatalf("prune after grace: %d %v", n, err)
	}
	held, _ := p.Held()
	if _, ok := held["dead"]; ok {
		t.Fatal("abandoned hold survived")
	}
	if held["live"] != live.Port {
		t.Fatalf("live hold lost: %v", held)
	}
}

func TestStateFileSurvivesAndIsAtomic(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 12)
	p := newPorts(t, cfg, nil)
	a, _ := p.Allocate(PortRequest{Name: "a"})
	// a new Ports instance (another process in real life) sees the hold
	held, err := newPorts(t, cfg, nil).Held()
	if err != nil || held["a"] != a.Port {
		t.Fatalf("held=%v err=%v", held, err)
	}
	// no temp files are left behind in the registry dir
	ents, _ := os.ReadDir(cfg.Dir())
	for _, e := range ents {
		if strings.Contains(e.Name(), ".tmp") {
			t.Fatalf("leftover temp file %s", e.Name())
		}
	}
	// a corrupt state file is refused loudly, never read as "no holds"
	if err := os.WriteFile(filepath.Join(cfg.Dir(), "ports.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newPorts(t, cfg, nil).Allocate(PortRequest{Name: "z"}); err == nil || !strings.Contains(err.Error(), "ports.json") {
		t.Fatalf("corrupt state: %v", err)
	}
}

func TestConcurrentAllocateGoroutinesGetDistinctPorts(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 40)
	var wg sync.WaitGroup
	var mu sync.Mutex
	got := map[int]string{}
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			p := newPorts(t, cfg, nil) // each goroutine has its own handle, like separate CLI calls
			for j := 0; j < 3; j++ {
				n := fmt.Sprintf("g%d-%d", i, j)
				res, err := p.Allocate(PortRequest{Name: n})
				if err != nil {
					t.Error(err)
					return
				}
				mu.Lock()
				if prev, dup := got[res.Port]; dup {
					t.Errorf("port %d given to %s and %s", res.Port, prev, n)
				}
				got[res.Port] = n
				mu.Unlock()
			}
		}(i)
	}
	wg.Wait()
	if len(got) != 24 {
		t.Fatalf("expected 24 distinct ports, got %d", len(got))
	}
}

// TestConcurrentAllocateAcrossProcesses starts several REAL processes at the
// same instant; each allocates through the same state dir (SC-015 / FR-088).
func TestConcurrentAllocateAcrossProcesses(t *testing.T) {
	for round := 0; round < 5; round++ {
		cfg := testCfg(t)
		lo, hi := freePortBlock(t, 40)
		gofile := filepath.Join(t.TempDir(), "go")
		const n = 8
		type result struct {
			port string
			err  error
		}
		res := make([]result, n)
		var wg sync.WaitGroup
		cmds := make([]*exec.Cmd, n)
		for i := 0; i < n; i++ {
			cmds[i] = exec.Command(os.Args[0], "__helper", "alloc", cfg.StateDir, fmt.Sprintf("svc%d", i), gofile, strconv.Itoa(lo), strconv.Itoa(hi))
			i := i
			wg.Add(1)
			go func() {
				defer wg.Done()
				out, err := cmds[i].Output()
				res[i] = result{strings.TrimSpace(string(out)), err}
			}()
		}
		time.Sleep(150 * time.Millisecond) // all helpers are spinning on the go file
		if err := os.WriteFile(gofile, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		wg.Wait()
		seen := map[string]int{}
		for i, r := range res {
			if r.err != nil {
				t.Fatalf("round %d helper %d: %v (%s)", round, i, r.err, r.port)
			}
			seen[r.port]++
		}
		for port, c := range seen {
			if c > 1 {
				t.Fatalf("round %d: port %s handed to %d processes", round, port, c)
			}
		}
		held, _ := newPorts(t, Config{StateDir: cfg.StateDir, Strategy: Dynamic, RangeLo: lo, RangeHi: hi}, nil).Held()
		if len(held) != n {
			t.Fatalf("round %d: %d holds recorded for %d allocations (lost update)", round, len(held), n)
		}
	}
}

func TestTwoUsersGetDisjointPorts(t *testing.T) {
	lo, hi := freePortBlock(t, 20)
	mk := func() *Ports {
		return newPorts(t, Config{StateDir: t.TempDir(), Strategy: Dynamic, RangeLo: lo, RangeHi: hi}, nil)
	}
	alice, bob := mk(), mk() // separate state dirs, same configured range
	var ports []int
	for i := 0; i < 4; i++ {
		for _, who := range []*Ports{alice, bob} {
			res, err := who.Allocate(PortRequest{Name: fmt.Sprintf("svc%d", i)})
			if err != nil {
				t.Fatal(err)
			}
			// the service starts and holds its port, as a real one would
			listener(t, res.Port)
			ports = append(ports, res.Port)
		}
	}
	sort.Ints(ports)
	for i := 1; i < len(ports); i++ {
		if ports[i] == ports[i-1] {
			t.Fatalf("users share port %d: %v", ports[i], ports)
		}
	}
}

// freePortBlock returns an inclusive range of n currently-free consecutive
// loopback ports.
func freePortBlock(t *testing.T, n int) (int, int) {
	t.Helper()
	for base := 36000 + int(time.Now().UnixNano()%20000); ; base += 7 {
		if base+n > 65000 {
			base = 36000
		}
		if blockIsFree(base, n) {
			return base, base + n - 1
		}
	}
}

// blockIsFree reports whether n consecutive ports from base would ALL pass the production bind test.
//
// Root cause of the flake in TestFixedAllocationBlocksDynamicOnSamePort (captured: "port 45546 for \"pinned\" is
// already in use by another program", reproduced 3/3 under ~8000 concurrent loopback connections; `ss` showed
// 192.168.1.115:45546 -> a remote host:443 CLOSE-WAIT): the kernel hands ephemeral ports (32768-60999, which this
// helper's 36000-56000 window overlaps) to ANY outgoing connection of the host, including ones leaving a
// NON-loopback interface address. The old helper proved a port free by listening on 127.0.0.1 only, which
// succeeds on such a port; the production bindTest also binds the wildcards and every local interface address
// and rightly refuses it. The helper therefore picked blocks whose first port the allocator under test then
// rejected. It now applies the SAME bindTest.
func blockIsFree(base, n int) bool {
	for p := base; p < base+n; p++ {
		if bindTest(p) != nil {
			return false
		}
	}
	return true
}

func bindable(port int) error {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		return err
	}
	return ln.Close()
}

// An earlier explicit/fixed assignment is not a dynamic sticky hint: switching
// a profile to auto must come from the configured range.
func TestStickyIgnoresEarlierExplicitAssignment(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 6)
	outside := freePort(t)
	pinned := NewPorts(cfg, envOf(map[string]string{"LLMCTL_PORT_SVC": strconv.Itoa(outside)}))
	if _, err := pinned.Allocate(PortRequest{Name: "svc", Profile: "svc"}); err != nil {
		t.Fatal(err)
	}
	if _, err := pinned.Release("svc"); err != nil {
		t.Fatal(err)
	}
	res, err := newPorts(t, cfg, map[string]string{"LLMCTL_PORT_SVC": "auto"}).Allocate(PortRequest{Name: "svc", Profile: "svc"})
	if err != nil {
		t.Fatal(err)
	}
	if res.Port == outside || res.Port < cfg.RangeLo || res.Port > cfg.RangeHi || res.Sticky {
		t.Fatalf("auto after an explicit port must come from the range: %+v (explicit was %d)", res, outside)
	}
	// and a hold left by an explicit assignment (no release) is not reused either
	_, _ = pinned.Allocate(PortRequest{Name: "svc2", Profile: "svc2"}) // no env -> fixed w/o documented: error, ignored
	pinned2 := NewPorts(cfg, envOf(map[string]string{"LLMCTL_PORT_SVC3": strconv.Itoa(outside)}))
	if _, err := pinned2.Allocate(PortRequest{Name: "svc3", Profile: "svc3"}); err != nil {
		t.Fatal(err)
	}
	res, err = newPorts(t, cfg, map[string]string{"LLMCTL_PORT_SVC3": "auto"}).Allocate(PortRequest{Name: "svc3", Profile: "svc3"})
	if err != nil || res.Port == outside {
		t.Fatalf("%+v %v", res, err)
	}
}

func TestPortsFileIsAlwaysValidJSONUnderChurn(t *testing.T) {
	cfg := testCfg(t)
	cfg.Strategy = Dynamic
	cfg.RangeLo, cfg.RangeHi = freePortBlock(t, 8)
	p := newPorts(t, cfg, nil)
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			n := fmt.Sprintf("n%d", i%4)
			_, _ = p.Allocate(PortRequest{Name: n})
			_, _ = p.Release(n)
		}
	}()
	file := filepath.Join(cfg.Dir(), "ports.json")
	deadline := time.Now().Add(1500 * time.Millisecond)
	reads := 0
	for time.Now().Before(deadline) {
		b, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		reads++
		var v map[string]any
		if err := json.Unmarshal(b, &v); err != nil {
			close(stop)
			<-done
			t.Fatalf("torn ports.json observed after %d reads: %v (%q)", reads, err, b)
		}
	}
	close(stop)
	<-done
	if reads == 0 {
		t.Fatal("never read the file")
	}
}

// The discrepancy that caused the flake, pinned deterministically: a port that is the LOCAL port of a connection on a
// NON-loopback interface address passes a 127.0.0.1-only listen (the old helper's test) but fails the production
// bind test, so blockIsFree must reject a block containing it. Needs a non-loopback IPv4 address; skips honestly
// (and says why) on a host without one.
func TestBlockIsFreeRejectsAPortHeldOnANonLoopbackAddress(t *testing.T) {
	ip := ""
	for _, a := range localBindAddrs() {
		if p := net.ParseIP(a); p != nil && p.To4() != nil && !p.IsUnspecified() && !p.IsLoopback() {
			ip = a
			break
		}
	}
	if ip == "" {
		t.Skip("no non-loopback IPv4 address on this host: the connection that caused the flake cannot be modelled")
	}
	srv, err := net.Listen("tcp", net.JoinHostPort(ip, "0"))
	if err != nil {
		t.Skipf("cannot listen on %s: %v", ip, err)
	}
	defer srv.Close()
	go func() {
		for {
			c, err := srv.Accept()
			if err != nil {
				return
			}
			defer c.Close()
		}
	}()
	var held net.Conn
	var port int
	for p := 40000 + int(time.Now().UnixNano()%15000); held == nil; p++ {
		d := net.Dialer{LocalAddr: &net.TCPAddr{IP: net.ParseIP(ip), Port: p}}
		if c, err := d.Dial("tcp", srv.Addr().String()); err == nil {
			held, port = c, p
		}
	}
	defer held.Close()
	// control: the old helper's check (listen on 127.0.0.1 only) is blind to this port
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("control needle failed: the old 127.0.0.1-only check is not blind to port %d (%v), so this test proves nothing", port, err)
	}
	ln.Close()
	if bindTest(port) == nil {
		t.Fatalf("production bindTest accepted port %d that a connection on %s holds", port, ip)
	}
	if blockIsFree(port-2, 5) {
		t.Fatalf("blockIsFree accepted a block containing port %d, held on %s", port, ip)
	}
}
