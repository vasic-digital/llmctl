// Package readout turns first-token logprobs into option-letter probabilities (FR-076). It is pure
// math with no I/O and a faithful port of lib/llmctl_decide/readout.py.
//
// Rules (each covered by a test):
//   - Probability mass is SUMMED over every spelling of an option letter: the upper-case ASCII
//     letter with or without one leading space (also the sentencepiece marker U+2581). Lower-case
//     letters, longer tokens and letters that are not options never count. Every list entry is one
//     token and its mass is added - two token ids that decode to the same text are two entries
//     (B-10); only the very same token id listed twice is one entry (the highest logprob wins).
//   - If the combined mass over the option letters is below the threshold the readout fails with
//     *ReadoutFailed (422 readout_failed, non-retryable): there is no renormalised guess.
//     Renormalisation happens only when mass >= threshold, and the raw mass is reported.
//   - An option letter absent from the list is never a silent zero: it is listed in Missing, gets an
//     UPPER BOUND in UpperBounds, and the readout is Flagged. DERIVATION of the bound (B2-01, B3-01):
//     let p_min be the smallest listed probability and S the sum of ALL listed probabilities (option
//     letters or not). Every unlisted token has probability <= p_min (the list is the top-n), and the
//     mass of everything unlisted is U = 1 - S. A letter is the sum of s of its spelling tokens
//     ("B", " B", "▁B": s = 3), so the true mass of an absent letter is x_i <= min(s*p_min, U), and
//     JOINTLY sum_i x_i <= U over all absent letters. Each absent letter reports its OWN full bound
//     min(s*p_min, U) (a listed mass of 1 gives bound 0). The Conservative distribution places the
//     absent masses at the WORST CASE of that polytope for the answer's confidence: the allocation
//     that maximises the denominator of the normalisation (sum_i x_i^(1/T)), so the winner - always
//     chosen among the PRESENT letters - holds the smallest share any feasible hidden allocation can
//     leave it. NormalisedBounds carries each absent letter's own bound on the scale of
//     Probabilities/Conservative. LIMITS (stated, not hidden): the masses of PRESENT letters are
//     lower bounds (their own unlisted spellings are not added to the denominator); an engine that
//     exposes more than s token ids for one letter is not covered. Its entry in Probabilities is the flagged 0.
//   - NaN, +Inf, a logprob above 0 (1e-9 tolerance), a non-number logprob, or every entry being -Inf
//     make the readout fail (*ReadoutFailed). A structurally unusable response (no top list, entries
//     that are not {token, logprob}) is *BackendReadoutError (502 backend_failed): the backend
//     misbehaved, which is a different failure from a model that answered something other than a letter.
package readout

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"unicode/utf8"
)

// SpellingsPerLetter is the number of distinct spellings the readout sums for one option letter
// ("B", " B", "▁B"); it multiplies the smallest listed probability to give the bound of an absent letter.
// The catalog's readout.spellings list does NOT restrict the readout (it sums all three forms), so
// the gateway uses this default: a smaller s would be an unsound bound.
const SpellingsPerLetter = 3

// UnlistedEpsilon is the round-off below which 1 - sum(listed) counts as zero (an engine prints
// logprobs with far fewer digits than this).
const UnlistedEpsilon = 1e-9

// ErrBadArgument marks a programming error in the arguments of Compute (letters, threshold,
// temperature); it is never a client or backend error.
var ErrBadArgument = errors.New("readout: bad argument")

// ReadoutFailed is a deterministic readout failure: 422 readout_failed, non-retryable.
type ReadoutFailed struct {
	Reason string  // internal reason; belongs in the log, not in a response body
	Mass   float64 // raw option-letter mass seen (0 when not applicable)
}

func (e *ReadoutFailed) Error() string     { return "readout failed: " + e.Reason }
func (e *ReadoutFailed) Status() int       { return 422 }
func (e *ReadoutFailed) ErrorType() string { return "readout_failed" }
func (e *ReadoutFailed) Retryable() bool   { return false }

// BackendReadoutError is a structurally unusable backend response: 502 backend_failed, retryable.
type BackendReadoutError struct{ Reason string }

func (e *BackendReadoutError) Error() string     { return "backend readout error: " + e.Reason }
func (e *BackendReadoutError) Status() int       { return 502 }
func (e *BackendReadoutError) ErrorType() string { return "backend_failed" }
func (e *BackendReadoutError) Retryable() bool   { return true }

// Entry is one first-token alternative.
type Entry struct {
	Token   string
	Logprob float64
	// ID is the engine's token id when HasID; two entries with one id are one token.
	ID    int
	HasID bool
}

// Readout is the option-letter distribution.
type Readout struct {
	Probabilities map[string]float64 // per option letter, renormalised over the observed mass
	Mass          float64            // raw combined probability mass over the option letters
	Missing       []string           // option letters absent from the readout (letter order)
	UpperBounds   map[string]float64 // missing letter -> upper bound on its raw probability
	// Conservative is the distribution over ALL letters in which every absent letter holds its upper
	// bound as mass before renormalising (equal to Probabilities when nothing is absent).
	Conservative map[string]float64
	// NormalisedBounds is, per absent letter, an upper bound on its probability on the SAME scale as
	// Probabilities/Conservative (the share it would hold if it held its full raw bound and every
	// other absent letter held nothing). Conservative[l] <= NormalisedBounds[l] always.
	NormalisedBounds map[string]float64
	// Listed is the sum of all listed probabilities, PMin the smallest listed probability and
	// Unlisted = max(0, 1 - Listed): the quantities the bounds are derived from (B3-01).
	Listed, PMin, Unlisted float64
}

// Flagged reports whether any option letter was absent from the readout.
func (r Readout) Flagged() bool { return len(r.Missing) > 0 }

// ExtractTopLogprobs returns the first-token top_logprobs list from a decoded chat-completions
// response. It accepts choices[0].logprobs.top_logprobs[0] (llama-server) and
// choices[0].logprobs.content[0].top_logprobs (OpenAI). Anything else is *BackendReadoutError.
func ExtractTopLogprobs(raw any) ([]any, error) {
	fail := &BackendReadoutError{Reason: "backend response carries no first-token top_logprobs"}
	first := func(v any) (any, bool) {
		l, ok := v.([]any)
		if !ok || len(l) == 0 {
			return nil, false
		}
		return l[0], true
	}
	doc, ok := raw.(map[string]any)
	if !ok {
		return nil, fail
	}
	choice, ok := first(doc["choices"])
	if !ok {
		return nil, fail
	}
	cm, ok := choice.(map[string]any)
	if !ok {
		return nil, fail
	}
	lp, ok := cm["logprobs"].(map[string]any)
	if !ok {
		return nil, fail
	}
	var top any
	if l, isList := lp["top_logprobs"].([]any); isList && len(l) > 0 {
		top = l[0]
	} else if tl := lp["top_logprobs"]; tl != nil && !isFalsy(tl) {
		return nil, fail // truthy but not a usable list
	} else {
		c, ok := first(lp["content"])
		if !ok {
			return nil, fail
		}
		cmm, ok := c.(map[string]any)
		if !ok {
			return nil, fail
		}
		top = cmm["top_logprobs"]
	}
	list, ok := top.([]any)
	if !ok || len(list) == 0 {
		return nil, &BackendReadoutError{Reason: "empty top_logprobs"}
	}
	return list, nil
}

func isFalsy(v any) bool {
	switch t := v.(type) {
	case nil:
		return true
	case bool:
		return !t
	case string:
		return t == ""
	case []any:
		return len(t) == 0
	case map[string]any:
		return len(t) == 0
	case float64:
		return t == 0
	}
	return false
}

// ExtractTopLogprobsJSON decodes a response body and extracts the first-token list; undecodable
// JSON is *BackendReadoutError.
func ExtractTopLogprobsJSON(body []byte) ([]any, error) {
	var raw any
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, &BackendReadoutError{Reason: "backend response is not JSON"}
	}
	return ExtractTopLogprobs(raw)
}

func letterOf(token string) string {
	t := token
	if r, n := utf8.DecodeRuneInString(t); n > 0 && (r == ' ' || r == '▁') {
		t = t[n:]
	}
	if len(t) == 1 && t[0] >= 'A' && t[0] <= 'Z' {
		return t
	}
	return ""
}

func asFloat(v any) (float64, bool) {
	switch t := v.(type) {
	case float64:
		return t, true
	case float32:
		return float64(t), true
	case int:
		return float64(t), true
	case int32:
		return float64(t), true
	case int64:
		return float64(t), true
	case json.Number:
		f, err := t.Float64()
		return f, err == nil
	}
	return 0, false
}

// Compute reads the option-letter distribution from typed first-token alternatives.
func Compute(top []Entry, letters []string, threshold, temperature float64) (*Readout, error) {
	raw := make([]any, len(top))
	for i, e := range top {
		m := map[string]any{"token": e.Token, "logprob": e.Logprob}
		if e.HasID {
			m["id"] = float64(e.ID)
		}
		raw[i] = m
	}
	return ComputeRaw(raw, letters, threshold, temperature)
}

// ComputeRaw is Compute over decoded JSON entries ({"token": string, "logprob": number}); the first
// problem in entry order decides the error class. letters must be 2+ distinct upper-case ASCII
// letters, threshold in (0,1], temperature finite and > 0 (else ErrBadArgument).
func ComputeRaw(top []any, letters []string, threshold, temperature float64) (*Readout, error) {
	return ComputeRawSpellings(top, letters, threshold, temperature, SpellingsPerLetter)
}

// ComputeRawSpellings is ComputeRaw with an explicit number of spelling tokens per option letter
// (s of the bound derivation above); spellings < 1 is ErrBadArgument.
func ComputeRawSpellings(top []any, letters []string, threshold, temperature float64, spellings int) (*Readout, error) {
	if spellings < 1 {
		return nil, fmt.Errorf("%w: spellings must be >= 1", ErrBadArgument)
	}
	seen := map[string]bool{}
	if len(letters) < 2 {
		return nil, fmt.Errorf("%w: letters must be 2+ distinct upper-case ASCII letters", ErrBadArgument)
	}
	for _, l := range letters {
		if len(l) != 1 || l[0] < 'A' || l[0] > 'Z' || seen[l] {
			return nil, fmt.Errorf("%w: letters must be 2+ distinct upper-case ASCII letters", ErrBadArgument)
		}
		seen[l] = true
	}
	if !(threshold > 0 && threshold <= 1) {
		return nil, fmt.Errorf("%w: threshold must be in (0, 1]", ErrBadArgument)
	}
	if math.IsNaN(temperature) || math.IsInf(temperature, 0) || temperature <= 0 {
		return nil, fmt.Errorf("%w: temperature must be finite and > 0", ErrBadArgument)
	}
	if len(top) == 0 {
		return nil, &BackendReadoutError{Reason: "top_logprobs must be a non-empty list"}
	}
	type row struct {
		tok string
		lp  float64
	}
	var rows []row
	byID := map[int]int{} // token id -> index in rows
	for _, el := range top {
		e, ok := el.(map[string]any)
		if !ok {
			return nil, &BackendReadoutError{Reason: "malformed top_logprobs entry"}
		}
		tok, tokOK := e["token"].(string)
		lpv, hasLP := e["logprob"]
		if !tokOK || !hasLP {
			return nil, &BackendReadoutError{Reason: "malformed top_logprobs entry"}
		}
		v, ok := asFloat(lpv)
		if !ok {
			return nil, &ReadoutFailed{Reason: "non-numeric logprob"}
		}
		if math.IsNaN(v) || math.IsInf(v, 1) || v > 1e-9 {
			return nil, &ReadoutFailed{Reason: "invalid logprob"}
		}
		if idv, has := e["id"]; has {
			if id, ok := asFloat(idv); ok && id == math.Trunc(id) {
				if at, seen := byID[int(id)]; seen {
					if v > rows[at].lp {
						rows[at].lp = v
					}
					continue
				}
				byID[int(id)] = len(rows)
			}
		}
		rows = append(rows, row{tok, v})
	}
	allNegInf := true
	for _, r := range rows {
		allNegInf = allNegInf && math.IsInf(r.lp, -1)
	}
	if allNegInf {
		return nil, &ReadoutFailed{Reason: "every logprob is -inf"}
	}
	massBy := map[string]float64{}
	var massOrder []string
	for _, r := range rows {
		l := letterOf(r.tok)
		if l == "" || !seen[l] {
			continue
		}
		if _, have := massBy[l]; !have {
			massOrder = append(massOrder, l)
		}
		massBy[l] += math.Exp(r.lp)
	}
	mass := 0.0
	for _, l := range massOrder {
		mass += massBy[l]
	}
	if mass < threshold {
		return nil, &ReadoutFailed{Reason: fmt.Sprintf("combined option-letter mass %.6f is below the threshold", mass), Mass: mass}
	}
	floor := math.Inf(1)
	listed := 0.0
	for _, r := range rows {
		if !math.IsInf(r.lp, -1) {
			listed += math.Exp(r.lp)
			if r.lp < floor {
				floor = r.lp
			}
		}
	}
	pmin := math.Exp(floor)
	unlisted := math.Max(0, 1-listed)
	if unlisted < UnlistedEpsilon { // float round-off of a fully listed distribution is not hidden mass
		unlisted = 0
	}
	// see the package comment: x_i <= min(s*p_min, U), sum x_i <= U
	bound := math.Min(float64(spellings)*pmin, unlisted)
	res := &Readout{Probabilities: map[string]float64{}, Mass: mass, UpperBounds: map[string]float64{}, NormalisedBounds: map[string]float64{},
		Listed: listed, PMin: pmin, Unlisted: unlisted}
	for _, l := range letters {
		if _, have := massBy[l]; !have {
			res.Missing = append(res.Missing, l)
			res.UpperBounds[l] = bound
		}
	}
	probs, err := distribution(letters, massBy, massOrder, temperature)
	if err != nil {
		return nil, &ReadoutFailed{Reason: "no positive option-letter mass", Mass: mass}
	}
	res.Probabilities = probs
	if len(res.Missing) == 0 {
		res.Conservative = copyMap(probs)
		return res, nil
	}
	withBounds := map[string]float64{}
	order := append([]string(nil), massOrder...)
	for _, l := range massOrder {
		withBounds[l] = massBy[l]
	}
	// the absent letters hold the worst-case allocation of their joint polytope (B3-01)
	caps := make([]float64, len(res.Missing))
	for i, l := range res.Missing {
		caps[i] = res.UpperBounds[l]
	}
	alloc := WorstAllocation(caps, unlisted, 1/temperature)
	for i, l := range res.Missing {
		withBounds[l] = alloc[i]
		order = append(order, l)
	}
	if res.Conservative, err = distribution(letters, withBounds, order, temperature); err != nil {
		return nil, &ReadoutFailed{Reason: "no positive option-letter mass", Mass: mass}
	}
	// the normalised bound of one absent letter: it holds its full raw bound, every other absent
	// letter nothing (the share is largest then)
	for _, l := range res.Missing {
		one := map[string]float64{}
		o1 := append([]string(nil), massOrder...)
		for _, k := range massOrder {
			one[k] = massBy[k]
		}
		one[l] = res.UpperBounds[l]
		o1 = append(o1, l)
		d, derr := distribution(letters, one, o1, temperature)
		if derr != nil {
			return nil, &ReadoutFailed{Reason: "no positive option-letter mass", Mass: mass}
		}
		nb := d[l]
		if c := res.Conservative[l]; nb < c { // numerically never, but the invariant is documented
			nb = c
		}
		res.NormalisedBounds[l] = nb
	}
	return res, nil
}

// WorstAllocation returns, for the caps x_i <= caps[i] and the joint limit sum x_i <= total, the
// allocation that MAXIMISES sum x_i^a (a = 1/T): the denominator of the temperature normalisation, so
// the share of any present letter is smallest there. For a <= 1 (concave) the optimum spreads the
// mass evenly up to the caps (water-filling); for a > 1 (convex) it fills the largest caps first.
// The result uses min(total, sum caps) of mass.
func WorstAllocation(caps []float64, total, a float64) []float64 {
	k := len(caps)
	out := make([]float64, k)
	idx := make([]int, k)
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(x, y int) bool { return caps[idx[x]] < caps[idx[y]] })
	remaining := math.Max(0, total)
	if a <= 1 {
		for n, i := range idx {
			share := remaining / float64(k-n)
			out[i] = math.Min(caps[i], share)
			remaining -= out[i]
		}
		return out
	}
	for n := k - 1; n >= 0; n-- {
		i := idx[n]
		out[i] = math.Min(caps[i], remaining)
		remaining -= out[i]
	}
	return out
}

func copyMap(m map[string]float64) map[string]float64 {
	out := make(map[string]float64, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// distribution is the temperature softmax over log(mass)/T of the letters that hold mass (plain
// renormalisation at T=1); letters without mass get 0. Overflow of log(m)/T falls back to the
// argmax one-hot (the limit distribution).
func distribution(letters []string, massBy map[string]float64, order []string, temperature float64) (map[string]float64, error) {
	out := map[string]float64{}
	logs := map[string]float64{}
	top1 := math.Inf(-1)
	var topLetter string
	for _, l := range order {
		if m := massBy[l]; m > 0 {
			x := math.Log(m) / temperature
			logs[l] = x
			if x > top1 || topLetter == "" {
				top1, topLetter = x, l
			}
		}
	}
	if len(logs) == 0 {
		return nil, errors.New("readout: no positive mass")
	}
	if math.IsInf(top1, 0) { // log(m)/T overflowed: the limit distribution is the argmax one-hot
		for _, l := range letters {
			out[l] = 0
		}
		out[argmaxMass(massBy, order)] = 1
		return out, nil
	}
	exps := map[string]float64{}
	z := 0.0
	for _, l := range order {
		if x, ok := logs[l]; ok {
			exps[l] = math.Exp(x - top1)
			z += exps[l]
		}
	}
	for _, l := range letters {
		if e, ok := exps[l]; ok {
			out[l] = e / z
		} else {
			out[l] = 0
		}
	}
	return out, nil
}

func argmaxMass(massBy map[string]float64, order []string) string {
	best := ""
	for _, l := range order {
		if best == "" || massBy[l] > massBy[best] {
			best = l
		}
	}
	return best
}
