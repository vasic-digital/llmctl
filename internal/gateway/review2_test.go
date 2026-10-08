package gateway

// Review-2 scope B (and review A's A-02 / A-08 in this package). Every test was written first and
// observed RED against the pre-fix tree.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/readout"
)

func answerJSON(t *testing.T, a contract.Answer) map[string]any {
	t.Helper()
	b, err := json.Marshal(a)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// ---- B-01 -------------------------------------------------------------------------------------

func TestLetterMissingLetterIsAFlaggedBoundNeverCertainty(t *testing.T) {
	// the review's captured case: B is absent from the top list; mass(A)=0.74 passes the threshold
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.3}, lpEntry{"\n", -1.6}))
	})
	ans, _, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody))
	if err != nil {
		t.Fatal(err)
	}
	m := answerJSON(t, ans[0].Answer)
	noul := m["noul"].(float64)
	if noul >= 1 || noul <= 0.5 {
		t.Fatalf("a missing 'no' letter must not turn into certainty; noul=%v", noul)
	}
	flags, _ := m["flags"].([]any)
	if len(flags) != 1 || flags[0] != "option_missing" {
		t.Fatalf("the answer must be flagged: %v", m)
	}
	ub := m["upper_bounds"].(map[string]any)
	// B2-01/B2-02: the bound covers three spellings of the absent letter and is on the SAME scale as
	// the probabilities, so the reported probability never exceeds its own bound
	// B3-01: the bound is min(3 x smallest listed, 1 - everything listed)
	raw := math.Min(3*math.Exp(-1.6), 1-math.Exp(-0.3)-math.Exp(-1.6))
	want := raw / (math.Exp(-0.3) + raw)
	if got := ub["no"].(float64); math.Abs(got-want) > 1e-6 {
		t.Fatalf("upper bound of the absent option: %v want %v", ub, want)
	}
	if noulNo := 1 - noul; noulNo > ub["no"].(float64)+1e-9 {
		t.Fatalf("P(no)=%v exceeds its own upper bound %v", noulNo, ub["no"])
	}
}

func TestLetterMissingChoiceAndScoreOptionsAreBoundedNotZero(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.4}, lpEntry{" B", -1.5}, lpEntry{"x", -3.0}))
	})
	for name, body := range map[string]string{"choice": choiceBody, "score": scoreBody} {
		ans, _, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, body))
		if err != nil {
			t.Fatal(name, err)
		}
		m := answerJSON(t, ans[0].Answer)
		probs := m["probabilities"].(map[string]any)
		for k, v := range probs {
			if v.(float64) == 0 {
				t.Errorf("%s: option %s reported as an exact 0: %v", name, k, probs)
			}
		}
		if m["flags"] == nil || m["upper_bounds"] == nil {
			t.Errorf("%s: not flagged: %v", name, m)
		}
	}
	// the conservative confidence is lower than the one a complete readout with the same top gives
	srvFull, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.4}, lpEntry{" B", -1.5}, lpEntry{" C", -3.0}))
	})
	full, _, _ := newLetter().Decide(context.Background(), ep(srvFull.URL), specByID(t, "decide-tiny"), parseFor(t, choiceBody))
	part, _, _ := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, choiceBody))
	if _, has := answerJSON(t, full[0].Answer)["flags"]; has {
		t.Fatal("a complete readout is not flagged")
	}
	if part[0].Answer.Confidence > full[0].Answer.Confidence+1e-12 {
		t.Fatalf("flagged confidence %v must not exceed the complete readout's %v", part[0].Answer.Confidence, full[0].Answer.Confidence)
	}
}

// ---- B-02 / B-05: budgets from the catalog ----------------------------------------------------

func realCatalog(t *testing.T) []ProfileSpec {
	t.Helper()
	specs, err := LoadCatalog("../../models/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	return specs
}

func specNamed(t *testing.T, specs []ProfileSpec, id string) ProfileSpec {
	t.Helper()
	for _, s := range specs {
		if s.ID == id {
			return s
		}
	}
	t.Fatalf("no profile %s", id)
	return ProfileSpec{}
}

func TestCatalogCtxBecomesTheTokenBudget(t *testing.T) {
	specs := realCatalog(t)
	// decide-tiny was the real letter-logit profile used here until it was reclassified jev-verdict
	// (not servable, 2026-10-08); `decide` is a shipped letter-logit profile (ctx 8192, parallel 2).
	dec := specNamed(t, specs, "decide")
	if dec.Protocol != ProtoLetter || dec.Ctx != 8192 || dec.Parallel != 2 {
		t.Fatalf("ctx/parallel not read from the catalog defaults: %+v", dec)
	}
	l := dec.Limits(contract.DefaultLimits())
	if l.MaxPromptTokens != contract.PromptTokenBudget(8192) || l.MaxPromptTokens <= 7000 || l.MaxPromptTokens >= 8192 {
		t.Fatalf("budget %d", l.MaxPromptTokens)
	}
	nli := specNamed(t, specs, "decide-nli").Limits(contract.DefaultLimits())
	if !nli.PairMode || nli.MaxPromptTokens != 512 {
		t.Fatalf("the encoder window is the catalog ctx: %+v", nli)
	}
	for _, s := range specs {
		if s.Ctx <= 0 {
			t.Errorf("%s has no ctx", s.ID)
		}
		if got := s.Limits(contract.DefaultLimits()).EffectiveStateChars(); got <= 0 || got > 8192 {
			t.Errorf("%s effective state chars %d", s.ID, got)
		}
	}
}

func TestRealCatalogRejectsWhatCannotFitBeforeAnyEngine(t *testing.T) {
	specs := realCatalog(t)
	profiles, err := BuildProfiles(specs, "decide-tiny", contract.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	parse := func(model, state string) error {
		b, _ := json.Marshal(map[string]any{"model": model, "state": state,
			"questions": map[string]any{"q": map[string]any{"type": "choice", "instructions": "which?", "criteria": map[string]string{"a": "x", "b": "y"}}}})
		_, err := contract.ParseRequest(b, contract.DefaultLimits(), profiles)
		return err
	}
	// `decide` (letter-logit, 8192-token window; decide-tiny is jev-verdict and not servable since 2026-10-08)
	prose := strings.Repeat("The invoice is overdue and billing was notified. ", 160) // ~7.9k chars of English
	if err := parse("decide", prose); err != nil {
		t.Fatalf("ordinary prose that fits an 8192-token window must be accepted: %v", err)
	}
	dense := strings.Repeat("0123456789", 815) // 8150 digits ~ 8150 tokens > the 8063-token budget, <= 8192 chars
	var ce *contract.ContractError
	if err := parse("decide", dense); !errors.As(err, &ce) || ce.Status != 422 || ce.ErrorType != contract.ErrTypeValidationFailed {
		t.Fatalf("8150 digits cannot fit an 8192-token window: a 422 validation_failed before the engine, got %v", err)
	}
	// the encoder window (512 tokens) is far smaller than the 8192-character cap
	long := strings.Repeat("The server is down and nobody noticed it. ", 70)
	if err := parse("decide-nli", long); !errors.As(err, &ce) || ce.Status != 422 {
		t.Fatalf("a premise over the 512-token encoder window must be refused up front: %v", err)
	}
}

// ---- B-03: engine rejections are classified -----------------------------------------------------

func llamaOverflow(w http.ResponseWriter) {
	w.WriteHeader(400)
	_, _ = w.Write([]byte(`{"error":{"code":400,"message":"request (3030 tokens) exceeds the available context size (1024 tokens), try increasing it","type":"exceed_context_size_error","n_prompt_tokens":3030,"n_ctx":1024}}`))
}

func TestEngineContextOverflowIsA422NotARetryable502(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) { llamaOverflow(w) })
	_, _, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody))
	c := ce(t, err)
	if c.Status != 422 || c.ErrorType != contract.ErrTypeValidationFailed || c.Retryable() {
		t.Fatalf("%+v", c)
	}
	if strings.Contains(c.Message, "3030") || strings.Contains(c.Message, "1024") {
		t.Fatal("engine text leaked")
	}
}

func TestEngineDeterministicRejectionsAreNonRetryable(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   int
		et     string
		reg    bool // the endpoint came from the registry
	}{
		{"other 400", 400, `{"error":{"code":400,"message":"bad grammar","type":"invalid_request_error"}}`, 500, contract.ErrTypeBackendFailed, false},
		// B2-08: a 404/405 is a stale registry entry / recycled port answering for another program:
		// transient (the registry heals), so the retryable 502, not the fixed-cause 500
		{"404", 404, `{}`, 502, contract.ErrTypeBackendFailed, true},
		{"405", 405, ``, 502, contract.ErrTypeBackendFailed, true},
		// B3-06: the same answer from a STATIC endpoint heals nothing: a fixed fault, not retryable
		{"static 404", 404, `{}`, 500, contract.ErrTypeBackendFailed, false},
		{"static 405", 405, ``, 500, contract.ErrTypeBackendFailed, false},
		{"422 unknown", 422, `{"error":"weird"}`, 500, contract.ErrTypeBackendFailed, false},
		{"onnx hypothesis too long", 422, `{"error":"hypothesis_too_long","message":"x"}`, 422, contract.ErrTypeValidationFailed, false},
		{"onnx too many pairs", 413, `{"error":"too_many_pairs","message":"x"}`, 422, contract.ErrTypeValidationFailed, false},
		{"engine 500", 500, `secret engine text`, 502, contract.ErrTypeBackendFailed, false},
		{"engine 503", 503, `{"error":"busy"}`, 502, contract.ErrTypeBackendFailed, false},
		{"engine 429", 429, ``, 502, contract.ErrTypeBackendFailed, false},
		{"engine 408", 408, ``, 502, contract.ErrTypeBackendFailed, false},
		{"redirect", 307, ``, 502, contract.ErrTypeBackendFailed, false},
	}
	resetLoggedFaults() // C3-16: independent of what earlier runs of this process already logged
	t.Cleanup(resetLoggedFaults)
	var logged []string
	var mu sync.Mutex
	old := engineLogf
	engineLogf = func(f string, a ...any) { mu.Lock(); logged = append(logged, fmt.Sprintf(f, a...)); mu.Unlock() }
	defer func() { engineLogf = old }()
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) { w.WriteHeader(tc.status); _, _ = w.Write([]byte(tc.body)) })
			spec, body, drv := "decide-tiny", noulBody, Driver(newLetter())
			if strings.HasPrefix(tc.name, "onnx") {
				spec, drv = "decide-nli", &NLIBackend{Logf: func(string, ...any) {}}
			}
			e := ep(srv.URL)
			e.FromRegistry = tc.reg
			_, _, err := drv.Decide(context.Background(), e, specByID(t, spec), parseFor(t, body))
			c := ce(t, err)
			if c.Status != tc.want || c.ErrorType != tc.et {
				t.Fatalf("%+v", c)
			}
			if tc.want != 502 && c.Retryable() {
				t.Fatal("a deterministic rejection must not be retryable")
			}
			if strings.Contains(c.Message, "secret") || strings.Contains(c.Message, "grammar") {
				t.Fatal("engine text leaked")
			}
		})
	}
	mu.Lock()
	defer mu.Unlock()
	joined := strings.Join(logged, "\n")
	if !strings.Contains(joined, "HTTP 404") || !strings.Contains(joined, "not retryable") || strings.Contains(joined, "bad grammar") || strings.Contains(joined, "secret") {
		t.Fatalf("a server-side config fault is logged (status only, never engine text):\n%s", joined)
	}
}

func TestNLIEmptyStateIsRefusedBeforeTheEngine(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) { w.WriteHeader(400) })
	req := parseFor(t, strings.Replace(noulBody, `"decide-tiny"`, `"decide-nli"`, 1))
	req.StateText = ""
	_, _, err := (&NLIBackend{Logf: func(string, ...any) {}}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), req)
	c := ce(t, err)
	if c.Status != 422 || c.ErrorType != contract.ErrTypeValidationFailed {
		t.Fatalf("%+v", c)
	}
	if rec.n != 0 {
		t.Fatalf("the engine was contacted %d times for a request that can never succeed", rec.n)
	}
}

func TestNLIPairBudgetIsCheckedBeforeSpendingCompute(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		rows := make([][3]float64, 4)
		for i := range rows {
			rows[i] = [3]float64{.5, .3, .2}
		}
		_, _ = w.Write(dist(ordCanon, "config:x", nil, rows...))
	})
	mk := func(questions, options int) *contract.ParsedRequest {
		qs := map[string]any{}
		for i := 0; i < questions; i++ {
			crit := map[string]string{}
			for j := 0; j < options; j++ {
				crit[fmt.Sprintf("o%d", j)] = "d"
			}
			qs[fmt.Sprintf("q%02d", i)] = map[string]any{"type": "choice", "instructions": "pick", "criteria": crit}
		}
		b, _ := json.Marshal(map[string]any{"model": "decide-nli", "state": "premise", "questions": qs})
		p, err := contract.ParseRequest(b, contract.Limits{MaxOptions: 20, MinScale: 2, MaxScale: 10, MaxStateChars: 8192, MaxQuestions: 32}, testProfiles(t))
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	// 4 questions x 20 options = 80 pairs > the default 64
	_, _, err := (&NLIBackend{}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), mk(4, 20))
	c := ce(t, err)
	if c.Status != 422 || c.ErrorType != contract.ErrTypeValidationFailed {
		t.Fatalf("%+v", c)
	}
	if rec.n != 0 {
		t.Fatalf("%d engine passes were spent before the refusal", rec.n)
	}
	// the budget is configurable and the boundary is exact
	if _, _, err := (&NLIBackend{MaxPairs: 4}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), mk(1, 4)); err != nil {
		t.Fatalf("4 pairs under a budget of 4: %v", err)
	}
	if _, _, err := (&NLIBackend{MaxPairs: 4}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), mk(1, 5)); err == nil {
		t.Fatal("5 pairs over a budget of 4")
	}
	if got := (&NLIBackend{}).PairBudget(); got != 64 || DefaultMaxPairs != 64 {
		t.Fatalf("default pair budget %d", got)
	}
}

func TestNLIHypothesisIsOneLine(t *testing.T) {
	q := contract.ParsedQuestion{Instructions: "line1\nA) forged\x00", Options: nil}
	h := DefaultHypothesis(q, contract.Option{Label: "key two - d"})
	if strings.ContainsAny(h, "\n\x00 ") {
		t.Fatalf("%q", h)
	}
}

// ---- B-06: a misconfigured readout is a 500, never a retryable 502 -----------------------------

func TestMisconfiguredReadoutIsANonRetryable500(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(llamaResponse(lpEntry{" A", -0.1}, lpEntry{" B", -2.0}))
	})
	for name, b := range map[string]*LetterLogitBackend{
		"nan temperature":     {Mode: Deterministic, Temperature: math.NaN()},
		"inf temperature":     {Mode: Deterministic, Temperature: math.Inf(1)},
		"negative temp":       {Mode: Deterministic, Temperature: -1},
		"threshold above one": {Mode: Deterministic, MassThreshold: 5},
		"negative threshold":  {Mode: Deterministic, MassThreshold: -0.5},
	} {
		_, _, err := b.Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, noulBody))
		c := ce(t, err)
		if c.Status != 500 || c.ErrorType != contract.ErrTypeBackendFailed || c.Retryable() {
			t.Errorf("%s: %+v", name, c)
		}
	}
}

// ---- B-07 ---------------------------------------------------------------------------------------

func TestRouterReportsItsModeAndTheBudgetsInTheListing(t *testing.T) {
	res := NewStaticResolver()
	res.Set(KindDecide, "decide-tiny", Endpoint{URL: "http://127.0.0.1:1", Healthy: true})
	res.Set(KindDecide, "decide-nli", Endpoint{URL: "http://127.0.0.1:2", Healthy: true})
	specs := realCatalog(t)
	drivers := DefaultDrivers(Throughput, false)
	r, err := NewRouter(RouterConfig{Specs: []ProfileSpec{specNamed(t, specs, "decide-tiny"), specNamed(t, specs, "decide-nli")},
		Resolver: res, Mode: Throughput, Concurrency: 2, Drivers: drivers, BaseLimits: contract.DefaultLimits()})
	if err != nil {
		t.Fatal(err)
	}
	if r.Mode() != "throughput" {
		t.Fatal(r.Mode())
	}
	for _, m := range r.Models() {
		if m.MaxStateChars <= 0 || m.MaxContextTokens <= 0 {
			t.Errorf("%s: limits not advertised: %+v", m.ID, m)
		}
		if m.ID == "decide-nli" && m.MaxPairs != 64 {
			t.Errorf("nli pair budget not advertised: %+v", m)
		}
		if m.ID == "decide-tiny" && m.MaxPairs != 0 {
			t.Errorf("letter profile has no pair budget: %+v", m)
		}
	}
	rd, _ := NewRouter(RouterConfig{Specs: specs[:1], Resolver: res, Drivers: DefaultDrivers(Deterministic, false)})
	if rd.Mode() != "deterministic" {
		t.Fatal(rd.Mode())
	}
}

// ---- B-09 + A-02: process identity ------------------------------------------------------------

var (
	stubMu   sync.Mutex
	stubDirs = map[string]string{}
	stubRoot string
)

func TestMain(m *testing.M) {
	code := m.Run()
	if stubRoot != "" {
		_ = os.RemoveAll(stubRoot)
	}
	os.Exit(code)
}

// cachedStub builds the sleeping stub once per name for the whole test run.
func cachedStub(t *testing.T, name string) string {
	t.Helper()
	stubMu.Lock()
	defer stubMu.Unlock()
	if p, ok := stubDirs[name]; ok {
		return p
	}
	if stubRoot == "" {
		d, err := os.MkdirTemp("", "gwstub-")
		if err != nil {
			t.Fatal(err)
		}
		stubRoot = d
	}
	dir := filepath.Join(stubRoot, name+"-dir")
	_ = os.MkdirAll(dir, 0o755)
	p := buildStubIn(t, dir, name)
	stubDirs[name] = p
	return p
}

func buildStub(t *testing.T, name string) string { return buildStubIn(t, t.TempDir(), name) }

func buildStubIn(t *testing.T, dir, name string) string {
	t.Helper()
	src := filepath.Join(dir, "main.go")
	if err := os.WriteFile(src, []byte("package main\nimport \"time\"\nfunc main(){ time.Sleep(300*time.Second) }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(dir, name)
	cmd := exec.Command("go", "build", "-o", out, src)
	cmd.Dir = dir
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("cannot build a stub binary: %v\n%s", err, b)
	}
	return out
}

func startStub(t *testing.T, bin string, args ...string) *exec.Cmd {
	t.Helper()
	c := exec.Command(bin, args...)
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Process.Kill(); _, _ = c.Process.Wait() })
	time.Sleep(100 * time.Millisecond)
	return c
}

func infoFor(t *testing.T, pid int, exe string) PidInfo {
	t.Helper()
	ticks, err := procStartTicks(pid)
	if err != nil {
		t.Fatal(err)
	}
	dev, ino, err := fileIdentity(exe)
	if err != nil {
		t.Fatal(err)
	}
	return PidInfo{PID: pid, Start: time.Now(), StartTicks: ticks, ExeDev: dev, ExeIno: ino, HasIdentity: true}
}

func TestVerifyRejectsACarrierThatMentionsTheGateway(t *testing.T) {
	// A-02 / B-09: the words are in an argument, the executable is bash
	c := exec.Command("bash", "-c", "sleep 30; : watch llmctl-decide serve --status")
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Process.Kill(); _, _ = c.Process.Wait() })
	time.Sleep(150 * time.Millisecond)
	if err := VerifyServeProcess(c.Process.Pid, "llmctl-decide"); err == nil {
		t.Fatal("a shell whose argument mentions llmctl-decide and serve is not the gateway")
	}
	pf := filepath.Join(t.TempDir(), "decide.pid")
	_ = WritePidfile(pf, c.Process.Pid, time.Now())
	var signalled int
	res, _ := StopGateway(pf, "llmctl-decide", time.Second, func(int, syscall.Signal) error { signalled++; return nil })
	if res != StopRefused || signalled != 0 {
		t.Fatalf("res=%v signalled=%d", res, signalled)
	}
	for _, cmdline := range []string{"bash\x00-c\x00grep llmctl-decide serve /var/log/x\x00", "watch\x00llmctl-decide\x00serve\x00", "vim\x00serve\x00llmctl-decide\x00"} {
		old := procCmdline
		procCmdline = func(int) ([]byte, error) { return []byte(cmdline), nil }
		err := VerifyServeProcess(2, "llmctl-decide")
		procCmdline = old
		if err == nil {
			t.Errorf("carrier %q accepted", cmdline)
		}
	}
}

func TestVerifyRequiresServeAsTheSubcommand(t *testing.T) {
	bin := buildStub(t, "llmctl-decide")
	for _, args := range [][]string{{"status"}, {}, {"--serve"}, {"x", "serve"}} {
		c := startStub(t, bin, args...)
		if err := VerifyServeProcess(c.Process.Pid, "llmctl-decide"); err == nil {
			t.Errorf("args %v: not the gateway", args)
		}
	}
	c := startStub(t, bin, "serve", "--foreground")
	if err := VerifyServeProcess(c.Process.Pid, "llmctl-decide"); err != nil {
		t.Fatalf("the real shape: %v", err)
	}
}

func TestVerifyByExecutableIdentityAndStartTime(t *testing.T) {
	bin := buildStub(t, "llmctl-decide")
	g := startStub(t, bin, "serve", "--foreground")
	info := infoFor(t, g.Process.Pid, bin)
	if err := VerifyServeProcessInfo(info, "llmctl-decide"); err != nil {
		t.Fatalf("the matching identity: %v", err)
	}
	// a different binary (other inode) with the same name and arguments: the pid was reused
	other := filepath.Join(t.TempDir(), "llmctl-decide")
	data, _ := os.ReadFile(bin)
	_ = os.WriteFile(other, data, 0o755)
	g2 := startStub(t, other, "serve", "--foreground")
	ticks2, err := procStartTicks(g2.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	// only the executable differs: the start time is the imposter's own
	if err := VerifyServeProcessInfo(PidInfo{PID: g2.Process.Pid, StartTicks: ticks2, ExeDev: info.ExeDev, ExeIno: info.ExeIno, HasIdentity: true}, "llmctl-decide"); err == nil {
		t.Fatal("same name and arguments but another executable: refused (device+inode)")
	}
	// the right binary but a different process start time: a recycled pid
	bad := info
	bad.StartTicks++
	if err := VerifyServeProcessInfo(bad, "llmctl-decide"); err == nil {
		t.Fatal("start time mismatch must refuse")
	}
}

func TestStopNeverSignalsARecycledPid(t *testing.T) {
	bin := buildStub(t, "llmctl-decide")
	recycled := startStub(t, bin, "serve", "--foreground") // looks exactly like the gateway
	info := infoFor(t, recycled.Process.Pid, bin)
	info.StartTicks -= 50 // the pidfile was written by an earlier process that held this pid
	pf := filepath.Join(t.TempDir(), "decide.pid")
	if err := writePidInfo(pf, info); err != nil {
		t.Fatal(err)
	}
	var signalled int
	res, err := StopGateway(pf, "llmctl-decide", time.Second, func(int, syscall.Signal) error { signalled++; return nil })
	if res != StopRefused || err == nil || signalled != 0 {
		t.Fatalf("res=%v err=%v signalled=%d", res, err, signalled)
	}
	if syscall.Kill(recycled.Process.Pid, 0) != nil {
		t.Fatal("the recycled-pid process must still be alive")
	}
	// and the genuine one is stopped (through the default pidfd / re-verified path)
	genuine := startStub(t, bin, "serve", "--foreground")
	if err := writePidInfo(pf, infoFor(t, genuine.Process.Pid, bin)); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _, _ = genuine.Process.Wait(); close(done) }()
	res, err = StopGateway(pf, "llmctl-decide", 3*time.Second, nil)
	if err != nil || res != Stopped {
		t.Fatalf("res=%v err=%v", res, err)
	}
	<-done
}

// Without pidfd (old kernels, sandboxes) the identity is verified again immediately before the
// signal: two independent reads of the process, not one.
func TestStopReVerifiesBeforeSignallingWhenNoPidfd(t *testing.T) {
	oldOpen, oldCmd := pidfdOpenFn, procCmdline
	pidfdOpenFn = func(int) (int, error) { return -1, syscall.ENOSYS }
	reads := 0
	procCmdline = func(pid int) ([]byte, error) { reads++; return oldCmd(pid) }
	defer func() { pidfdOpenFn, procCmdline = oldOpen, oldCmd }()
	bin := buildStub(t, "llmctl-decide")
	g := startStub(t, bin, "serve", "--foreground")
	pf := filepath.Join(t.TempDir(), "decide.pid")
	if err := writePidInfo(pf, infoFor(t, g.Process.Pid, bin)); err != nil {
		t.Fatal(err)
	}
	var signalled int
	res, err := StopGateway(pf, "llmctl-decide", time.Second, func(pid int, s syscall.Signal) error {
		if reads < 2 {
			t.Errorf("the pid was verified %d time(s) before the signal; without a pidfd it must be re-verified right before", reads)
		}
		signalled++
		return syscall.Kill(pid, s)
	})
	if signalled != 1 {
		t.Fatalf("res=%v err=%v signalled=%d", res, err, signalled)
	}
	_, _ = g.Process.Wait()
}

func TestPidfileRecordsTheExecutableIdentityOfTheWriter(t *testing.T) {
	pf := filepath.Join(t.TempDir(), "decide.pid")
	if err := WritePidfile(pf, os.Getpid(), time.Now()); err != nil {
		t.Fatal(err)
	}
	info, err := ReadPidfile(pf)
	if err != nil || !info.HasIdentity || info.StartTicks == 0 || info.ExeIno == 0 {
		t.Fatalf("%+v %v", info, err)
	}
	if err := VerifyIdentityOnly(info); err != nil {
		t.Fatalf("a process matches its own recorded identity: %v", err)
	}
	// a pidfile for another pid carries no identity (the writer cannot read it) and stays readable
	if err := WritePidfile(pf, 4242, time.Now()); err != nil {
		t.Fatal(err)
	}
	if info, err := ReadPidfile(pf); err != nil || info.HasIdentity || info.PID != 4242 {
		t.Fatalf("%+v %v", info, err)
	}
}

// ---- B-13: only loopback peers --------------------------------------------------------------

// A non-loopback address of THIS host that really accepts connections: refusing it must be the
// dialer's policy, not a failure to connect.
func TestLoopbackDialerRefusesAReachableNonLoopbackAddress(t *testing.T) {
	var host net.IP
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil && !ipn.IP.IsLoopback() {
			host = ipn.IP
			break
		}
	}
	if host == nil {
		t.Skip("no non-loopback IPv4 address on this host")
	}
	l, err := net.Listen("tcp", "0.0.0.0:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()
	_, port, _ := net.SplitHostPort(l.Addr().String())
	d := newLoopbackDialer(func(context.Context, string) ([]net.IPAddr, error) { return []net.IPAddr{{IP: host}}, nil })
	if c, err := d(context.Background(), "tcp", "localhost:"+port); err == nil {
		c.Close()
		t.Fatalf("localhost resolving to %s (reachable) must be refused, not dialled", host)
	}
	if c, err := d(context.Background(), "tcp", net.JoinHostPort(host.String(), port)); err == nil {
		c.Close()
		t.Fatalf("the literal non-loopback address %s (reachable) must be refused", host)
	}
}

func TestLoopbackDialerRefusesNonLoopbackResolution(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()
	_, port, _ := net.SplitHostPort(l.Addr().String())
	lookup := func(ips ...string) func(context.Context, string) ([]net.IPAddr, error) {
		return func(context.Context, string) ([]net.IPAddr, error) {
			var out []net.IPAddr
			for _, s := range ips {
				out = append(out, net.IPAddr{IP: net.ParseIP(s)})
			}
			return out, nil
		}
	}
	d := newLoopbackDialer(lookup("10.0.0.5"))
	if c, err := d(context.Background(), "tcp", "localhost:"+port); err == nil {
		c.Close()
		t.Fatal("a name that resolves only to a non-loopback address must be refused")
	}
	d = newLoopbackDialer(lookup("10.0.0.5", "127.0.0.1"))
	c, err := d(context.Background(), "tcp", "localhost:"+port)
	if err != nil {
		t.Fatalf("the loopback address among the answers is used: %v", err)
	}
	c.Close()
	if !strings.HasPrefix(c.RemoteAddr().String(), "127.0.0.1:") {
		t.Fatal(c.RemoteAddr())
	}
	// a literal non-loopback IP is refused as well, whatever the lookup says
	if c, err := d(context.Background(), "tcp", "10.0.0.5:80"); err == nil {
		c.Close()
		t.Fatal("literal non-loopback")
	}
	if c, err := d(context.Background(), "tcp", "[::ffff:10.0.0.5]:80"); err == nil {
		c.Close()
		t.Fatal("v4-mapped non-loopback")
	}
}

// ---- A-08: no redirects -----------------------------------------------------------------------

func TestEngineClientNeverFollowsRedirects(t *testing.T) {
	var hits atomic.Int32
	var gotAuth atomic.Value
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		gotAuth.Store(r.Header.Get("Authorization"))
		_, _ = w.Write([]byte(`{}`))
	}))
	defer sink.Close()
	front := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, sink.URL+"/v1/chat/completions", http.StatusTemporaryRedirect)
	}))
	defer front.Close()
	for name, hc := range map[string]*http.Client{"shared": nil, "caller client": {}} {
		_, err := postJSON(context.Background(), hc, Endpoint{URL: front.URL, Key: "engine-secret"}, "/v1/chat/completions", []byte(`{"state":"x"}`))
		if err == nil {
			t.Errorf("%s: a 307 must not turn into a success", name)
		}
	}
	if hits.Load() != 0 {
		t.Fatalf("the redirect target received %d requests (auth %v): key and body must never follow a redirect", hits.Load(), gotAuth.Load())
	}
}

// ---- B-11 ---------------------------------------------------------------------------------------

func TestSmokeAcceptsTheFullLetterRange(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		entries := []lpEntry{{" A", -0.7}}
		for c := 'B'; c <= 'Z'; c++ {
			entries = append(entries, lpEntry{" " + string(c), -4.0})
		}
		_, _ = w.Write(llamaResponse(entries...))
	})
	for _, n := range []int{2, 20, 21, 26} {
		res, err := Smoke(context.Background(), SmokeConfig{URL: srv.URL, Protocol: ProtoLetter, Options: n, Timeout: 5 * time.Second})
		if err != nil || !res.OK {
			t.Errorf("--options %d: %v", n, err)
		}
	}
	if _, err := Smoke(context.Background(), SmokeConfig{URL: srv.URL, Protocol: ProtoLetter, Options: 27}); !errors.Is(err, ErrSmokeUsage) {
		t.Fatalf("27 is a usage error: %v", err)
	}
}

// ---- B-17 (mutation M6): the 26-option cap -----------------------------------------------------

func TestLetterProfileLimitIsCappedAt26(t *testing.T) {
	s := ProfileSpec{ID: "p", Protocol: ProtoLetter, MaxOptions: 30, ScoreLevels: [2]int{2, 10}}
	base := contract.DefaultLimits()
	base.MaxOptions = 255
	if got := s.Limits(base).MaxOptions; got != 26 {
		t.Fatalf("a letter profile cannot render more than 26 options, got %d", got)
	}
	base.MaxOptions = 12
	if got := s.Limits(base).MaxOptions; got != 12 {
		t.Fatalf("the global cap lowers it: %d", got)
	}
	s.Protocol = ProtoNLI
	if got := s.Limits(base).MaxOptions; got != 30 {
		t.Fatalf("an encoder profile uses its own cap: %d", got)
	}
}

var _ = readout.ErrBadArgument

// B2-15 R2: a LEGACY pidfile (no recorded identity) written BEFORE the live "serve" process started
// cannot belong to it: the pid was reused. It is refused, nothing is signalled and the helper lives.
// Golden-false control: a pidfile written AFTER the process started is accepted.
func TestLegacyPidfileOlderThanTheProcessIsRefusedAndNewerAccepted(t *testing.T) {
	bin := buildStub(t, "llmctl-decide")
	g := startStub(t, bin, "serve", "--foreground")
	pid := g.Process.Pid
	pf := filepath.Join(t.TempDir(), "decide.pid")

	old := PidInfo{PID: pid, Start: time.Now().Add(-2 * time.Hour)} // no identity: legacy shape
	if err := writePidInfo(pf, old); err != nil {
		t.Fatal(err)
	}
	var signalled int
	res, err := StopGateway(pf, "llmctl-decide", time.Second, func(int, syscall.Signal) error { signalled++; return nil })
	if res != StopRefused || err == nil || signalled != 0 {
		t.Fatalf("an older legacy pidfile must be refused: res=%v err=%v signalled=%d", res, err, signalled)
	}
	if VerifyServeProcessInfo(old, "llmctl-decide") == nil {
		t.Fatal("VerifyServeProcessInfo accepted a pidfile older than the process")
	}
	if syscall.Kill(pid, 0) != nil {
		t.Fatal("the helper must still be alive")
	}
	// control: written after the process started
	if err := VerifyServeProcessInfo(PidInfo{PID: pid, Start: time.Now()}, "llmctl-decide"); err != nil {
		t.Fatalf("a legacy pidfile newer than the process must be accepted: %v", err)
	}
}
