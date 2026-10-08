// Package server hosts the Gin based HTTPS decision gateway (spec FR-019, FR-022,
// FR-066..FR-073, FR-078, FR-079; contracts/openapi.yaml and endpoint-inventory.tsv).
//
// Architecture (one decision per bullet, each covered by a test):
//
//   - The LISTENING socket is plain TCP wrapped by a guard listener. Accept takes a global and a
//     per-source connection slot without blocking and resets the connection before any TLS work
//     when either bound is exhausted; admitted connections handshake lazily in their own
//     goroutine under HandshakeTimeout, so a hostile or silent peer never delays Accept.
//   - net/http's own ReadHeaderTimeout/ReadTimeout are the absolute per-request read deadline
//     (slow-drip headers and bodies are cut); once a request is fully read the deadline is
//     cleared so the end-to-end Timeout, not the read deadline, bounds the decision.
//   - Gin runs in release mode via gin.New() with no Logger and no Recovery middleware; the
//     server's own meta middleware does request ids, hygiene headers, panic recovery (a generic
//     500, never panic text), the audit record and the metrics observation.
//   - Authentication runs before routing: an unknown path is 404 and a wrong method 405 only for
//     an authenticated caller; /healthz and /readyz are the only unauthenticated paths.
//   - Failed authentications from a source are throttled (429) - the valid key never is.
//
// Request framing: a request body without Content-Length (chunked) is NOT refused with 411: it is
// read through a hard cap of MaxBody bytes and answered 413 when it exceeds it, so every client
// that can stream still works while memory stays bounded. A declared Content-Length above the cap
// is answered 413 before a single body byte is read, and the connection is closed. Oversize
// request lines / headers are answered 431 by net/http itself (the only response not built from
// the contract), and the connection is closed.
package server

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/internal/audit"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/metrics"
)

// NewEngine returns a Gin engine in release mode without the default logger,
// so request data is never written by framework middleware.
func NewEngine() *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	return gin.New()
}

// ModelInfo describes one served decision model for GET /v1/models.
type ModelInfo struct {
	ID          string
	Aliases     []string
	Protocol    string // letter-logit | systemone-native | nli-onnx
	Status      string // ready | starting | degraded | draining
	MaxOptions  int
	ScoreLevels [2]int // fewest, most score levels
	Notes       string
	// Description is the human-readable text of the SDK listing ("" = a generic one is derived).
	Description string
	// ReleaseDate is the model's release date as YYYY-MM-DD ("" or malformed = DefaultReleaseDate).
	// It is catalog data (decision.release_date), never stamped per request.
	ReleaseDate string
	// MaxStateChars / MaxContextTokens / MaxPairs are the effective per-request budgets of the
	// profile (0 = not advertised): the largest prose state in characters, the engine context a
	// prompt must fit in tokens, and the encoder's pair budget per request.
	MaxStateChars    int
	MaxContextTokens int
	MaxPairs         int
	// TemplateHash is the profile's decision.template_hash (64 lowercase hex, "" = not advertised):
	// the digest calibration profiles are bound to (gateway.TemplateHash).
	TemplateHash string
	// Calibration is set only when a calibration profile file exists for the model: whether the
	// gateway applies it, or the closed reason code it does not.
	Calibration *CalibrationInfo
	// Maturity is the per-type maturity of the profile (key = question type noul|choice|score), derived from the
	// golden-run evidence (scripts/maturity_from_golden.py, OD-24); nil = the catalog carries none and nothing is
	// published.  Published on GET /v1/models as `maturity` plus `experimental_types`.
	Maturity map[string]MaturityInfo
}

// MaturityInfo is one type's maturity: "measured" (the Wilson lower bound clears the baseline), "experimental" (it
// does not) or "unmeasured" (no live golden run yet; shown as experimental, reason "not yet measured").
type MaturityInfo struct {
	Status     string
	LowerBound *float64
	Baseline   *float64
	N          int
	Reason     string
}

// Experimental reports whether answers of this type are labelled experimental (anything but measured).
func (m MaturityInfo) Experimental() bool { return m.Status == "experimental" || m.Status == "unmeasured" }

// MaturityReporter is implemented by a Backend that labels answers: Maturity returns "experimental" for a
// question type the profile has not measured above its baseline, "" otherwise (the answer is then unchanged).
type MaturityReporter interface {
	Maturity(profile, qtype string) string
}

// CalibrationInfo reports the state of a model's calibration profile on GET /v1/models.
type CalibrationInfo struct {
	Applied   bool
	Method    string // temperature | platt | isotonic (applied only)
	N         int    // labelled answers the profile was fitted on (applied only)
	ProfileID string // the calibration profile name (applied only)
	// Reason is the closed refusal code of a profile that is NOT applied: mismatch (another model
	// file or prompt template/readout), unbound, invalid, insecure or model_unresolved.
	Reason string
}

// DecisionMeta is what the decision log records about the model that answered: the checksum of the
// model file, the prompt-template hash and the calibration profile applied ("" = none).
type DecisionMeta struct {
	ModelSHA256        string
	TemplateHash       string
	CalibrationProfile string
}

// DecisionMetaProvider is implemented by a Backend that can describe a profile for the decision log.
type DecisionMetaProvider interface {
	DecisionMeta(profile string) DecisionMeta
}

// ModeReporter is implemented by a Backend that serves in a named mode (deterministic|throughput);
// the gateway answers every decision with x-llmctl-decide-mode: <mode>.
type ModeReporter interface{ Mode() string }

// DefaultReleaseDate is the release date reported for a model whose catalog entry pins none: the
// publication date of the decision-model contract (specs/009-jev-decision-models) this gateway
// implements. It is a fixed documented value so the listing is stable across requests and restarts.
const DefaultReleaseDate = "2026-10-07"

type truncKey struct{}

// truncNote records, per request, that the backend truncated the caller's state to fit the model.
type truncNote struct{ hit atomic.Bool }

// WithTruncationNote returns a context a Backend can report truncation on and a function that
// tells whether it did. The gateway uses it internally; it is exported so that drivers and their
// tests can observe NoteTruncated without a running server.
func WithTruncationNote(ctx context.Context) (context.Context, func() bool) {
	n := &truncNote{}
	return context.WithValue(ctx, truncKey{}, n), n.hit.Load
}

// NoteTruncated lets a Backend report from inside Decide that it truncated the request's state
// (opt-in truncation): the gateway then answers with x-llmctl-decide-truncated: true. It is a
// no-op when ctx did not come from the gateway.
func NoteTruncated(ctx context.Context) {
	if n, ok := ctx.Value(truncKey{}).(*truncNote); ok {
		n.hit.Store(true)
	}
}

// Backend is what the gateway delegates business logic to.
type Backend interface {
	// Decide answers a validated request. Return a *contract.ContractError (for example
	// contract.ReadoutFailedError or a 503 from contract.TransportError) to choose the status;
	// any other error is reported as a generic 502. ctx carries the end-to-end deadline.
	Decide(ctx context.Context, req *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error)
	// Models lists the served models.
	Models() []ModelInfo
	// Ready reports whether at least one decision instance is ready.
	Ready() bool
}

// DecisionWriter receives one rendered decision-log line (*audit.Sink implements it).
type DecisionWriter interface{ WriteLine(string) error }

// AuditWriter receives one sanitised record per request (*audit.Sink implements it).
type AuditWriter interface{ Write(audit.Record) error }

// Config assembles a Server.
type Config struct {
	Backend Backend
	Limits  Limits // zero value = DefaultLimits()
	// TLS carries the certificate source (Certificates or GetCertificate - the latter is the
	// hot-reload seam). New clones it and enforces TLS >= 1.2, ALPN http/1.1 and no tickets.
	TLS *tls.Config
	// Keys returns the currently accepted keys on every request (rotation needs no restart).
	Keys func() []keyring.Secret
	// AcceptXAPIKey additionally accepts the key in an X-API-Key header (openapi apiKeyAuth
	// alias). Off by default; the key is never read from the query string.
	AcceptXAPIKey bool

	Profiles       *contract.Profiles // served profile ids for request validation
	ContractLimits contract.Limits    // zero value = contract.DefaultLimits()

	Audit AuditWriter // nil = no request log
	// Decisions receives one JSON line per decision (FR-080 opt-in decision log; nil = off). The
	// lines come from audit.NewDecisionRecord/DecisionLine, so they carry text only when
	// DecisionState is true (LLMCTL_DECIDE_LOG_STATE=1, the operator's consent).
	Decisions     DecisionWriter
	DecisionState bool
	LogKey        []byte            // per-installation HMAC key for state hashes (>= 16 bytes); nil = no hash
	Metrics       *metrics.Registry // nil = a fresh registry
	// Stderr receives the one-time operator diagnostics of the server itself (the first request-log
	// write failure); nil = os.Stderr. Nothing secret is ever written to it.
	Stderr io.Writer
}

// Server is the HTTPS decision gateway.
type Server struct {
	cfg         Config
	lim         Limits
	engine      *gin.Engine
	http        *http.Server
	tlsCfg      *tls.Config
	slots       *slotTable
	throttle    *authThrottle
	metrics     *metrics.Registry
	sem         chan struct{}
	waiting     atomic.Int32
	draining    atomic.Bool
	shed        atomic.Int64
	auditErr    sync.Once
	decisionErr sync.Once

	fresh   sync.Mutex
	pending map[net.Conn]time.Time // accepted connections that have not started a request yet

	// keyMatch is the constant-time comparison; tests pin that it is keyring.KeyMatches.
	keyMatch func(candidate string, accepted []keyring.Secret) bool
	now      func() time.Time
	// sleep pauses for d or until ctx ends; tests replace it to observe the progressive failure delay.
	sleep func(ctx context.Context, d time.Duration)
}

// New validates cfg and builds the server. Nothing listens until Serve.
func New(cfg Config) (*Server, error) {
	if cfg.Limits == (Limits{}) {
		cfg.Limits = DefaultLimits()
	}
	if err := cfg.Limits.Validate(); err != nil {
		return nil, err
	}
	switch {
	case cfg.Backend == nil:
		return nil, errors.New("server: Config.Backend is required")
	case cfg.Keys == nil:
		return nil, errors.New("server: Config.Keys is required")
	case cfg.Profiles == nil:
		return nil, errors.New("server: Config.Profiles is required")
	case cfg.TLS == nil || (len(cfg.TLS.Certificates) == 0 && cfg.TLS.GetCertificate == nil && cfg.TLS.GetConfigForClient == nil):
		return nil, errors.New("server: Config.TLS needs a certificate source")
	}
	if cfg.ContractLimits == (contract.Limits{}) {
		cfg.ContractLimits = contract.DefaultLimits()
	}
	if err := cfg.ContractLimits.Validate(); err != nil {
		return nil, err
	}
	if cfg.Metrics == nil {
		cfg.Metrics = metrics.New(cfg.Profiles.IDs()...)
	}
	s := &Server{
		cfg: cfg, lim: cfg.Limits, metrics: cfg.Metrics, keyMatch: keyring.KeyMatches, now: time.Now, sleep: sleepCtx,
		slots: newSlotTable(cfg.Limits.MaxConns, cfg.Limits.MaxConnsPerSource).
			withUnauth(cfg.Limits.MaxUnauthConns, cfg.Limits.MaxUnauthPerSource, cfg.Limits.MaxUnauthPerAggregate),
		sem: make(chan struct{}, cfg.Limits.Concurrency),

		pending: map[net.Conn]time.Time{},
	}
	s.throttle = newAuthThrottle(cfg.Limits.AuthFailLimit, cfg.Limits.AuthFailWindow, 4096, func() time.Time { return s.now() })

	t := hardenTLS(cfg.TLS.Clone())
	if inner := cfg.TLS.GetConfigForClient; inner != nil {
		// The config a callback returns REPLACES the base config for that connection, so the floor
		// must be re-applied to what it returns (a nil result falls back to the hardened base).
		t.GetConfigForClient = func(h *tls.ClientHelloInfo) (*tls.Config, error) {
			c, err := inner(h)
			if c == nil || err != nil {
				return nil, err
			}
			return hardenTLS(c.Clone()), nil
		}
	}
	s.tlsCfg = t

	s.engine = s.buildEngine()
	s.http = &http.Server{
		Handler:           s.Handler(),
		ReadHeaderTimeout: s.lim.ReadDeadline,
		ReadTimeout:       s.lim.ReadDeadline,
		WriteTimeout:      s.lim.Timeout + 5*time.Second,
		IdleTimeout:       s.lim.IdleTimeout,
		MaxHeaderBytes:    s.lim.MaxHeaderBytes,
		ErrorLog:          log.New(io.Discard, "", 0), // net/http error text can carry peer data
		ConnState: func(c net.Conn, st http.ConnState) {
			s.fresh.Lock()
			defer s.fresh.Unlock()
			if st == http.StateNew {
				s.pending[c] = time.Now()
			} else {
				delete(s.pending, c)
			}
		},
		ConnContext: func(ctx context.Context, c net.Conn) context.Context {
			return context.WithValue(ctx, connKey{}, c)
		},
	}
	return s, nil
}

// hardenTLS enforces the transport floor on c: TLS >= 1.2, ALPN http/1.1 only, no session tickets.
func hardenTLS(c *tls.Config) *tls.Config {
	if c.MinVersion < tls.VersionTLS12 {
		c.MinVersion = tls.VersionTLS12
	}
	c.NextProtos = []string{"http/1.1"}
	c.SessionTicketsDisabled = true
	return c
}

func (s *Server) tlsConfig() *tls.Config { return s.tlsCfg }

// Handler is the full request pipeline (usable with httptest; no TLS involved).
func (s *Server) Handler() http.Handler { return s.engine }

// Serve serves on l (a plain TCP listener; TLS is applied per connection after slot
// acquisition) until Drain or Close; it then returns http.ErrServerClosed.
func (s *Server) Serve(l net.Listener) error {
	return s.http.Serve(&guardListener{Listener: l, slots: s.slots, cfg: s.tlsCfg, hs: s.lim.HandshakeTimeout,
		preAuth: s.lim.PreAuthTimeout, shed: &s.shed})
}

// ListenAndServe listens on addr (TCP) and serves.
func (s *Server) ListenAndServe(addr string) error {
	l, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	return s.Serve(l)
}

// Drain stops the gateway gracefully: readiness flips to not-ready first (and new work is
// answered 503), the listener closes, and in-flight requests complete within DrainGrace or ctx,
// whichever ends first; remaining connections are then closed and the deadline error returned.
func (s *Server) Drain(ctx context.Context) error {
	s.draining.Store(true)
	gctx, cancel := context.WithTimeout(ctx, s.lim.DrainGrace)
	defer cancel()
	stop := make(chan struct{})
	defer close(stop)
	go s.closeStalePending(stop)
	err := s.http.Shutdown(gctx)
	if err != nil {
		_ = s.http.Close()
	}
	return err
}

// closeStalePending closes connections that were accepted but never began a request while a drain
// is running: net/http would otherwise treat them as active for several seconds. A connection that
// is genuinely mid-handshake or mid-first-request moves to active within the short grace below.
func (s *Server) closeStalePending(stop <-chan struct{}) {
	t := time.NewTicker(50 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
		}
		var stale []net.Conn
		s.fresh.Lock()
		for c, since := range s.pending {
			if time.Since(since) > 250*time.Millisecond {
				stale = append(stale, c)
			}
		}
		s.fresh.Unlock()
		for _, c := range stale {
			_ = c.Close()
		}
	}
}

// Close stops immediately.
func (s *Server) Close() error {
	s.draining.Store(true)
	return s.http.Close()
}

// Draining reports whether Drain or Close was called.
func (s *Server) Draining() bool { return s.draining.Load() }

// Shed counts connections refused at Accept because a connection bound was exhausted.
func (s *Server) Shed() int64 { return s.shed.Load() }

// ConnsInUse is the number of connection slots currently held.
func (s *Server) ConnsInUse() int { return s.slots.inUse() }

// QueueDepth is the number of requests currently waiting for a decision slot.
func (s *Server) QueueDepth() int {
	if n := int(s.waiting.Load()); n > 0 {
		return n
	}
	return 0
}

func (s *Server) ready() bool { return !s.draining.Load() && s.cfg.Backend.Ready() }

func sleepCtx(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
	case <-ctx.Done():
	}
}
