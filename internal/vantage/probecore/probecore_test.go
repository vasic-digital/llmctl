package probecore

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func tlsServer(t *testing.T, h http.Handler) (*httptest.Server, []byte) {
	t.Helper()
	s := httptest.NewTLSServer(h)
	t.Cleanup(s.Close)
	return s, pemOf(s)
}

func pemOf(s *httptest.Server) []byte {
	var b bytes.Buffer
	for _, c := range s.TLS.Certificates[0].Certificate {
		b.WriteString("-----BEGIN CERTIFICATE-----\n")
		enc := base64Wrap(c)
		b.WriteString(enc)
		b.WriteString("-----END CERTIFICATE-----\n")
	}
	return b.Bytes()
}

func TestHTTPTrustedCA(t *testing.T) {
	s, ca := tlsServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer k" {
			http.Error(w, "no", 401)
			return
		}
		io.WriteString(w, "hello")
	}))
	r := HTTP(context.Background(), HTTPRequest{URL: s.URL, CAPEM: ca, ServerName: "example.com", Headers: map[string]string{"Authorization": "Bearer k"}})
	if r.Error != "" || !r.TLS || !r.TLSVerified || r.Status != 200 || r.Body != "hello" || r.PeerAddr == "" || r.LocalAddr == "" {
		t.Fatalf("unexpected result: %+v", r)
	}
	r = HTTP(context.Background(), HTTPRequest{URL: s.URL, CAPEM: ca, ServerName: "example.com"})
	if r.Status != 401 || !r.TLSVerified {
		t.Fatalf("want 401 over verified TLS: %+v", r)
	}
}

func TestHTTPWrongOrNoCAFailsVerification(t *testing.T) {
	s, _ := tlsServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	for name, ca := range map[string][]byte{"no roots": nil, "garbage roots": []byte("not pem")} {
		r := HTTP(context.Background(), HTTPRequest{URL: s.URL, CAPEM: ca, ServerName: "example.com"})
		if r.TLSVerified || r.Status != 0 || r.ErrorClass != "tls_verify" || r.TLSError == "" {
			t.Fatalf("%s: TLS must NOT verify: %+v", name, r)
		}
	}
}

func TestHTTPPlainAndErrors(t *testing.T) {
	p := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "plain "+r.Method) }))
	defer p.Close()
	r := HTTP(context.Background(), HTTPRequest{URL: p.URL, Method: "POST", Body: "x"})
	if r.TLS || r.Status != 200 || r.Body != "plain POST" || r.Error != "" {
		t.Fatalf("%+v", r)
	}
	if r := HTTP(context.Background(), HTTPRequest{URL: "::bad"}); r.ErrorClass != "http" {
		t.Fatalf("bad url: %+v", r)
	}
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	ln.Close()
	if r := HTTP(context.Background(), HTTPRequest{URL: "http://" + addr, Timeout: time.Second}); r.ErrorClass != "connect" || r.Error == "" {
		t.Fatalf("closed port: %+v", r)
	}
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { time.Sleep(500 * time.Millisecond) }))
	defer slow.Close()
	if r := HTTP(context.Background(), HTTPRequest{URL: slow.URL, Timeout: 50 * time.Millisecond}); r.ErrorClass != "timeout" {
		t.Fatalf("timeout: %+v", r)
	}
}

func TestHTTPTruncatesBody(t *testing.T) {
	p := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, strings.Repeat("a", maxBody+10))
	}))
	defer p.Close()
	r := HTTP(context.Background(), HTTPRequest{URL: p.URL})
	if !r.BodyTruncated || len(r.Body) != maxBody {
		t.Fatalf("len=%d trunc=%v", len(r.Body), r.BodyTruncated)
	}
}

func TestDialPortsDistinguishesOpenFromClosed(t *testing.T) {
	open, _ := net.Listen("tcp", "127.0.0.1:0")
	defer open.Close()
	closed, _ := net.Listen("tcp", "127.0.0.1:0")
	cp := closed.Addr().(*net.TCPAddr).Port
	closed.Close()
	op := open.Addr().(*net.TCPAddr).Port
	res := DialPorts(context.Background(), "127.0.0.1", []int{op, cp}, time.Second)
	if len(res.Reachable) != 1 || res.Reachable[0] != op || !res.Results[0].Reachable || res.Results[1].Reachable || res.Results[1].Error == "" {
		t.Fatalf("%+v", res)
	}
}

func TestParsePorts(t *testing.T) {
	got, err := ParsePorts(" 80, 443 ,,8080")
	if err != nil || len(got) != 3 || got[2] != 8080 {
		t.Fatalf("%v %v", got, err)
	}
	for _, bad := range []string{"", "0", "70000", "a", ","} {
		if _, err := ParsePorts(bad); err == nil {
			t.Fatalf("%q must be rejected", bad)
		}
	}
}

func TestParseRoutes(t *testing.T) {
	txt := "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n" +
		"tap0\t00000000\t0202000A\t0003\t0\t0\t0\t00000000\t0\t0\t0\n" +
		"tap0\t0002000A\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n"
	r := ParseRoutes(txt)
	if len(r) != 2 || r[0].Gateway != "10.0.2.2" || r[0].Dest != "0.0.0.0" || r[1].Dest != "10.0.2.0" || r[1].Mask != "255.255.255.0" {
		t.Fatalf("%+v", r)
	}
	if hexIP("zz") != "" {
		t.Fatal("bad hex")
	}
}

func TestGatherHasNoLoopback(t *testing.T) {
	for _, a := range Gather().Addrs {
		if net.ParseIP(a).IsLoopback() {
			t.Fatalf("loopback leaked: %s", a)
		}
	}
}

func enc(w io.Writer, v any) error { return json.NewEncoder(w).Encode(v) }

func TestMainDispatch(t *testing.T) {
	var out, errb bytes.Buffer
	if c := Main(nil, &out, &errb, enc); c != 2 {
		t.Fatalf("no args rc=%d", c)
	}
	if c := Main([]string{"nope"}, &out, &errb, enc); c != 2 {
		t.Fatal("unknown cmd")
	}
	out.Reset()
	if c := Main([]string{"info"}, &out, &errb, enc); c != 0 || !strings.Contains(out.String(), `"addrs"`) {
		t.Fatalf("info: %d %s", c, out.String())
	}
	s, ca := tlsServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "z") }))
	out.Reset()
	c := Main([]string{"http", "--url", s.URL, "--server-name", "example.com", "--ca-pem-hex", hexOf(ca), "--header", "X-A: b", "--method", "GET", "--body", "", "--timeout", "3s"}, &out, &errb, enc)
	var res HTTPResult
	if c != 0 || json.Unmarshal(out.Bytes(), &res) != nil || res.Status != 200 || !res.TLSVerified {
		t.Fatalf("http: rc=%d out=%s err=%s", c, out.String(), errb.String())
	}
	for _, bad := range [][]string{{"http"}, {"http", "--url"}, {"http", "--bogus", "x"}, {"http", "--url", "u", "--ca-pem-hex", "zz"},
		{"http", "--url", "u", "--header", "novalue"}, {"http", "--url", "u", "--timeout", "x"}, {"dial"}, {"dial", "--host", "h", "--ports", "x"}, {"dial", "--zzz", "1"}} {
		if c := Main(bad, &out, &errb, enc); c != 2 {
			t.Fatalf("%v rc=%d", bad, c)
		}
	}
	open, _ := net.Listen("tcp", "127.0.0.1:0")
	defer open.Close()
	out.Reset()
	port := open.Addr().(*net.TCPAddr).Port
	if c := Main([]string{"dial", "--host", "127.0.0.1", "--ports", itoa(port), "--timeout", "1s"}, &out, &errb, enc); c != 0 || !strings.Contains(out.String(), `"reachable":[`+itoa(port)+`]`) {
		t.Fatalf("dial: %d %s", c, out.String())
	}
}

func TestHoldReturnsOnMax(t *testing.T) {
	var out bytes.Buffer
	done := make(chan struct{})
	go func() { Hold(20*time.Millisecond, &out); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Hold did not honour max")
	}
	var o, e bytes.Buffer
	if c := Main([]string{"hold", "--max", "10ms"}, &o, &e, enc); c != 0 {
		t.Fatal(c)
	}
}

var _ = tls.VersionTLS12

// C-16: --request-file carries headers and body so they never appear on argv.
func TestMainRequestFileCarriesHeadersAndBody(t *testing.T) {
	var gotAuth, gotBody string
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		io.WriteString(w, "ok")
	}))
	defer s.Close()
	f := t.TempDir() + "/req.json"
	if err := os.WriteFile(f, []byte(`{"headers":{"Authorization":"Bearer tkn"},"body":"{\"q\":1}"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	var out, errb bytes.Buffer
	if c := Main([]string{"http", "--url", s.URL, "--method", "POST", "--request-file", f}, &out, &errb, enc); c != 0 {
		t.Fatalf("rc=%d %s %s", c, out.String(), errb.String())
	}
	if gotAuth != "Bearer tkn" || gotBody != `{"q":1}` {
		t.Fatalf("server saw auth=%q body=%q", gotAuth, gotBody)
	}
	for _, bad := range []string{"/nonexistent/req.json"} {
		if c := Main([]string{"http", "--url", s.URL, "--request-file", bad}, &out, &errb, enc); c != 2 {
			t.Fatalf("missing request file must be a usage error, rc=%d", c)
		}
	}
	bad := t.TempDir() + "/bad.json"
	_ = os.WriteFile(bad, []byte("{nope"), 0o600)
	if c := Main([]string{"http", "--url", s.URL, "--request-file", bad}, &out, &errb, enc); c != 2 {
		t.Fatalf("invalid JSON request file must be a usage error, rc=%d", c)
	}
}
