package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/server"
)

// NLIBackend maps the typed questions onto natural-language-inference pairs for the encoder runtime
// (contracts/encoder-runtime.md): POST /v1/score {"pairs":[{"premise","hypothesis"}...]} answers
//
//	{"labels":["entailment","neutral","contradiction"], "label_source":"config:...",
//	 "scores":[[p_label0,p_label1,p_label2], ...], "truncated":[...], "model", "max_tokens"}
//
// with one row per pair: scores[i] is the FULL softmax over `labels` in the model's id2label order.
// The decoder never assumes a column. It selects entailment and contradiction (and, when present,
// neutral) BY NAME from `labels` (case-insensitive: entailment|entails|entail,
// contradiction|contradicts|contradict, neutral) and refuses - as a configuration error - when
// label_source says the names are generic (`generic-config...`, `none...`) or a required label is
// missing or ambiguous: 502 backend_failed with a generic body, the reason logged server side only,
// and the instance reported degraded (Degraded; the router then fails readiness) instead of
// guessing a column. A binary head whose labels are exactly {entailment, not_entailment} (the pinned
// decide-nli model) is served as-is: only P(entailment) enters the score and not_entailment is its
// exact complement, so nothing is split into neutral/contradiction (D-06).
//
// Mapping (documented, adjustable through Hypothesis): the premise is the state text; each option
// becomes one pair whose hypothesis is DefaultHypothesis(question, option) - the question
// instructions followed by the option label ("yes - <description>", "<key> - <description>",
// "<level description>"). The option score is P(entailment | premise, that option's hypothesis),
// normalised over the question's options to sum 1: noul = P(entail | yes-criteria) compared with
// P(entail | no-criteria); choice and score normalise the entailment probability across all options
// (one forward pass per option: latency grows with the option count, which the catalog flags as
// experimental). Neutral and contradiction are located and validated (every row must be a finite
// probability distribution that matches `labels`) but do not enter the score. All-zero entailment is
// a deterministic readout_failed, not a guess.
//
// Truncation: the runtime shortens only the premise and reports it per pair. Silent truncation is
// refused (422 validation_failed) unless Truncate (LLMCTL_DECIDE_TRUNCATE) is on; when it is on and
// the runtime did truncate, the gateway answers with x-llmctl-decide-truncated: true
// (server.NoteTruncated).
type NLIBackend struct {
	Hypothesis func(q contract.ParsedQuestion, o contract.Option) string
	Truncate   bool
	// MaxPairs bounds the encoder passes one request may cost (all questions together, FR-016);
	// 0 = DefaultMaxPairs. The check runs before the first pass is spent.
	MaxPairs int
	HTTP     *http.Client
	// Logf receives server-side diagnostics (label configuration errors). nil = log.Printf. It is
	// never given request content or keys.
	Logf func(format string, args ...any)
	// Now is the clock of the degraded verdict (nil = time.Now).
	Now func() time.Time

	mu  sync.Mutex
	bad map[string]time.Time // endpoint URL -> when its labels were last found unusable
}

// NLIDegradedFor is how long an instance whose labels could not be mapped stays degraded before a
// request is allowed to re-test it (the runtime may have been fixed and restarted on the same port).
const NLIDegradedFor = 30 * time.Second

// DefaultMaxPairs is the default per-request pair budget: the encoder runtime's own cap per call
// (LLMCTL_ONNX_MAX_PAIRS, default 64).
const DefaultMaxPairs = 64

// PairBudget is the effective per-request pair budget.
func (n *NLIBackend) PairBudget() int {
	if n.MaxPairs > 0 {
		return n.MaxPairs
	}
	return DefaultMaxPairs
}

// DefaultHypothesis is the documented default hypothesis text. It is one line of clean text: a
// key, label or instruction cannot smuggle control characters or line breaks into the runtime.
func DefaultHypothesis(q contract.ParsedQuestion, o contract.Option) string {
	if q.Instructions == "" {
		return contract.OneLine(o.Label)
	}
	return contract.OneLine(q.Instructions + " " + o.Label)
}

type scoreRequest struct {
	Pairs []scorePair `json:"pairs"`
}

type scorePair struct {
	Premise    string `json:"premise"`
	Hypothesis string `json:"hypothesis"`
}

type scoreResponse struct {
	Labels      []string    `json:"labels"`
	LabelSource string      `json:"label_source"`
	Scores      [][]float64 `json:"scores"`
	Truncated   []bool      `json:"truncated"`
}

// labelConfigError marks a response whose labels cannot be mapped; it is a configuration problem
// of the runtime, not of the request.
type labelConfigError struct{ reason string }

func (e *labelConfigError) Error() string { return e.reason }

func (n *NLIBackend) now() time.Time {
	if n.Now != nil {
		return n.Now()
	}
	return time.Now()
}

func (n *NLIBackend) logf(format string, args ...any) {
	if n.Logf != nil {
		n.Logf(format, args...)
		return
	}
	log.Printf(format, args...)
}

// Degraded implements the router's degrader: true while the instance's labels were found unusable
// less than NLIDegradedFor ago.
func (n *NLIBackend) Degraded(ep Endpoint) bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	at, ok := n.bad[ep.URL]
	if !ok {
		return false
	}
	if n.now().Sub(at) >= NLIDegradedFor {
		delete(n.bad, ep.URL)
		return false
	}
	return true
}

func (n *NLIBackend) setBad(ep Endpoint, bad bool) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if bad {
		if n.bad == nil {
			n.bad = map[string]time.Time{}
		}
		n.bad[ep.URL] = n.now()
	} else {
		delete(n.bad, ep.URL)
	}
}

// nliColumns are the positions of the named labels in the runtime's id2label order.
type nliColumns struct{ entail, contra, neutral int } // neutral -1 when the model has none

func labelKind(l string) string {
	switch strings.ToLower(strings.TrimSpace(l)) {
	case "entailment", "entails", "entail":
		return "entailment"
	case "contradiction", "contradicts", "contradict":
		return "contradiction"
	case "neutral":
		return "neutral"
	case "not_entailment", "not-entailment", "not entailment", "non_entailment", "non-entailment":
		return "not_entailment"
	}
	return ""
}

// resolveColumns finds the labels by name; it never guesses.
func resolveColumns(labels []string, source string) (nliColumns, error) {
	src := strings.ToLower(strings.TrimSpace(source))
	if strings.HasPrefix(src, "generic-config") || strings.HasPrefix(src, "none") {
		return nliColumns{}, &labelConfigError{"label_source " + clip(source, 80) + " carries no entailment/contradiction semantics"}
	}
	cols := nliColumns{-1, -1, -1}
	seen := map[string]int{}
	for i, l := range labels {
		k := labelKind(l)
		if k == "" {
			continue
		}
		seen[k]++
		switch k {
		case "entailment":
			cols.entail = i
		case "contradiction":
			cols.contra = i
		case "neutral":
			cols.neutral = i
		}
	}
	for k, c := range seen {
		if c > 1 {
			return nliColumns{}, &labelConfigError{"label " + k + " appears " + strconv.Itoa(c) + " times in labels"}
		}
	}
	// A BINARY NLI head (id2label exactly {entailment, not_entailment}, e.g. the pinned decide-nli
	// zeroshot-v2.0 model) is served as-is: the score is P(entailment) alone and not_entailment is its
	// exact complement, so nothing is split or invented (D-06). not_entailment beside any other label
	// is a contradictory label set and is refused.
	if seen["not_entailment"] > 0 {
		if len(labels) != 2 || cols.entail < 0 {
			return nliColumns{}, &labelConfigError{"labels " + clip(strings.Join(labels, ","), 120) + " mix not_entailment with labels other than exactly one entailment"}
		}
		return cols, nil
	}
	if cols.entail < 0 || cols.contra < 0 {
		return nliColumns{}, &labelConfigError{"labels " + clip(strings.Join(labels, ","), 120) + " do not name both entailment and contradiction"}
	}
	return cols, nil
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n] + "..."
	}
	return s
}

// decodeScore validates the response shape and returns the entailment probability of every pair.
func decodeScore(raw []byte, n int) (*scoreResponse, []float64, error) {
	var r scoreResponse
	if err := json.Unmarshal(raw, &r); err != nil || len(r.Scores) != n || len(r.Labels) == 0 {
		return nil, nil, backendFailed()
	}
	if len(r.Truncated) != 0 && len(r.Truncated) != n {
		return nil, nil, backendFailed()
	}
	cols, err := resolveColumns(r.Labels, r.LabelSource)
	if err != nil {
		return nil, nil, err
	}
	ent := make([]float64, n)
	for i, row := range r.Scores {
		if len(row) != len(r.Labels) {
			return nil, nil, backendFailed()
		}
		sum := 0.0
		for _, p := range row {
			if math.IsNaN(p) || math.IsInf(p, 0) || p < 0 || p > 1+1e-6 {
				return nil, nil, backendFailed()
			}
			sum += p
		}
		if math.Abs(sum-1) > 1e-3 { // a softmax row; anything else (a scalar, a raw logit row) is not
			return nil, nil, backendFailed()
		}
		ent[i] = row[cols.entail]
	}
	return &r, ent, nil
}

// Decide implements Driver.
func (n *NLIBackend) Decide(ctx context.Context, ep Endpoint, spec ProfileSpec, req *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
	if spec.Protocol != ProtoNLI {
		return nil, contract.Usage{}, wrongProtocol(ProtoNLI, spec.Protocol)
	}
	hyp := n.Hypothesis
	if hyp == nil {
		hyp = DefaultHypothesis
	}
	// Refusals that need no engine are answered before any pass is spent (B-03/B-05): the runtime
	// rejects an empty premise or hypothesis and an oversize pair list on every attempt.
	premise := contract.CleanText(req.StateText)
	if premise == "" {
		return nil, contract.Usage{}, validationFailed("The state must not be empty for this model.")
	}
	pairs := 0
	for _, q := range req.Questions {
		pairs += len(q.Options)
	}
	if pairs > n.PairBudget() {
		return nil, contract.Usage{}, validationFailed("Request exceeds the cost budget.")
	}
	var out []contract.NamedAnswer
	var usage contract.Usage
	for _, q := range req.Questions {
		for _, o := range q.Options {
			if strings.TrimSpace(hyp(q, o)) == "" {
				return nil, usage, validationFailed("Request failed validation.")
			}
		}
	}
	for _, q := range req.Questions {
		sr := scoreRequest{}
		chars := 0
		for _, o := range q.Options {
			h := hyp(q, o)
			sr.Pairs = append(sr.Pairs, scorePair{Premise: premise, Hypothesis: h})
			chars += utf8.RuneCountInString(premise) + utf8.RuneCountInString(h)
		}
		raw, _ := json.Marshal(sr)
		body, err := postJSON(ctx, n.HTTP, ep, "/v1/score", raw)
		if err != nil {
			return nil, usage, err
		}
		resp, ent, err := decodeScore(body, len(q.Options))
		if err != nil {
			var lc *labelConfigError
			if errors.As(err, &lc) {
				n.setBad(ep, true)
				n.logf("llmctl decide: encoder runtime %s: unusable NLI labels (%s); refusing to guess a column", ep.Instance, lc.reason)
				return nil, usage, backendFailed()
			}
			return nil, usage, err
		}
		n.setBad(ep, false)
		anyTruncated := false
		for _, t := range resp.Truncated {
			anyTruncated = anyTruncated || t
		}
		if anyTruncated {
			if !n.Truncate {
				return nil, usage, validationFailed("Request failed validation.")
			}
			server.NoteTruncated(ctx)
		}
		sum := 0.0
		for _, s := range ent {
			sum += s
		}
		if !(sum > 0) {
			return nil, usage, contract.ReadoutFailedError()
		}
		probs := make([]float64, len(ent))
		for i, s := range ent {
			probs[i] = s / sum
		}
		a, err := contract.BuildAnswer(q, probs)
		if err != nil {
			return nil, usage, backendFailed()
		}
		out = append(out, contract.NamedAnswer{Name: q.Name, Answer: a})
		usage.InputTokens += estimateIn(chars)
	}
	return out, usage, nil
}
