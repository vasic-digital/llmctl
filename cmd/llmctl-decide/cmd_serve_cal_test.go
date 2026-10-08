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
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/calibrate"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/gateway"
	"github.com/vasic-digital/llmctl/internal/keyring"
)

const serveCalSHA = "9999999999999999999999999999999999999999999999999999999999999999"

const calServeCatalog = `{"profiles":{"fast":{"capability":["chat"],"port":8080},
"decide-tiny":{"engine":"llama","port":8092,"capability":["decide"],
 "files":[{"role":"model","sha256":"` + serveCalSHA + `"}],
 "decision":{"protocol":"letter-logit","max_options":20,"score_levels":[2,10],
  "readout":{"n_probs":32,"mass_threshold":0.5,"spellings":["A"," A"],"cache_prompt":false}}}}}`

// liveGateway is an in-process gateway over a fake llama-server (unit tier only).
type liveGateway struct {
	t    *testing.T
	se   *serveEnvT
	addr string
	key  string
	cli  *http.Client
	out  *syncBuf
	err  *syncBuf
	done chan int
	term chan os.Signal
}

func startCalGateway(t *testing.T, mutate func(se *serveEnvT)) *liveGateway {
	t.Helper()
	se := setupServeEnv(t)
	if err := os.WriteFile(se.env["LLMCTL_CATALOG"], []byte(calServeCatalog), 0o600); err != nil {
		t.Fatal(err)
	}
	llama := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"choices":[{"logprobs":{"top_logprobs":[[{"token":" A","logprob":-0.1},{"token":" B","logprob":-2.3}]]}}]}`)
	}))
	t.Cleanup(llama.Close)
	se.env["LLMCTL_DECIDE_ENDPOINT_DECIDE_TINY"] = llama.URL
	ikf := filepath.Join(se.dir, "internal.key")
	if err := os.WriteFile(ikf, []byte("internal-key-1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	se.env["LLMCTL_DECIDE_INTERNAL_KEY_FILE"] = ikf
	if mutate != nil {
		mutate(se)
	}
	port := freePort(t)
	sigs := make(chan os.Signal, 1)
	prev := sigSource
	sigSource = func() (<-chan os.Signal, func()) { return sigs, func() {} }
	t.Cleanup(func() { sigSource = prev })
	g := &liveGateway{t: t, se: se, out: &syncBuf{}, err: &syncBuf{}, done: make(chan int, 1), addr: "127.0.0.1:" + itoa(port)}
	go func() { g.done <- run([]string{"serve", "--foreground", "--port", itoa(port)}, g.out, g.err) }()
	deadline := time.Now().Add(15 * time.Second)
	for {
		if c, err := net.DialTimeout("tcp", g.addr, 100*time.Millisecond); err == nil {
			c.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("gateway did not start: out=%q err=%q", g.out.String(), g.err.String())
		}
		select {
		case rc := <-g.done:
			t.Fatalf("serve exited early rc=%d err=%q", rc, g.err.String())
		default:
		}
		time.Sleep(50 * time.Millisecond)
	}
	pem, err := os.ReadFile(filepath.Join(se.home, "cert", "ca", "ca.crt"))
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(pem)
	g.cli = &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}, DisableKeepAlives: true}}
	kr, err := keyring.Resolve(se.env["LLMCTL_ROOT"], se.env, false)
	if err != nil || kr.Source == "none" {
		t.Fatalf("key not generated: %v", err)
	}
	g.key = kr.Key.Reveal()
	g.term = sigs
	t.Cleanup(g.stop)
	return g
}

func (g *liveGateway) stop() {
	g.term <- syscall.SIGTERM
	select {
	case <-g.done:
	case <-time.After(20 * time.Second):
		g.t.Error("no clean shutdown")
	}
}

func (g *liveGateway) do(method, path, body string) (int, string) {
	g.t.Helper()
	req, _ := http.NewRequest(method, "https://"+g.addr+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+g.key)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := g.cli.Do(req)
	if err != nil {
		g.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func (se *serveEnvT) calDir() string {
	return filepath.Join(se.env["LLMCTL_STATE_DIR"], "decide", "calibration")
}

// writeBoundProfile writes a profile bound to the live model checksum and the live template hash.
func writeBoundProfile(t *testing.T, se *serveEnvT, p *calibrate.Profile) string {
	t.Helper()
	specs, err := gateway.ParseCatalog([]byte(calServeCatalog))
	if err != nil || len(specs) != 1 {
		t.Fatal(err)
	}
	th, err := gateway.TemplateHash(specs[0], 1)
	if err != nil {
		t.Fatal(err)
	}
	if p.ModelSHA256 == "" {
		p.ModelSHA256 = serveCalSHA
	}
	if p.TemplateHash == "" {
		p.TemplateHash = th
	}
	p.Profile, p.Bound, p.Version = "decide-tiny", true, calibrate.ProfileVersion
	path, err := calibrate.WriteProfile(se.calDir(), p)
	if err != nil {
		t.Fatal(err)
	}
	return path
}

const calChoice = `{"model":"decide-tiny","state":"SECRET-STATE invoice overdue","questions":{"team":{"type":"choice","instructions":"SECRET-Q which team?","criteria":{"billing":"money","support":"help"}}}}`

type calAnswer struct {
	Choice        string             `json:"choice"`
	Probabilities map[string]float64 `json:"probabilities"`
	Confidence    float64            `json:"confidence"`
	ConfidenceRaw *float64           `json:"confidence_raw"`
	Calibration   *struct {
		Method    string `json:"method"`
		N         int    `json:"n"`
		ProfileID string `json:"profile_id"`
	} `json:"calibration"`
}

func (g *liveGateway) ask() calAnswer {
	g.t.Helper()
	st, body := g.do("POST", "/v1/systemone", calChoice)
	if st != 200 {
		g.t.Fatalf("systemone %d %s", st, body)
	}
	var r struct {
		Answers map[string]calAnswer `json:"answers"`
	}
	if err := json.Unmarshal([]byte(body), &r); err != nil {
		g.t.Fatal(err)
	}
	return r.Answers["team"]
}

func TestServeAppliesBoundCalibrationProfileAndLogsDecisions(t *testing.T) {
	var logPath string
	g := startCalGateway(t, func(se *serveEnvT) {
		writeBoundProfile(t, se, &calibrate.Profile{Method: calibrate.MethodTemperature, Params: map[string]any{"temperature": 3.0}, NSamples: 321})
		se.env["LLMCTL_DECIDE_LOG_STATE"] = "1"
		logPath = filepath.Join(se.env["LLMCTL_STATE_DIR"], "logs", "decide-decisions.jsonl")
	})
	a := g.ask()
	if a.Calibration == nil || a.Calibration.Method != "temperature" || a.Calibration.N != 321 || a.Calibration.ProfileID != "decide-tiny" || a.ConfidenceRaw == nil {
		t.Fatalf("answer not calibrated: %+v", a)
	}
	pmax := 0.0
	for _, v := range a.Probabilities {
		pmax = max(pmax, v)
	}
	want := contract.Round9((&calibrate.Temperature{T: 3}).Apply(pmax))
	if a.Confidence != want {
		t.Errorf("confidence %v, want the calibrated %v of the winner share %v", a.Confidence, want, pmax)
	}
	if a.Choice != "billing" || pmax < 0.89 || pmax > 0.91 { // the engine gave A -0.1 vs B -2.3: softmax 0.9
		t.Errorf("raw readout changed: choice %s probs %v", a.Choice, a.Probabilities)
	}
	_, models := g.do("GET", "/v1/models", "")
	specs, _ := gateway.ParseCatalog([]byte(calServeCatalog))
	th, _ := gateway.TemplateHash(specs[0], 1)
	if !strings.Contains(models, `"template_hash":"`+th+`"`) || !strings.Contains(models, `"calibration":{"applied":true,"method":"temperature","n":321,"profile_id":"decide-tiny"}`) {
		t.Errorf("/v1/models: %s", models)
	}
	// the decision log: consent => text; mode 0600; the request log stays text-free
	b, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	line := strings.TrimSpace(string(b))
	for _, w := range []string{`"state":"SECRET-STATE invoice overdue"`, `"question":"SECRET-Q which team?"`, `"choice":"billing"`, `"calibrated":true`,
		`"model_sha256":"` + serveCalSHA + `"`, `"template_hash":"` + th + `"`, `"calibration_profile":"decide-tiny"`, `"profile":"decide-tiny"`, `"status":200`} {
		if !strings.Contains(line, w) {
			t.Errorf("decision line lacks %s:\n%s", w, line)
		}
	}
	if fi, _ := os.Stat(logPath); fi.Mode().Perm() != 0o600 {
		t.Errorf("decision log mode %v", fi.Mode().Perm())
	}
	reqLog, _ := os.ReadFile(filepath.Join(g.se.env["LLMCTL_STATE_DIR"], "logs", "decide-requests.jsonl"))
	if strings.Contains(string(reqLog), "SECRET") {
		t.Error("the request log must never carry state or question text")
	}
	if strings.Contains(string(b), g.key) || strings.Contains(g.err.String(), g.key) || strings.Contains(g.out.String(), g.key) {
		t.Error("the access key leaked")
	}
	if !strings.Contains(g.out.String(), "decision log") || !strings.Contains(g.out.String(), "state text LOGGED") {
		t.Errorf("the banner must make the consent visible:\n%s", g.out.String())
	}
	if strings.Contains(g.err.String(), "NOT applied") {
		t.Errorf("an applied profile logs no refusal: %s", g.err.String())
	}
}

func TestServeRefusesMismatchedProfileOnceAndStaysUncalibrated(t *testing.T) {
	g := startCalGateway(t, func(se *serveEnvT) {
		writeBoundProfile(t, se, &calibrate.Profile{ModelSHA256: strings.Repeat("7", 64), Method: calibrate.MethodTemperature, Params: map[string]any{"temperature": 3.0}, NSamples: 321})
	})
	a := g.ask()
	if a.Calibration != nil || a.ConfidenceRaw != nil {
		t.Fatalf("a profile fitted for another model must not be applied: %+v", a)
	}
	if n := strings.Count(g.err.String(), "NOT applied (mismatch)"); n != 1 {
		t.Errorf("want exactly one refusal line, got %d: %q", n, g.err.String())
	}
	_, models := g.do("GET", "/v1/models", "")
	if !strings.Contains(models, `"calibration":{"applied":false,"reason":"mismatch"}`) {
		t.Errorf("/v1/models: %s", models)
	}
}

func TestServeReloadsCalibrationOnSIGHUP(t *testing.T) {
	var path string
	g := startCalGateway(t, func(se *serveEnvT) {
		path = writeBoundProfile(t, se, &calibrate.Profile{Method: calibrate.MethodTemperature, Params: map[string]any{"temperature": 3.0}, NSamples: 321})
	})
	if a := g.ask(); a.Calibration == nil {
		t.Fatal("setup: not calibrated")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if a := g.ask(); a.Calibration == nil {
		t.Fatal("a profile is read at start and on SIGHUP, not on every request")
	}
	if err := syscall.Kill(os.Getpid(), syscall.SIGHUP); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if a := g.ask(); a.Calibration == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("SIGHUP did not drop the removed calibration profile")
		}
		time.Sleep(50 * time.Millisecond)
	}
	// and a new profile written afterwards is picked up by the next SIGHUP
	writeBoundProfile(t, g.se, &calibrate.Profile{Method: calibrate.MethodTemperature, Params: map[string]any{"temperature": 2.0}, NSamples: 400})
	_ = syscall.Kill(os.Getpid(), syscall.SIGHUP)
	for {
		if a := g.ask(); a.Calibration != nil && a.Calibration.N == 400 {
			break
		}
		if time.Now().After(deadline.Add(5 * time.Second)) {
			t.Fatal("SIGHUP did not load the new calibration profile")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestServeDecisionLogWithoutConsentHasNoText(t *testing.T) {
	var logPath string
	g := startCalGateway(t, func(se *serveEnvT) {
		logPath = filepath.Join(se.dir, "elsewhere", "decisions.jsonl")
		se.env["LLMCTL_DECIDE_DECISION_LOG"] = logPath // enabled by path, no LLMCTL_DECIDE_LOG_STATE
	})
	g.ask()
	b, err := os.ReadFile(logPath)
	if err != nil || len(b) == 0 {
		t.Fatalf("decision log: %v", err)
	}
	for _, leak := range []string{"SECRET", "billing", "support", `"team"`} {
		if strings.Contains(string(b), leak) {
			t.Errorf("no-consent decision log leaked %q: %s", leak, b)
		}
	}
	if !strings.Contains(string(b), `"state_logged":false`) || !strings.Contains(string(b), `"choice_index":0`) {
		t.Errorf("record: %s", b)
	}
	if !strings.Contains(g.out.String(), "state text not logged") {
		t.Errorf("banner:\n%s", g.out.String())
	}
}

func TestServeNoDecisionLogByDefault(t *testing.T) {
	g := startCalGateway(t, nil)
	g.ask()
	if _, err := os.Stat(filepath.Join(g.se.env["LLMCTL_STATE_DIR"], "logs", "decide-decisions.jsonl")); !os.IsNotExist(err) {
		t.Errorf("the decision log must not exist unless opted in: %v", err)
	}
	if strings.Contains(g.out.String(), "decision log") {
		t.Errorf("banner mentions a decision log that is off:\n%s", g.out.String())
	}
}

func TestServeDecisionLogConfigurationErrors(t *testing.T) {
	for name, env := range map[string]map[string]string{
		"state flag not 0/1":           {"LLMCTL_DECIDE_LOG_STATE": "yes"},
		"same file as the request log": {"LLMCTL_DECIDE_DECISION_LOG": "@REQLOG@"},
	} {
		se := setupServeEnv(t)
		for k, v := range env {
			if v == "@REQLOG@" {
				v = filepath.Join(se.env["LLMCTL_STATE_DIR"], "logs", "decide-requests.jsonl")
			}
			se.env[k] = v
		}
		var o, e bytes.Buffer
		if rc := run([]string{"serve", "--foreground", "--port", itoa(freePort(t))}, &o, &e); rc != 2 {
			t.Errorf("%s: rc=%d, want 2 (usage); stderr=%s", name, rc, e.String())
		}
		if !strings.Contains(e.String(), "LLMCTL_DECIDE_") {
			t.Errorf("%s: the message must name the variable: %s", name, e.String())
		}
	}
}

// The effective readout temperature (LLMCTL_DECIDE_TEMPERATURE) moves the probabilities, so it is
// part of the template hash: /v1/models publishes the hash for THAT temperature, and a profile fitted
// at the default temperature is refused when the gateway runs at another.
func TestServeTemplateHashFollowsTheReadoutTemperature(t *testing.T) {
	g := startCalGateway(t, func(se *serveEnvT) {
		writeBoundProfile(t, se, &calibrate.Profile{Method: calibrate.MethodTemperature, Params: map[string]any{"temperature": 3.0}, NSamples: 321})
		se.env["LLMCTL_DECIDE_TEMPERATURE"] = "2"
	})
	specs, _ := gateway.ParseCatalog([]byte(calServeCatalog))
	h2, _ := gateway.TemplateHash(specs[0], 2)
	_, models := g.do("GET", "/v1/models", "")
	if !strings.Contains(models, `"template_hash":"`+h2+`"`) || !strings.Contains(models, `"reason":"mismatch"`) {
		t.Errorf("/v1/models: %s", models)
	}
	if a := g.ask(); a.Calibration != nil {
		t.Error("a profile fitted at temperature 1 must not apply at temperature 2")
	}
}
