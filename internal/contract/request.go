package contract

import (
	"encoding/json"
	"errors"
	"unicode/utf8"
)

// Option is one answer option of a question.
type Option struct {
	Letter string // "A".."Z"; "" when the option index exceeds the 26 renderable letters
	Key    string // the key the answer reports (yes/no, the criteria key, or the level index)
	Label  string // the text rendered after the letter
}

// LegendEntry is one score level's description, echoed in the answer exactly as given.
type LegendEntry struct {
	Key   string          // "0".."9"
	Value json.RawMessage // the original JSON value (original key order, null kept)
}

// ParsedQuestion is a validated question. The name only keys the answer; it is never rendered.
type ParsedQuestion struct {
	Name         string
	Type         string // noul | choice | score
	Instructions string
	Options      []Option
	Legend       []LegendEntry // score questions only
}

// ParsedRequest is a validated /v1/systemone body.
type ParsedRequest struct {
	Model     string // the SERVED profile id, never the request's string
	StateText string // possibly shortened (see Truncated)
	Truncated bool   // the opt-in shortening was applied (report x-llmctl-decide-truncated: true)
	Questions []ParsedQuestion
}

// QuestionChars is what a question contributes to the budget: instructions plus every option
// label, counted in code points.
func QuestionChars(q ParsedQuestion) int {
	n := utf8.RuneCountInString(q.Instructions)
	for _, o := range q.Options {
		n += utf8.RuneCountInString(o.Label)
	}
	return n
}

func letter(i int) string {
	if i < 26 {
		return string(rune('A' + i))
	}
	return ""
}

func parseQuestion(name string, qv *value, lim Limits) (ParsedQuestion, error) {
	if name == "" || qv.kind != vObject {
		return ParsedQuestion{}, errInvalid("Request failed validation.")
	}
	bad := errInvalid("Request failed validation.")
	for _, m := range qv.obj {
		if m.key != "type" && m.key != "instructions" && m.key != "criteria" {
			return ParsedQuestion{}, bad
		}
	}
	tv, _ := qv.get("type")
	if tv == nil || tv.kind != vString || (tv.s != TypeNoul && tv.s != TypeChoice && tv.s != TypeScore) {
		return ParsedQuestion{}, bad
	}
	ins, _ := qv.get("instructions")
	if !isDesc(ins) {
		return ParsedQuestion{}, bad
	}
	crit, _ := qv.get("criteria")
	if crit != nil && crit.kind == vNull {
		crit = nil
	}
	q := ParsedQuestion{Name: name, Type: tv.s, Instructions: ins.text()}
	switch q.Type {
	case TypeNoul:
		descs := map[string]string{}
		if crit != nil {
			if crit.kind != vObject {
				return q, bad
			}
			for _, m := range crit.obj {
				if m.key != "true" && m.key != "false" {
					return q, bad
				}
				if m.val.kind != vNull && m.val.kind != vString {
					return q, bad
				}
				descs[m.key] = m.val.text()
			}
		}
		for i, kf := range [][2]string{{"yes", "true"}, {"no", "false"}} {
			label := kf[0]
			if d := descs[kf[1]]; d != "" {
				label += " - " + d
			}
			q.Options = append(q.Options, Option{letter(i), kf[0], label})
		}
	case TypeChoice:
		if crit == nil || crit.kind != vObject {
			return q, bad
		}
		if len(crit.obj) > HostedMaxOptions {
			return q, errBadRequest("Too many options.")
		}
		if len(crit.obj) < 2 || len(crit.obj) > lim.MaxOptions {
			return q, bad
		}
		for i, m := range crit.obj {
			if m.key == "" || !isDesc(m.val) {
				return q, bad
			}
			label := m.key
			if d := m.val.text(); d != "" {
				label = m.key + " - " + d
			}
			q.Options = append(q.Options, Option{letter(i), m.key, label})
		}
	default: // score
		if crit == nil || crit.kind != vArray || len(crit.arr) < lim.MinScale || len(crit.arr) > lim.MaxScale {
			return q, bad
		}
		for i, d := range crit.arr {
			if !isDesc(d) {
				return q, bad
			}
			key := itoa(i)
			label := d.text()
			if label == "" {
				label = "level " + key
			}
			q.Options = append(q.Options, Option{letter(i), key, label})
			q.Legend = append(q.Legend, LegendEntry{Key: key, Value: json.RawMessage(d.raw())})
		}
	}
	return q, nil
}

func itoa(i int) string { return string(appendInt(nil, i)) }

func appendInt(b []byte, i int) []byte {
	if i >= 10 {
		b = appendInt(b, i/10)
	}
	return append(b, byte('0'+i%10))
}

// ParseRequest validates a /v1/systemone body. Errors are *ContractError (400 / 422) except for
// programming errors (invalid limits, nil profiles), which are plain errors. 413 is CheckBodySize.
func ParseRequest(body []byte, limits Limits, profiles *Profiles) (*ParsedRequest, error) {
	if profiles == nil {
		return nil, errors.New("contract: nil profiles")
	}
	if err := limits.Validate(); err != nil {
		return nil, err
	}
	doc, err := parseJSON(body)
	if err != nil {
		return nil, errBadRequest("Request body is not valid JSON.")
	}
	if doc.kind != vObject {
		return nil, errBadRequest("Request body must be a JSON object.")
	}
	for _, m := range doc.obj {
		if m.key != "model" && m.key != "state" && m.key != "questions" {
			return nil, errInvalid("Request failed validation.")
		}
	}
	state, hasState := doc.get("state")
	questions, hasQs := doc.get("questions")
	if !hasState || !hasQs {
		return nil, errInvalid("Request failed validation.")
	}
	if state.kind != vString && state.kind != vObject && state.kind != vArray {
		return nil, errInvalid("state must be text, an object or an array.")
	}
	served := profiles.Default()
	if mv, ok := doc.get("model"); ok {
		if served, err = profiles.Resolve(mv.toAny()); err != nil {
			return nil, err
		}
	}
	lim := profiles.LimitsFor(served, limits)
	if questions.kind != vObject || len(questions.obj) < 1 || len(questions.obj) > lim.MaxQuestions {
		return nil, errInvalid("Request failed validation.")
	}
	parsed := make([]ParsedQuestion, 0, len(questions.obj))
	longest := 0
	for _, m := range questions.obj {
		q, err := parseQuestion(m.key, m.val, lim)
		if err != nil {
			return nil, err
		}
		if n := QuestionChars(q); n > longest {
			longest = n
		}
		parsed = append(parsed, q)
	}
	stateText := state.text()
	truncated := false
	rs := []rune(stateText)
	charOver := len(rs)+longest > lim.MaxStateChars
	budgeted := lim.MaxPromptTokens > 0
	if budgeted && lim.PairMode {
		// the hypothesis is never shortened: it has to fit the window with room for a premise
		for _, q := range parsed {
			if hypothesisTokens(q)+MinPremiseTokens > lim.MaxPromptTokens {
				return nil, errInvalid("Question alone exceeds the budget.")
			}
		}
	}
	// A pair profile's premise is shortened by the encoder runtime (reported per pair), so with the
	// opt-in truncation only the hypothesis constrains the request; without it the premise must fit.
	tokenFits := func(st string) bool {
		if !budgeted || (lim.PairMode && lim.Truncate) {
			return true
		}
		return worstPromptTokens(parsed, st, lim) <= lim.MaxPromptTokens
	}
	if charOver || !tokenFits(stateText) {
		if !lim.Truncate {
			return nil, errInvalid("State plus question exceeds the budget.")
		}
		keep := len(rs) - 1
		if charOver {
			keep = lim.MaxStateChars - longest - utf8.RuneCountInString(TruncationMarker)
		}
		if keep < 2 || !tokenFits(shorten(rs, 2)) {
			return nil, errInvalid("Question alone exceeds the budget.")
		}
		if !tokenFits(shorten(rs, keep)) { // largest keep that fits the token budget
			lo, hi := 2, keep // fits(lo) holds, fits(hi) does not
			for hi-lo > 1 {
				if mid := (lo + hi) / 2; tokenFits(shorten(rs, mid)) {
					lo = mid
				} else {
					hi = mid
				}
			}
			keep = lo
		}
		stateText = shorten(rs, keep)
		truncated = true
	}
	return &ParsedRequest{Model: served, StateText: stateText, Truncated: truncated, Questions: parsed}, nil
}

// shorten keeps keep runes of the state around the truncation marker: the head gets the larger half.
// The cut never lands inside a grapheme cluster (a base character with its combining marks, a ZWJ
// emoji sequence, a regional-indicator flag): the head is pulled back and the tail pushed forward to
// the nearest cluster boundary, so a kept piece is never a malformed glyph next to the marker. The
// result is therefore at most keep runes.
func shorten(r []rune, keep int) string {
	tail := keep / 2
	head := keep - tail
	for head > 0 && !clusterBoundary(r, head) {
		head--
	}
	t := len(r) - tail
	for t < len(r) && !clusterBoundary(r, t) {
		t++
	}
	return string(r[:head]) + TruncationMarker + string(r[t:])
}

// clusterBoundary reports whether a grapheme cluster may start at r[i] (0 and len(r) always can).
func clusterBoundary(r []rune, i int) bool {
	if i <= 0 || i >= len(r) {
		return true
	}
	if isExtender(r[i]) || r[i-1] == 0x200d {
		return false
	}
	if isRegionalIndicator(r[i]) && isRegionalIndicator(r[i-1]) {
		n := 0 // regional indicators pair up from the start of their run
		for j := i - 1; j >= 0 && isRegionalIndicator(r[j]); j-- {
			n++
		}
		return n%2 == 0
	}
	return true
}

func isRegionalIndicator(r rune) bool { return r >= 0x1f1e6 && r <= 0x1f1ff }
