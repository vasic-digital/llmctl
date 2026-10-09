package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/readout"
)

// LetterLogitBackend answers by asking a llama-server for ONE token with first-token logprobs and
// reading the probability of each option letter (FR-009, FR-010, FR-076).
//
// Request per question (deterministic mode, the default): POST /v1/chat/completions with the shared
// prompt, max_tokens 1, temperature 0, logprobs + top_logprobs/n_probs from the profile, a fixed seed
// and cache_prompt false. The caller serialises slots (one per instance), so repeated requests are
// byte-identical per instance. Throughput mode omits the seed.
type LetterLogitBackend struct {
	Mode Mode
	Seed int // fixed seed of deterministic mode; 0 = DefaultSeed, SeedZero = the fixed seed 0 (ResolveSeed)
	// MassThreshold overrides the profile's threshold when > 0 (LLMCTL_DECIDE_MASS_THRESHOLD).
	MassThreshold float64
	// Temperature is the global readout scalar (LLMCTL_DECIDE_TEMPERATURE); 0 = 1.
	Temperature float64
	HTTP        *http.Client
}

// Decide implements Driver.
func (b *LetterLogitBackend) Decide(ctx context.Context, ep Endpoint, spec ProfileSpec, req *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
	if spec.Protocol != ProtoLetter {
		return nil, contract.Usage{}, wrongProtocol(ProtoLetter, spec.Protocol)
	}
	// a setting that can never produce an answer is a deterministic server fault, not a transient
	// backend failure (review-2 B-06): 500, not the retryable 502
	if math.IsNaN(b.Temperature) || math.IsInf(b.Temperature, 0) || b.Temperature < 0 ||
		math.IsNaN(b.MassThreshold) || b.MassThreshold < 0 || b.MassThreshold > 1 {
		logFaultOnce("llmctl decide: the letter-logit readout settings are invalid (temperature must be finite and > 0, mass threshold in (0,1]); fix LLMCTL_DECIDE_TEMPERATURE / LLMCTL_DECIDE_MASS_THRESHOLD")
		return nil, contract.Usage{}, misconfigured()
	}
	temp := b.Temperature
	if temp <= 0 {
		temp = 1
	}
	thr := spec.Readout.MassThreshold
	if b.MassThreshold > 0 {
		thr = b.MassThreshold
	}
	if thr <= 0 {
		thr = DefaultMassThreshold
	}
	nprobs := spec.Readout.NProbs
	if nprobs <= 0 {
		nprobs = DefaultNProbs
	}
	var out []contract.NamedAnswer
	var usage contract.Usage
	// the per-slot context the engine REALLY serves (GET /props), when it says (B2-05, G-093)
	engineN, engineKnown := engineCtx(ctx, b.HTTP, ep)
	if engineKnown && spec.Ctx > engineN {
		logFaultOnce("llmctl decide: engine %s serves a per-slot context of %d tokens but the gateway budgets %d for %s; set LLMCTL_CTX_%s to match the launcher",
			ep.Instance, engineN, spec.Ctx, spec.ID, strings.ToUpper(strings.ReplaceAll(spec.ID, "-", "_")))
	}
	// B3-05: render and budget-check EVERY question before the first completion is requested, so an
	// earlier question's compute is never spent on a request a later question will refuse. The only
	// engine contact before that is the (cached) GET /props read of the per-slot context.
	prompts := make([]string, len(req.Questions))
	for i, q := range req.Questions {
		prompt, err := contract.RenderPrompt(q, req.StateText)
		if err != nil {
			return nil, usage, validationFailed("Request failed validation.")
		}
		if engineKnown && contract.EstimateTextTokens(prompt) > contract.PromptTokenBudget(engineN) {
			return nil, usage, validationFailed("State plus question exceeds the budget.")
		}
		prompts[i] = prompt
	}
	for qi, q := range req.Questions {
		prompt := prompts[qi]
		body := map[string]any{
			"messages":     []map[string]string{{"role": "user", "content": prompt}},
			"max_tokens":   1,
			"temperature":  0,
			"logprobs":     true,
			"top_logprobs": nprobs,
			"n_probs":      nprobs,
			"cache_prompt": spec.Readout.CachePrompt && b.Mode == Throughput, // never in deterministic mode (B2-12)
			"stream":       false,
			// Thinking-mode templates (Qwen3/3.5 family) open with a reasoning token, delivered in
			// reasoning_content, so no option letter is ever in the first-token alternatives
			// (422 readout_failed / option_missing). llama-server honours this per-request kwarg; a
			// template that does not use it ignores it.
			"chat_template_kwargs": map[string]any{"enable_thinking": false},
		}
		if b.Mode != Throughput {
			body["seed"] = ResolveSeed(b.Seed)
		}
		raw, _ := json.Marshal(body)
		resp, err := postJSON(ctx, b.HTTP, ep, "/v1/chat/completions", raw)
		if err != nil {
			return nil, usage, err
		}
		top, err := readout.ExtractTopLogprobsJSON(resp)
		if err != nil {
			return nil, usage, mapReadoutErr(err)
		}
		letters := make([]string, len(q.Options))
		for i, o := range q.Options {
			letters[i] = o.Letter
		}
		ro, err := readout.ComputeRaw(top, letters, thr, temp)
		if err != nil {
			return nil, usage, mapReadoutErr(err)
		}
		// An option letter absent from the readout is NEVER an exact 0 (FR-076, B-01): the answer is
		// built from the conservative distribution (the absent option holds its upper bound as mass),
		// flagged, and carries the bounds on the SAME scale as the probabilities (the share the option
		// would hold at its full raw bound, B2-02), so a reader never sees "probability 0.15, at most 0.1".
		probs := make([]float64, len(letters))
		src := ro.Probabilities
		var bounds map[string]float64
		if ro.Flagged() {
			src = ro.Conservative
			bounds = map[string]float64{}
			for i, l := range letters {
				if ub, missing := ro.NormalisedBounds[l]; missing {
					bounds[q.Options[i].Key] = ub
				}
			}
		}
		for i, l := range letters {
			probs[i] = src[l]
		}
		a, err := contract.BuildAnswerBounded(q, probs, bounds)
		if err != nil {
			return nil, usage, backendFailed()
		}
		out = append(out, contract.NamedAnswer{Name: q.Name, Answer: a})
		usage.InputTokens += estimateIn(utf8.RuneCountInString(prompt))
		usage.OutputTokens++
	}
	return out, usage, nil
}

// mapReadoutErr: a model that answered something other than a letter is a deterministic 422; a
// structurally unusable engine response (or any other failure) is the generic 502.
func mapReadoutErr(err error) error {
	var rf *readout.ReadoutFailed
	if errors.As(err, &rf) {
		return contract.ReadoutFailedError()
	}
	if errors.Is(err, readout.ErrBadArgument) { // a bad setting: deterministic, not transient
		logFaultOnce("llmctl decide: the readout rejected its configuration (%v)", err)
		return misconfigured()
	}
	return backendFailed()
}
