package server

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/audit"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/metrics"
)

// A-17 M1: several Authorization headers are ambiguous and never a valid credential, even when
// every one of them carries the valid key.
func TestDuplicateAuthorizationHeadersAreRefused(t *testing.T) {
	h := startServer(t)
	tc := h.rawTLS()
	br := bufio.NewReader(tc)
	wire := "GET /v1/models HTTP/1.1\r\nHost: localhost\r\n" +
		"Authorization: Bearer " + testKey + "\r\nAuthorization: Bearer " + testKey + "\r\n\r\n"
	resp, _, err := rawRequest(t, tc, br, wire)
	if err != nil || resp.StatusCode != 401 {
		t.Fatalf("two Authorization headers (both valid) must be 401: %v %v", resp, err)
	}
	// control: the identical request with ONE header is served
	tc2 := h.rawTLS()
	resp, _, err = rawRequest(t, tc2, bufio.NewReader(tc2), getWire("/v1/models", testKey))
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("control request: %v %v", resp, err)
	}
}

// A-17 M2: session tickets are off - a second connection never resumes.
func TestSessionTicketsAreDisabledNoResumption(t *testing.T) {
	h := startServer(t)
	if !h.srv.tlsCfg.SessionTicketsDisabled {
		t.Fatal("SessionTicketsDisabled must be true on the server TLS config")
	}
	cache := tls.NewLRUClientSessionCache(4)
	cfg := h.clientTLS()
	cfg.ClientSessionCache = cache
	for i := 0; i < 3; i++ {
		raw, err := net.Dial("tcp", h.addr)
		if err != nil {
			t.Fatal(err)
		}
		tc := tls.Client(raw, cfg)
		_ = tc.SetDeadline(time.Now().Add(4 * time.Second))
		if _, _, err := rawRequest(t, tc, bufio.NewReader(tc), getWire("/healthz", "")); err != nil { // reading processes any ticket
			t.Fatal(err)
		}
		if tc.ConnectionState().DidResume {
			t.Fatalf("connection %d resumed a session: tickets must be off", i)
		}
		tc.Close()
	}
}

// A-09: a certificate source supplied as GetConfigForClient cannot bypass the enforced floor.
func TestGetConfigForClientCannotBypassTheTLSFloor(t *testing.T) {
	var loose *tls.Config
	h := startServer(t, func(c *Config) {
		loose = &tls.Config{Certificates: c.TLS.Certificates, MinVersion: tls.VersionTLS10,
			NextProtos: []string{"h2", "http/1.1"}, SessionTicketsDisabled: false}
		c.TLS = &tls.Config{GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) { return loose, nil }}
	})
	got, err := h.srv.tlsCfg.GetConfigForClient(&tls.ClientHelloInfo{})
	if err != nil || got == nil {
		t.Fatalf("callback: %v", err)
	}
	if got.MinVersion < tls.VersionTLS12 || !got.SessionTicketsDisabled || len(got.NextProtos) != 1 || got.NextProtos[0] != "http/1.1" {
		t.Fatalf("the config returned by GetConfigForClient was not hardened: min=%x tickets-off=%v alpn=%v",
			got.MinVersion, got.SessionTicketsDisabled, got.NextProtos)
	}
	if loose.MinVersion != tls.VersionTLS10 {
		t.Error("the callback's own config must not be mutated")
	}
	// on the wire: ALPN offered h2 first, but the server answers http/1.1; TLS 1.1 is refused
	cfg := h.clientTLS()
	cfg.NextProtos = []string{"h2", "http/1.1"}
	raw, _ := net.Dial("tcp", h.addr)
	tc := tls.Client(raw, cfg)
	_ = tc.SetDeadline(time.Now().Add(4 * time.Second))
	if err := tc.Handshake(); err != nil {
		t.Fatal(err)
	}
	if p := tc.ConnectionState().NegotiatedProtocol; p != "http/1.1" {
		t.Errorf("ALPN = %q, want http/1.1", p)
	}
	tc.Close()
	old := h.clientTLS()
	old.MinVersion, old.MaxVersion = tls.VersionTLS10, tls.VersionTLS11
	raw2, _ := net.Dial("tcp", h.addr)
	tc2 := tls.Client(raw2, old)
	_ = tc2.SetDeadline(time.Now().Add(3 * time.Second))
	if err := tc2.Handshake(); err == nil {
		t.Fatal("TLS 1.0/1.1 must be refused even through GetConfigForClient")
	}
	// a callback that returns nil falls back to the hardened base config instead of failing
	h2 := startServer(t, func(c *Config) {
		c.TLS = &tls.Config{Certificates: c.TLS.Certificates,
			GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) { return nil, nil }}
	})
	if r := h2.do(h2.client(), "GET", "/healthz", "", nil); r.status != 200 {
		t.Fatalf("nil from GetConfigForClient: %d", r.status)
	}
	// and an error from it is passed through, not swallowed
	boom := errors.New("boom")
	s, err := New(func() Config {
		c := newConfig(t, sharedPKI(t), newFakeBackend(), &capSink{})
		c.TLS = &tls.Config{GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) { return nil, boom }}
		return c
	}())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.tlsCfg.GetConfigForClient(&tls.ClientHelloInfo{}); !errors.Is(err, boom) {
		t.Errorf("callback error must be returned: %v", err)
	}
}

// A-06: failed authentications are progressively delayed (the valid key never is).
func TestFailDelayIsProgressiveAndCapped(t *testing.T) {
	if failDelay(0) != 0 || failDelay(1) != 0 {
		t.Error("the first failure is not delayed")
	}
	prev := time.Duration(0)
	for n := 2; n <= 40; n++ {
		d := failDelay(n)
		if d < prev || d > failDelayCap {
			t.Fatalf("failDelay(%d)=%v not monotone/capped (%v)", n, d, failDelayCap)
		}
		prev = d
	}
	if failDelay(2) != failStep || failDelay(1000) != failDelayCap {
		t.Errorf("shape: %v %v", failDelay(2), failDelayCap)
	}
}

func TestWrongKeysAreSleptOnAndTheValidKeyNever(t *testing.T) {
	s := mustNewForInternal(t)
	var mu sync.Mutex
	var slept []time.Duration
	s.sleep = func(_ context.Context, d time.Duration) { mu.Lock(); slept = append(slept, d); mu.Unlock() }
	do := func(key string) int {
		r := mustReq(t, "GET", "/v1/models")
		r.Header.Set("Authorization", "Bearer "+key)
		return serveRecorded(s, r).Code
	}
	for i := 0; i < 5; i++ {
		if c := do("wrong-key-0123456789"); c != 401 {
			t.Fatalf("wrong key: %d", c)
		}
	}
	if len(slept) != 4 || slept[0] != failStep || slept[3] != 4*failStep {
		t.Fatalf("progressive delays not applied to failures 2..5: %v", slept)
	}
	n := len(slept)
	for i := 0; i < 5; i++ {
		if c := do(testKey); c != 200 {
			t.Fatalf("valid key: %d", c)
		}
	}
	if len(slept) != n {
		t.Fatalf("the valid key must never be delayed: %v", slept)
	}
}

// A-06: a throttled source is never evicted for a newcomer; a table full of throttled sources
// fails closed for new sources only.
func TestThrottleKeepsThrottledSourcesAndFailsClosedWhenFullOfThem(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	th := newAuthThrottle(2, time.Minute, 3, clk.now)
	for _, src := range []string{"a", "b", "c"} {
		for i := 0; i < 3; i++ { // 3 failures > limit 2: throttled
			th.fail(src)
		}
	}
	if th.size() != 3 {
		t.Fatalf("size %d", th.size())
	}
	throttled, ra, _ := th.fail("newcomer")
	if !throttled || ra < 1 {
		t.Fatalf("a table full of throttled sources must fail closed for a NEW source: %v %d", throttled, ra)
	}
	if th.size() != 3 {
		t.Fatalf("the newcomer must not be admitted over a throttled source: %d", th.size())
	}
	// the throttled sources are still throttled (no reset by eviction)
	if throttled, _, _ := th.fail("a"); !throttled {
		t.Fatal("source a must still be throttled")
	}
	// once a window expires there is room again and the newcomer is counted normally
	clk.t = clk.t.Add(2 * time.Minute)
	if throttled, _, _ := th.fail("newcomer"); throttled {
		t.Fatal("after the windows expire the newcomer is counted normally")
	}
}

func TestThrottleEvictsNonThrottledBeforeThrottled(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	th := newAuthThrottle(2, time.Minute, 3, clk.now)
	for i := 0; i < 3; i++ {
		th.fail("hot") // throttled, and the OLDEST entry
	}
	clk.t = clk.t.Add(time.Second)
	th.fail("cold1")
	th.fail("cold2")
	clk.t = clk.t.Add(time.Second)
	th.fail("newcomer") // table full: a non-throttled one must go, not "hot"
	if throttled, _, _ := th.fail("hot"); !throttled {
		t.Fatal("the throttled source must survive the eviction")
	}
}

// A-14: audit write failures are counted and reported once, and the request is not failed.
type errSink struct{}

func (errSink) Write(audit.Record) error {
	return errors.New("write /var/log/x: no space left on device")
}

func TestAuditWriteFailuresAreCountedAndReportedOnce(t *testing.T) {
	var out strings.Builder
	pki := sharedPKI(t)
	cfg := newConfig(t, pki, newFakeBackend(), &capSink{})
	cfg.Audit = errSink{}
	cfg.Stderr = &out
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		r := mustReq(t, "GET", "/v1/models")
		r.Header.Set("Authorization", "Bearer "+testKey)
		if c := serveRecorded(s, r).Code; c != 200 {
			t.Fatalf("a failing request log must not fail the request: %d", c)
		}
	}
	if got := s.metrics.Count(metrics.AuditWriteFailure); got != 3 {
		t.Fatalf("failures counted = %d, want 3", got)
	}
	if !strings.Contains(string(s.metrics.Render()), "llmctl_decide_audit_write_failures_total 3\n") {
		t.Error("the counter is not exposed on /metrics")
	}
	if n := strings.Count(out.String(), "request log write failed"); n != 1 {
		t.Fatalf("stderr must carry the first failure exactly once, got %d:\n%s", n, out.String())
	}
	if strings.Contains(out.String(), testKey) {
		t.Error("no secret may reach stderr")
	}
}

func mustReq(t *testing.T, method, path string) *http.Request {
	t.Helper()
	r, err := http.NewRequest(method, path, nil)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// A-07: the credential length gate equals the longest valid key, so it cannot refuse a valid key.
func TestCredentialLengthGateEqualsTheLongestValidKey(t *testing.T) {
	if maxCredentialBytes != keyring.MaxKeyLen {
		t.Fatalf("maxCredentialBytes %d != keyring.MaxKeyLen %d", maxCredentialBytes, keyring.MaxKeyLen)
	}
	long := strings.Repeat("aB3-xY9_kL", 60)[:keyring.MaxKeyLen]
	cfgKeys := func() []keyring.Secret { return []keyring.Secret{keyring.NewSecret(long)} }
	s := mustNewForInternal(t)
	s.cfg.Keys = cfgKeys
	do := func(tok string) int {
		r := mustReq(t, "GET", "/v1/models")
		r.Header.Set("Authorization", "Bearer "+tok)
		return serveRecorded(s, r).Code
	}
	if c := do(long); c != 200 {
		t.Fatalf("the longest valid key must be accepted: %d", c)
	}
	if c := do(long + "x"); c != 401 {
		t.Fatalf("one byte over: %d", c)
	}
}
