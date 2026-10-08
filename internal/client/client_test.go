package client

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/keyring"
)

const okBody = `{"model":"decide-tiny","answers":{"q":{"type":"noul","noul":0.9}},"usage":{"input_tokens":4,"output_tokens":1}}`

func TestAskSendsBearerKeyAndBodyAsData(t *testing.T) {
	var gotAuth, gotCT, gotPath, gotMethod string
	var gotBody []byte
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotCT, gotPath, gotMethod = r.Header.Get("Authorization"), r.Header.Get("Content-Type"), r.URL.Path, r.Method
		gotBody, _ = io.ReadAll(r.Body)
		jsonHandler(200, okBody, nil)(w, r)
	}))
	defer srv.Close()
	c, _ := newTestClient(t, srv, nil)
	big := []byte(`{"state":"` + strings.Repeat("x", 5<<20) + `"}`)
	res, err := c.Ask(context.Background(), big)
	if err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer "+testKey || gotCT != "application/json" || gotPath != "/v1/systemone" || gotMethod != "POST" {
		t.Fatalf("auth=%q ct=%q path=%q method=%q", gotAuth, gotCT, gotPath, gotMethod)
	}
	if len(gotBody) != len(big) {
		t.Fatalf("5 MB body arrived as %d bytes", len(gotBody))
	}
	if string(res.Body) != okBody || res.Latency <= 0 || res.Port == 0 {
		t.Fatalf("result %+v", res)
	}
}

func TestReadyAndModelsAuth(t *testing.T) {
	var readyAuth, modelsAuth atomic.Value
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/readyz":
			readyAuth.Store(r.Header.Get("Authorization"))
			jsonHandler(200, `{"status":"ready"}`, nil)(w, r)
		case "/v1/models":
			modelsAuth.Store(r.Header.Get("Authorization"))
			jsonHandler(200, `{"object":"list","data":[]}`, nil)(w, r)
		}
	}))
	defer srv.Close()
	c, _ := newTestClient(t, srv, nil)
	if err := c.Ready(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Models(context.Background()); err != nil {
		t.Fatal(err)
	}
	if readyAuth.Load() != "" {
		t.Errorf("/readyz is unauthenticated; the key must not be sent, got %q", readyAuth.Load())
	}
	if modelsAuth.Load() != "Bearer "+testKey {
		t.Errorf("/v1/models auth = %q", modelsAuth.Load())
	}
}

func TestStatusToKind(t *testing.T) {
	rows := []struct {
		status int
		body   string
		want   Kind
	}{
		{401, `{"message":"Authentication required.","error_type":"unauthorized"}`, KindKey},
		{403, `{}`, KindKey},
		{400, `{"message":"Invalid request.","error_type":"invalid_request"}`, KindUsage},
		{413, `{"message":"Payload too large.","error_type":"payload_too_large"}`, KindUsage},
		{422, `{"message":"Request failed validation.","error_type":"validation_failed"}`, KindUsage},
		{422, `{"message":"unknown model","error_type":"unknown_model"}`, KindUsage},
		{422, `{"message":"The model produced no usable answer for this question.","error_type":"readout_failed"}`, KindBackend},
		{429, `{"message":"Too many requests.","error_type":"rate_limited"}`, KindBackend},
		{503, `{"message":"Service not ready.","error_type":"not_ready"}`, KindUnreachable},
		{529, `{"message":"Temporarily overloaded.","error_type":"overloaded"}`, KindBackend},
		{502, `{"message":"The decision backend failed.","error_type":"backend_failed"}`, KindBackend},
		{404, `{"message":"Not found.","error_type":"invalid_request"}`, KindBackend},
		{500, `<html>boom</html>`, KindBackend},
	}
	for _, r := range rows {
		srv := httptest.NewTLSServer(jsonHandler(r.status, r.body, nil))
		c, _ := newTestClient(t, srv, nil)
		_, err := c.Ask(context.Background(), []byte(`{}`))
		srv.Close()
		if kindOf(err) != r.want {
			t.Errorf("HTTP %d %s: kind %v (%v), want %v", r.status, r.body, kindOf(err), err, r.want)
		}
		if ExitCodeOf(err) != int(r.want) {
			t.Errorf("exit code %d != %d", ExitCodeOf(err), r.want)
		}
	}
}

func TestRetryIsBoundedAndOnlyForRetryableStatuses(t *testing.T) {
	cases := []struct {
		status, retries, wantHits int
	}{
		{503, 2, 3}, {429, 2, 3}, {529, 2, 3}, {503, 0, 1}, {503, 999, 11}, // 999 is clamped to 10
		{502, 2, 1}, {401, 2, 1}, {422, 2, 1}, {500, 2, 1}, {404, 2, 1},
	}
	for _, tc := range cases {
		var hits atomic.Int32
		srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			hits.Add(1)
			jsonHandler(tc.status, `{"message":"x","error_type":"overloaded"}`, nil)(w, r)
		}))
		c, _ := newTestClient(t, srv, func(cfg *Config) { cfg.Retries = tc.retries })
		_, _ = c.Ask(context.Background(), []byte(`{}`))
		srv.Close()
		if int(hits.Load()) != tc.wantHits {
			t.Errorf("status %d retries %d: %d requests, want %d", tc.status, tc.retries, hits.Load(), tc.wantHits)
		}
	}
}

func TestRetrySucceedsAfterTransientAndHonoursRetryAfter(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if hits.Add(1) < 3 {
			jsonHandler(503, `{"message":"Service not ready.","error_type":"not_ready"}`, map[string]string{"Retry-After": "2"})(w, r)
			return
		}
		jsonHandler(200, okBody, nil)(w, r)
	}))
	defer srv.Close()
	c, slept := newTestClient(t, srv, nil)
	res, err := c.Ask(context.Background(), []byte(`{}`))
	if err != nil || string(res.Body) != okBody {
		t.Fatalf("res=%v err=%v", res, err)
	}
	if hits.Load() != 3 || len(*slept) != 2 || (*slept)[0] != 2*time.Second || (*slept)[1] != 2*time.Second {
		t.Fatalf("hits=%d sleeps=%v", hits.Load(), *slept)
	}
}

func TestRetryAfterIsCappedAndBackoffGrows(t *testing.T) {
	if d := retryDelay(http.Header{"Retry-After": {"3600"}}, 0); d != MaxRetryDelay {
		t.Errorf("huge Retry-After = %v", d)
	}
	if d := retryDelay(http.Header{"Retry-After": {"-4"}}, 0); d != 250*time.Millisecond {
		t.Errorf("negative Retry-After falls back to the backoff, got %v", d)
	}
	if retryDelay(http.Header{}, 1) <= retryDelay(http.Header{}, 0) {
		t.Error("backoff must grow with the attempt")
	}
	future := time.Now().Add(3 * time.Second).UTC().Format(http.TimeFormat)
	if d := retryDelay(http.Header{"Retry-After": {future}}, 0); d <= 0 || d > 4*time.Second {
		t.Errorf("HTTP-date Retry-After = %v", d)
	}
}

func TestWrongCAIsTLSKind(t *testing.T) {
	srv := httptest.NewTLSServer(jsonHandler(200, okBody, nil))
	defer srv.Close()
	c, err := New(Config{Endpoint: srv.URL, CAFile: otherCAFile(t), Key: keyring.NewSecret(testKey)})
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.Ask(context.Background(), []byte(`{}`))
	if kindOf(err) != KindTLS {
		t.Fatalf("wrong CA -> %v (%v), want TLS kind 5", kindOf(err), err)
	}
}

func TestHostnameMismatchIsTLSKind(t *testing.T) {
	srv := httptest.NewTLSServer(jsonHandler(200, okBody, nil))
	defer srv.Close()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(srv.URL, "https://"))
	c, err := New(Config{Endpoint: "https://localhost:" + port, CAFile: caFile(t, srv), Key: keyring.NewSecret(testKey)})
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.Ask(context.Background(), []byte(`{}`))
	if kindOf(err) != KindTLS {
		t.Fatalf("hostname mismatch -> %v (%v), want TLS kind 5", kindOf(err), err)
	}
}

func TestPlainHTTPServerOnTLSEndpointIsTLSKind(t *testing.T) {
	plain := httptest.NewServer(jsonHandler(200, okBody, nil))
	defer plain.Close()
	srv := httptest.NewTLSServer(jsonHandler(200, okBody, nil))
	defer srv.Close()
	c, err := New(Config{Endpoint: "https://" + strings.TrimPrefix(plain.URL, "http://"), CAFile: caFile(t, srv), Key: keyring.NewSecret(testKey)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = c.Ask(context.Background(), []byte(`{}`)); kindOf(err) != KindTLS {
		t.Fatalf("clear-text server -> %v (%v), want kind 5", kindOf(err), err)
	}
}

func TestCAFileProblemsAreTLSKind(t *testing.T) {
	dir := t.TempDir()
	for _, p := range []string{"", dir + "/nope.crt"} {
		if _, err := LoadCA(p); kindOf(err) != KindTLS {
			t.Errorf("LoadCA(%q) = %v", p, err)
		}
	}
	bad := dir + "/bad.crt"
	if err := writeFile(bad, "not a certificate"); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCA(bad); kindOf(err) != KindTLS {
		t.Errorf("garbage PEM = %v", err)
	}
}

func TestClosedPortIsUnreachableKind(t *testing.T) {
	srv := httptest.NewTLSServer(jsonHandler(200, okBody, nil))
	defer srv.Close()
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	ln.Close()
	c, err := New(Config{Endpoint: "https://" + addr, CAFile: caFile(t, srv), Key: keyring.NewSecret(testKey)})
	if err != nil {
		t.Fatal(err)
	}
	_, err = c.Ask(context.Background(), []byte(`{}`))
	if kindOf(err) != KindUnreachable {
		t.Fatalf("closed port -> %v (%v), want kind 6", kindOf(err), err)
	}
	if !strings.Contains(err.Error(), "connection refused") {
		t.Errorf("message should say why: %v", err)
	}
}

func TestSlowServerTimesOutAsBackendKind(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-time.After(3 * time.Second):
		case <-r.Context().Done():
		}
	}))
	defer srv.Close()
	c, _ := newTestClient(t, srv, func(cfg *Config) { cfg.Timeout = 150 * time.Millisecond })
	start := time.Now()
	_, err := c.Ask(context.Background(), []byte(`{}`))
	if kindOf(err) != KindBackend || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("got %v (%v)", kindOf(err), err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("timeout was not honoured")
	}
}

func TestErrorTextNeverContainsTheKeyOrRawBody(t *testing.T) {
	bodies := []struct {
		status int
		body   string
	}{
		{422, `{"message":"bad ` + testKey + ` here","error_type":"validation_failed"}`},
		{500, `secret echo ` + testKey},
		{502, `{"message":"` + testKey + `","error_type":"nonsense_type"}`},
	}
	for _, b := range bodies {
		srv := httptest.NewTLSServer(jsonHandler(b.status, b.body, nil))
		c, _ := newTestClient(t, srv, nil)
		_, err := c.Ask(context.Background(), []byte(`{}`))
		srv.Close()
		if err == nil || strings.Contains(err.Error(), testKey) {
			t.Errorf("error leaks the key or is nil: %v", err)
		}
		if strings.Contains(err.Error(), "secret echo") {
			t.Errorf("raw body echoed: %v", err)
		}
	}
}

func TestRedirectsAreNeverFollowed(t *testing.T) {
	var elsewhere atomic.Int32
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { elsewhere.Add(1) }))
	defer target.Close()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/steal", http.StatusTemporaryRedirect)
	}))
	defer srv.Close()
	c, _ := newTestClient(t, srv, nil)
	_, err := c.Ask(context.Background(), []byte(`{}`))
	if err == nil || elsewhere.Load() != 0 {
		t.Fatalf("redirect followed (hits %d) or accepted: %v", elsewhere.Load(), err)
	}
}

func TestEnvironmentProxyIsIgnored(t *testing.T) {
	var proxied atomic.Int32
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { proxied.Add(1) }))
	defer proxy.Close()
	t.Setenv("HTTPS_PROXY", proxy.URL)
	t.Setenv("https_proxy", proxy.URL)
	t.Setenv("NO_PROXY", "")
	srv := httptest.NewTLSServer(jsonHandler(200, okBody, nil))
	defer srv.Close()
	c, _ := newTestClient(t, srv, nil)
	if _, err := c.Ask(context.Background(), []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	if proxied.Load() != 0 {
		t.Fatal("the key was routed through an environment proxy")
	}
}

func TestMalformedSuccessBodyIsBackendKind(t *testing.T) {
	srv := httptest.NewTLSServer(jsonHandler(200, `not json`, nil))
	defer srv.Close()
	c, _ := newTestClient(t, srv, nil)
	if _, err := c.Ask(context.Background(), []byte(`{}`)); kindOf(err) != KindBackend {
		t.Fatalf("%v", err)
	}
}

func TestTruncatedHeaderIsReported(t *testing.T) {
	srv := httptest.NewTLSServer(jsonHandler(200, okBody, map[string]string{"x-llmctl-decide-truncated": "true"}))
	defer srv.Close()
	c, _ := newTestClient(t, srv, nil)
	res, err := c.Ask(context.Background(), []byte(`{}`))
	if err != nil || !res.Truncated {
		t.Fatalf("%v %+v", err, res)
	}
}

func TestEndpointValidation(t *testing.T) {
	for _, bad := range []string{"", "http://127.0.0.1:8095", "ftp://x", "https://", "https://u:p@host:1", "https://h:1/v1", "https://h:1?x=1", "127.0.0.1:8095"} {
		if _, err := ParseEndpoint(bad); kindOf(err) != KindUsage {
			t.Errorf("ParseEndpoint(%q) = %v, want usage error", bad, err)
		}
	}
	if u, err := ParseEndpoint("https://127.0.0.1:8095/"); err != nil || u.Path != "" {
		t.Errorf("trailing slash: %v %v", u, err)
	}
}

// TestVerificationCannotBeDisabled pins the structural guarantee (FR-068): the transport always
// verifies against exactly the supplied CA, and Config offers no knob that could change that.
func TestVerificationCannotBeDisabled(t *testing.T) {
	srv := httptest.NewTLSServer(jsonHandler(200, okBody, nil))
	defer srv.Close()
	c, _ := newTestClient(t, srv, nil)
	tr := c.hc.Transport.(*http.Transport)
	if tr.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("InsecureSkipVerify is on")
	}
	if tr.TLSClientConfig.RootCAs == nil || tr.TLSClientConfig.MinVersion < 0x0303 {
		t.Fatal("transport must trust only the supplied CA and require TLS 1.2+")
	}
	allowed := map[string]bool{"Endpoint": true, "CAFile": true, "Key": true, "Retries": true, "Timeout": true, "Sleep": true}
	ty := reflect.TypeOf(Config{})
	for i := 0; i < ty.NumField(); i++ {
		if !allowed[ty.Field(i).Name] {
			t.Errorf("unexpected Config field %q: nothing may relax verification", ty.Field(i).Name)
		}
	}
}

func TestNewRequiresAKey(t *testing.T) {
	srv := httptest.NewTLSServer(jsonHandler(200, okBody, nil))
	defer srv.Close()
	_, err := New(Config{Endpoint: srv.URL, CAFile: caFile(t, srv)})
	if kindOf(err) != KindKey {
		t.Fatalf("%v", err)
	}
}

func TestSeverityOrdering(t *testing.T) {
	order := []int{0, Abstained, 2, 1, 3, 6, 5, 4}
	for i := 1; i < len(order); i++ {
		if Severity(order[i]) <= Severity(order[i-1]) {
			t.Errorf("severity(%d) must exceed severity(%d)", order[i], order[i-1])
		}
	}
	if ExitCodeOf(nil) != 0 || ExitCodeOf(io.EOF) != 1 {
		t.Error("ExitCodeOf basics")
	}
}
