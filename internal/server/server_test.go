package server

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httptrace"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/keyring"
)

var hex16 = regexp.MustCompile(`^[0-9a-f]{16}$`)

func checkHygiene(t *testing.T, label string, hdr http.Header) {
	t.Helper()
	if hdr.Get("Cache-Control") != "no-store" {
		t.Errorf("%s: Cache-Control = %q", label, hdr.Get("Cache-Control"))
	}
	if hdr.Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("%s: X-Content-Type-Options = %q", label, hdr.Get("X-Content-Type-Options"))
	}
	if !hex16.MatchString(hdr.Get("x-request-id")) {
		t.Errorf("%s: x-request-id = %q", label, hdr.Get("x-request-id"))
	}
	if hdr.Get("x-llmctl-request-id") != hdr.Get("x-request-id") {
		t.Errorf("%s: x-llmctl-request-id must equal x-request-id", label)
	}
	if hdr.Get("Server") != "" {
		t.Errorf("%s: Server header must be absent, got %q", label, hdr.Get("Server"))
	}
	for k := range hdr {
		if strings.HasPrefix(strings.ToLower(k), "access-control-") {
			t.Errorf("%s: CORS header %s must not be sent", label, k)
		}
	}
}

// TestServerEndToEnd is the full happy path over real TLS plus the transport/hygiene contract.
func TestServerEndToEnd(t *testing.T) {
	h := startServer(t)
	c := h.clientFrom("", true)

	// liveness / readiness: unauthenticated, minimal
	r := h.do(c, "GET", "/healthz", "", map[string]string{"Authorization": ""})
	if r.status != 200 || strings.TrimSpace(string(r.body)) != `{"status":"ok"}` {
		t.Fatalf("healthz: %d %s", r.status, r.body)
	}
	checkHygiene(t, "healthz", r.hdr)
	r = h.do(c, "GET", "/readyz", "", map[string]string{"Authorization": ""})
	if r.status != 200 || strings.TrimSpace(string(r.body)) != `{"status":"ready"}` {
		t.Fatalf("readyz: %d %s", r.status, r.body)
	}

	// decision
	r = h.do(c, "POST", "/v1/systemone", sampleBody, nil)
	if r.status != 200 {
		t.Fatalf("systemone: %d %s", r.status, r.body)
	}
	checkHygiene(t, "systemone", r.hdr)
	if ct := r.hdr.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("content-type %q", ct)
	}
	var resp struct {
		Model   string                     `json:"model"`
		Answers map[string]json.RawMessage `json:"answers"`
		Usage   map[string]int             `json:"usage"`
	}
	if err := json.Unmarshal(r.body, &resp); err != nil || resp.Model != "decide-tiny" || len(resp.Answers) != 1 || resp.Usage["input_tokens"] != 5 {
		t.Fatalf("response shape: %v %+v", err, resp)
	}
	if r.hdr.Get("x-llmctl-decide-truncated") != "" {
		t.Error("truncation header must be absent unless truncation applied")
	}

	// models
	r = h.do(c, "GET", "/v1/models", "", nil)
	if r.status != 200 {
		t.Fatalf("models: %d %s", r.status, r.body)
	}
	var ml struct {
		Object string `json:"object"`
		Data   []struct {
			ID       string   `json:"id"`
			Aliases  []string `json:"aliases"`
			Protocol string   `json:"protocol"`
			Status   string   `json:"status"`
			Limits   struct {
				MaxOptions  int   `json:"max_options"`
				ScoreLevels []int `json:"score_levels"`
			} `json:"limits"`
		} `json:"data"`
	}
	if err := json.Unmarshal(r.body, &ml); err != nil || ml.Object != "list" || len(ml.Data) != 1 ||
		ml.Data[0].ID != "decide-tiny" || ml.Data[0].Limits.MaxOptions != 20 || len(ml.Data[0].Limits.ScoreLevels) != 2 ||
		ml.Data[0].Protocol != "letter-logit" || len(ml.Data[0].Aliases) != 2 {
		t.Fatalf("models shape: %v %s", err, r.body)
	}

	// metrics (key protected)
	r = h.do(c, "GET", "/metrics", "", nil)
	if r.status != 200 || !strings.HasPrefix(r.hdr.Get("Content-Type"), "text/plain; version=0.0.4") {
		t.Fatalf("metrics: %d %v", r.status, r.hdr)
	}
	if !strings.Contains(string(r.body), "llmctl_decide_") {
		t.Errorf("metrics body lacks families:\n%s", r.body)
	}
	if h.do(c, "GET", "/metrics", "", map[string]string{"Authorization": ""}).status != 401 {
		t.Error("metrics without key must be 401")
	}

	// negotiated TLS is >= 1.2 and http/1.1
	tc := h.rawTLS()
	st := tc.ConnectionState()
	if st.Version < tls.VersionTLS12 || st.NegotiatedProtocol != "http/1.1" {
		t.Errorf("tls state: version=%x alpn=%q", st.Version, st.NegotiatedProtocol)
	}

	// keep-alive: the second request reuses the connection
	reused := false
	tr := httptrace.WithClientTrace(context.Background(), &httptrace.ClientTrace{GotConn: func(i httptrace.GotConnInfo) { reused = reused || i.Reused }})
	req, _ := http.NewRequestWithContext(tr, "GET", "https://"+h.addr+"/healthz", nil)
	resp2, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp2.Body)
	resp2.Body.Close()
	if !reused {
		t.Error("keep-alive connection was not reused")
	}
}

func TestStatusInventory(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.MaxBody = 4096 }))
	c := h.client()
	noKey := map[string]string{"Authorization": ""}
	wrongKey := map[string]string{"Authorization": "Bearer definitely-wrong"}
	big := strings.Repeat("x", 5000)
	opts := func(n int) string {
		var b []string
		for i := 0; i < n; i++ {
			b = append(b, `"o`+strconv.Itoa(i)+`":"d"`)
		}
		return `{"state":"s","questions":{"q":{"type":"choice","instructions":"i","criteria":{` + strings.Join(b, ",") + `}}}}`
	}
	cases := []struct {
		id, method, path, body string
		hdr                    map[string]string
		status                 int
		etype                  string
	}{
		{"EP-009", "POST", "/v1/systemone", sampleBody, noKey, 401, "unauthorized"},
		{"EP-010", "POST", "/v1/systemone", sampleBody, wrongKey, 401, "unauthorized"},
		{"EP-011", "POST", "/v1/systemone", "this is not json", nil, 400, "invalid_request"},
		{"EP-012", "POST", "/v1/systemone", `[1,2,3]`, nil, 400, "invalid_request"},
		{"EP-013", "POST", "/v1/systemone", sampleBody, map[string]string{"Content-Type": "text/plain"}, 400, "invalid_request"},
		{"EP-014", "POST", "/v1/systemone", big, nil, 413, "payload_too_large"},
		{"EP-015", "POST", "/v1/systemone", opts(1), nil, 422, "validation_failed"},
		{"EP-016", "POST", "/v1/systemone", strings.Replace(sampleBody, "jev-latest", "no-such-model", 1), nil, 422, "unknown_model"},
		{"EP-018", "POST", "/v1/systemone", strings.Replace(sampleBody, `"state"`, `"bogus":1,"state"`, 1), nil, 422, "validation_failed"},
		{"EP-025", "GET", "/v1/systemone", "", nil, 405, "method_not_allowed"},
		{"EP-031", "GET", "/v1/models", "", noKey, 401, "unauthorized"},
		{"EP-032", "GET", "/v1/models", "", wrongKey, 401, "unauthorized"},
		{"EP-033", "POST", "/v1/models", `{}`, nil, 405, "method_not_allowed"},
		{"EP-041", "POST", "/healthz", "", noKey, 405, "method_not_allowed"},
		{"EP-041b", "POST", "/readyz", "", noKey, 405, "method_not_allowed"},
		{"EP-051", "GET", "/metrics", "", noKey, 401, "unauthorized"},
		{"EP-052", "POST", "/metrics", "", nil, 405, "method_not_allowed"},
		{"EP-060", "GET", "/no/such/path", "", nil, 404, "invalid_request"},
		{"EP-060b", "POST", "/no/such/path", `{}`, nil, 404, "invalid_request"},
		{"EP-061", "GET", "/no/such/path", "", noKey, 401, "unauthorized"},
		{"EP-061b", "GET", "/healthz/", "", noKey, 401, "unauthorized"},
	}
	for _, tc := range cases {
		t.Run(tc.id, func(t *testing.T) {
			r := h.do(c, tc.method, tc.path, tc.body, tc.hdr)
			if r.status != tc.status || r.errType() != tc.etype {
				t.Fatalf("got %d/%q want %d/%q (body %s)", r.status, r.errType(), tc.status, tc.etype, r.body)
			}
			checkHygiene(t, tc.id, r.hdr)
			var eb contract.ErrorBody
			if err := json.Unmarshal(r.body, &eb); err != nil || eb.Message == "" {
				t.Errorf("error body must be {message,error_type}: %v %s", err, r.body)
			}
			switch tc.status {
			case 401:
				if !strings.HasPrefix(r.hdr.Get("WWW-Authenticate"), "Bearer") {
					t.Errorf("401 needs WWW-Authenticate, got %q", r.hdr.Get("WWW-Authenticate"))
				}
			case 405:
				want := "GET"
				if tc.path == "/v1/systemone" {
					want = "POST"
				}
				if r.hdr.Get("Allow") != want {
					t.Errorf("Allow = %q, want %q", r.hdr.Get("Allow"), want)
				}
			}
		})
	}
	// 256 options is the hosted 400 (needs a larger body cap than the table's 4096)
	h2 := startServer(t)
	if r := h2.do(h2.client(), "POST", "/v1/systemone", opts(256), nil); r.status != 400 || r.errType() != "invalid_request" {
		t.Errorf("EP-015b: %d %s", r.status, r.body)
	}
	// The unknown path message never echoes the path.
	r := h.do(c, "GET", "/echo-me-secret-path", "", nil)
	if strings.Contains(string(r.body), "echo-me") {
		t.Error("404 body must not echo the path")
	}
}

func TestBackendErrorMapping(t *testing.T) {
	h := startServer(t)
	c := h.client()
	cases := []struct {
		name   string
		err    func() error
		status int
		etype  string
		retry  bool
	}{
		{"readout_failed", func() error { return contract.ReadoutFailedError() }, 422, "readout_failed", false},
		{"backend_died", func() error { return errBoom }, 502, "backend_failed", false},
		{"contract_503", func() error { e, _ := contract.TransportError(503, contract.TransportOptions{}); return e }, 503, "not_ready", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h.be.setDecide(func(context.Context, *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
				return nil, contract.Usage{}, tc.err()
			})
			r := h.do(c, "POST", "/v1/systemone", sampleBody, nil)
			if r.status != tc.status || r.errType() != tc.etype {
				t.Fatalf("%d %s", r.status, r.body)
			}
			if tc.retry && r.hdr.Get("Retry-After") == "" {
				t.Error("retryable status needs Retry-After")
			}
			if strings.Contains(string(r.body), "SECRET-ENGINE-TEXT") {
				t.Error("internal error text leaked into the body")
			}
		})
	}
}

func TestReadinessAndNotReady(t *testing.T) {
	h := startServer(t)
	c := h.client()
	h.be.ready.Store(false)
	r := h.do(c, "GET", "/readyz", "", map[string]string{"Authorization": ""})
	if r.status != 503 || strings.TrimSpace(string(r.body)) != `{"status":"not_ready"}` || r.hdr.Get("Retry-After") == "" {
		t.Fatalf("readyz not ready: %d %s %v", r.status, r.body, r.hdr)
	}
	if strings.Contains(string(r.body), "decide-tiny") {
		t.Error("probe leaked a profile name")
	}
	if r := h.do(c, "GET", "/healthz", "", map[string]string{"Authorization": ""}); r.status != 200 {
		t.Errorf("liveness stays 200 when not ready: %d", r.status)
	}
	if r := h.do(c, "POST", "/v1/systemone", sampleBody, nil); r.status != 503 || r.errType() != "not_ready" || r.hdr.Get("Retry-After") == "" {
		t.Errorf("systemone not ready: %d %s", r.status, r.body)
	}
	if h.be.calls.Load() != 0 {
		t.Error("backend must not be called while not ready")
	}
	if r := h.do(c, "GET", "/v1/models", "", nil); r.status != 503 || r.errType() != "not_ready" {
		t.Errorf("EP-034: %d %s", r.status, r.body)
	}
	h.be.ready.Store(true)
	if r := h.do(c, "GET", "/readyz", "", map[string]string{"Authorization": ""}); r.status != 200 {
		t.Errorf("ready again: %d", r.status)
	}
}

func TestProbesAreMinimalEvenWithSecretProfiles(t *testing.T) {
	h := startServer(t)
	h.be.models = []ModelInfo{{ID: "super-secret-profile", Protocol: "letter-logit", Status: "ready", MaxOptions: 5, ScoreLevels: [2]int{2, 10}}}
	for _, p := range []string{"/healthz", "/readyz"} {
		r := h.do(h.client(), "GET", p, "", map[string]string{"Authorization": "Bearer junk"})
		if r.status != 200 || strings.Contains(string(r.body), "secret") || len(r.body) > 40 {
			t.Errorf("%s: %d %q", p, r.status, r.body)
		}
	}
}

func TestAuthXAPIKeyOnlyWhenEnabled(t *testing.T) {
	h := startServer(t)
	r := h.do(h.client(), "GET", "/v1/models", "", map[string]string{"Authorization": "", "X-API-Key": testKey})
	if r.status != 401 {
		t.Fatalf("X-API-Key must not authenticate by default: %d", r.status)
	}
	h2 := startServer(t, func(c *Config) { c.AcceptXAPIKey = true })
	r = h2.do(h2.client(), "GET", "/v1/models", "", map[string]string{"Authorization": "", "X-API-Key": testKey})
	if r.status != 200 {
		t.Fatalf("X-API-Key accepted when enabled: %d", r.status)
	}
	// the key is never accepted from the query string
	r = h.do(h.client(), "GET", "/v1/models?api_key="+testKey, "", map[string]string{"Authorization": ""})
	if r.status != 401 {
		t.Errorf("query-string key must not authenticate: %d", r.status)
	}
}

func TestAuthSchemeParsing(t *testing.T) {
	h := startServer(t)
	c := h.client()
	for name, v := range map[string]string{
		"lower scheme ok": "bearer " + testKey,
		"upper scheme ok": "BEARER " + testKey,
	} {
		if r := h.do(c, "GET", "/v1/models", "", map[string]string{"Authorization": v}); r.status != 200 {
			t.Errorf("%s: %d", name, r.status)
		}
	}
	for name, v := range map[string]string{
		"basic":         "Basic " + testKey,
		"no scheme":     testKey,
		"empty token":   "Bearer ",
		"extra word":    "Bearer " + testKey + " extra",
		"prefix of key": "Bearer " + testKey[:10],
		"key plus junk": "Bearer " + testKey + "x",
		"huge":          "Bearer " + strings.Repeat("a", 5000),
	} {
		if r := h.do(c, "GET", "/v1/models", "", map[string]string{"Authorization": v}); r.status != 401 {
			t.Errorf("%s: want 401 got %d", name, r.status)
		}
	}
}

func TestRotationAcceptsEveryAcceptedKey(t *testing.T) {
	h := startServer(t, func(c *Config) {
		c.Keys = func() []keyring.Secret {
			return []keyring.Secret{keyring.NewSecret(testKey), keyring.NewSecret("previous-key-still-valid-0123456789")}
		}
	})
	for _, k := range []string{testKey, "previous-key-still-valid-0123456789"} {
		if r := h.do(h.client(), "GET", "/v1/models", "", map[string]string{"Authorization": "Bearer " + k}); r.status != 200 {
			t.Errorf("accepted key rejected: %d", r.status)
		}
	}
}

func TestNoAcceptedKeysFailsClosed(t *testing.T) {
	h := startServer(t, func(c *Config) { c.Keys = func() []keyring.Secret { return nil } })
	if r := h.do(h.client(), "GET", "/v1/models", "", map[string]string{"Authorization": "Bearer anything"}); r.status != 401 {
		t.Fatalf("no accepted keys must deny everything: %d", r.status)
	}
}

func TestThrottleNeverThrottlesTheValidKey(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.AuthFailLimit = 3 }))
	c := h.clientFrom("127.0.0.1", false)
	bad := map[string]string{"Authorization": "Bearer wrong"}
	for i := 1; i <= 3; i++ {
		if r := h.do(c, "POST", "/v1/systemone", sampleBody, bad); r.status != 401 {
			t.Fatalf("failure %d: %d", i, r.status)
		}
	}
	r := h.do(c, "POST", "/v1/systemone", sampleBody, bad)
	if r.status != 429 || r.errType() != "rate_limited" {
		t.Fatalf("4th failure: %d %s", r.status, r.body)
	}
	if ra, err := strconv.Atoi(r.hdr.Get("Retry-After")); err != nil || ra < 1 {
		t.Errorf("429 needs a Retry-After hint, got %q", r.hdr.Get("Retry-After"))
	}
	checkHygiene(t, "429", r.hdr)
	// the throttled source still gets full service WITH the valid key (EP-019)
	for i := 0; i < 5; i++ {
		if r := h.do(c, "POST", "/v1/systemone", sampleBody, nil); r.status != 200 {
			t.Fatalf("valid key from a throttled source must be served, got %d %s", r.status, r.body)
		}
		if r := h.do(c, "GET", "/v1/models", "", nil); r.status != 200 {
			t.Fatalf("valid key models from throttled source: %d", r.status)
		}
	}
	// still throttled for wrong keys, and a missing key counts as a failure too
	if r := h.do(c, "GET", "/v1/models", "", bad); r.status != 429 {
		t.Errorf("wrong key from throttled source: %d", r.status)
	}
	if r := h.do(c, "GET", "/v1/models", "", map[string]string{"Authorization": ""}); r.status != 429 {
		t.Errorf("missing key from throttled source: %d", r.status)
	}
	// probes are never throttled
	if r := h.do(c, "GET", "/healthz", "", bad); r.status != 200 {
		t.Errorf("probe from a throttled source: %d", r.status)
	}
	// another source has its own counter
	c2 := h.clientFrom("127.0.0.2", false)
	if r := h.do(c2, "GET", "/v1/models", "", bad); r.status != 401 {
		t.Errorf("second source must not be throttled by the first: %d", r.status)
	}
}

func TestBodyCapRejectedBeforeReading(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.MaxBody = 1000 }))
	tc := h.rawTLS()
	br := bufio.NewReader(tc)
	// headers only, declaring a huge body that is never sent: the answer must come anyway
	wire := "POST /v1/systemone HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " + testKey +
		"\r\nContent-Type: application/json\r\nContent-Length: 50000000\r\n\r\n"
	_ = tc.SetDeadline(time.Now().Add(3 * time.Second))
	io.WriteString(tc, wire)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatalf("no answer before the body was sent: %v", err)
	}
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 413 || !strings.Contains(string(b), "payload_too_large") {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
	if !resp.Close {
		t.Error("413 on an unread body must close the connection")
	}
}

func TestChunkedBodiesAreBoundedNotRefusedOutright(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.MaxBody = 1000 }))
	chunk := func(body string) string {
		return "POST /v1/systemone HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " + testKey +
			"\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n" +
			strconv.FormatInt(int64(len(body)), 16) + "\r\n" + body + "\r\n0\r\n\r\n"
	}
	tc := h.rawTLS()
	resp, b, err := rawRequest(t, tc, bufio.NewReader(tc), chunk(sampleBody))
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("small chunked body must be served: %v %v %s", err, resp, b)
	}
	tc2 := h.rawTLS()
	resp, b, err = rawRequest(t, tc2, bufio.NewReader(tc2), chunk(strings.Repeat("a", 5000)))
	if err != nil || resp.StatusCode != 413 {
		t.Fatalf("oversize chunked body must be 413: %v %v %s", err, resp, b)
	}
}

// N-12: a second request on the same TLS connection must succeed after an error response.
func TestKeepAliveAfterErrorResponses(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.MaxBody = 2000; noShedding(l) }))
	steps := []struct {
		name, wire string
		status     int
	}{
		{"401 with body", postWire("/v1/systemone", "wrong", sampleBody), 401},
		{"401 no key with body", postWire("/v1/systemone", "", sampleBody), 401},
		{"404 POST with body", postWire("/nope", testKey, sampleBody), 404},
		{"405 POST with body", postWire("/v1/models", testKey, sampleBody), 405},
		{"400 bad json", postWire("/v1/systemone", testKey, "not json at all"), 400},
		{"422 unknown model", postWire("/v1/systemone", testKey, strings.Replace(sampleBody, "jev-latest", "zzz", 1)), 422},
		{"413 body sent in full", postWire("/v1/systemone", testKey, strings.Repeat("x", 2001)), 413},
	}
	for _, st := range steps {
		t.Run(st.name, func(t *testing.T) {
			tc := h.rawTLS()
			br := bufio.NewReader(tc)
			resp, _, err := rawRequest(t, tc, br, st.wire)
			if err != nil || resp.StatusCode != st.status {
				t.Fatalf("first: %v %v", err, resp)
			}
			if resp.Close {
				return // an honest Connection: close is also a correct outcome
			}
			resp2, b2, err := rawRequest(t, tc, br, getWire("/healthz", ""))
			if err != nil || resp2.StatusCode != 200 || !strings.Contains(string(b2), `"ok"`) {
				t.Fatalf("second request on the same connection desynchronised: %v %v %s", err, resp2, b2)
			}
			// and a third, authenticated one
			resp3, _, err := rawRequest(t, tc, br, getWire("/v1/models", testKey))
			if err != nil || resp3.StatusCode != 200 {
				t.Fatalf("third request: %v %v", err, resp3)
			}
		})
	}
}

func TestRequestIDSanitised(t *testing.T) {
	h := startServer(t)
	c := h.client()
	r := h.do(c, "GET", "/healthz", "", map[string]string{"x-request-id": "0123456789abcdef"})
	if r.hdr.Get("x-request-id") != "0123456789abcdef" {
		t.Errorf("valid client id should be echoed: %q", r.hdr.Get("x-request-id"))
	}
	for _, bad := range []string{"<script>alert(1)</script>", "../../etc/passwd", strings.Repeat("a", 500), "ABCDEF0123456789", "short"} {
		r := h.do(c, "GET", "/healthz", "", map[string]string{"x-request-id": bad})
		if got := r.hdr.Get("x-request-id"); !hex16.MatchString(got) || got == bad {
			t.Errorf("client id %q must be replaced, got %q", bad, got)
		}
	}
	a := h.do(c, "GET", "/healthz", "", nil).hdr.Get("x-request-id")
	b := h.do(c, "GET", "/healthz", "", nil).hdr.Get("x-request-id")
	if a == b {
		t.Error("generated ids must differ")
	}
}

func TestTruncationHeaderOnlyWhenApplied(t *testing.T) {
	long := `{"state":"` + strings.Repeat("abcdefghij", 40) + `","questions":{"q":{"type":"noul","instructions":"Is it urgent?"}}}`
	mk := func(trunc bool) *harness {
		return startServer(t, func(c *Config) {
			c.ContractLimits.MaxStateChars = 100
			c.ContractLimits.Truncate = trunc
		})
	}
	h := mk(false)
	if r := h.do(h.client(), "POST", "/v1/systemone", long, nil); r.status != 422 || r.hdr.Get("x-llmctl-decide-truncated") != "" {
		t.Fatalf("default: over-budget is rejected, no header: %d %s", r.status, r.body)
	}
	h = mk(true)
	r := h.do(h.client(), "POST", "/v1/systemone", long, nil)
	if r.status != 200 || r.hdr.Get("x-llmctl-decide-truncated") != "true" {
		t.Fatalf("opt-in: answered with header: %d %v", r.status, r.hdr)
	}
	r = h.do(h.client(), "POST", "/v1/systemone", sampleBody, nil)
	if r.status != 200 || r.hdr.Get("x-llmctl-decide-truncated") != "" {
		t.Fatalf("not truncated => no header: %d %v", r.status, r.hdr)
	}
}

func TestPanicBecomesGeneric500AndServerSurvives(t *testing.T) {
	h := startServer(t)
	h.be.setDecide(func(context.Context, *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		panic("PANIC-SECRET-TEXT")
	})
	r := h.do(h.client(), "POST", "/v1/systemone", sampleBody, nil)
	if r.status != 500 || strings.Contains(string(r.body), "PANIC") || !strings.Contains(string(r.body), `"error_type"`) {
		t.Fatalf("%d %s", r.status, r.body)
	}
	checkHygiene(t, "500", r.hdr)
	h.be.setDecide(nil)
	if r := h.do(h.client(), "POST", "/v1/systemone", sampleBody, nil); r.status != 200 {
		t.Fatalf("server must survive a handler panic: %d", r.status)
	}
	if !strings.Contains(h.sink.all(), `"status":500`) {
		t.Error("the 500 must be audited")
	}
}

func TestSaturation529(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.Concurrency = 1; l.Queue = 1; l.Timeout = 5 * time.Second }))
	h.be.entered = make(chan struct{}, 8)
	release := make(chan struct{})
	h.be.setDecide(func(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		<-release
		return uniformAnswers(r)
	})
	c := h.clientFrom("", false)
	res := make(chan result, 2)
	go func() { res <- h.do(c, "POST", "/v1/systemone", sampleBody, nil) }()
	<-h.be.entered // request 1 holds the only slot
	go func() { res <- h.do(c, "POST", "/v1/systemone", sampleBody, nil) }()
	waitFor(t, 3*time.Second, "request 2 queued", func() bool { return h.srv.QueueDepth() == 1 })
	r3 := h.do(c, "POST", "/v1/systemone", sampleBody, nil)
	if r3.status != 529 || r3.errType() != "overloaded" || r3.hdr.Get("Retry-After") == "" {
		t.Fatalf("saturated: %d %s %v", r3.status, r3.body, r3.hdr)
	}
	close(release)
	for i := 0; i < 2; i++ {
		if r := <-res; r.status != 200 {
			t.Errorf("queued/in-flight request %d: %d %s", i, r.status, r.body)
		}
	}
	if h.srv.QueueDepth() != 0 {
		t.Error("queue must drain")
	}
}

func TestQueueDeadline529(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.Concurrency = 1; l.Queue = 4; l.Timeout = 300 * time.Millisecond }))
	h.be.entered = make(chan struct{}, 8)
	release := make(chan struct{})
	h.be.setDecide(func(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		<-release // ignores ctx on purpose: the slot stays busy
		return uniformAnswers(r)
	})
	c := h.client()
	first := make(chan result, 1)
	go func() { first <- h.do(c, "POST", "/v1/systemone", sampleBody, nil) }()
	<-h.be.entered
	start := time.Now()
	r := h.do(c, "POST", "/v1/systemone", sampleBody, nil)
	if r.status != 529 || r.errType() != "overloaded" {
		t.Fatalf("queued past deadline: %d %s", r.status, r.body)
	}
	if d := time.Since(start); d < 200*time.Millisecond || d > 2*time.Second {
		t.Errorf("queue wait %v not bounded by the request timeout", d)
	}
	close(release)
	<-first
}

func TestBackendTimeoutIs502(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.Timeout = 200 * time.Millisecond }))
	h.be.setDecide(func(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		<-ctx.Done()
		return nil, contract.Usage{}, ctx.Err()
	})
	r := h.do(h.client(), "POST", "/v1/systemone", sampleBody, nil)
	if r.status != 502 || r.errType() != "backend_failed" {
		t.Fatalf("%d %s", r.status, r.body)
	}
	// the documented additive signal: the end-to-end budget (not an engine fault) ended the request
	if got := r.hdr.Get("x-llmctl-decide-reason"); got != "deadline_exceeded" {
		t.Errorf("x-llmctl-decide-reason = %q, want deadline_exceeded", got)
	}
	if got := r.hdr.Get("x-llmctl-decide-deadline-ms"); got != "200" {
		t.Errorf("x-llmctl-decide-deadline-ms = %q, want 200", got)
	}
}

// A backend failure that is not the budget expiring is engine_error, with no deadline header.
func TestBackendFailureIsEngineError(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.Timeout = 5 * time.Second }))
	h.be.setDecide(func(context.Context, *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		return nil, contract.Usage{}, errors.New("engine exploded")
	})
	r := h.do(h.client(), "POST", "/v1/systemone", sampleBody, nil)
	if r.status != 502 || r.hdr.Get("x-llmctl-decide-reason") != "engine_error" || r.hdr.Get("x-llmctl-decide-deadline-ms") != "" {
		t.Fatalf("%d reason=%q deadline=%q", r.status, r.hdr.Get("x-llmctl-decide-reason"), r.hdr.Get("x-llmctl-decide-deadline-ms"))
	}
}

func TestMetricsBoundedAndClean(t *testing.T) {
	h := startServer(t)
	c := h.client()
	for i := 0; i < 5; i++ {
		h.do(c, "GET", "/v1/unique-hostile-path-"+strconv.Itoa(i), "", nil)
	}
	h.do(c, "POST", "/v1/systemone", sampleBody, nil)
	h.do(c, "POST", "/v1/systemone", strings.Replace(sampleBody, "the printer is on fire", "STATE-TEXT-MARKER", 1), nil)
	body := string(h.do(c, "GET", "/metrics", "", nil).body)
	for _, bad := range []string{"unique-hostile", "STATE-TEXT-MARKER", testKey, "printer", `"q"`} {
		if strings.Contains(body, bad) {
			t.Errorf("metrics leaked %q", bad)
		}
	}
	if !strings.Contains(body, `endpoint="/v1/systemone"`) || !strings.Contains(body, `endpoint="other"`) {
		t.Errorf("expected bounded endpoint labels:\n%s", body)
	}
}

func TestAuditRecordsHaveNoSecretsAndKeyedHash(t *testing.T) {
	h := startServer(t)
	c := h.client()
	// capture stderr while exercising failures
	old := os.Stderr
	pr, pw, _ := os.Pipe()
	os.Stderr = pw
	done := make(chan string)
	go func() { b, _ := io.ReadAll(pr); done <- string(b) }()

	h.do(c, "POST", "/v1/systemone", strings.Replace(sampleBody, "the printer is on fire", "STATE-SECRET-TEXT", 1), nil)
	h.do(c, "POST", "/v1/systemone", sampleBody, map[string]string{"Authorization": "Bearer wrong-key-WRONGSECRET"})
	h.do(c, "GET", "/v1/models", "", map[string]string{"Authorization": ""})
	h.be.setDecide(func(context.Context, *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		panic("PANIC-SECRET-TEXT")
	})
	h.do(c, "POST", "/v1/systemone", sampleBody, nil)
	h.be.setDecide(func(context.Context, *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		return nil, contract.Usage{}, errBoom
	})
	h.do(c, "POST", "/v1/systemone", sampleBody, nil)
	// hostile garbage at the TLS layer
	g := h.rawTCP("")
	g.Write([]byte("GET / HTTP/1.1\r\nAuthorization: Bearer " + testKey + "\r\n\r\n"))
	time.Sleep(100 * time.Millisecond)

	pw.Close()
	os.Stderr = old
	stderr := <-done
	logs := h.sink.all() + stderr + string(h.do(c, "GET", "/metrics", "", nil).body)
	for _, secret := range []string{testKey, "WRONGSECRET", "STATE-SECRET-TEXT", "PANIC-SECRET-TEXT", "SECRET-ENGINE-TEXT", "Bearer"} {
		if strings.Contains(logs, secret) {
			t.Errorf("secret %q leaked into logs/stderr/metrics", secret)
		}
	}
	if h.sink.count() < 5 {
		t.Fatalf("expected audit records, got %d", h.sink.count())
	}
	lines := strings.Split(h.sink.all(), "\n")
	var sawHash, sawWrong, sawMissing bool
	for _, l := range lines {
		var rec map[string]any
		if err := json.Unmarshal([]byte(l), &rec); err != nil {
			t.Fatalf("bad audit line %q", l)
		}
		if s, ok := rec["state_hash"].(string); ok && len(s) == 64 {
			sawHash = true
		}
		if rec["auth"] == "wrong" {
			sawWrong = true
		}
		if rec["auth"] == "missing" {
			sawMissing = true
		}
		if !hex16.MatchString(rec["request_id"].(string)) {
			t.Errorf("request id in audit: %v", rec["request_id"])
		}
	}
	if !sawHash || !sawWrong || !sawMissing {
		t.Errorf("audit lacks hash=%v wrong=%v missing=%v:\n%s", sawHash, sawWrong, sawMissing, h.sink.all())
	}
}

func TestStateHashIsKeyedAndStable(t *testing.T) {
	h := startServer(t)
	c := h.client()
	h.do(c, "POST", "/v1/systemone", sampleBody, nil)
	h.do(c, "POST", "/v1/systemone", sampleBody, nil)
	var hashes []string
	for _, l := range strings.Split(h.sink.all(), "\n") {
		var rec struct {
			StateHash *string `json:"state_hash"`
			Profile   *string `json:"profile"`
		}
		json.Unmarshal([]byte(l), &rec)
		if rec.StateHash != nil {
			hashes = append(hashes, *rec.StateHash)
			if rec.Profile == nil || *rec.Profile != "decide-tiny" {
				t.Errorf("profile id missing in audit: %s", l)
			}
		}
	}
	if len(hashes) != 2 || hashes[0] != hashes[1] {
		t.Fatalf("same state must hash equally: %v", hashes)
	}
	// without a log key the hash is omitted rather than computed with a weak key
	h2 := startServer(t, func(c *Config) { c.LogKey = nil })
	h2.do(h2.client(), "POST", "/v1/systemone", sampleBody, nil)
	if strings.Contains(h2.sink.all(), `"state_hash":"`) {
		t.Error("no log key => no hash")
	}
}

// ---------------- hostile clients and connection caps ----------------

func expectClosedWithoutHTTP(t *testing.T, c net.Conn, within time.Duration) []byte {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(within))
	b, err := io.ReadAll(c)
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		t.Fatalf("connection was not closed within %v", within)
	}
	if bytes.Contains(b, []byte("HTTP/1")) {
		t.Fatalf("server answered HTTP to a non-TLS client: %q", b)
	}
	return b
}

func healthyStill(t *testing.T, h *harness, label string) {
	t.Helper()
	start := time.Now()
	if r := h.do(h.client(), "GET", "/healthz", "", map[string]string{"Authorization": ""}); r.status != 200 {
		t.Fatalf("%s: healthy client got %d", label, r.status)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("%s: healthy client was slow (%v)", label, d)
	}
}

func TestHostileGarbageAndPlainHTTP(t *testing.T) {
	h := startServer(t)
	g := h.rawTCP("")
	g.Write(bytes.Repeat([]byte{0xde, 0xad, 0xbe, 0xef}, 64))
	expectClosedWithoutHTTP(t, g, 3*time.Second)
	healthyStill(t, h, "after garbage")

	p := h.rawTCP("")
	p.Write([]byte("GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n"))
	b := expectClosedWithoutHTTP(t, p, 3*time.Second)
	if bytes.Contains(b, []byte("301")) || bytes.Contains(b, []byte("Location")) {
		t.Fatalf("plain HTTP must never be redirected: %q", b)
	}
	// TLS record header claiming a giant record
	g2 := h.rawTCP("")
	g2.Write([]byte{0x16, 0x03, 0x03, 0xff, 0xff, 1, 2, 3})
	expectClosedWithoutHTTP(t, g2, 3*time.Second)
	healthyStill(t, h, "after plain http")
}

func TestOldTLSVersionsRefused(t *testing.T) {
	h := startServer(t)
	for _, v := range []uint16{tls.VersionTLS10, tls.VersionTLS11} {
		cfg := h.clientTLS()
		cfg.MinVersion, cfg.MaxVersion = v, v
		conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 3 * time.Second}, "tcp", h.addr, cfg)
		if err == nil {
			conn.Close()
			t.Fatalf("TLS %x must be refused", v)
		}
	}
	// the floor holds even if the supplied tls.Config tries to lower it
	pki := sharedPKI(t)
	cfg := newConfig(t, pki, newFakeBackend(), &capSink{})
	cfg.TLS = &tls.Config{Certificates: []tls.Certificate{pki.Cert}, MinVersion: tls.VersionTLS10}
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if s.tlsConfig().MinVersion < tls.VersionTLS12 {
		t.Fatal("server must raise the TLS floor to 1.2")
	}
}

func TestHugeHeaderRefusedAndOthersUnaffected(t *testing.T) {
	h := startServer(t)
	tc := h.rawTLS()
	big := strings.Repeat("A", 200<<10)
	_ = tc.SetDeadline(time.Now().Add(4 * time.Second))
	io.WriteString(tc, "GET /healthz HTTP/1.1\r\nHost: x\r\nX-Big: "+big+"\r\n\r\n")
	resp, err := http.ReadResponse(bufio.NewReader(tc), nil)
	if err == nil {
		if resp.StatusCode != 431 {
			t.Fatalf("huge header must be 431 (or closed), got %d", resp.StatusCode)
		}
		if !resp.Close {
			t.Error("431 must close the connection")
		}
	}
	healthyStill(t, h, "after huge header")
}

func TestHalfOpenConnectionsAreCutByHandshakeTimeout(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.HandshakeTimeout = 300 * time.Millisecond; noShedding(l) }))
	var idle []net.Conn
	for i := 0; i < 10; i++ {
		idle = append(idle, h.rawTCP(""))
	}
	// the accept loop must not be blocked by silent peers
	healthyStill(t, h, "while 10 half-open sockets are held")
	start := time.Now()
	for _, c := range idle {
		_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
		_, err := c.Read(make([]byte, 1))
		var ne net.Error
		if err == nil || (errors.As(err, &ne) && ne.Timeout()) {
			t.Fatal("half-open connection was not closed by the server")
		}
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("handshake timeout of 300ms took %v to cut idle sockets", d)
	}
	// stalled MID-handshake: a ClientHello prefix, then silence
	m := h.rawTCP("")
	m.Write([]byte{0x16, 0x03, 0x01, 0x00, 0x80, 0x01, 0x00})
	expectClosedWithoutHTTP(t, m, 3*time.Second)
}

func TestSlowDripHeadersCutAtReadDeadline(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.ReadDeadline = 600 * time.Millisecond }))
	tc := h.rawTLS()
	stop := make(chan struct{})
	go func() {
		for _, b := range []byte("GET /v1/models HTTP/1.1\r\nHost: localhost\r\nX-Slow: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") {
			select {
			case <-stop:
				return
			case <-time.After(60 * time.Millisecond):
			}
			if _, err := tc.Write([]byte{b}); err != nil {
				return
			}
		}
	}()
	defer close(stop)
	start := time.Now()
	_ = tc.SetReadDeadline(time.Now().Add(4 * time.Second))
	b, _ := io.ReadAll(tc)
	if d := time.Since(start); d > 2500*time.Millisecond {
		t.Fatalf("slow-drip connection survived %v (> deadline 600ms)", d)
	}
	if bytes.Contains(b, []byte("200 OK")) {
		t.Fatal("slow-drip request must not be served")
	}
	healthyStill(t, h, "after slow drip")
}

func TestSlowDripBodyCutAtReadDeadline(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.ReadDeadline = 600 * time.Millisecond }))
	tc := h.rawTLS()
	hdr := "POST /v1/systemone HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " + testKey +
		"\r\nContent-Type: application/json\r\nContent-Length: 200\r\n\r\n"
	io.WriteString(tc, hdr)
	stop := make(chan struct{})
	go func() {
		for i := 0; i < 200; i++ {
			select {
			case <-stop:
				return
			case <-time.After(60 * time.Millisecond):
			}
			if _, err := tc.Write([]byte("{")); err != nil {
				return
			}
		}
	}()
	defer close(stop)
	start := time.Now()
	_ = tc.SetReadDeadline(time.Now().Add(4 * time.Second))
	b, _ := io.ReadAll(tc)
	if d := time.Since(start); d > 2500*time.Millisecond {
		t.Fatalf("slow-drip body survived %v", d)
	}
	if bytes.Contains(b, []byte("200 OK")) {
		t.Fatal("must not be served")
	}
}

func holdOpen(t *testing.T, h *harness, src string) net.Conn {
	t.Helper()
	return h.rawTCP(src)
}

// Per-source cap (review A2-04): the newcomer from a source that is AT its cap is admitted and that
// source's own oldest unauthenticated connection is evicted (reset); other sources are unaffected.
// This replaces the former test that pinned "refuse the newcomer".
func TestPerSourceCapEvictsTheSourcesOwnOldestAndSparesOthers(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) {
		l.MaxConns = 6
		l.MaxConnsPerSource = 2
		l.HandshakeTimeout = 5 * time.Second // eviction must not wait for this
	}))
	c1 := holdOpen(t, h, "127.0.0.1")
	c2 := holdOpen(t, h, "127.0.0.1")
	waitFor(t, 2*time.Second, "two slots in use", func() bool { return h.srv.ConnsInUse() == 2 })

	// the third connection from the same source evicts that source's OLDEST one immediately
	c3 := holdOpen(t, h, "127.0.0.1")
	_ = c1.SetReadDeadline(time.Now().Add(2 * time.Second))
	if n, err := c1.Read(make([]byte, 1)); err == nil || isTimeout(err) {
		t.Fatalf("the source's oldest connection must be evicted (reset), got n=%d err=%v", n, err)
	}
	_ = c2.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if _, err := c2.Read(make([]byte, 1)); err != nil && !isTimeout(err) {
		t.Fatalf("only the oldest is evicted, c2 must stay open: %v", err)
	}
	if h.srv.Shed() != 0 {
		t.Errorf("the newcomer must not be shed: shed=%d", h.srv.Shed())
	}
	waitFor(t, 2*time.Second, "two slots in use again", func() bool { return h.srv.ConnsInUse() == 2 })

	// a second source is served normally while the first source's slots are held
	other := h.clientFrom("127.0.0.2", false)
	if r := h.do(other, "POST", "/v1/systemone", sampleBody, nil); r.status != 200 {
		t.Fatalf("second source must be served while source 1 holds its slots: %d", r.status)
	}
	// releasing a held slot leaves the first source able to be served
	c2.Close()
	waitFor(t, 3*time.Second, "slot freed", func() bool { return h.srv.ConnsInUse() <= 1 })
	again := h.clientFrom("127.0.0.1", false)
	if r := h.do(again, "GET", "/healthz", "", nil); r.status != 200 {
		t.Fatalf("source 1 after release: %d", r.status)
	}
	_ = c3
}

// A full pool no longer refuses a newcomer (review A-01, FR-022 "without affecting others"): the
// oldest unauthenticated holder of the heaviest source is evicted, and a client with the valid key
// from another source is served. This replaces the former test that pinned the starvation.
func TestGlobalCapEvictsUnauthenticatedHoldersInsteadOfRefusingTheNewcomer(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.MaxConns = 3; l.MaxConnsPerSource = 3; l.MaxUnauthConns = 3 }))
	holders := []net.Conn{holdOpen(t, h, "127.0.0.1"), holdOpen(t, h, "127.0.0.1"), holdOpen(t, h, "127.0.0.3")}
	waitFor(t, 2*time.Second, "three slots in use", func() bool { return h.srv.ConnsInUse() == 3 })

	r := h.do(h.clientFrom("127.0.0.4", false), "POST", "/v1/systemone", sampleBody, nil)
	if r.status != 200 {
		t.Fatalf("a valid-key client must be served while the pool is full of silent holders: %d %s", r.status, r.body)
	}
	if h.srv.Shed() != 0 {
		t.Errorf("the newcomer must not be shed: shed=%d", h.srv.Shed())
	}
	// the victim came from the heaviest source (127.0.0.1 holds two), the lone 127.0.0.3 holder survives
	dead := 0
	for _, c := range holders[:2] {
		_ = c.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
		if _, err := c.Read(make([]byte, 1)); err != nil && !isTimeout(err) {
			dead++
		}
	}
	if dead != 1 {
		t.Errorf("exactly one holder of the heaviest source must have been reset, got %d", dead)
	}
	_ = holders[2].SetReadDeadline(time.Now().Add(200 * time.Millisecond))
	if _, err := holders[2].Read(make([]byte, 1)); err != nil && !isTimeout(err) {
		t.Errorf("the single-connection source must not be the victim: %v", err)
	}
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

// dialLoose opens a TCP connection from src and reports (nil, false) when it was shed.
func dialLoose(addr, src string) (net.Conn, bool) {
	d := &net.Dialer{Timeout: 2 * time.Second, LocalAddr: &net.TCPAddr{IP: net.ParseIP(src)}}
	c, err := d.Dial("tcp", addr)
	return c, err == nil
}

// A-18 / FR-022: at least 8 hostile IPv4 sources hold bare TCP connections AND idle keep-alives on
// the DEFAULT limits, and a client with the valid key, from yet another source, is still served -
// repeatedly, with and without a connection it opened before the flood. RED before the fix: the 64
// global slots were all taken and the legitimate client was reset at Accept.
func TestValidKeyClientIsServedWhileHostileSourcesHoldTheSlots(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.PreAuthTimeout = 1500 * time.Millisecond }))
	defer func() {}()

	// a legitimate client opens (and authenticates) a keep-alive connection BEFORE the flood
	pre := h.clientFrom("127.0.0.20", true)
	if r := h.do(pre, "POST", "/v1/systemone", sampleBody, nil); r.status != 200 {
		t.Fatalf("pre-flood: %d", r.status)
	}

	var hostile []net.Conn
	for i := 2; i <= 9; i++ { // 127.0.0.2 .. 127.0.0.9: eight hostile sources
		src := fmt.Sprintf("127.0.0.%d", i)
		for k := 0; k < 12; k++ { // more attempts than any per-source bound: the rest are shed
			c, ok := dialLoose(h.addr, src)
			if !ok {
				continue
			}
			hostile = append(hostile, c)
			if k%2 == 0 { // half of them complete the handshake, send one unauthenticated probe and idle
				tc := tls.Client(c, h.clientTLS())
				_ = tc.SetDeadline(time.Now().Add(2 * time.Second))
				if tc.Handshake() == nil {
					_, _ = io.WriteString(tc, "GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n")
				}
			}
		}
	}
	t.Cleanup(func() {
		for _, c := range hostile {
			c.Close()
		}
	})
	if got := h.srv.slots.unauthInUse(); got < h.srv.lim.MaxUnauthConns-2 {
		t.Fatalf("the flood must (nearly) fill the unauthenticated pool for the test to mean anything: %d/%d", got, h.srv.lim.MaxUnauthConns)
	}

	// 1. the connection that authenticated before the flood is untouched
	if r := h.do(pre, "GET", "/v1/models", "", nil); r.status != 200 {
		t.Fatalf("an authenticated keep-alive connection must survive the flood: %d", r.status)
	}
	// 2. fresh connections from another source, each with the valid key
	for i := 0; i < 10; i++ {
		c := h.clientFrom("127.0.0.30", false)
		if r := h.do(c, "POST", "/v1/systemone", sampleBody, nil); r.status != 200 {
			t.Fatalf("legitimate request %d during the flood: %d %s", i, r.status, r.body)
		}
	}
	// 3. the silent and the probing holders are reaped by the pre-auth timeout, not held forever
	waitFor(t, 6*time.Second, "hostile holders reaped by the pre-auth timeout", func() bool {
		return h.srv.slots.unauthInUse() == 0
	})
	// 4. the authenticated keep-alive connection is NOT subject to that timer
	time.Sleep(1700 * time.Millisecond)
	if r := h.do(pre, "GET", "/v1/models", "", nil); r.status != 200 {
		t.Fatalf("an authenticated idle connection must outlive the pre-auth timeout: %d", r.status)
	}
}

// The pre-auth timer: bare TCP, a completed handshake with no request, and an unauthenticated probe
// followed by idling are all closed within PreAuthTimeout; an authenticated connection is not.
func TestPreAuthTimeoutReapsUnauthenticatedConnections(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.PreAuthTimeout = 400 * time.Millisecond }))
	bare := h.rawTCP("")
	tlsOnly := h.rawTLS()
	probe := h.rawTLS()
	probeBR := bufio.NewReader(probe)
	if resp, _, err := rawRequest(t, probe, probeBR, getWire("/healthz", "")); err != nil || resp.StatusCode != 200 {
		t.Fatalf("probe: %v", err)
	}
	authed := h.rawTLS()
	authedBR := bufio.NewReader(authed)
	if resp, _, err := rawRequest(t, authed, authedBR, getWire("/v1/models", testKey)); err != nil || resp.StatusCode != 200 {
		t.Fatalf("authed: %v", err)
	}
	start := time.Now()
	for name, c := range map[string]net.Conn{"bare": bare, "tls-only": tlsOnly, "probe": probe} {
		_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
		if _, err := c.Read(make([]byte, 1)); err == nil || isTimeout(err) {
			t.Errorf("%s connection must be closed by the pre-auth timeout, got %v", name, err)
		}
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("reaping took %v for a 400ms timeout", d)
	}
	waitFor(t, 2*time.Second, "only the authenticated connection remains", func() bool { return h.srv.ConnsInUse() == 1 })
	time.Sleep(600 * time.Millisecond) // well past the timeout
	if resp, _, err := rawRequest(t, authed, authedBR, getWire("/v1/models", testKey)); err != nil || resp.StatusCode != 200 {
		t.Fatalf("the authenticated connection must not be reaped: %v", err)
	}
}

// Capacity reserved for authenticated connections: with a small unauthenticated budget the rest of
// MaxConns stays available to connections that proved the key, no matter how many hostile
// connections are open.
func TestAuthenticatedConnectionsKeepReservedCapacity(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) {
		l.MaxConns, l.MaxConnsPerSource = 12, 12
		l.MaxUnauthConns, l.MaxUnauthPerSource, l.MaxUnauthPerAggregate = 4, 4, 4
		l.PreAuthTimeout = 30 * time.Second
	}))
	var authed []*tls.Conn
	for i := 0; i < 8; i++ { // eight authenticated connections: more than the unauthenticated budget
		tc := h.rawTLS()
		if resp, _, err := rawRequest(t, tc, bufio.NewReader(tc), getWire("/v1/models", testKey)); err != nil || resp.StatusCode != 200 {
			t.Fatalf("authenticated connection %d: %v", i, err)
		}
		authed = append(authed, tc)
	}
	waitFor(t, 2*time.Second, "eight promoted", func() bool { return h.srv.slots.inUse() == 8 && h.srv.slots.unauthInUse() == 0 })
	for i := 0; i < 4; i++ {
		holdOpen(t, h, "127.0.0.2")
	}
	waitFor(t, 2*time.Second, "unauthenticated budget full", func() bool { return h.srv.slots.unauthInUse() == 4 })
	// all 12 slots are in use; a legitimate newcomer still gets in (it evicts an unauthenticated holder)
	if r := h.do(h.clientFrom("127.0.0.9", false), "GET", "/v1/models", "", nil); r.status != 200 {
		t.Fatalf("newcomer with the valid key: %d", r.status)
	}
	for i, tc := range authed { // no authenticated connection was evicted
		if resp, _, err := rawRequest(t, tc, bufio.NewReader(tc), getWire("/healthz", "")); err != nil || resp.StatusCode != 200 {
			t.Fatalf("authenticated connection %d lost: %v", i, err)
		}
	}
}

// ---------------- drain and shutdown ----------------

func TestGracefulDrain(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.DrainGrace = 5 * time.Second }))
	h.be.entered = make(chan struct{}, 4)
	release := make(chan struct{})
	h.be.setDecide(func(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		<-release
		return uniformAnswers(r)
	})
	res := make(chan result, 1)
	go func() { res <- h.do(h.client(), "POST", "/v1/systemone", sampleBody, nil) }()
	<-h.be.entered

	drained := make(chan error, 1)
	go func() { drained <- h.srv.Drain(context.Background()) }()
	waitFor(t, 2*time.Second, "draining flag", h.srv.Draining)

	// readiness flipped FIRST (checked in-process: the listener is already closing)
	rr := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/readyz", nil)
	h.srv.Handler().ServeHTTP(rr, req)
	if rr.Code != 503 || strings.TrimSpace(rr.Body.String()) != `{"status":"not_ready"}` {
		t.Fatalf("readyz while draining: %d %s", rr.Code, rr.Body)
	}
	rr = httptest.NewRecorder()
	req = httptest.NewRequest("POST", "/v1/systemone", strings.NewReader(sampleBody))
	req.Header.Set("Authorization", "Bearer "+testKey)
	req.Header.Set("Content-Type", "application/json")
	h.srv.Handler().ServeHTTP(rr, req)
	if rr.Code != 503 || rr.Header().Get("Retry-After") == "" || !strings.Contains(rr.Body.String(), "not_ready") {
		t.Fatalf("new work while draining: %d %s", rr.Code, rr.Body)
	}
	select {
	case err := <-drained:
		t.Fatalf("Drain returned before the in-flight request finished: %v", err)
	case <-time.After(200 * time.Millisecond):
	}

	close(release)
	r := <-res
	if r.status != 200 {
		t.Fatalf("in-flight request must complete during the grace: %d %s", r.status, r.body)
	}
	if err := <-drained; err != nil {
		t.Fatalf("Drain: %v", err)
	}
	if err := <-h.serve; !errors.Is(err, http.ErrServerClosed) {
		t.Fatalf("Serve returned %v", err)
	}
	if _, err := net.DialTimeout("tcp", h.addr, 500*time.Millisecond); err == nil {
		t.Error("listener must be closed after drain")
	}
	h.serve <- http.ErrServerClosed // for the cleanup waiter
}

func TestDrainGraceExpiryForcesClose(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.DrainGrace = 300 * time.Millisecond; l.Timeout = 30 * time.Second }))
	h.be.entered = make(chan struct{}, 4)
	block := make(chan struct{})
	defer close(block)
	h.be.setDecide(func(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		select {
		case <-block:
		case <-ctx.Done():
		}
		return nil, contract.Usage{}, errBoom
	})
	go h.doBG()
	<-h.be.entered
	start := time.Now()
	err := h.srv.Drain(context.Background())
	if err == nil {
		t.Fatal("Drain past the grace with a stuck request must report it")
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Errorf("Drain took %v with a 300ms grace", d)
	}
	<-h.serve
	h.serve <- http.ErrServerClosed
}

func TestDrainRespectsCallerContext(t *testing.T) {
	h := startServer(t, withLimits(func(l *Limits) { l.DrainGrace = time.Minute; l.Timeout = 30 * time.Second }))
	h.be.entered = make(chan struct{}, 4)
	block := make(chan struct{})
	defer close(block)
	h.be.setDecide(func(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		<-block
		return nil, contract.Usage{}, errBoom
	})
	go h.doBG()
	<-h.be.entered
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err := h.srv.Drain(ctx); err == nil || time.Since(start) > 3*time.Second {
		t.Fatalf("caller deadline must bound Drain: %v after %v", err, time.Since(start))
	}
	<-h.serve
	h.serve <- http.ErrServerClosed
}

func serverFrames() []string {
	buf := make([]byte, 1<<20)
	buf = buf[:runtime.Stack(buf, true)]
	var bad []string
	for _, g := range strings.Split(string(buf), "\n\n") {
		if strings.Contains(g, "net/http.(*conn).serve") || strings.Contains(g, "net/http.(*Server).Serve") ||
			strings.Contains(g, "llmctl/internal/server.(*srvConn)") || strings.Contains(g, "llmctl/internal/server.(*Server)") {
			if strings.Contains(g, "server.TestGoroutine") {
				continue
			}
			bad = append(bad, g)
		}
	}
	return bad
}

func TestNoGoroutineLeakAfterShutdown(t *testing.T) {
	pki := sharedPKI(t)
	be := newFakeBackend()
	sink := &capSink{}
	cfg := newConfig(t, pki, be, sink)
	cfg.Limits.HandshakeTimeout = 300 * time.Millisecond
	noShedding(&cfg.Limits)
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	done := make(chan error, 1)
	go func() { done <- s.Serve(ln) }()
	h := &harness{t: t, srv: s, addr: ln.Addr().String(), pki: pki, be: be, sink: sink}

	c := h.clientFrom("", true)
	for i := 0; i < 20; i++ {
		h.do(c, "POST", "/v1/systemone", sampleBody, nil)
		h.do(c, "POST", "/v1/systemone", sampleBody, map[string]string{"Authorization": "Bearer bad"})
	}
	var junk []net.Conn
	for i := 0; i < 15; i++ {
		jc, _ := net.Dial("tcp", h.addr)
		if i%2 == 0 {
			jc.Write([]byte("garbage garbage garbage"))
		}
		junk = append(junk, jc)
	}
	tc := h.rawTLS() // a live keep-alive connection at shutdown time
	_ = tc

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.Drain(ctx); err != nil {
		t.Fatalf("drain: %v", err)
	}
	<-done
	for _, jc := range junk {
		jc.Close()
	}
	tc.Close()
	c.CloseIdleConnections()
	deadline := time.Now().Add(5 * time.Second)
	for {
		bad := serverFrames()
		if len(bad) == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("server goroutines leaked after shutdown:\n%s", strings.Join(bad, "\n\n"))
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestNewValidatesConfig(t *testing.T) {
	pki := sharedPKI(t)
	base := func() Config { return newConfig(t, pki, newFakeBackend(), &capSink{}) }
	for name, mut := range map[string]func(*Config){
		"nil backend":  func(c *Config) { c.Backend = nil },
		"nil tls":      func(c *Config) { c.TLS = nil },
		"nil keys":     func(c *Config) { c.Keys = nil },
		"nil profiles": func(c *Config) { c.Profiles = nil },
		"bad limits":   func(c *Config) { c.Limits.MaxConns = -1 },
		"tls no cert":  func(c *Config) { c.TLS = &tls.Config{} },
	} {
		cfg := base()
		mut(&cfg)
		if _, err := New(cfg); err == nil {
			t.Errorf("%s: New must fail", name)
		}
	}
	if _, err := New(base()); err != nil {
		t.Fatal(err)
	}
}

func TestTLSCertificateReloadViaGetCertificate(t *testing.T) {
	pki1, pki2 := sharedPKI(t), sharedPKI(t)
	var mu sync.Mutex
	cur := pki1
	h := startServer(t, func(c *Config) {
		c.TLS = &tls.Config{GetCertificate: func(*tls.ClientHelloInfo) (*tls.Certificate, error) {
			mu.Lock()
			defer mu.Unlock()
			return &cur.Cert, nil
		}}
	})
	h.pki = pki1
	if r := h.do(h.client(), "GET", "/healthz", "", nil); r.status != 200 {
		t.Fatal("first cert")
	}
	mu.Lock()
	cur = pki2
	mu.Unlock()
	h.pki = pki2
	if r := h.do(h.client(), "GET", "/healthz", "", nil); r.status != 200 {
		t.Fatal("reloaded cert must be served on new handshakes")
	}
}

// B2-11: the instance that answered is reported in x-llmctl-decide-instance when the backend noted
// one, and the header is absent when it did not.
func TestInstanceHeaderIsSetOnlyWhenTheBackendNotedAnInstance(t *testing.T) {
	h := startServer(t)
	r := h.do(h.client(), "POST", "/v1/systemone", sampleBody, nil)
	if r.status != 200 {
		t.Fatalf("control: %d", r.status)
	}
	if v, present := r.hdr[http.CanonicalHeaderKey(contract.HeaderInstance)]; present {
		t.Fatalf("no instance noted: the header must be absent, got %q", v)
	}
	h.be.setDecide(func(ctx context.Context, rq *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		contract.NoteInstance(ctx, "engine-7.b")
		return uniformAnswers(rq)
	})
	r2 := h.do(h.client(), "POST", "/v1/systemone", sampleBody, nil)
	if r2.status != 200 {
		t.Fatalf("routed answer: %d %s", r2.status, r2.body)
	}
	if got := r2.hdr.Get(contract.HeaderInstance); got != "engine-7.b" {
		t.Fatalf("instance header = %q, want engine-7.b", got)
	}
}
