package client

import (
	"context"
	"encoding/json"
	"math"
	"strconv"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// QuestionProbe is the order-sensitivity measurement of one question.
type QuestionProbe struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	Options    int    `json:"options,omitempty"`
	Permutable bool   `json:"permutable"`
	Reason     string `json:"reason,omitempty"` // why a question was not probed

	Orders       int  `json:"orders"`                  // option orders averaged (a whole number of cycles of this question's option count)
	PartialCycle bool `json:"partial_cycle,omitempty"` // fewer orders than options: position bias is only partly cancelled

	Answer    string  `json:"answer,omitempty"` // the order-averaged answer
	Flips     int     `json:"flips"`            // orders whose own answer clearly differed from the averaged one
	FlipRate  float64 `json:"flip_rate"`
	Unanimous bool    `json:"unanimous"`

	// PositionShare[p] is the share of orders whose own answer sat at LISTING position p; with no
	// position bias and a whole number of cycles the content moves through every position, so a
	// share far from PositionExpected (1/options) is positional bias.
	PositionShare        []float64 `json:"position_share,omitempty"`
	PositionExpected     float64   `json:"position_expected,omitempty"`
	MaxPositionDeviation float64   `json:"max_position_deviation,omitempty"`
}

// ProbeSummary pools the permutable questions.
type ProbeSummary struct {
	Questions            int     `json:"permutable_questions"`
	Trials               int     `json:"trials"` // (question, order) pairs
	Flips                int     `json:"flips"`
	FlipRate             float64 `json:"flip_rate"`
	MaxPositionDeviation float64 `json:"max_position_deviation"`
}

// ProbeResult is the outcome of ProbeOrder.
type ProbeResult struct {
	Calls     int             `json:"calls"` // gateway calls made
	Questions []QuestionProbe `json:"questions"`
	Summary   ProbeSummary    `json:"summary"`
}

// probeClass is the classification step shared by PermutableQuestions and ProbeOrder.
type probeClass struct {
	top     []string
	topVals map[string]json.RawMessage
	qkeys   []string
	qvals   map[string]json.RawMessage
	choices map[string]bool
	maxN    int
	idx     map[string]int
	res     *ProbeResult
}

func classifyProbe(body []byte) (*probeClass, error) {
	top, topVals, err := orderedObject(body)
	if err != nil {
		return nil, errf(KindUsage, "the request is not a JSON object")
	}
	qkeys, qvals, err := orderedObject(topVals["questions"])
	if err != nil {
		return nil, errf(KindUsage, "the request has no questions object")
	}
	res := &ProbeResult{}
	choices := map[string]bool{}
	maxN := 1
	idx := map[string]int{}
	for _, name := range qkeys {
		qp := QuestionProbe{Name: name}
		idx[name] = len(res.Questions)
		_, fv, err := orderedObject(qvals[name])
		if err != nil {
			qp.Reason = "not a JSON object"
			res.Questions = append(res.Questions, qp)
			continue
		}
		var typ string
		_ = json.Unmarshal(fv["type"], &typ)
		qp.Type = typ
		switch typ {
		case contract.TypeChoice:
			ck, _, err := orderedObject(fv["criteria"])
			switch {
			case err != nil:
				qp.Reason = "choice criteria are not a JSON object"
			case len(ck) < 2:
				qp.Options = len(ck)
				qp.Reason = "fewer than two options: nothing to reorder"
			default:
				qp.Options, qp.Permutable = len(ck), true
				choices[name] = true
				if len(ck) > maxN {
					maxN = len(ck)
				}
			}
		case contract.TypeNoul:
			qp.Reason = "noul: yes/no are not interchangeable options"
		case contract.TypeScore:
			qp.Reason = "score: the levels are an ordered scale, not interchangeable options"
		default:
			qp.Reason = "unknown question type"
		}
		res.Questions = append(res.Questions, qp)
	}
	return &probeClass{top: top, topVals: topVals, qkeys: qkeys, qvals: qvals, choices: choices, maxN: maxN, idx: idx, res: res}, nil
}

// PermutableQuestions returns the per-question classification of a request without any network
// call: which questions ProbeOrder could reorder, and why the others cannot be.
func PermutableQuestions(body []byte) ([]QuestionProbe, error) {
	pc, err := classifyProbe(body)
	if err != nil {
		return nil, err
	}
	return pc.res.Questions, nil
}

// ProbeOrder asks the same request with the options of every choice question rotated cyclically
// (call i lists option j at position (j-i) mod n - the same rotation as AskPermuted/--permute) and
// reports, per question, how often the answer flips with the order and where in the listing the
// answers sit. k = 0 means a full cycle (as many calls as the largest option count); otherwise
// 2..MaxPermute, capped at the largest option count. Questions that are not interchangeable
// (noul, score, single-option choices) are reported as such and cost no call; a request with no
// choice question makes no call. A failed call aborts the probe with that call's error.
func (c *Client) ProbeOrder(ctx context.Context, body []byte, k int) (*ProbeResult, error) {
	if k != 0 && (k < 2 || k > MaxPermute) {
		return nil, errf(KindUsage, "--permute needs 0 (a full cycle) or a whole number between 2 and "+strconv.Itoa(MaxPermute)+": one order cannot show order sensitivity")
	}
	pc, err := classifyProbe(body)
	if err != nil {
		return nil, err
	}
	top, topVals, qkeys, qvals, choices, maxN, idx, res := pc.top, pc.topVals, pc.qkeys, pc.qvals, pc.choices, pc.maxN, pc.idx, pc.res
	if len(choices) == 0 {
		return res, nil
	}
	runs := maxN
	if k != 0 {
		runs = min(k, maxN)
	}
	if runs < 2 {
		runs = 2
	}
	bad := errf(KindBackend, "the gateway answered a permuted call with a malformed result")
	answers := make([]map[string]permAnswer, runs)
	for i := 0; i < runs; i++ {
		rb, err := rotateBody(top, topVals, qkeys, qvals, choices, i)
		if err != nil {
			return nil, errf(KindUsage, "the criteria of a choice question are not a JSON object")
		}
		r, err := c.Ask(ctx, rb)
		if err != nil {
			return nil, err
		}
		res.Calls++
		_, rtop, err := orderedObject(r.Body)
		if err != nil {
			return nil, bad
		}
		_, av, err := orderedObject(rtop["answers"])
		if err != nil {
			return nil, bad
		}
		answers[i] = map[string]permAnswer{}
		for name := range choices {
			var a permAnswer
			if json.Unmarshal(av[name], &a) != nil || len(a.Probabilities) == 0 {
				return nil, bad
			}
			answers[i][name] = a
		}
	}
	for name := range choices {
		qp := &res.Questions[idx[name]]
		_, fv, _ := orderedObject(qvals[name])
		order, _, _ := orderedObject(fv["criteria"])
		n := len(order)
		used := runs
		if used >= n {
			used = (used / n) * n
		} else {
			qp.PartialCycle = true
		}
		qp.Orders = used
		avg := map[string]float64{}
		boundedRuns := map[string]int{}
		for i := 0; i < used; i++ {
			a := answers[i][name]
			if len(a.Probabilities) != n {
				return nil, bad
			}
			for _, key := range order {
				p, ok := a.Probabilities[key]
				if !ok {
					return nil, bad
				}
				avg[key] += p / float64(used)
			}
			for key := range a.UpperBounds {
				boundedRuns[key]++
			}
		}
		best := ""
		for _, key := range order {
			if boundedRuns[key] == used {
				continue
			}
			if best == "" || avg[key] > avg[best] {
				best = key
			}
		}
		if best == "" {
			best = order[0]
		}
		qp.Answer = best
		posOf := map[string]int{}
		for i, key := range order {
			posOf[key] = i
		}
		counts := make([]int, n)
		for i := 0; i < used; i++ {
			a := answers[i][name]
			top := 0.0
			for _, key := range order {
				top = math.Max(top, a.Probabilities[key])
			}
			if a.Probabilities[best] < top-2e-9 { // one rounding step (9 decimals) is a tie, not a flip
				qp.Flips++
			}
			own := a.Choice
			if _, ok := posOf[own]; !ok {
				own = ""
				for _, key := range order { // fall back to the argmax, first key wins a tie
					if own == "" || a.Probabilities[key] > a.Probabilities[own] {
						own = key
					}
				}
			}
			// in call i the option at original index j is listed at position (j-i) mod n
			counts[((posOf[own]-i)%n+n)%n]++
		}
		qp.FlipRate = float64(qp.Flips) / float64(used)
		qp.Unanimous = qp.Flips == 0
		qp.PositionExpected = 1 / float64(n)
		qp.PositionShare = make([]float64, n)
		for p, c := range counts {
			qp.PositionShare[p] = float64(c) / float64(used)
			qp.MaxPositionDeviation = math.Max(qp.MaxPositionDeviation, math.Abs(qp.PositionShare[p]-qp.PositionExpected))
		}
		res.Summary.Questions++
		res.Summary.Trials += used
		res.Summary.Flips += qp.Flips
		res.Summary.MaxPositionDeviation = math.Max(res.Summary.MaxPositionDeviation, qp.MaxPositionDeviation)
	}
	if res.Summary.Trials > 0 {
		res.Summary.FlipRate = float64(res.Summary.Flips) / float64(res.Summary.Trials)
	}
	return res, nil
}
