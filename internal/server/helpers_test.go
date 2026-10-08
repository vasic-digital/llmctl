package server

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/audit"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/server/internal/testpki"
)

const testKey = "test-access-key-0123456789-abcdefghijklmnop"

const sampleBody = `{"model":"jev-latest","state":"the printer is on fire","questions":{"q":{"type":"noul","instructions":"Is it urgent?"}}}`

// fakeBackend is the test double for Backend (allowed in unit tests only).
type fakeBackend struct {
	ready    atomic.Bool
	mu       sync.Mutex
	decide   func(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error)
	models   []ModelInfo
	inflight atomic.Int32
	calls    atomic.Int32
	entered  chan struct{} // receives one value per Decide entry when non-nil
	lastReq  *contract.ParsedRequest
	maturity map[string]string // question type -> "experimental" (T138); implements MaturityReporter
}

// Maturity implements MaturityReporter for the T138 tests.
func (b *fakeBackend) Maturity(profile, qtype string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.maturity[qtype]
}

func newFakeBackend() *fakeBackend {
	b := &fakeBackend{models: []ModelInfo{{
		ID: "decide-tiny", Aliases: []string{"jev-latest", "llmctl-decide-tiny"},
		Protocol: "letter-logit", Status: "ready", MaxOptions: 20, ScoreLevels: [2]int{2, 10},
	}}}
	b.ready.Store(true)
	return b
}

func (b *fakeBackend) Ready() bool { return b.ready.Load() }

func (b *fakeBackend) Models() []ModelInfo {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]ModelInfo(nil), b.models...)
}

func (b *fakeBackend) setDecide(f func(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error)) {
	b.mu.Lock()
	b.decide = f
	b.mu.Unlock()
}

func (b *fakeBackend) Decide(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
	b.calls.Add(1)
	b.inflight.Add(1)
	defer b.inflight.Add(-1)
	b.mu.Lock()
	f := b.decide
	b.lastReq = r
	b.mu.Unlock()
	if b.entered != nil {
		b.entered <- struct{}{}
	}
	if f != nil {
		return f(ctx, r)
	}
	return uniformAnswers(r)
}

func uniformAnswers(r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
	var out []contract.NamedAnswer
	for _, q := range r.Questions {
		n := len(q.Options)
		p := make([]float64, n)
		for i := range p {
			p[i] = 1 / float64(n)
		}
		a, err := contract.BuildAnswer(q, p)
		if err != nil {
			return nil, contract.Usage{}, err
		}
		out = append(out, contract.NamedAnswer{Name: q.Name, Answer: a})
	}
	return out, contract.Usage{InputTokens: 5, OutputTokens: 1}, nil
}

// capSink captures audit records in memory.
type capSink struct {
	mu    sync.Mutex
	lines []string
}

func (c *capSink) Write(r audit.Record) error {
	c.mu.Lock()
	c.lines = append(c.lines, audit.ToJSONLine(r))
	c.mu.Unlock()
	return nil
}

func (c *capSink) all() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return strings.Join(c.lines, "\n")
}

func (c *capSink) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.lines)
}

type harness struct {
	t     *testing.T
	srv   *Server
	addr  string
	ln    net.Listener
	pki   *testpki.PKI
	be    *fakeBackend
	sink  *capSink
	serve chan error
	cfg   Config
}

type hopt func(*Config)

func withLimits(f func(*Limits)) hopt { return func(c *Config) { f(&c.Limits) } }

func newConfig(t testing.TB, pki *testpki.PKI, be *fakeBackend, sink *capSink) Config {
	t.Helper()
	profiles, err := contract.NewProfiles([]string{"decide-tiny"}, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	return Config{
		Backend:        be,
		Limits:         DefaultLimits(),
		TLS:            &tls.Config{Certificates: []tls.Certificate{pki.Cert}},
		Keys:           func() []keyring.Secret { return []keyring.Secret{keyring.NewSecret(testKey)} },
		Audit:          sink,
		LogKey:         bytes.Repeat([]byte{7}, 32),
		Profiles:       profiles,
		ContractLimits: contract.DefaultLimits(),
	}
}

func sharedPKI(t testing.TB) *testpki.PKI {
	t.Helper()
	p, err := testpki.New(testpki.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func startServer(t *testing.T, opts ...hopt) *harness {
	t.Helper()
	pki := sharedPKI(t)
	be := newFakeBackend()
	sink := &capSink{}
	cfg := newConfig(t, pki, be, sink)
	for _, o := range opts {
		o(&cfg)
	}
	s, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	h := &harness{t: t, srv: s, addr: ln.Addr().String(), ln: ln, pki: pki, be: be, sink: sink, serve: make(chan error, 1), cfg: cfg}
	go func() { h.serve <- s.Serve(ln) }()
	t.Cleanup(func() {
		_ = s.Close()
		select {
		case <-h.serve:
		case <-time.After(5 * time.Second):
			t.Error("Serve did not return after Close")
		}
	})
	return h
}

func (h *harness) clientTLS() *tls.Config {
	return &tls.Config{RootCAs: h.pki.Pool, ServerName: "localhost", MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"}}
}

// clientFrom returns an HTTP client dialling from the given loopback source address.
func (h *harness) clientFrom(src string, keepAlive bool) *http.Client {
	d := &net.Dialer{Timeout: 3 * time.Second}
	if src != "" {
		d.LocalAddr = &net.TCPAddr{IP: net.ParseIP(src)}
	}
	tr := &http.Transport{
		DialContext:         d.DialContext,
		TLSClientConfig:     h.clientTLS(),
		DisableKeepAlives:   !keepAlive,
		TLSHandshakeTimeout: 3 * time.Second,
		ForceAttemptHTTP2:   false,
	}
	h.t.Cleanup(tr.CloseIdleConnections)
	return &http.Client{Transport: tr, Timeout: 10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func (h *harness) client() *http.Client { return h.clientFrom("", false) }

type result struct {
	status int
	hdr    http.Header
	body   []byte
}

func (r result) errType() string {
	i := strings.Index(string(r.body), `"error_type":"`)
	if i < 0 {
		return ""
	}
	rest := string(r.body)[i+len(`"error_type":"`):]
	return rest[:strings.Index(rest, `"`)]
}

// do performs a request with the valid key unless hdr overrides Authorization.
func (h *harness) do(c *http.Client, method, path, body string, hdr map[string]string) result {
	h.t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, "https://"+h.addr+path, rd)
	if err != nil {
		h.t.Fatal(err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Authorization", "Bearer "+testKey)
	for k, v := range hdr {
		if v == "" {
			req.Header.Del(k)
		} else {
			req.Header.Set(k, v)
		}
	}
	resp, err := c.Do(req)
	if err != nil {
		h.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return result{resp.StatusCode, resp.Header, b}
}

// rawTCP opens a plain TCP connection from src ("" = default).
func (h *harness) rawTCP(src string) net.Conn {
	h.t.Helper()
	d := &net.Dialer{Timeout: 3 * time.Second}
	if src != "" {
		d.LocalAddr = &net.TCPAddr{IP: net.ParseIP(src)}
	}
	c, err := d.Dial("tcp", h.addr)
	if err != nil {
		h.t.Fatalf("dial: %v", err)
	}
	h.t.Cleanup(func() { c.Close() })
	return c
}

// expectShed dials from src to a server whose bound is exhausted and requires that the connection
// is refused immediately (never left hanging). The documented refusal is an abortive close (RST),
// which a client may observe either on connect() itself (the RST beat the dialer's readiness
// check - a legitimate race, not a failure) or as the first read; BOTH are the intended shedding.
// Anything else (data, a clean EOF after a handshake, or a hang until the deadline) is a failure.
func (h *harness) expectShed(src string) {
	h.t.Helper()
	d := &net.Dialer{Timeout: 3 * time.Second}
	if src != "" {
		d.LocalAddr = &net.TCPAddr{IP: net.ParseIP(src)}
	}
	start := time.Now()
	c, err := d.Dial("tcp", h.addr)
	if err != nil {
		if errors.Is(err, syscall.ECONNRESET) {
			return // shed during connect: the intended RST
		}
		h.t.Fatalf("dial: unexpected non-shedding error: %v", err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := c.Read(make([]byte, 1))
	var ne net.Error
	if err == nil || n != 0 || (errors.As(err, &ne) && ne.Timeout()) {
		h.t.Fatalf("connection must be shed (RST), got n=%d err=%v", n, err)
	}
	if !errors.Is(err, syscall.ECONNRESET) {
		h.t.Fatalf("shedding is an abortive close (ECONNRESET), got %v", err)
	}
	if d := time.Since(start); d > time.Second {
		h.t.Errorf("shedding took %v: it waited on the handshake timeout", d)
	}
}

func (h *harness) rawTLS() *tls.Conn {
	h.t.Helper()
	tc := tls.Client(h.rawTCP(""), h.clientTLS())
	_ = tc.SetDeadline(time.Now().Add(5 * time.Second))
	if err := tc.Handshake(); err != nil {
		h.t.Fatalf("handshake: %v", err)
	}
	return tc
}

// rawRequest writes a request on c and reads one response.
func rawRequest(t *testing.T, c net.Conn, br *bufio.Reader, wire string) (*http.Response, []byte, error) {
	t.Helper()
	_ = c.SetDeadline(time.Now().Add(4 * time.Second))
	if _, err := io.WriteString(c, wire); err != nil {
		return nil, nil, err
	}
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		return nil, nil, err
	}
	b, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	return resp, b, err
}

func postWire(path, key, body string) string {
	auth := ""
	if key != "" {
		auth = "Authorization: Bearer " + key + "\r\n"
	}
	return fmt.Sprintf("POST %s HTTP/1.1\r\nHost: localhost\r\n%sContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s", path, auth, len(body), body)
}

func getWire(path, key string) string {
	auth := ""
	if key != "" {
		auth = "Authorization: Bearer " + key + "\r\n"
	}
	return fmt.Sprintf("GET %s HTTP/1.1\r\nHost: localhost\r\n%s\r\n", path, auth)
}

// ---- internal (in-process) helpers ----

func mustNewForInternal(t *testing.T) *Server {
	t.Helper()
	cfg := newConfig(t, sharedPKI(t), newFakeBackend(), &capSink{})
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func serveRecorded(s *Server, r *http.Request) *httptest.ResponseRecorder {
	rr := httptest.NewRecorder()
	r.RemoteAddr = "192.0.2.1:1234"
	s.Handler().ServeHTTP(rr, r)
	return rr
}

var errBoom = errors.New("engine exploded: SECRET-ENGINE-TEXT")

func waitFor(t *testing.T, d time.Duration, what string, cond func() bool) {
	t.Helper()
	end := time.Now().Add(d)
	for !cond() {
		if time.Now().After(end) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// doBG fires a valid decision request from a goroutine and ignores every outcome (it may outlive the test).
func (h *harness) doBG() {
	req, err := http.NewRequest("POST", "https://"+h.addr+"/v1/systemone", strings.NewReader(sampleBody))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+testKey)
	c := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: h.clientTLS(), DisableKeepAlives: true}}
	if resp, err := c.Do(req); err == nil {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}
}

// noShedding lifts every connection bound far above what a test opens, for tests that are about
// something else than admission (early rejection, handshake timeouts, leaks).
func noShedding(l *Limits) {
	l.MaxConns, l.MaxConnsPerSource = 512, 512
	l.MaxUnauthConns, l.MaxUnauthPerSource, l.MaxUnauthPerAggregate = 512, 512, 512
}
