package contract

import (
	"strings"
	"unicode/utf8"
)

// Token budgeting (review-2 B-02).
//
// A decoder engine rejects a prompt that does not fit its per-request context window with a
// deterministic HTTP 400, which used to surface as the retryable 502. The gateway therefore checks,
// BEFORE any engine is contacted, that the rendered prompt fits the window the serving instance
// really has. The check is in tokens, not code points: the code-point budget (MaxStateChars) says
// nothing about a context of a few thousand tokens, and tokens-per-character varies by 30x across
// scripts (0.03 for runs of newlines, 0.2 for English prose, 1.0 for digits, ~3 for rare astral
// code points).
//
// No tokenizer is linked in (the gateway must not depend on a model file), so the estimate is a
// per-rune cost table measured against the real llama-server /tokenize endpoint
// (specs/009-jev-decision-models/evidence/review-2/ctx-measurements.json; the test
// TestEstimatorCoversMeasuredClasses keeps the table at or above every measured class). Costs are in
// hundredths of a token per rune and are deliberately above the measured values for natural text,
// so an accepted request fits. What a table cannot know (an unusual tokenizer, adversarial rare
// code points beyond the classes below) is caught by the second layer: the engine's own
// exceed_context_size_error answer is mapped to the same 422 by the gateway driver.
const (
	// TemplateOverheadTokens is reserved for the chat template wrapped around the prompt (measured 30
	// on the ChatML template with its default system prompt; templates this table cannot measure get
	// the margin).
	TemplateOverheadTokens = 128
	// ReplyReserveTokens is the generated reply: one token (max_tokens 1).
	ReplyReserveTokens = 1
	// PairSpecialTokens covers [CLS] premise [SEP] hypothesis [SEP] plus a margin.
	PairSpecialTokens = 4
	// MinPremiseTokens is the least premise room an encoder pair must keep when truncation is on.
	MinPremiseTokens = 8
	// maxRunNormal is the longest ASCII letter/digit run still priced as words; a longer unbroken run
	// is identifiers, hashes, base64 or letter soup and is priced as high-entropy text.
	maxRunNormal = 12
)

// PromptTokenBudget is the estimated-token budget of a rendered prompt for an engine whose
// per-request context is ctx tokens; 0 (unknown) disables the check.
func PromptTokenBudget(ctx int) int {
	if ctx <= 0 {
		return 0
	}
	if b := ctx - TemplateOverheadTokens - ReplyReserveTokens; b > 1 {
		return b
	}
	return 1
}

func isASCIIAlnum(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')
}

// runeCost is the cost in hundredths of a token of one rune outside a long alphanumeric run.
func runeCost(r rune) int {
	switch {
	case r >= '0' && r <= '9':
		return 100
	case (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z'):
		return 40
	case r == ' ' || r == '\n' || r == '\t' || r == '\r':
		return 15
	case r < 0x80:
		return 80
	case r >= 0x0300 && r <= 0x036f: // combining marks: ~1.75 tokens each measured
		return 200
	case r <= 0x07ff: // Latin-1/Extended, Greek, Cyrillic, Hebrew, Arabic
		return 60
	case r <= 0x0fff: // Indic, Thai, Lao, Tibetan (Devanagari measured ~1.27 per character)
		return 150
	case r >= 0x2000 && r <= 0x206f: // general punctuation, ZWJ/ZWNJ
		return 100
	case r >= 0xe000 && r <= 0xf8ff: // BMP private use: measured 2.976 tokens/char (B2-13)
		return 300
	case r >= 0x3400 && r <= 0x4dbf: // CJK extension A: rare ideographs, measured ~1.6 tokens/char (B2-13)
		return 160
	case r >= 0x2e80 && r <= 0xd7af: // CJK, kana, Hangul, CJK punctuation
		// LIMIT (B2-13): the unified block U+4E00-9FFF mixes common ideographs (measured 0.61
		// tokens/char) with rare ones (a single rare ideograph measured 1.595); pricing the whole
		// block at 1.6 would refuse ordinary Chinese/Japanese text the engine serves, so the rare tail
		// of that block is NOT covered by layer 1 - the engine's own overflow answer (layer 2, 422)
		// bounds it. Hangul is unmeasured. All measurements come from ONE tokenizer (Qwen2.5, Debian
		// llama-server 8681); re-measure on the pinned build per decide model (open gap).
		return 100
	case r > 0xffff: // astral: emoji (1.0) up to rare ideographs / private use (~3.0)
		return 300
	default: // everything else in the BMP: symbols, variation selectors, PUA, forms
		return 160
	}
}

// EstimateTextTokens estimates how many tokens a string costs an engine (see the package notes).
func EstimateTextTokens(s string) int {
	total, run := 0, 0
	flush := func(end int) { // price the alphanumeric run s[end-run:end]
		if run == 0 {
			return
		}
		seg := s[end-run : end]
		if run <= maxRunNormal {
			for i := 0; i < len(seg); i++ {
				total += runeCost(rune(seg[i]))
			}
		} else {
			for i := 0; i < len(seg); i++ {
				if seg[i] >= '0' && seg[i] <= '9' {
					total += 100
				} else {
					total += 80
				}
			}
		}
		run = 0
	}
	for i, r := range s {
		if isASCIIAlnum(r) {
			run++
			continue
		}
		flush(i)
		total += runeCost(r)
	}
	flush(len(s))
	return (total + 99) / 100
}

// promptTokens is the estimated token cost of one question's prompt for the profile's mode.
func promptTokens(q ParsedQuestion, state string, lim Limits) int {
	if lim.PairMode {
		// pair: premise + hypothesis (instructions followed by the option label), worst option
		worstHyp := 0
		for _, o := range q.Options {
			h := o.Label
			if q.Instructions != "" {
				h = q.Instructions + " " + o.Label
			}
			if n := EstimateTextTokens(OneLine(h)); n > worstHyp {
				worstHyp = n
			}
		}
		return EstimateTextTokens(state) + worstHyp + PairSpecialTokens
	}
	p, err := RenderPrompt(q, state)
	if err != nil { // more than 26 options cannot be rendered: no letter prompt to bound
		return 0
	}
	return EstimateTextTokens(p)
}

// hypothesisTokens is the pair-mode window the hypothesis alone needs (worst option).
func hypothesisTokens(q ParsedQuestion) int {
	return promptTokens(q, "", Limits{PairMode: true})
}

// worstPromptTokens is the largest prompt estimate over the questions.
func worstPromptTokens(qs []ParsedQuestion, state string, lim Limits) int {
	worst := 0
	for _, q := range qs {
		if n := promptTokens(q, state, lim); n > worst {
			worst = n
		}
	}
	return worst
}

// minimalFixedTokens is the prompt cost around an empty state for a minimal question.
func minimalFixedTokens() int {
	q := ParsedQuestion{Name: "q", Type: TypeNoul, Instructions: "i",
		Options: []Option{{"A", "yes", "yes"}, {"B", "no", "no"}}}
	p, _ := RenderPrompt(q, "")
	return EstimateTextTokens(p)
}

// EffectiveStateChars is the number of characters of ordinary prose (cost 0.40 token per character,
// above the measured 0.2) a state may have under this limit: the character cap, lowered to what the
// token budget can hold. The advertised value of /v1/models; the token estimate stays the authority
// (JSON, digits and non-Latin scripts take more tokens per character).
func (l Limits) EffectiveStateChars() int {
	if l.MaxPromptTokens <= 0 {
		return l.MaxStateChars
	}
	room := l.MaxPromptTokens
	if !l.PairMode {
		room -= minimalFixedTokens()
	} else {
		room -= PairSpecialTokens + MinPremiseTokens
	}
	if room < 0 {
		room = 0
	}
	if byTokens := room * 100 / 40; byTokens < l.MaxStateChars {
		return byTokens
	}
	return l.MaxStateChars
}

// ---- text hygiene -----------------------------------------------------------------------------

// isHiddenControl reports a rune that has no business in a prompt: NUL and the C0/C1 controls (the
// ones that are line separators are handled separately), DEL, and the invisible bidirectional /
// formatting characters that can reorder or hide text (U+00AD, U+061C, U+200B, U+200E/F,
// U+202A-E, U+2060-2064, U+2066-9, U+FEFF, U+FFF9-B). ZWJ/ZWNJ are kept: scripts and emoji sequences need them,
// and so is U+180E (the Mongolian vowel separator is part of Mongolian spelling; it is invisible only
// for the structural MATCH fold in prompt.go, never removed from content, B3-02).
func isHiddenControl(r rune) bool {
	switch {
	case r == '\t':
		return false
	case r < 0x20, r == 0x7f:
		return !isLineSep(r)
	case r >= 0x80 && r <= 0x9f:
		return r != 0x85
	case r == 0x00ad, r == 0x061c, r == 0xfeff, r == 0x200b, r == 0x200e, r == 0x200f,
		r >= 0xfff9 && r <= 0xfffb,
		r >= 0x202a && r <= 0x202e, r >= 0x2060 && r <= 0x2064, r >= 0x2066 && r <= 0x2069:
		return true
	}
	return false
}

// isLineSep is every rune Python's str.splitlines() breaks on.
func isLineSep(r rune) bool {
	switch r {
	case '\n', '\r', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
		return true
	}
	return false
}

// CleanText removes the hidden controls and bidi characters (line separators are kept).
func CleanText(s string) string { return cleanText(s) }

// cleanText removes hidden controls; line separators are kept (callers decide what to do with them).
func cleanText(s string) string {
	need := false
	for _, r := range s {
		if isHiddenControl(r) {
			need = true
			break
		}
	}
	if !need {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		if !isHiddenControl(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// OneLine makes text safe for a single prompt line: hidden controls are removed and every line
// separator becomes one space, so a key, label or description can never start a new line of the
// prompt (it cannot forge an option, a question or an answer line).
func OneLine(s string) string {
	s = cleanText(s)
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		i += n
		if r == '\r' && i < len(s) && s[i] == '\n' {
			i++
		}
		if isLineSep(r) {
			b.WriteByte(' ')
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}

// isExtender reports a rune that continues the previous grapheme cluster: combining marks, ZWJ and
// ZWNJ, variation selectors, emoji skin-tone modifiers and tag characters.
func isExtender(r rune) bool {
	switch {
	case r == 0x200c, r == 0x200d:
		return true
	case r >= 0x0300 && r <= 0x036f, r >= 0x1ab0 && r <= 0x1aff, r >= 0x1dc0 && r <= 0x1dff,
		r >= 0x20d0 && r <= 0x20ff, r >= 0xfe00 && r <= 0xfe0f, r >= 0xfe20 && r <= 0xfe2f,
		r >= 0x1f3fb && r <= 0x1f3ff, r >= 0xe0020 && r <= 0xe007f, r >= 0xe0100 && r <= 0xe01ef:
		return true
	}
	return false
}
