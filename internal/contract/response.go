package contract

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"strconv"
)

// Probability is one option's probability, keyed as the answer reports it.
type Probability struct {
	Key   string
	Value float64
}

// Answer is a typed answer for one question. The JSON form follows the openapi schema:
//
//	noul:   {"type","noul"}                                   (no confidence field)
//	choice: {"type","choice","probabilities","confidence"}
//	score:  {"type","score","legend","probabilities","confidence"}
//
// probabilities are emitted in option order.
type Answer struct {
	Type          string
	Noul          float64
	Choice        string
	Score         float64
	Legend        []LegendEntry
	Probabilities []Probability
	Confidence    float64
	// Flags and UpperBounds are the additive honesty fields of an answer whose readout lacked an
	// option (review-2 B-01, FR-076): Flags is a subset of {FlagOptionMissing} and UpperBounds names,
	// in option order, the highest probability each absent option could have had. Both are omitted
	// on a complete readout, so an unflagged answer is byte-identical to the original shape.
	Flags       []string
	UpperBounds []Probability
	// Calibration is set only when a calibration profile bound to the live model and prompt template
	// replaced Confidence (T137, FR-080): Confidence then holds the calibrated probability that the
	// answer is correct and ConfidenceRaw the unchanged shaped confidence, so a client can audit the
	// replacement. Both are omitted on an uncalibrated answer, which keeps the original shape.
	Calibration   *Calibration
	ConfidenceRaw float64
	// Maturity is "experimental" when the profile has not measured this question TYPE above its baseline
	// (T138, OD-24; "" = the field is omitted, so a measured answer keeps the original shape byte for byte).
	Maturity string
}

// Calibration names the calibration profile that produced a calibrated confidence.
type Calibration struct {
	Method    string // temperature | platt | isotonic
	N         int    // labelled answers the profile was fitted on
	ProfileID string // the calibration profile's name (its file <name>.json)
}

// FlagOptionMissing marks an answer whose engine readout did not list every option letter. The
// probabilities of such an answer are conservative: an absent option holds its upper bound as mass
// before renormalising, so the answer never claims certainty the readout did not support.
const FlagOptionMissing = "option_missing"

// NamedAnswer pairs an answer with its question name (answers are emitted in question order).
type NamedAnswer struct {
	Name   string
	Answer Answer
}

// Usage is the usage block of a response.
type Usage struct {
	InputTokens  int `json:"input_tokens"`
	OutputTokens int `json:"output_tokens"`
}

// Response is the /v1/systemone response body.
type Response struct {
	Model   string
	Answers []NamedAnswer
	Usage   Usage
}

// Round9 rounds to Precision decimals, correctly (round-half-even on the exact binary value, like
// Python's round(x, 9)).
func Round9(x float64) float64 {
	r, _ := strconv.ParseFloat(strconv.FormatFloat(x, 'f', Precision, 64), 64)
	return r
}

func checkProbs(probs []float64, n int) ([]float64, error) {
	if len(probs) != n {
		return nil, errors.New("contract: wrong number of probabilities")
	}
	out := make([]float64, n)
	sum := 0.0
	for i, p := range probs {
		if math.IsNaN(p) || math.IsInf(p, 0) || p < 0 || p > 1+1e-9 {
			return nil, errors.New("contract: invalid probability")
		}
		out[i] = math.Min(p, 1)
		sum += out[i]
	}
	if math.Abs(sum-1) > SumTolerance {
		return nil, errors.New("contract: probabilities do not sum to 1")
	}
	return out, nil
}

func confidence(pmax float64, n int) float64 {
	c := (pmax - 1/float64(n)) / (1 - 1/float64(n))
	return Round9(math.Max(0, math.Min(1, c)))
}

// BuildAnswer builds the typed answer from per-option probabilities in option order. The
// probabilities must be finite, within [0,1+1e-9] and sum to 1 within SumTolerance; they are
// reported rounded to Precision decimals. Confidence is a shaping convention, not a calibrated
// probability of correctness (FR-015).
func BuildAnswer(q ParsedQuestion, probs []float64) (Answer, error) {
	return buildAnswer(q, probs, nil)
}

// buildAnswer is BuildAnswer; bounded names the options the readout only bounded (never listed): on
// an exact tie an option the readout listed wins over a bounded one (B2-03).
func buildAnswer(q ParsedQuestion, probs []float64, bounded map[string]float64) (Answer, error) {
	n := len(q.Options)
	if n == 0 {
		return Answer{}, errors.New("contract: question has no options")
	}
	p, err := checkProbs(probs, n)
	if err != nil {
		return Answer{}, err
	}
	r := make([]float64, n)
	for i, x := range p {
		r[i] = Round9(x)
	}
	if q.Type == TypeNoul {
		return Answer{Type: TypeNoul, Noul: r[0]}, nil
	}
	// The winner is chosen among the options the readout LISTED: a bounded (never listed) option holds
	// worst-case mass, never a measurement, so it cannot be the answer (B2-03, B3-01). The first
	// listed option wins an exact tie.
	best := -1
	for i, x := range p {
		if _, bnd := bounded[q.Options[i].Key]; bnd {
			continue
		}
		if best < 0 || x > p[best] {
			best = i
		}
	}
	if best < 0 { // every option bounded: not a readout (BuildAnswerBounded refuses it)
		return Answer{}, errors.New("contract: no listed option")
	}
	a := Answer{Type: q.Type, Confidence: confidence(p[best], n)}
	for i, o := range q.Options {
		a.Probabilities = append(a.Probabilities, Probability{o.Key, r[i]})
	}
	if q.Type == TypeChoice {
		a.Choice = q.Options[best].Key
		return a, nil
	}
	s := 0.0
	for i, x := range p {
		s += float64(i) * x
	}
	a.Score = Round9(s)
	a.Legend = append([]LegendEntry(nil), q.Legend...)
	return a, nil
}

// BuildAnswerBounded is BuildAnswer for a readout in which some options were absent. bounds maps an
// absent option's key to the upper bound of its probability; the answer is flagged FlagOptionMissing
// and carries the bounds (in option order). probs must already be the conservative distribution.
func BuildAnswerBounded(q ParsedQuestion, probs []float64, bounds map[string]float64) (Answer, error) {
	a, err := buildAnswer(q, probs, bounds)
	if err != nil || len(bounds) == 0 {
		return a, err
	}
	known := map[string]bool{}
	for _, o := range q.Options {
		known[o.Key] = true
	}
	for k, v := range bounds {
		if !known[k] || math.IsNaN(v) || math.IsInf(v, 0) || v < 0 || v > 1 {
			return Answer{}, errors.New("contract: invalid upper bound")
		}
	}
	a.Flags = []string{FlagOptionMissing}
	for _, o := range q.Options {
		if v, ok := bounds[o.Key]; ok {
			a.UpperBounds = append(a.UpperBounds, Probability{o.Key, Round9(v)})
		}
	}
	return a, nil
}

// EstimateTokens is about characters/4 (an estimate, labelled as such in the contract).
func EstimateTokens(chars int) (int, error) {
	if chars < 0 {
		return 0, errors.New("contract: chars must be >= 0")
	}
	return (chars + 3) / 4, nil
}

// BuildResponse assembles the response envelope.
func BuildResponse(servedModel string, answers []NamedAnswer, inputTokens, outputTokens int) (Response, error) {
	if servedModel == "" {
		return Response{}, errors.New("contract: model must be the served model id")
	}
	if inputTokens < 0 || outputTokens < 0 {
		return Response{}, errors.New("contract: token counts must be non-negative")
	}
	return Response{Model: servedModel, Answers: append([]NamedAnswer(nil), answers...), Usage: Usage{inputTokens, outputTokens}}, nil
}

func jsonString(b *bytes.Buffer, s string) {
	e, _ := json.Marshal(s)
	b.Write(e)
}

func jsonFloat(b *bytes.Buffer, f float64) {
	e, _ := json.Marshal(f)
	b.Write(e)
}

func (a Answer) writeTo(b *bytes.Buffer) {
	b.WriteString(`{"type":`)
	jsonString(b, a.Type)
	switch a.Type {
	case TypeNoul:
		b.WriteString(`,"noul":`)
		jsonFloat(b, a.Noul)
	case TypeChoice:
		b.WriteString(`,"choice":`)
		jsonString(b, a.Choice)
	default:
		b.WriteString(`,"score":`)
		jsonFloat(b, a.Score)
		b.WriteString(`,"legend":{`)
		for i, l := range a.Legend {
			if i > 0 {
				b.WriteByte(',')
			}
			jsonString(b, l.Key)
			b.WriteByte(':')
			b.Write(l.Value)
		}
		b.WriteByte('}')
	}
	if a.Type != TypeNoul {
		b.WriteString(`,"probabilities":{`)
		for i, p := range a.Probabilities {
			if i > 0 {
				b.WriteByte(',')
			}
			jsonString(b, p.Key)
			b.WriteByte(':')
			jsonFloat(b, p.Value)
		}
		b.WriteString(`},"confidence":`)
		jsonFloat(b, a.Confidence)
		if a.Calibration != nil {
			b.WriteString(`,"confidence_raw":`)
			jsonFloat(b, a.ConfidenceRaw)
			b.WriteString(`,"calibration":{"method":`)
			jsonString(b, a.Calibration.Method)
			b.WriteString(`,"n":` + strconv.Itoa(a.Calibration.N) + `,"profile_id":`)
			jsonString(b, a.Calibration.ProfileID)
			b.WriteByte('}')
		}
	}
	if len(a.Flags) > 0 {
		b.WriteString(`,"flags":[`)
		for i, f := range a.Flags {
			if i > 0 {
				b.WriteByte(',')
			}
			jsonString(b, f)
		}
		b.WriteString(`],"upper_bounds":{`)
		for i, p := range a.UpperBounds {
			if i > 0 {
				b.WriteByte(',')
			}
			jsonString(b, p.Key)
			b.WriteByte(':')
			jsonFloat(b, p.Value)
		}
		b.WriteByte('}')
	}
	if a.Maturity != "" {
		b.WriteString(`,"maturity":`)
		jsonString(b, a.Maturity)
	}
	b.WriteByte('}')
}

// MarshalJSON emits the answer in the documented field order.
func (a Answer) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	a.writeTo(&b)
	return b.Bytes(), nil
}

// MarshalJSON emits {"model","answers","usage"} with answers in question order.
func (r Response) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteString(`{"model":`)
	jsonString(&b, r.Model)
	b.WriteString(`,"answers":{`)
	for i, na := range r.Answers {
		if i > 0 {
			b.WriteByte(',')
		}
		jsonString(&b, na.Name)
		b.WriteByte(':')
		na.Answer.writeTo(&b)
	}
	b.WriteString(`},"usage":{"input_tokens":` + strconv.Itoa(r.Usage.InputTokens) + `,"output_tokens":` + strconv.Itoa(r.Usage.OutputTokens) + `}}`)
	return b.Bytes(), nil
}
