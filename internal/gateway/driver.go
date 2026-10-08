package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// Mode selects how instances of a profile are used.
type Mode string

const (
	// Deterministic serves a profile from its primary instance (fixed seed, one slot) and overflows
	// to further instances only when the primary is saturated (FR-074).
	Deterministic Mode = "deterministic"
	// Throughput spreads load over healthy instances, least loaded first; byte-identity across
	// instances is not promised and no seed is pinned.
	Throughput Mode = "throughput"
)

// ParseMode maps LLMCTL_DECIDE_MODE ("" = deterministic).
func ParseMode(s string) (Mode, error) {
	switch strings.TrimSpace(s) {
	case "", string(Deterministic):
		return Deterministic, nil
	case string(Throughput):
		return Throughput, nil
	}
	return "", fmt.Errorf("gateway: LLMCTL_DECIDE_MODE must be deterministic or throughput")
}

// Driver implements one decision protocol against one engine instance.
type Driver interface {
	Decide(ctx context.Context, ep Endpoint, spec ProfileSpec, req *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error)
}

// DefaultDrivers returns the three protocol drivers.
func DefaultDrivers(mode Mode, nativeEnabled bool) map[string]Driver {
	return map[string]Driver{
		ProtoLetter: &LetterLogitBackend{Mode: mode, Seed: DefaultSeed},
		ProtoNLI:    &NLIBackend{},
		ProtoNative: &NativeBackend{Enabled: nativeEnabled},
	}
}

// DefaultSeed is the fixed sampler seed of deterministic mode.
const DefaultSeed = 1

// SeedZero is how a configured seed of 0 is carried in LetterLogitBackend.Seed, whose zero value means
// "not configured" (DefaultSeed). llama.cpp treats 0 as an ordinary FIXED seed (only a negative seed is
// random), so LLMCTL_SEED=0 is valid; the driver sends 0 for it (B3-08).
const SeedZero = -1 << 31

// ResolveSeed maps LetterLogitBackend.Seed to the seed sent to the engine.
func ResolveSeed(configured int) int {
	switch configured {
	case 0:
		return DefaultSeed
	case SeedZero:
		return 0
	}
	return configured
}

// maxEngineBody bounds what is read back from an engine.
const maxEngineBody = 8 << 20

// backendFailed is the generic 502; engine text never reaches a client.
func backendFailed() error {
	e, err := contract.TransportError(http.StatusBadGateway, contract.TransportOptions{})
	if err != nil {
		return err
	}
	return e
}

// misconfigured is the deterministic server-side fault: a setting or an engine contract the gateway
// cannot serve with. 500 backend_failed, NOT retryable (review-2 B-03/B-06): a retry would fail the
// same way and only multiply the cost.
func misconfigured() error {
	e, err := contract.TransportError(http.StatusInternalServerError, contract.TransportOptions{})
	if err != nil {
		return err
	}
	return e
}

// engineLogf receives server-side diagnostics about deterministic engine/config faults. It is never
// given request content, engine response text or keys.
var engineLogf = log.Printf

var loggedFaults sync.Map // fault text -> struct{}: once per distinct fault, not once per request

// resetLoggedFaults forgets the once-per-fault memory (tests that assert on the log must not depend
// on what an earlier run in the same process already logged, C3-16).
func resetLoggedFaults() {
	loggedFaults.Range(func(k, _ any) bool { loggedFaults.Delete(k); return true })
}

func logFaultOnce(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	if _, seen := loggedFaults.LoadOrStore(msg, struct{}{}); !seen {
		engineLogf("%s", msg)
	}
}

// engineErrorKind extracts the machine error code of an engine's non-200 body: llama-server answers
// {"error":{"type":...}}, the encoder runtime {"error":"<code>"}. Only a short [a-z_] token is
// returned; engine text is never kept.
func engineErrorKind(body []byte) string {
	var doc struct {
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal(body, &doc) != nil || len(doc.Error) == 0 {
		return ""
	}
	var code string
	var obj struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(doc.Error, &code) == nil {
		return cleanKind(code)
	}
	if json.Unmarshal(doc.Error, &obj) == nil {
		return cleanKind(obj.Type)
	}
	return ""
}

func cleanKind(s string) string {
	if len(s) > 48 {
		return ""
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z') && r != '_' {
			return ""
		}
	}
	return s
}

// classifyEngineStatus maps a non-200 engine answer. Only a transient failure is the retryable 502;
// a rejection the same request would meet again is not (review-2 B-02/B-03):
//
//	400 exceed_context_size_error / 422 hypothesis_too_long / 413 too_many_pairs
//	    -> 422 validation_failed (the request cannot fit this model)
//	404/405 from a REGISTRY endpoint (a stale entry: another program answers on the port) -> 502,
//	    retryable; from a STATIC endpoint it is a fixed misconfiguration -> 500, not retryable (B3-06)
//	any other 4xx (the engine refuses the gateway's own request shape)
//	    -> 500 backend_failed, logged, not retryable
//	401 after the key re-read, 408, 429, 5xx, 3xx -> 502 (transient or an engine that is not ours)
func classifyEngineStatus(ep Endpoint, path string, status int, body []byte) error {
	kind := engineErrorKind(body)
	switch {
	case status == 400 && kind == "exceed_context_size_error":
		return validationFailed("State plus question exceeds the budget.")
	case status == 422 && kind == "hypothesis_too_long":
		return validationFailed("Question alone exceeds the budget.")
	case status == 413 && kind == "too_many_pairs":
		return validationFailed("Request exceeds the cost budget.")
	case status == 500 && path == "/v1/systemone" && nativeBatchTooLarge(body):
		// llama.cpp #30073: a state longer than the physical batch (-ub) is answered 500 "input (N tokens)
		// is too large to process ... increase the physical batch size". The request cannot fit this
		// instance: the same 422 as a context overflow; the engine's text never reaches the client.
		return validationFailed("State plus question exceeds the budget.")
	case status == 501 && path == "/v1/systemone":
		// "This model is not a decision model": a chat model sits behind a decision profile. A
		// deterministic configuration fault, so the non-retryable 500 (never the retryable 502).
		logFaultOnce("llmctl decide: engine %s %s answered HTTP 501: the model behind this profile is not a decision model (check the catalog file and the engine; not retryable)", ep.Instance, path)
		return misconfigured()
	case (status == 404 || status == 405) && ep.FromRegistry:
		// the registry entry points at a process that is not our engine any more (a recycled port, a stale
		// entry): temporary, the registry heals - the retryable 502, logged (B2-08)
		logFaultOnce("llmctl decide: engine %s %s answered HTTP %d: the registry entry may be stale or the port taken by another program (retryable)",
			ep.Instance, path, status)
		return backendFailed()
	case status >= 400 && status < 500 && status != 401 && status != 408 && status != 429:
		logFaultOnce("llmctl decide: engine %s %s answered HTTP %d (%s): the engine rejects the gateway's request deterministically; check the engine and the gateway configuration (not retryable)",
			ep.Instance, path, status, orNone(kind))
		return misconfigured()
	}
	return backendFailed()
}

// nativeBatchTooLarge recognises the engine's batch-overflow rejection by its message (the error
// type is the generic "server_error", so the text is the only discriminator). The message is read
// here and discarded; nothing of it is kept or logged.
func nativeBatchTooLarge(body []byte) bool {
	var doc struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &doc) != nil {
		return false
	}
	m := doc.Error.Message
	return strings.HasPrefix(m, "input (") && strings.Contains(m, "is too large to process") &&
		strings.Contains(m, "physical batch size")
}

func orNone(k string) string {
	if k == "" {
		return "no error code"
	}
	return k
}

func notReady() error {
	e, err := contract.TransportError(http.StatusServiceUnavailable, contract.TransportOptions{})
	if err != nil {
		return err
	}
	return e
}

func overloaded() error {
	e, err := contract.TransportError(529, contract.TransportOptions{})
	if err != nil {
		return err
	}
	return e
}

func validationFailed(msg string) error {
	return &contract.ContractError{Status: 422, ErrorType: contract.ErrTypeValidationFailed, Message: msg}
}

var sharedClient = &http.Client{
	Transport: &http.Transport{
		Proxy:               nil,                    // engines are on loopback: never through a proxy
		DialContext:         newLoopbackDialer(nil), // the peer is loopback, whatever a name resolves to
		MaxIdleConnsPerHost: 8,
		IdleConnTimeout:     30 * time.Second,
	},
	CheckRedirect: noRedirect,
}

// noRedirect: an engine never legitimately redirects, and a 307 must not carry the internal key or
// the decision state to another port (review A-08).
func noRedirect(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

// postJSON POSTs body to <ep.URL><path> with the internal key and returns the response body of a
// 200. Anything else (connect failure, non-200, oversize) is the generic 502; ctx expiry is too.
func postJSON(ctx context.Context, hc *http.Client, ep Endpoint, path string, body []byte) ([]byte, error) {
	if err := checkLoopback(ep.URL); err != nil {
		return nil, backendFailed()
	}
	if hc == nil {
		hc = sharedClient
	}
	if hc.CheckRedirect == nil { // a caller-supplied client gets the same no-redirect rule
		c := *hc
		c.CheckRedirect = noRedirect
		hc = &c
	}
	b, status, err := postOnce(ctx, hc, ep.URL, ep.Key, path, body)
	if err != nil {
		if ctx.Err() == nil { // a caller that gave up says nothing about the engine
			invalidateProps(ep.URL)
		}
		return nil, backendFailed()
	}
	if status != http.StatusOK {
		invalidateProps(ep.URL) // an engine error: what /props said before may be stale (restart)
	}
	if status == http.StatusUnauthorized {
		// G-040: the engine rejected the key - it may have been rotated on disk. Re-read the key
		// file once and retry once with the NEW key; never loop, never retry with the same key.
		nk := refreshedKey(ep)
		if nk == "" {
			return nil, backendFailed()
		}
		if b, status, err = postOnce(ctx, hc, ep.URL, nk, path, body); err != nil {
			return nil, backendFailed()
		}
	}
	if status != http.StatusOK {
		return nil, classifyEngineStatus(ep, path, status, b) // engine text (b) never reaches a client
	}
	return b, nil
}

// postOnce performs one POST and returns the (bounded) body with the status; only a 200's body is
// ever used.
func postOnce(ctx context.Context, hc *http.Client, base, key, path string, body []byte) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(base, "/")+path, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		eb, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		return eb, resp.StatusCode, nil
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, maxEngineBody+1))
	if err != nil || len(b) > maxEngineBody {
		return nil, 0, errors.New("gateway: unusable engine body")
	}
	return b, resp.StatusCode, nil
}

func wrongProtocol(want, got string) error {
	return fmt.Errorf("gateway: driver for %s asked to serve a %s profile", want, got)
}

func asContract(err error) (*contract.ContractError, bool) {
	var c *contract.ContractError
	if errors.As(err, &c) {
		return c, true
	}
	return nil, false
}

func estimateIn(chars int) int {
	n, _ := contract.EstimateTokens(chars)
	return n
}
