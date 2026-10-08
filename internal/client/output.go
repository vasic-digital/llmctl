package client

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"strconv"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// answerView is the part of one answer the client inspects.
type answerView struct {
	Type          string             `json:"type"`
	Noul          *float64           `json:"noul"`
	Choice        string             `json:"choice"`
	Score         *float64           `json:"score"`
	Probabilities map[string]float64 `json:"probabilities"`
	Confidence    *float64           `json:"confidence"`
	ConfidenceRaw *float64           `json:"confidence_raw"`
	Calibration   json.RawMessage    `json:"calibration"`
	Flags         []string           `json:"flags"`
	UpperBounds   map[string]float64 `json:"upper_bounds"`
}

// Calibrated reports whether Confidence is a CALIBRATED probability: the gateway attached a
// calibration object ({method,n,profile_id}). The string "mixed" (a --permute run whose calls
// disagreed about the calibration) and a missing/null value are NOT calibrated.
func (a answerView) Calibrated() bool {
	t := bytes.TrimSpace(a.Calibration)
	return len(t) > 0 && t[0] == '{'
}

// Flagged reports an answer whose readout lacked an option (flags: option_missing).
func (a answerView) Flagged() bool { return len(a.Flags) > 0 }

// absent reports whether key names an option the engine did not list (it has an upper bound).
func (a answerView) absent(key string) bool { _, ok := a.UpperBounds[key]; return ok }

// AnyFlagged reports whether any answer in the response is flagged.
func AnyFlagged(body []byte) (bool, error) {
	_, as, err := Answers(body)
	if err != nil {
		return false, err
	}
	for _, a := range as {
		if a.Flagged() {
			return true, nil
		}
	}
	return false, nil
}

// responseView is the part of a response the client inspects.
type responseView struct {
	Model   string                     `json:"model"`
	Answers map[string]json.RawMessage `json:"answers"`
}

// Answers decodes the per-question answers of a response body.
func Answers(body []byte) (model string, answers map[string]answerView, err error) {
	var rv responseView
	if err := json.Unmarshal(body, &rv); err != nil {
		return "", nil, errors.New("the response is not a JSON object")
	}
	answers = map[string]answerView{}
	for name, raw := range rv.Answers {
		var a answerView
		if err := json.Unmarshal(raw, &a); err != nil {
			return "", nil, errors.New("an answer in the response is malformed")
		}
		answers[name] = a
	}
	return rv.Model, answers, nil
}

// AnswerConfidence is the confidence of one answer; a noul answer carries none on the wire, so
// it is derived with the same normalisation as the contract for two options.
//
// A FLAGGED answer (an option letter was absent from the engine's readout) arrives from the gateway
// as the WORST CASE of everything the absent options could hold (B3-01: the absent options sit at the
// allocation that leaves the winner the smallest share), and its winner is an option the engine
// LISTED. The confidence is therefore that of the best LISTED option's share; an absent option is
// never the winner of a gate (it was never measured). It is not additionally scaled by the upper
// bounds: they are already inside the shares, and doing it twice would refuse answers the true bound
// allows (a §11.4.201 false refusal).
func AnswerConfidence(a answerView) float64 {
	c := 0.0
	switch {
	case a.Type == contract.TypeNoul && a.Noul != nil:
		p := math.Max(*a.Noul, 1-*a.Noul)
		if a.Flagged() { // the winner must be the option the engine listed
			switch {
			case a.absent("yes") && !a.absent("no"):
				p = 1 - *a.Noul
			case a.absent("no") && !a.absent("yes"):
				p = *a.Noul
			default:
				p = 0
			}
		}
		c = math.Max(0, math.Min(1, (p-0.5)/0.5))
	case a.Confidence != nil:
		c = *a.Confidence
	}
	if a.Calibrated() && a.Type != contract.TypeNoul {
		// A calibrated confidence is a probability of being right (chance = 1/n, not 0) and the gateway
		// already caps a flagged answer at the winner's worst-case share, so the shaped-scale cap below
		// (a different scale) is not applied. An answer with no LISTED option still has no winner.
		if a.Flagged() {
			any := false
			for k := range a.Probabilities {
				any = any || !a.absent(k)
			}
			if !any {
				return 0
			}
		}
		return c
	}
	if a.Flagged() && a.Type != contract.TypeNoul {
		n := len(a.Probabilities)
		best, any := 0.0, false
		for k, p := range a.Probabilities {
			if !a.absent(k) && p > best {
				best = p
			}
			any = any || !a.absent(k)
		}
		if !any || n < 2 {
			return 0
		}
		cp := (best - 1/float64(n)) / (1 - 1/float64(n))
		c = math.Min(c, contract.Round9(math.Max(0, math.Min(1, cp))))
	}
	return c
}

// AnyCalibrated reports whether some answer of the response carries a calibration object, i.e. the
// abstention gate compared at least one calibrated confidence.
func AnyCalibrated(body []byte) (bool, error) {
	_, as, err := Answers(body)
	if err != nil {
		return false, err
	}
	for _, a := range as {
		if a.Calibrated() {
			return true, nil
		}
	}
	return false, nil
}

// MinConfidence returns the lowest answer confidence of a response (1 when there are none).
func MinConfidence(body []byte) (float64, error) {
	_, as, err := Answers(body)
	if err != nil {
		return 0, err
	}
	min := 1.0
	for _, a := range as {
		if c := AnswerConfidence(a); c < min {
			min = c
		}
	}
	return min, nil
}

// Annotation is what the client adds to the gateway's JSON object.
type Annotation struct {
	Profile    string
	Port       int
	Latency    float64 // milliseconds, real (not quantised)
	Truncated  bool
	Abstained  *bool         // nil = the field is omitted
	Mode       string        // gateway serving mode (x-llmctl-decide-mode); "" = omitted
	Instance   string        // engine instance that answered (x-llmctl-decide-instance); "" = omitted
	Calibrated bool          // the abstention gate read at least one calibrated confidence
	Flagged    bool          // some answer carries flags (an absent option letter)
	Permute    *PermuteStats // --permute run; nil = omitted
}

// Annotate appends "evidence" (and "abstained") to the response object without touching the
// gateway's own bytes, so field order and number formatting are preserved.
func Annotate(body []byte, a Annotation) ([]byte, error) {
	t := bytes.TrimSpace(body)
	if len(t) < 2 || t[0] != '{' || t[len(t)-1] != '}' {
		return nil, errors.New("the response is not a JSON object")
	}
	var b bytes.Buffer
	b.Write(bytes.TrimRight(t[:len(t)-1], " \t\r\n"))
	if len(bytes.TrimSpace(t[1:len(t)-1])) > 0 {
		b.WriteByte(',')
	}
	b.WriteString(`"evidence":{"profile":`)
	b.Write(jstr(a.Profile))
	b.WriteString(`,"port":` + strconv.Itoa(a.Port))
	b.WriteString(`,"latency_ms":` + strconv.FormatFloat(math.Round(a.Latency*1000)/1000, 'f', -1, 64))
	if a.Truncated {
		b.WriteString(`,"truncated":true`)
	}
	if a.Mode != "" {
		b.Write([]byte(`,"mode":`))
		b.Write(jstr(a.Mode))
	}
	if a.Instance != "" {
		b.Write([]byte(`,"instance":`))
		b.Write(jstr(a.Instance))
	}
	b.WriteString(`,"calibrated":` + strconv.FormatBool(a.Calibrated))
	if a.Flagged {
		b.WriteString(`,"flagged":true`)
	}
	if a.Permute != nil {
		b.WriteString(`,"permute":{"k":` + strconv.Itoa(a.Permute.K) + `,"flip_rate":` + strconv.FormatFloat(math.Round(a.Permute.FlipRate*1e6)/1e6, 'f', -1, 64) + `}`)
	}
	b.WriteByte('}')
	if a.Abstained != nil {
		b.WriteString(`,"abstained":` + strconv.FormatBool(*a.Abstained))
	}
	b.WriteByte('}')
	if !json.Valid(b.Bytes()) {
		return nil, errors.New("internal error: annotated response is not JSON")
	}
	return b.Bytes(), nil
}
