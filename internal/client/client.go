package client

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/keyring"
)

// Defaults.
const (
	DefaultRetries = 2
	DefaultTimeout = 30 * time.Second
	// MaxRetryDelay bounds how long one Retry-After may stall the client.
	MaxRetryDelay = 10 * time.Second
	// MaxResponseBytes bounds what is read from a response body.
	MaxResponseBytes = 16 << 20
	maxRetriesCap    = 10
)

// Config configures a Client. There is intentionally no field that relaxes certificate checks.
type Config struct {
	Endpoint string         // https://host:port (no path)
	CAFile   string         // PEM file with the CA(s) to trust; the only trust anchor
	Key      keyring.Secret // sent as Authorization: Bearer
	Retries  int            // extra attempts after 429/503/529; clamped to 0..10
	Timeout  time.Duration  // per attempt; 0 = DefaultTimeout
	// Sleep waits between attempts (tests inject a fake); nil = a real, context-aware sleep.
	Sleep func(ctx context.Context, d time.Duration) error
}

// Client talks to one gateway.
type Client struct {
	base    *url.URL
	hc      *http.Client
	key     keyring.Secret
	retries int
	timeout time.Duration
	sleep   func(ctx context.Context, d time.Duration) error
}

// Result is a successful response.
type Result struct {
	Body      []byte        // the gateway's JSON body, byte for byte
	Latency   time.Duration // wall time of the successful attempt, retries excluded
	Truncated bool          // x-llmctl-decide-truncated: true
	Port      int           // port of the endpoint
	Mode      string        // x-llmctl-decide-mode: deterministic | throughput ("" = not reported)
	Instance  string        // x-llmctl-decide-instance: the engine instance that answered ("" = not reported)
}

// LoadCA reads a PEM CA bundle; any problem is a TLS-kind error (exit 5).
func LoadCA(path string) (*x509.CertPool, error) {
	if path == "" {
		return nil, errf(KindTLS, "no CA certificate configured; set LLMCTL_CACERT or run `llmctl cert ensure`")
	}
	pem, err := os.ReadFile(path)
	if err != nil {
		return nil, errf(KindTLS, "cannot read the CA certificate "+path+" ("+shortOSError(err)+"); run `llmctl cert ensure` on the gateway host and `llmctl cert export` to copy it here, or set LLMCTL_CACERT")
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, errf(KindTLS, "the CA certificate "+path+" contains no valid PEM certificate")
	}
	return pool, nil
}

func shortOSError(err error) string {
	if os.IsNotExist(err) {
		return "no such file"
	}
	if os.IsPermission(err) {
		return "permission denied"
	}
	return "unreadable"
}

// ParseEndpoint validates an endpoint URL: https only, a host, no credentials, no path/query.
func ParseEndpoint(raw string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return nil, errf(KindUsage, "invalid endpoint URL (want https://host:port)")
	}
	if u.Scheme != "https" {
		return nil, errf(KindUsage, "the endpoint must be an https:// URL; llmctl never talks to the gateway in clear text")
	}
	if u.User != nil {
		return nil, errf(KindUsage, "the endpoint URL must not carry credentials")
	}
	if (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return nil, errf(KindUsage, "the endpoint must be a bare base URL (https://host:port)")
	}
	u.Path = ""
	return u, nil
}

// New builds a Client. It loads the CA but does not touch the network.
func New(cfg Config) (*Client, error) {
	base, err := ParseEndpoint(cfg.Endpoint)
	if err != nil {
		return nil, err
	}
	pool, err := LoadCA(cfg.CAFile)
	if err != nil {
		return nil, err
	}
	if cfg.Key.Reveal() == "" {
		return nil, errf(KindKey, "no access key available")
	}
	retries := cfg.Retries
	switch {
	case retries < 0:
		retries = 0
	case retries > maxRetriesCap:
		retries = maxRetriesCap
	}
	timeout := cfg.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	tr := &http.Transport{
		Proxy:               nil, // never route the key through an environment proxy
		DialContext:         (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		TLSClientConfig:     &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 10 * time.Second,
		DisableKeepAlives:   true,
	}
	c := &Client{
		base: base,
		hc: &http.Client{
			Transport:     tr,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		key: cfg.Key, retries: retries, timeout: timeout, sleep: cfg.Sleep,
	}
	if c.sleep == nil {
		c.sleep = realSleep
	}
	return c, nil
}

func realSleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// Port returns the endpoint's port (443 when the URL names none).
func (c *Client) Port() int {
	if p, err := strconv.Atoi(c.base.Port()); err == nil {
		return p
	}
	return 443
}

// Ask POSTs a /v1/systemone request body.
func (c *Client) Ask(ctx context.Context, body []byte) (*Result, error) {
	return c.do(ctx, http.MethodPost, "/v1/systemone", body, true)
}

// Models fetches GET /v1/models (authenticated).
func (c *Client) Models(ctx context.Context) (*Result, error) {
	return c.do(ctx, http.MethodGet, "/v1/models", nil, true)
}

// Ready probes GET /readyz (unauthenticated; the key is not sent).
func (c *Client) Ready(ctx context.Context) error {
	_, err := c.do(ctx, http.MethodGet, "/readyz", nil, false)
	return err
}

func retryable(status int) bool { return status == 429 || status == 503 || status == 529 }

func (c *Client) do(ctx context.Context, method, path string, body []byte, auth bool) (*Result, error) {
	var last *Error
	for attempt := 0; ; attempt++ {
		res, status, hdr, err := c.once(ctx, method, path, body, auth)
		if err == nil {
			return res, nil
		}
		last = err
		if !retryable(status) || attempt >= c.retries {
			return nil, last
		}
		if serr := c.sleep(ctx, retryDelay(hdr, attempt)); serr != nil {
			return nil, last
		}
	}
}

// retryDelay honours Retry-After (seconds or an HTTP date), bounded; absent, a small backoff.
func retryDelay(h http.Header, attempt int) time.Duration {
	d := 250 * time.Millisecond << uint(attempt)
	if v := strings.TrimSpace(h.Get("Retry-After")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			d = time.Duration(n) * time.Second
		} else if t, err := http.ParseTime(v); err == nil {
			d = time.Until(t)
		}
	}
	if d < 0 {
		d = 0
	}
	if d > MaxRetryDelay {
		d = MaxRetryDelay
	}
	return d
}

func (c *Client) once(ctx context.Context, method, path string, body []byte, auth bool) (*Result, int, http.Header, *Error) {
	actx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	u := *c.base
	u.Path = path
	var rd io.Reader
	if body != nil {
		rd = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(actx, method, u.String(), rd)
	if err != nil {
		return nil, 0, nil, errf(KindUsage, "cannot build the request")
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if auth {
		req.Header.Set("Authorization", "Bearer "+c.key.Reveal())
	}
	start := time.Now()
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, 0, nil, c.redact(classifyTransport(err))
	}
	defer resp.Body.Close()
	raw, rerr := io.ReadAll(io.LimitReader(resp.Body, MaxResponseBytes+1))
	lat := time.Since(start)
	if rerr != nil {
		return nil, resp.StatusCode, resp.Header, c.redact(classifyTransport(rerr))
	}
	if len(raw) > MaxResponseBytes {
		return nil, resp.StatusCode, resp.Header, errf(KindBackend, "the gateway response is larger than the client accepts")
	}
	if resp.StatusCode == http.StatusOK {
		if !json.Valid(raw) {
			return nil, resp.StatusCode, resp.Header, errf(KindBackend, "the gateway answered 200 with a body that is not JSON")
		}
		return &Result{Body: raw, Latency: lat, Truncated: resp.Header.Get("x-llmctl-decide-truncated") == "true", Port: c.Port(),
			Mode: cleanMode(resp.Header.Get("x-llmctl-decide-mode")), Instance: cleanInstance(resp.Header.Get("x-llmctl-decide-instance"))}, 200, resp.Header, nil
	}
	return nil, resp.StatusCode, resp.Header, c.redact(statusError(resp.StatusCode, raw))
}

// redact removes the key from an error message (defence in depth: nothing we print is expected
// to contain it, but a hostile server could echo it).
func (c *Client) redact(e *Error) *Error {
	if k := c.key.Reveal(); k != "" && strings.Contains(e.Msg, k) {
		e.Msg = strings.ReplaceAll(e.Msg, k, "<redacted>")
	}
	return e
}

// statusError classifies a non-200 response. Only the contract's closed error_type set and a
// bounded, printable message are used; a raw body is never echoed.
func statusError(status int, raw []byte) *Error {
	var eb contract.ErrorBody
	_ = json.Unmarshal(raw, &eb)
	known := false
	for _, t := range contract.ErrorTypes {
		if t == eb.ErrorType {
			known = true
		}
	}
	et := ""
	if known {
		et = eb.ErrorType
	}
	detail := "HTTP " + strconv.Itoa(status)
	if et != "" {
		detail += " " + et
	}
	if m := sanitizeMessage(eb.Message); m != "" && known {
		detail += ": " + m
	}
	mk := func(k Kind, msg string) *Error { return &Error{Kind: k, Msg: msg, Status: status, ErrorType: et} }
	switch {
	case et == contract.ErrTypeReadoutFailed:
		return mk(KindBackend, "the model produced no usable answer ("+detail+")")
	case status == 401 || status == 403:
		return mk(KindKey, "the gateway rejected the access key ("+detail+"); check LLMCTL_API_KEY (`llmctl key doctor`) - it must be the key the gateway runs with")
	case status == 503 || et == contract.ErrTypeNotReady:
		return mk(KindUnreachable, "no decision instance is ready ("+detail+"); start one with `llmctl start <profile>` and check `llmctl decide status`")
	case status == 400 || status == 413 || status == 422:
		return mk(KindUsage, "the gateway refused the request ("+detail+")")
	case status == 429:
		return mk(KindBackend, "the gateway is rate limiting this client ("+detail+")")
	case status == 529:
		return mk(KindBackend, "the gateway is overloaded ("+detail+")")
	}
	return mk(KindBackend, "unexpected response from the gateway ("+detail+")")
}

// cleanInstance accepts only a short [A-Za-z0-9._-] label (what the gateway reports, contract.SafeInstanceLabel); anything else is not echoed.
func cleanInstance(v string) string {
	if v == "" || len(v) > 64 {
		return ""
	}
	for _, r := range v {
		if !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') && !(r >= '0' && r <= '9') && r != '.' && r != '-' && r != '_' {
			return ""
		}
	}
	return v
}

// cleanMode accepts only the two documented mode values; anything else is not echoed.
func cleanMode(v string) string {
	if v == "deterministic" || v == "throughput" {
		return v
	}
	return ""
}

// sanitizeMessage makes a gateway-supplied message safe for a terminal: every control character
// (C0, DEL, C1 including the 8-bit CSI U+009B), line separator and bidirectional/format character
// becomes a space.
func sanitizeMessage(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || r == 0x2028 || r == 0x2029 {
			r = ' '
		}
		b.WriteRune(r)
		if b.Len() >= 160 {
			break
		}
	}
	return strings.TrimSpace(b.String())
}
