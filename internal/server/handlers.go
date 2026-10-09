package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/internal/audit"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/keyring"
	"github.com/vasic-digital/llmctl/internal/metrics"
)

type connKey struct{}

// Gin context keys.
const (
	ckRID     = "llmctl.rid"
	ckAuth    = "llmctl.auth"
	ckProfile = "llmctl.profile"
	ckHash    = "llmctl.statehash"
	ckQTypes  = "llmctl.qtypes"
	ckDecReq  = "llmctl.decision.request"
	ckDecAns  = "llmctl.decision.answers"
)

const jsonCT = "application/json; charset=utf-8"

var ridPattern = regexp.MustCompile(`^[0-9a-f]{16}$`)

// allowed methods per path (everything else answers 405 after authentication).
var allowedMethod = map[string]string{
	"/v1/systemone": http.MethodPost,
	"/v1/models":    http.MethodGet,
	"/healthz":      http.MethodGet,
	"/readyz":       http.MethodGet,
	"/metrics":      http.MethodGet,
}

// probe paths are the ONLY unauthenticated paths.
func isProbe(path string) bool { return path == "/healthz" || path == "/readyz" }

func (s *Server) buildEngine() *gin.Engine {
	e := NewEngine()
	e.HandleMethodNotAllowed = true
	e.RedirectTrailingSlash = false
	e.RedirectFixedPath = false
	e.RemoveExtraSlash = false
	e.UseRawPath = false
	e.ForwardedByClientIP = false
	_ = e.SetTrustedProxies(nil)

	// Order matters: meta (ids, headers, recovery, audit, metrics) -> auth -> routing.
	// Global middleware also wraps NoRoute/NoMethod, which is what makes 404/405 post-auth.
	e.Use(s.metaMiddleware, s.authMiddleware)
	e.NoRoute(func(c *gin.Context) { s.fail(c, mustTransport(404, contract.TransportOptions{})) })
	e.NoMethod(func(c *gin.Context) {
		allow := allowedMethod[c.Request.URL.Path]
		if allow == "" {
			allow = "GET, POST"
		}
		s.fail(c, mustTransport(405, contract.TransportOptions{Allow: allow}))
	})

	e.POST("/v1/systemone", s.handleSystemOne)
	e.GET("/v1/models", s.handleModels)
	e.GET("/healthz", s.handleHealthz)
	e.GET("/readyz", s.handleReadyz)
	e.GET("/metrics", s.handleMetrics)
	return e
}

func mustTransport(status int, o contract.TransportOptions) *contract.ContractError {
	ce, err := contract.TransportError(status, o)
	if err != nil {
		panic("server: transport error table out of sync: " + err.Error())
	}
	return ce
}

// ---------------------------------------------------------------- meta (ids, headers, audit)

func newRID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("server: no entropy for request id")
	}
	return hex.EncodeToString(b[:])
}

func (s *Server) metaMiddleware(c *gin.Context) {
	start := time.Now()
	rid := c.GetHeader("x-request-id")
	if !ridPattern.MatchString(rid) { // client ids are echoed only when already in our exact shape
		rid = newRID()
	}
	c.Set(ckRID, rid)
	c.Set(ckAuth, "none")
	h := c.Writer.Header()
	h.Set("x-request-id", rid)
	h.Set("x-llmctl-request-id", rid)
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	if s.draining.Load() {
		h.Set("Connection", "close")
	}
	defer func() {
		if rec := recover(); rec != nil {
			if rec == http.ErrAbortHandler {
				panic(rec)
			}
			// Generic 500: nothing about the panic (value, stack) is written anywhere.
			if !c.Writer.Written() {
				h.Set("Connection", "close")
				c.AbortWithStatusJSON(http.StatusInternalServerError, contract.ErrorBody{
					Message: "Internal error.", ErrorType: contract.ErrTypeBackendFailed})
			} else {
				panic(http.ErrAbortHandler) // half-written response: drop the connection quietly
			}
		}
		s.finish(c, time.Since(start))
		s.lingerDrain(c)
	}()
	c.Next()
}

// Lingering close (G-037). A response that tells the client "Connection: close" while the request
// body is still unread (an early 413/400/503) would normally be followed by net/http closing a
// socket that holds unread request bytes; the kernel then answers the client's remaining upload
// with an RST that can destroy the response before the client reads it (the client sees EPIPE /
// ECONNRESET instead of the status). So the response is flushed first and a BOUNDED amount of the
// body is drained - at most lingerMaxBytes, for at most lingerWindow - before the connection
// closes. The bounds keep a hostile uploader from pinning the slot or the CPU: beyond them the
// abortive close is accepted as the documented outcome.
const (
	lingerMaxBytes = 1 << 20
	lingerWindow   = time.Second
)

func (s *Server) lingerDrain(c *gin.Context) {
	r := c.Request
	if r.Body == nil || r.Body == http.NoBody || r.ContentLength == 0 {
		return
	}
	if !strings.EqualFold(c.Writer.Header().Get("Connection"), "close") {
		return // keep-alive responses are drained (bounded) by net/http itself
	}
	c.Writer.Flush()
	_ = http.NewResponseController(c.Writer).SetReadDeadline(time.Now().Add(lingerWindow))
	_, _ = io.Copy(io.Discard, io.LimitReader(r.Body, lingerMaxBytes))
}

func (s *Server) finish(c *gin.Context, d time.Duration) {
	status := c.Writer.Status()
	profile := c.GetString(ckProfile)
	s.metrics.Observe(c.Request.URL.Path, profile, status, "", d.Seconds())
	if qt, ok := c.Get(ckQTypes); ok {
		for _, t := range qt.([]string) {
			s.metrics.ObserveQuestion(profile, t)
		}
	}
	s.logDecision(c, status, d)
	if s.cfg.Audit == nil {
		return
	}
	size := c.Writer.Size()
	if size < 0 {
		size = 0
	}
	f := audit.Fields{
		RequestID: c.GetString(ckRID), Method: c.Request.Method, Path: c.Request.URL.Path,
		Status: status, Millis: float64(d) / float64(time.Millisecond), Bytes: int64(size),
		AuthResult: c.GetString(ckAuth), ClientIP: clientIPText(c.Request.RemoteAddr),
	}
	if profile != "" {
		f.Profile = audit.Str(profile)
	}
	if h := c.GetString(ckHash); h != "" {
		f.StateHash = audit.Str(h)
	}
	if sc, ok := c.Request.Context().Value(connKey{}).(*srvConn); ok {
		f.TLSVersion = sc.tlsVersion()
	}
	if err := s.cfg.Audit.Write(audit.NewRecord(f)); err != nil {
		// The request is not failed by it, but the FR-079 log silently stopping is an operator-visible
		// fault: count every failure, report the first on stderr (the error text carries no secret).
		s.metrics.Inc(metrics.AuditWriteFailure)
		s.auditErr.Do(func() {
			w := s.cfg.Stderr
			if w == nil {
				w = os.Stderr
			}
			fmt.Fprintf(w, "llmctl serve: request log write failed: %v (further failures are only counted in llmctl_decide_audit_write_failures_total)\n", err)
		})
	}
}

// ---------------------------------------------------------------- authentication

func (s *Server) credential(r *http.Request) (token string, present bool) {
	if vs := r.Header.Values("Authorization"); len(vs) > 0 {
		if len(vs) != 1 {
			return "", true // several Authorization headers: ambiguous, never a valid credential
		}
		scheme, tok, ok := strings.Cut(vs[0], " ")
		if !ok || !strings.EqualFold(scheme, "Bearer") || tok == "" || strings.ContainsAny(tok, " \t") {
			return "", true
		}
		return tok, true
	}
	if s.cfg.AcceptXAPIKey {
		if vs := r.Header.Values("X-API-Key"); len(vs) == 1 && vs[0] != "" {
			return vs[0], true
		}
	}
	return "", false
}

// maxCredentialBytes equals the longest key the keyring accepts, so the length gate below can never
// refuse a valid key and reveals nothing about the accepted keys' lengths (review A-07).
const maxCredentialBytes = keyring.MaxKeyLen

func (s *Server) authMiddleware(c *gin.Context) {
	if isProbe(c.Request.URL.Path) {
		return // liveness/readiness: no credentials, minimal bodies
	}
	tok, present := s.credential(c.Request)
	if present && tok != "" && len(tok) <= maxCredentialBytes {
		if keys := s.cfg.Keys(); len(keys) > 0 && s.keyMatch(tok, keys) {
			c.Set(ckAuth, "ok")
			if sc, ok := c.Request.Context().Value(connKey{}).(*srvConn); ok {
				sc.markAuthed() // leaves the unauthenticated pool: it can no longer be evicted or reaped
			}
			return // the valid key is NEVER throttled: this branch never touches the throttle
		}
	}
	result := "missing"
	if present {
		result = "wrong"
	}
	throttled, retry, n := s.throttle.fail(sourceKey(remoteAddr(c.Request)))
	if d := failDelay(n); d > 0 {
		s.sleep(c.Request.Context(), d) // progressive: slows guessing, never touches the valid key
	}
	if throttled {
		c.Set(ckAuth, "throttled")
		s.fail(c, mustTransport(429, contract.TransportOptions{RetryAfter: &retry}))
		return
	}
	c.Set(ckAuth, result)
	s.fail(c, mustTransport(401, contract.TransportOptions{}))
}

type addrString string

func (a addrString) Network() string { return "tcp" }
func (a addrString) String() string  { return string(a) }

func remoteAddr(r *http.Request) addrString { return addrString(r.RemoteAddr) }

// ---------------------------------------------------------------- error / response writers

func (s *Server) fail(c *gin.Context, ce *contract.ContractError) {
	for k, v := range ce.Headers {
		c.Writer.Header().Set(k, v)
	}
	c.AbortWithStatusJSON(ce.Status, ce.Body())
}

// markBackend502 adds the additive reason headers to a backend 502 (contracts/openapi.yaml): the
// gateway's own end-to-end budget LLMCTL_DECIDE_TIMEOUT expiring on a slow-but-alive engine is
// "deadline_exceeded" (+ the budget in ms) - a client must not retry it as if the engine had failed,
// a retry cancels the engine task and redoes the whole prefill; anything else is "engine_error".
// A caller that went away (parent context done) is not the gateway's deadline.
func (s *Server) markBackend502(c *gin.Context, reqCtx, parent context.Context) {
	h := c.Writer.Header()
	if errors.Is(reqCtx.Err(), context.DeadlineExceeded) && parent.Err() == nil {
		h.Set("x-llmctl-decide-reason", "deadline_exceeded")
		h.Set("x-llmctl-decide-deadline-ms", strconv.FormatInt(s.lim.Timeout.Milliseconds(), 10))
		return
	}
	h.Set("x-llmctl-decide-reason", "engine_error")
}

// failClose answers like fail and closes the connection (used when the request body was not
// consumed, so the stream could not be re-framed safely).
func (s *Server) failClose(c *gin.Context, ce *contract.ContractError) {
	c.Writer.Header().Set("Connection", "close")
	s.fail(c, ce)
}

func asContractError(err error) *contract.ContractError {
	var ce *contract.ContractError
	if errors.As(err, &ce) {
		return ce
	}
	return nil
}

// requestRead ends the absolute read deadline once the request has been fully read, so a decision
// that legitimately takes longer than the read deadline is bounded by Timeout instead.
func requestRead(c *gin.Context) {
	_ = http.NewResponseController(c.Writer).SetReadDeadline(time.Time{})
}

// ---------------------------------------------------------------- handlers

func (s *Server) handleHealthz(c *gin.Context) {
	if c.Request.ContentLength == 0 {
		requestRead(c)
	}
	c.Data(http.StatusOK, jsonCT, []byte(`{"status":"ok"}`))
}

func (s *Server) handleReadyz(c *gin.Context) {
	if c.Request.ContentLength == 0 {
		requestRead(c)
	}
	if !s.ready() {
		c.Writer.Header().Set("Retry-After", "1")
		c.Data(http.StatusServiceUnavailable, jsonCT, []byte(`{"status":"not_ready"}`))
		return
	}
	c.Data(http.StatusOK, jsonCT, []byte(`{"status":"ready"}`))
}

func (s *Server) handleMetrics(c *gin.Context) {
	if c.Request.ContentLength == 0 {
		requestRead(c)
	}
	c.Data(http.StatusOK, metrics.ContentType, s.metrics.Render())
}

type modelView struct {
	ID           string           `json:"id"`
	Aliases      []string         `json:"aliases"`
	Protocol     string           `json:"protocol"`
	Status       string           `json:"status"`
	Limits       limitsView       `json:"limits"`
	Notes        string           `json:"notes,omitempty"`
	TemplateHash string           `json:"template_hash,omitempty"`
	Calibration  *calibrationView `json:"calibration,omitempty"`
	// Maturity / ExperimentalTypes (T138, OD-24): per question type, measured|experimental|unmeasured with the
	// numbers behind it; ExperimentalTypes lists every type that is not measured, in type order.
	Maturity          map[string]maturityView `json:"maturity,omitempty"`
	ExperimentalTypes []string                `json:"experimental_types,omitempty"`
}

type maturityView struct {
	Status     string   `json:"status"`
	LowerBound *float64 `json:"lower_bound,omitempty"`
	Baseline   *float64 `json:"baseline,omitempty"`
	N          *int     `json:"n,omitempty"`
	Reason     string   `json:"reason,omitempty"`
}

// maturityOf renders a model's maturity map; the experimental list follows the fixed type order.
func maturityOf(m map[string]MaturityInfo) (map[string]maturityView, []string) {
	if len(m) == 0 {
		return nil, nil
	}
	out := map[string]maturityView{}
	var exp []string
	for _, t := range []string{"noul", "choice", "score"} {
		e, ok := m[t]
		if !ok { // a type absent from a published maturity map is unmeasured (same rule as the planner)
			e = MaturityInfo{Status: "unmeasured", Reason: "not yet measured"}
		}
		v := maturityView{Status: e.Status, LowerBound: e.LowerBound, Baseline: e.Baseline, Reason: e.Reason}
		if e.Status != "unmeasured" {
			n := e.N
			v.N = &n
		}
		out[t] = v
		if e.Experimental() {
			exp = append(exp, t)
		}
	}
	return out, exp
}

// calibrationView is present only when a calibration profile file exists for the model: applied
// (with its method, sample count and profile name) or not applied (with the closed reason code).
type calibrationView struct {
	Applied   bool   `json:"applied"`
	Method    string `json:"method,omitempty"`
	N         int    `json:"n,omitempty"`
	ProfileID string `json:"profile_id,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

type limitsView struct {
	MaxOptions       int    `json:"max_options"`
	ScoreLevels      [2]int `json:"score_levels"`
	MaxStateChars    int    `json:"max_state_chars,omitempty"`
	MaxContextTokens int    `json:"max_context_tokens,omitempty"`
	MaxPairs         int    `json:"max_pairs,omitempty"`
}

// sdkModel is one entry of the hosted-SDK listing (typesafe-sdk py 0.7.2 / @typesafe-ai/sdk js 0.6.0
// require exactly name, description and release_date per entry under a top-level "models" array).
type sdkModel struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	ReleaseDate string `json:"release_date"`
}

func validDate(d string) bool {
	_, err := time.Parse("2006-01-02", d)
	return err == nil && len(d) == 10
}

// handleModels answers BOTH shapes additively in one body: the llmctl listing (object/data) and
// the SDK listing (models), one SDK entry per accepted name (the profile id, then each alias).
func (s *Server) handleModels(c *gin.Context) {
	if c.Request.ContentLength == 0 {
		requestRead(c)
	}
	if !s.ready() {
		s.fail(c, mustTransport(503, contract.TransportOptions{}))
		return
	}
	data := []modelView{}
	models := []sdkModel{}
	for _, m := range s.cfg.Backend.Models() {
		al := m.Aliases
		if al == nil {
			al = []string{}
		}
		mat, expTypes := maturityOf(m.Maturity)
		data = append(data, modelView{ID: m.ID, Aliases: al, Protocol: m.Protocol, Status: m.Status,
			Limits: limitsView{MaxOptions: m.MaxOptions, ScoreLevels: m.ScoreLevels, MaxStateChars: m.MaxStateChars,
				MaxContextTokens: m.MaxContextTokens, MaxPairs: m.MaxPairs}, Notes: m.Notes,
			TemplateHash: m.TemplateHash, Calibration: calibrationOf(m.Calibration), Maturity: mat, ExperimentalTypes: expTypes})
		desc := m.Description
		if desc == "" {
			desc = fmt.Sprintf("llmctl decision model (%s protocol, up to %d options).", m.Protocol, m.MaxOptions)
		}
		date := m.ReleaseDate
		if !validDate(date) {
			date = DefaultReleaseDate
		}
		models = append(models, sdkModel{Name: m.ID, Description: desc, ReleaseDate: date})
		for _, a := range al {
			models = append(models, sdkModel{Name: a, Description: "Alias of " + m.ID + ". " + desc, ReleaseDate: date})
		}
	}
	b, err := json.Marshal(struct {
		Object string      `json:"object"`
		Data   []modelView `json:"data"`
		Models []sdkModel  `json:"models"`
	}{"list", data, models})
	if err != nil {
		s.fail(c, mustTransport(502, contract.TransportOptions{}))
		return
	}
	c.Data(http.StatusOK, jsonCT, b)
}

func calibrationOf(c *CalibrationInfo) *calibrationView {
	if c == nil {
		return nil
	}
	if !c.Applied {
		return &calibrationView{Reason: c.Reason}
	}
	return &calibrationView{Applied: true, Method: c.Method, N: c.N, ProfileID: c.ProfileID}
}

// admit takes a decision slot, waiting in the bounded queue until ctx ends.
func (s *Server) admit(ctx context.Context) (release func(), ok bool) {
	select {
	case s.sem <- struct{}{}:
		return func() { <-s.sem }, true
	default:
	}
	if int(s.waiting.Add(1)) > s.lim.Queue {
		s.waiting.Add(-1)
		return nil, false
	}
	defer s.waiting.Add(-1)
	select {
	case s.sem <- struct{}{}:
		return func() { <-s.sem }, true
	case <-ctx.Done():
		return nil, false
	}
}

func (s *Server) handleSystemOne(c *gin.Context) {
	r := c.Request
	// 1. framing checks that need no body: declared size (413 before reading), content type.
	if r.ContentLength >= 0 {
		if err := contract.CheckBodySize(r.ContentLength, s.lim.MaxBody); err != nil {
			s.failClose(c, asContractError(err))
			return
		}
	}
	if err := contract.CheckContentType(r.Header.Get("Content-Type")); err != nil {
		if r.ContentLength != 0 {
			c.Writer.Header().Set("Connection", "close")
		}
		s.fail(c, asContractError(err))
		return
	}
	// 2. shed early when not ready or draining (before spending time reading the body).
	if !s.ready() {
		if r.ContentLength != 0 {
			c.Writer.Header().Set("Connection", "close")
		}
		s.fail(c, mustTransport(503, contract.TransportOptions{}))
		return
	}
	// 3. bounded read (also bounds chunked bodies that declare no length).
	body, err := io.ReadAll(http.MaxBytesReader(c.Writer, r.Body, s.lim.MaxBody))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			s.failClose(c, asContractError(contract.CheckBodySize(s.lim.MaxBody+1, s.lim.MaxBody)))
		} else {
			s.failClose(c, mustBadRequest())
		}
		return
	}
	requestRead(c)
	// 4. validate against the contract.
	req, err := contract.ParseRequest(body, s.cfg.ContractLimits, s.cfg.Profiles)
	if err != nil {
		if ce := asContractError(err); ce != nil {
			s.fail(c, ce)
		} else {
			s.fail(c, mustTransport(502, contract.TransportOptions{}))
		}
		return
	}
	c.Set(ckProfile, req.Model)
	c.Set(ckDecReq, req)
	qt := make([]string, 0, len(req.Questions))
	for _, q := range req.Questions {
		qt = append(qt, q.Type)
	}
	c.Set(ckQTypes, qt)
	if len(s.cfg.LogKey) >= audit.MinKeyBytes {
		if h, err := audit.StateHash(s.cfg.LogKey, req.StateText); err == nil {
			c.Set(ckHash, h)
		}
	}
	// 5. admission (bounded concurrency + bounded queue) and the decision.
	ctx, cancel := context.WithTimeout(r.Context(), s.lim.Timeout)
	defer cancel()
	ctx, truncated := WithTruncationNote(ctx)
	ctx, instance := contract.WithInstanceNote(ctx)
	release, ok := s.admit(ctx)
	if !ok {
		s.fail(c, mustTransport(529, contract.TransportOptions{}))
		return
	}
	answers, usage, err := s.cfg.Backend.Decide(ctx, req)
	release()
	if err == nil {
		c.Set(ckDecAns, answers)
	}
	if err != nil {
		ce := asContractError(err)
		if ce == nil {
			ce = mustTransport(502, contract.TransportOptions{}) // generic: engine text never reaches the client
		}
		if ce.Status == http.StatusBadGateway {
			s.markBackend502(c, ctx, r.Context())
		}
		s.fail(c, ce)
		return
	}
	if mr, ok := s.cfg.Backend.(MaturityReporter); ok {
		// T138: label the answers of a type the profile has not measured above its baseline (additive field)
		for i := range answers {
			if lab := mr.Maturity(req.Model, answers[i].Answer.Type); lab != "" {
				answers[i].Answer.Maturity = lab
			}
		}
	}
	resp, err := contract.BuildResponse(req.Model, answers, usage.InputTokens, usage.OutputTokens)
	var out []byte
	if err == nil {
		out, err = json.Marshal(resp)
	}
	if err != nil {
		s.fail(c, mustTransport(502, contract.TransportOptions{}))
		return
	}
	if req.Truncated || truncated() {
		c.Writer.Header().Set("x-llmctl-decide-truncated", "true")
	}
	if inst := instance(); inst != "" {
		c.Writer.Header().Set(contract.HeaderInstance, inst)
	}
	if mr, ok := s.cfg.Backend.(ModeReporter); ok && mr.Mode() != "" {
		c.Writer.Header().Set("x-llmctl-decide-mode", mr.Mode())
	}
	c.Data(http.StatusOK, jsonCT, out)
}

func mustBadRequest() *contract.ContractError {
	ce, err := contract.NewError(http.StatusBadRequest, contract.ErrTypeInvalidRequest, "Invalid request.", nil)
	if err != nil {
		panic(err)
	}
	return ce
}
