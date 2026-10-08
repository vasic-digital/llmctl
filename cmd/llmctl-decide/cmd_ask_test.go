package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"encoding/pem"

	"github.com/vasic-digital/llmctl/internal/keyring"
)

const askTestKey = "ASKk3y-0123456789abcdefghijklmnopqrstuvwxyz-QWERTY"

const askChoiceBody = `{"model":"decide-tiny","answers":{"q":{"type":"choice","choice":"billing","probabilities":{"billing":0.7,"legal":0.3},"confidence":0.4}},"usage":{"input_tokens":4,"output_tokens":1}}`

// askRig is an in-process gateway stand-in plus an isolated environment.
type askRig struct {
	t      *testing.T
	srv    *httptest.Server
	hits   atomic.Int32
	status int
	body   string
	models string // /v1/models body; "" = the default listing
	last   []byte
	env    keyring.Environ
	ca     string
}

func newAskRig(t *testing.T) *askRig {
	t.Helper()
	r := &askRig{t: t, status: 200, body: askChoiceBody}
	r.srv = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		r.hits.Add(1)
		if req.Header.Get("Authorization") != "Bearer "+askTestKey {
			w.WriteHeader(401)
			_, _ = w.Write([]byte(`{"message":"Authentication required.","error_type":"unauthorized"}`))
			return
		}
		switch req.URL.Path {
		case "/v1/models":
			if r.models != "" {
				_, _ = w.Write([]byte(r.models))
				return
			}
			_, _ = w.Write([]byte(`{"object":"list","data":[{"id":"decide-tiny","aliases":["jev-latest"],"protocol":"letter-logit","status":"ready"}]}`))
			return
		}
		var buf bytes.Buffer
		_, _ = buf.ReadFrom(req.Body)
		r.last = buf.Bytes()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(r.status)
		_, _ = w.Write([]byte(r.body))
	}))
	t.Cleanup(r.srv.Close)
	dir := t.TempDir()
	r.ca = filepath.Join(dir, "ca.crt")
	if err := os.WriteFile(r.ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: r.srv.Certificate().Raw}), 0o644); err != nil {
		t.Fatal(err)
	}
	r.env = keyring.Environ{
		"LLMCTL_API_KEY":  askTestKey,
		"LLMCTL_ENDPOINT": r.srv.URL,
		"LLMCTL_CACERT":   r.ca,
		"LLMCTL_ENV_FILE": filepath.Join(dir, "absent.env"),
		"HOME":            dir,
	}
	return r
}

// run executes a subcommand in-process with the rig's environment.
func (r *askRig) run(stdin string, args ...string) (int, string, string) {
	r.t.Helper()
	oldEnv, oldIn := askEnviron, askStdin
	askEnviron = func() keyring.Environ {
		c := keyring.Environ{}
		for k, v := range r.env {
			c[k] = v
		}
		return c
	}
	askStdin = strings.NewReader(stdin)
	defer func() { askEnviron, askStdin = oldEnv, oldIn }()
	var out, errb bytes.Buffer
	rc := run(args, &out, &errb)
	if strings.Contains(out.String()+errb.String(), askTestKey) {
		r.t.Fatalf("the key leaked into output of %v:\nstdout=%s\nstderr=%s", args, out.String(), errb.String())
	}
	return rc, out.String(), errb.String()
}

var askChoiceArgs = []string{"ask", "--type", "choice", "--instructions", "Which team?", "--criteria", `{"billing":"invoices","legal":"contracts"}`, "--state", "The invoice is overdue."}

func TestAskSuccessJSONAndEvidence(t *testing.T) {
	r := newAskRig(t)
	rc, out, errs := r.run("", append(askChoiceArgs, "--json")...)
	if rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, errs)
	}
	var d struct {
		Model    string `json:"model"`
		Evidence struct {
			Profile   string  `json:"profile"`
			Port      int     `json:"port"`
			LatencyMS float64 `json:"latency_ms"`
		} `json:"evidence"`
		Answers map[string]struct {
			Choice string `json:"choice"`
		} `json:"answers"`
		Abstained *bool `json:"abstained"`
	}
	if err := json.Unmarshal([]byte(out), &d); err != nil {
		t.Fatalf("stdout is not JSON: %v\n%s", err, out)
	}
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(r.srv.URL, "https://"))
	if d.Answers["q"].Choice != "billing" || d.Evidence.Profile != "decide-tiny" || d.Evidence.LatencyMS <= 0 || d.Abstained != nil {
		t.Fatalf("%+v", d)
	}
	if itoa(d.Evidence.Port) != port {
		t.Fatalf("evidence port %d != %s", d.Evidence.Port, port)
	}
	var sent map[string]json.RawMessage
	if err := json.Unmarshal(r.last, &sent); err != nil || string(sent["state"]) != `"The invoice is overdue."` {
		t.Fatalf("server saw %s", r.last)
	}
	if strings.Contains(string(r.last), `"model"`) {
		t.Fatalf("no --profile: no model field expected: %s", r.last)
	}
}

func TestAskProfileIsSentAsModel(t *testing.T) {
	r := newAskRig(t)
	if rc, _, e := r.run("", append(askChoiceArgs, "--profile", "decide-tiny")...); rc != 0 {
		t.Fatalf("%d %s", rc, e)
	}
	if !strings.Contains(string(r.last), `"model":"decide-tiny"`) {
		t.Fatalf("%s", r.last)
	}
}

func TestAskStateSources(t *testing.T) {
	r := newAskRig(t)
	big := strings.Repeat("0123456789abcdef\n", 4<<20/17)
	f := filepath.Join(t.TempDir(), "state.txt")
	if err := os.WriteFile(f, []byte(big), 0o600); err != nil {
		t.Fatal(err)
	}
	args := []string{"ask", "--type", "noul", "--instructions", "ok?"}
	if rc, _, e := r.run("", append(args, "--state-file", f)...); rc != 0 {
		t.Fatalf("state-file: %d %s", rc, e)
	}
	if len(r.last) < len(big) {
		t.Fatalf("server received %d bytes of a %d byte state", len(r.last), len(big))
	}
	if rc, _, e := r.run("from stdin\nline two", append(args, "--stdin")...); rc != 0 || !strings.Contains(string(r.last), `from stdin\nline two`) {
		t.Fatalf("stdin: %d %s %s", rc, e, r.last)
	}
}

func TestAskQuestionFile(t *testing.T) {
	r := newAskRig(t)
	qf := filepath.Join(t.TempDir(), "q.json")
	_ = os.WriteFile(qf, []byte(`{"type":"choice","instructions":"Which?","criteria":{"billing":"x","legal":"y"}}`), 0o600)
	if rc, _, e := r.run("", "ask", "--question-file", qf, "--state", "s"); rc != 0 {
		t.Fatalf("%d %s", rc, e)
	}
	if !strings.Contains(string(r.last), `"questions":{"q":{"type":"choice"`) {
		t.Fatalf("%s", r.last)
	}
	if rc, _, e := r.run("", "ask", "--question-file", qf, "--type", "noul", "--state", "s"); rc != 2 || !strings.Contains(e, "replaces") {
		t.Fatalf("mixing question-file with --type must be a usage error: %d %s", rc, e)
	}
}

func TestAskUsageErrorsExit2AndNeverReachTheNetwork(t *testing.T) {
	r := newAskRig(t)
	cases := map[string][]string{
		"unknown flag":       {"ask", "--bogus", "x"},
		"positional":         {"ask", "stray"},
		"no state":           {"ask", "--type", "noul", "--instructions", "q"},
		"two state sources":  {"ask", "--type", "noul", "--instructions", "q", "--state", "s", "--stdin"},
		"bad type":           {"ask", "--type", "maybe", "--instructions", "q", "--state", "s"},
		"bad criteria json":  {"ask", "--type", "choice", "--instructions", "q", "--state", "s", "--criteria", "{"},
		"missing state file": {"ask", "--type", "noul", "--instructions", "q", "--state-file", "/nonexistent/state"},
		"flag missing value": {"ask", "--state"},
		"bad min-confidence": {"ask", "--min-confidence", "7", "--type", "noul", "--instructions", "q", "--state", "s"},
		"http endpoint":      {"ask", "--endpoint", "http://127.0.0.1:1", "--type", "noul", "--instructions", "q", "--state", "s"},
		"models stray":       {"models", "extra"},
		"batch bad flag":     {"batch", "--nope"},
	}
	for name, args := range cases {
		if rc, _, e := r.run("", args...); rc != 2 || e == "" {
			t.Errorf("%s: rc=%d stderr=%q, want 2 with a message", name, rc, e)
		}
	}
	if r.hits.Load() != 0 {
		t.Fatalf("%d requests reached the gateway for invalid input", r.hits.Load())
	}
}

func TestBadNumericEnvIsAClearUsageError(t *testing.T) {
	for _, kv := range [][2]string{{"LLMCTL_DECIDE_PORT", "abc"}, {"LLMCTL_DECIDE_PORT", "70000"}, {"LLMCTL_DECIDE_MAX_OPTIONS", "abc"},
		{"LLMCTL_DECIDE_TIMEOUT", "-3"}, {"LLMCTL_DECIDE_MAX_STATE_CHARS", "1.5"}, {"LLMCTL_DECIDE_TRUNCATE", "2"}} {
		r := newAskRig(t)
		r.env[kv[0]] = kv[1]
		rc, _, e := r.run("", append(askChoiceArgs, "--json")...)
		if rc != 2 || !strings.Contains(e, kv[0]) || strings.Contains(e, "goroutine") || strings.Contains(e, "panic") {
			t.Errorf("%s=%s: rc=%d stderr=%q", kv[0], kv[1], rc, e)
		}
		if r.hits.Load() != 0 {
			t.Errorf("%s: request sent despite bad env", kv[0])
		}
	}
}

func TestDefaultEndpointFollowsDecidePort(t *testing.T) {
	ce, err := askLoadEnv(keyring.Environ{"LLMCTL_DECIDE_PORT": "9123"})
	if err != nil {
		t.Fatal(err)
	}
	if got := ce.resolveEndpoint(""); got != "https://127.0.0.1:9123" {
		t.Fatal(got)
	}
	ce, _ = askLoadEnv(keyring.Environ{})
	if got := ce.resolveEndpoint(""); got != "https://127.0.0.1:8095" {
		t.Fatal(got)
	}
	ce, _ = askLoadEnv(keyring.Environ{"LLMCTL_ENDPOINT": "https://nas:1"})
	if ce.resolveEndpoint("") != "https://nas:1" || ce.resolveEndpoint("https://flag:2") != "https://flag:2" {
		t.Fatal("endpoint precedence flag > env")
	}
}

func TestDefaultCAPath(t *testing.T) {
	ce, _ := askLoadEnv(keyring.Environ{"LLMCTL_HOME": "/h", "HOME": "/u"})
	if got := ce.resolveCA(""); got != "/h/cert/ca/ca.crt" {
		t.Fatal(got)
	}
	ce, _ = askLoadEnv(keyring.Environ{"HOME": "/u"})
	if got := ce.resolveCA(""); got != "/u/llmctl/cert/ca/ca.crt" {
		t.Fatal(got)
	}
	ce, _ = askLoadEnv(keyring.Environ{"HOME": "/u", "LLMCTL_CACERT": "/x/ca.pem"})
	if ce.resolveCA("") != "/x/ca.pem" || ce.resolveCA("/flag.pem") != "/flag.pem" {
		t.Fatal("CA precedence flag > env")
	}
}

func TestKeyProblemsExit4(t *testing.T) {
	r := newAskRig(t)
	delete(r.env, "LLMCTL_API_KEY")
	if rc, _, e := r.run("", append(askChoiceArgs, "--json")...); rc != 4 || !strings.Contains(e, "key") {
		t.Fatalf("missing key: rc=%d %s", rc, e)
	}
	r.env["LLMCTL_API_KEY"] = "   "
	if rc, _, _ := r.run("", append(askChoiceArgs, "--json")...); rc != 4 {
		t.Fatalf("blank key: rc=%d", rc)
	}
	r.env["LLMCTL_API_KEY"] = "tooshort"
	if rc, _, _ := r.run("", append(askChoiceArgs, "--json")...); rc != 4 {
		t.Fatalf("malformed key: rc=%d", rc)
	}
	r.env["LLMCTL_API_KEY"] = "WRONGk3y-0123456789abcdefghijklmnopqrstuvwxyz-QWERTY"
	rc, _, e := r.run("", append(askChoiceArgs, "--json")...)
	if rc != 4 || !strings.Contains(e, "rejected") {
		t.Fatalf("wrong key: rc=%d %s", rc, e)
	}
	if r.hits.Load() != 1 { // only the wrong-key request reached the server, and 401 is not retried
		t.Fatalf("hits=%d", r.hits.Load())
	}
}

func TestKeyIsReadFromTheEnvFileToo(t *testing.T) {
	r := newAskRig(t)
	delete(r.env, "LLMCTL_API_KEY")
	if err := os.WriteFile(r.env["LLMCTL_ENV_FILE"], []byte("LLMCTL_API_KEY="+askTestKey+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if rc, _, e := r.run("", append(askChoiceArgs, "--json")...); rc != 0 {
		t.Fatalf("rc=%d %s", rc, e)
	}
}

func TestTLSAndReachabilityExitCodes(t *testing.T) {
	r := newAskRig(t)
	other := filepath.Join(t.TempDir(), "other.crt") // not a certificate at all -> unreadable CA
	_ = os.WriteFile(other, []byte("garbage"), 0o644)
	r.env["LLMCTL_CACERT"] = other
	if rc, _, e := r.run("", append(askChoiceArgs, "--json")...); rc != 5 {
		t.Fatalf("bad CA file: rc=%d %s", rc, e)
	}
	r.env["LLMCTL_CACERT"] = filepath.Join(t.TempDir(), "missing.crt")
	if rc, _, e := r.run("", append(askChoiceArgs, "--json")...); rc != 5 || !strings.Contains(e, "llmctl cert") {
		t.Fatalf("missing CA: rc=%d %s", rc, e)
	}
	r.env["LLMCTL_CACERT"] = r.ca
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	ln.Close()
	r.env["LLMCTL_ENDPOINT"] = "https://" + addr
	if rc, _, e := r.run("", append(askChoiceArgs, "--json")...); rc != 6 {
		t.Fatalf("closed port: rc=%d %s", rc, e)
	}
}

func TestBackendAndReadinessExitCodes(t *testing.T) {
	r := newAskRig(t)
	r.status, r.body = 422, `{"message":"The model produced no usable answer for this question.","error_type":"readout_failed"}`
	if rc, _, _ := r.run("", append(askChoiceArgs, "--json")...); rc != 1 {
		t.Fatalf("readout failure rc=%d", rc)
	}
	r.status, r.body = 422, `{"message":"Request failed validation.","error_type":"validation_failed"}`
	if rc, _, _ := r.run("", append(askChoiceArgs, "--json")...); rc != 2 {
		t.Fatalf("validation rc=%d", rc)
	}
	r.status, r.body = 503, `{"message":"Service not ready.","error_type":"not_ready"}`
	before := r.hits.Load()
	rc, _, e := r.run("", append(askChoiceArgs, "--json", "--retries", "1")...)
	if rc != 6 || r.hits.Load()-before != 2 {
		t.Fatalf("not ready: rc=%d hits=%d %s", rc, r.hits.Load()-before, e)
	}
}

func TestAbstention(t *testing.T) {
	r := newAskRig(t) // the canned answer has confidence 0.4
	rc, out, e := r.run("", append(askChoiceArgs, "--json", "--min-confidence", "0.9")...)
	if rc != 10 {
		t.Fatalf("rc=%d %s", rc, e)
	}
	if !strings.Contains(out, `"abstained":true`) || !strings.Contains(out, `"choice":"billing"`) {
		t.Fatalf("JSON must still be printed with abstained true: %s", out)
	}
	rc, out, _ = r.run("", append(askChoiceArgs, "--json", "--min-confidence", "0.2")...)
	if rc != 0 || !strings.Contains(out, `"abstained":false`) {
		t.Fatalf("rc=%d %s", rc, out)
	}
}

func TestDryRunNeedsNoKeyAndNoNetwork(t *testing.T) {
	r := newAskRig(t)
	delete(r.env, "LLMCTL_API_KEY")
	r.env["LLMCTL_ENDPOINT"] = "https://127.0.0.1:1"
	rc, out, e := r.run("", append(askChoiceArgs, "--dry-run")...)
	if rc != 0 || !strings.Contains(out, "https://127.0.0.1:1/v1/systemone") || !strings.Contains(out, "questions: 1") || strings.Contains(out, "overdue") {
		t.Fatalf("rc=%d out=%s err=%s", rc, out, e)
	}
	rc, out, _ = r.run("", append(askChoiceArgs, "--dry-run", "--json")...)
	var d map[string]any
	if rc != 0 || json.Unmarshal([]byte(out), &d) != nil || d["dry_run"] != true {
		t.Fatalf("rc=%d %s", rc, out)
	}
	if r.hits.Load() != 0 {
		t.Fatal("dry-run touched the network")
	}
	// dry-run validates: a 30-option choice exceeds the default cap of 20
	crit := "{"
	for i := 0; i < 30; i++ {
		if i > 0 {
			crit += ","
		}
		crit += `"o` + itoa(i) + `":"d"`
	}
	crit += "}"
	rc, _, e = r.run("", "ask", "--type", "choice", "--instructions", "q", "--state", "s", "--criteria", crit, "--dry-run")
	if rc != 2 || !strings.Contains(e, "invalid request") {
		t.Fatalf("rc=%d %s", rc, e)
	}
}

func TestExplainPrintsPromptLetterMapAndProbabilities(t *testing.T) {
	r := newAskRig(t)
	rc, out, e := r.run("", append(askChoiceArgs, "--explain", "--json")...)
	if rc != 0 {
		t.Fatalf("%d %s", rc, e)
	}
	for _, want := range []string{"=== STATE BEGIN ===", "The invoice is overdue.", "A) billing - invoices", "A -> billing", "B -> legal", "per-option probabilities"} {
		if !strings.Contains(e, want) {
			t.Errorf("--explain output lacks %q:\n%s", want, e)
		}
	}
	if json.Valid([]byte(out)) == false {
		t.Fatalf("stdout must stay machine-readable: %s", out)
	}
}

func TestModels(t *testing.T) {
	r := newAskRig(t)
	rc, out, e := r.run("", "models")
	if rc != 0 || !strings.Contains(out, "decide-tiny") || !strings.Contains(out, "jev-latest") {
		t.Fatalf("%d %s %s", rc, out, e)
	}
	rc, out, _ = r.run("", "models", "--json")
	if rc != 0 || !json.Valid([]byte(out)) {
		t.Fatalf("%d %s", rc, out)
	}
	r.env["LLMCTL_API_KEY"] = "WRONGk3y-0123456789abcdefghijklmnopqrstuvwxyz-QWERTY"
	if rc, _, _ := r.run("", "models"); rc != 4 {
		t.Fatalf("models with wrong key rc=%d", rc)
	}
}

func TestBatchOrderPerLineErrorsAndSeverity(t *testing.T) {
	r := newAskRig(t)
	good := func(id string) string {
		return `{"id":` + id + `,"state":"s","questions":{"q":{"type":"choice","instructions":"q","criteria":{"billing":"a","legal":"b"}}}}`
	}
	in := strings.Join([]string{good(`1`), `not json`, good(`"two"`), `{"id":4,"state":"s"}`, `{"id":5,"state":"s","questions":{},"extra":1}`, good(`6`)}, "\n") + "\n"
	rc, out, e := r.run(in, "batch")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 6 {
		t.Fatalf("want 6 output lines, got %d:\n%s\n%s", len(lines), out, e)
	}
	type L struct {
		ID     json.RawMessage `json:"id"`
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code int    `json:"exit_code"`
			Msg  string `json:"message"`
		} `json:"error"`
	}
	var ls []L
	for _, l := range lines {
		var x L
		if err := json.Unmarshal([]byte(l), &x); err != nil {
			t.Fatalf("not JSON: %s", l)
		}
		ls = append(ls, x)
	}
	if string(ls[0].ID) != "1" || ls[0].Result == nil || string(ls[2].ID) != `"two"` || ls[2].Result == nil || string(ls[5].ID) != "6" || ls[5].Result == nil {
		t.Fatalf("results/ids out of order: %s", out)
	}
	for _, i := range []int{1, 3, 4} {
		if ls[i].Error == nil || ls[i].Error.Code != 2 || ls[i].Result != nil {
			t.Errorf("line %d should be a usage error: %s", i, lines[i])
		}
	}
	if string(ls[1].ID) != "null" || string(ls[3].ID) != "4" {
		t.Errorf("error lines keep the id when known: %s | %s", lines[1], lines[3])
	}
	if rc != 2 {
		t.Fatalf("exit code is the highest severity seen (usage 2), got %d", rc)
	}
	// backend failure outranks usage
	r.status, r.body = 422, `{"message":"x","error_type":"readout_failed"}`
	rc, _, _ = r.run(good(`1`)+"\nnot json\n", "batch")
	if rc != 1 {
		t.Fatalf("readout(1) outranks usage(2): rc=%d", rc)
	}
	// all good
	r.status, r.body = 200, askChoiceBody
	if rc, _, _ = r.run(good(`1`)+"\n", "batch", "--min-confidence", "0.1"); rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	if rc, out, _ = r.run(good(`1`)+"\n", "batch", "--min-confidence", "0.9"); rc != 10 || !strings.Contains(out, `"abstained":true`) {
		t.Fatalf("rc=%d %s", rc, out)
	}
}

func TestBatchFilesAndHugeLine(t *testing.T) {
	r := newAskRig(t)
	dir := t.TempDir()
	huge := `{"id":"big","state":"` + strings.Repeat("y", 3<<20) + `","questions":{"q":{"type":"noul","instructions":"q"}}}` + "\n"
	in, out := filepath.Join(dir, "in.ndjson"), filepath.Join(dir, "out.ndjson")
	if err := os.WriteFile(in, []byte(huge), 0o600); err != nil {
		t.Fatal(err)
	}
	if rc, _, e := r.run("", "batch", "--in", in, "--out", out); rc != 0 {
		t.Fatalf("%d %s", rc, e)
	}
	b, _ := os.ReadFile(out)
	if !strings.Contains(string(b), `"id":"big"`) || len(r.last) < 3<<20 {
		t.Fatalf("out=%.200s server got %d bytes", b, len(r.last))
	}
	if st, _ := os.Stat(out); st.Mode().Perm() != 0o600 {
		t.Errorf("--out mode %v", st.Mode().Perm())
	}
	if rc, _, _ := r.run("", "batch", "--in", filepath.Join(dir, "nope")); rc != 2 {
		t.Fatalf("missing --in rc=%d", rc)
	}
}

func TestWrongButValidCAExits5(t *testing.T) {
	r := newAskRig(t)
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(9), Subject: pkix.Name{CommonName: "unrelated CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	wrong := filepath.Join(t.TempDir(), "wrong.crt")
	_ = os.WriteFile(wrong, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
	r.env["LLMCTL_CACERT"] = wrong
	rc, _, e := r.run("", append(askChoiceArgs, "--json")...)
	if rc != 5 || !strings.Contains(e, "not trusted") {
		t.Fatalf("rc=%d %s", rc, e)
	}
	if r.hits.Load() != 0 {
		t.Fatal("a request was served over an untrusted connection")
	}
	// the same CA via the flag overrides the environment
	if rc, _, e = r.run("", append(askChoiceArgs, "--json", "--cacert", r.ca)...); rc != 0 {
		t.Fatalf("--cacert override: rc=%d %s", rc, e)
	}
}

func TestDryRunCatchesMissingCriteriaAndOptionCaps(t *testing.T) {
	r := newAskRig(t)
	rc, _, e := r.run("", "ask", "--type", "choice", "--instructions", "q", "--state", "s", "--dry-run")
	if rc != 2 || !strings.Contains(e, "invalid request") {
		t.Fatalf("choice without criteria: rc=%d %s", rc, e)
	}
	rc, _, e = r.run("", "ask", "--type", "score", "--instructions", "q", "--state", "s", "--criteria", `["only one"]`, "--dry-run")
	if rc != 2 {
		t.Fatalf("score with one level: rc=%d %s", rc, e)
	}
	r.env["LLMCTL_DECIDE_MAX_OPTIONS"] = "3"
	rc, _, _ = r.run("", "ask", "--type", "choice", "--instructions", "q", "--state", "s", "--criteria", `{"a":"","b":"","c":"","d":""}`, "--dry-run")
	if rc != 2 {
		t.Fatalf("LLMCTL_DECIDE_MAX_OPTIONS=3 with four options: rc=%d", rc)
	}
	r.env["LLMCTL_DECIDE_MAX_OPTIONS"] = "4"
	if rc, _, e = r.run("", "ask", "--type", "choice", "--instructions", "q", "--state", "s", "--criteria", `{"a":"","b":"","c":"","d":""}`, "--dry-run"); rc != 0 {
		t.Fatalf("four options within a cap of four: rc=%d %s", rc, e)
	}
}

func TestTimeoutEnvAddsGrace(t *testing.T) {
	ce, err := askLoadEnv(keyring.Environ{"LLMCTL_DECIDE_TIMEOUT": "8"})
	if err != nil || ce.timeout != 13*time.Second {
		t.Fatalf("%v %v", ce, err)
	}
	if ce, _ = askLoadEnv(keyring.Environ{}); ce.timeout != 30*time.Second {
		t.Fatalf("default %v", ce.timeout)
	}
}
