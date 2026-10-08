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
