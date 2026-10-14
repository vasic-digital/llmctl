package main

import (
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const smokeLlama = `{"choices":[{"message":{"content":"A"},"logprobs":{"top_logprobs":[[{"token":" A","logprob":-0.1},{"token":" B","logprob":-2.5}]]}}]}`

func runSmoke(args ...string) (int, string, string) {
	var o, e bytes.Buffer
	rc := run(append([]string{"smoke"}, args...), &o, &e)
	return rc, o.String(), e.String()
}

func TestSmokeCmdOK(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(smokeLlama))
	}))
	defer srv.Close()
	kf := filepath.Join(t.TempDir(), "k")
	if err := os.WriteFile(kf, []byte("smoke-key-0123456789\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rc, out, errb := runSmoke("--url", srv.URL, "--key-file", kf, "--protocol", "letter-logit", "--json")
	if rc != 0 {
		t.Fatalf("rc=%d out=%s err=%s", rc, out, errb)
	}
	if gotAuth != "Bearer smoke-key-0123456789" {
		t.Fatalf("auth %q", gotAuth)
	}
	var d struct {
		OK            bool               `json:"ok"`
		Choice        string             `json:"choice"`
		Probabilities map[string]float64 `json:"probabilities"`
	}
	if err := json.Unmarshal([]byte(out), &d); err != nil || !d.OK || d.Choice != "billing" || len(d.Probabilities) != 2 {
		t.Fatalf("json %s (%v)", out, err)
	}
	if strings.Contains(out+errb, "smoke-key") {
		t.Fatal("the key must never be printed")
	}
}

func TestSmokeCmdHumanAndOptions(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(smokeLlama)) }))
	defer srv.Close()
	rc, out, _ := runSmoke("--url", srv.URL, "--protocol", "letter-logit", "--options", "2", "--expect-choice", "billing")
	if rc != 0 || !strings.Contains(out, "billing") {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
}

func TestSmokeCmdExitCodes(t *testing.T) {
	// 2: usage
	for _, a := range [][]string{
		{}, {"--url", "http://127.0.0.1:1"}, {"--url", "http://127.0.0.1:1", "--protocol", "x"},
		{"--url", "http://127.0.0.1:1", "--protocol", "letter-logit", "--options", "1"},
		{"--url", "http://127.0.0.1:1", "--protocol", "letter-logit", "--key-file", "/nonexistent/key"},
		{"--bogus"},
	} {
		if rc, _, _ := runSmoke(a...); rc != 2 {
			t.Errorf("%v: rc=%d want 2", a, rc)
		}
	}
	// 6: unreachable
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	if rc, _, _ := runSmoke("--url", "http://"+addr, "--protocol", "letter-logit"); rc != 6 {
		t.Errorf("unreachable rc=%d want 6", rc)
	}
	// 1: backend failure
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) }))
	defer bad.Close()
	if rc, _, _ := runSmoke("--url", bad.URL, "--protocol", "letter-logit"); rc != 1 {
		t.Errorf("backend failure rc=%d want 1", rc)
	}
}

// --question-file: the validator's decide suites ask their own known-answer question through the production driver.
func TestSmokeCmdQuestionFile(t *testing.T) {
	var body string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := new(bytes.Buffer)
		_, _ = b.ReadFrom(r.Body)
		body = b.String()
		_, _ = w.Write([]byte(smokeLlama))
	}))
	defer srv.Close()
	qf := filepath.Join(t.TempDir(), "q.json")
	q := `{"model":"smoke","state":"Contracts arrive at the front desk.","questions":{"q":{"type":"choice","instructions":"Which team reviews contracts?","criteria":{"legal":"reviews contracts","billing":"handles invoices"}}}}`
	if err := os.WriteFile(qf, []byte(q), 0o600); err != nil {
		t.Fatal(err)
	}
	rc, out, errb := runSmoke("--url", srv.URL, "--protocol", "letter-logit", "--question-file", qf, "--json")
	if rc != 0 {
		t.Fatalf("rc=%d out=%s err=%s", rc, out, errb)
	}
	if !strings.Contains(body, "Which team reviews contracts?") || strings.Contains(body, "Which team handles invoices?") {
		t.Fatalf("the engine did not receive the question file's question: %s", body)
	}
	var d struct {
		Choice string `json:"choice"`
	}
	if err := json.Unmarshal([]byte(out), &d); err != nil || d.Choice != "legal" {
		t.Fatalf("choice %q (%v) out=%s", d.Choice, err, out)
	}
	for _, bad := range []string{"", "not json", `{"model":"smoke","state":"s","questions":{}}`} {
		f := filepath.Join(t.TempDir(), "bad.json")
		_ = os.WriteFile(f, []byte(bad), 0o600)
		if rc, _, _ := runSmoke("--url", srv.URL, "--protocol", "letter-logit", "--question-file", f); rc != 2 {
			t.Errorf("question file %q: rc=%d want 2 (usage)", bad, rc)
		}
	}
	if rc, _, _ := runSmoke("--url", srv.URL, "--protocol", "letter-logit", "--question-file", "/nonexistent/q.json"); rc != 2 {
		t.Errorf("missing question file: rc=%d want 2", rc)
	}
}
