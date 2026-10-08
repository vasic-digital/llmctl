package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// MaxPermute bounds --permute K (every extra order is one more gateway call).
const MaxPermute = 64

// PermuteStats reports an order-permuted answer: K gateway calls were made and FlipRate is the share
// of (choice question, call) pairs whose own answer differed from the order-averaged one - a direct
// measure of how much the model's answer depends on the order the options were listed in.
type PermuteStats struct {
	K        int
	FlipRate float64
}

// orderedObject decodes a JSON object keeping the key order; duplicate keys are an error.
func orderedObject(raw json.RawMessage) ([]string, map[string]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	t, err := dec.Token()
	if err != nil {
		return nil, nil, err
	}
	if d, ok := t.(json.Delim); !ok || d != '{' {
		return nil, nil, errors.New("not a JSON object")
	}
	var keys []string
	vals := map[string]json.RawMessage{}
	for dec.More() {
		kt, err := dec.Token()
		if err != nil {
			return nil, nil, err
		}
		k, ok := kt.(string)
		if !ok {
			return nil, nil, errors.New("bad object key")
		}
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, nil, err
		}
		if _, dup := vals[k]; dup {
			return nil, nil, errors.New("duplicate key")
		}
		keys = append(keys, k)
		vals[k] = v
	}
	return keys, vals, nil
}

func writeObject(keys []string, vals map[string]json.RawMessage) []byte {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		b.Write(jstr(k))
		b.WriteByte(':')
		b.Write(vals[k])
	}
	b.WriteByte('}')
	return b.Bytes()
}

type choiceQ struct {
	name string
	n    int
}

// rotateBody returns the request with every choice question's criteria rotated by shift positions.
func rotateBody(top []string, topVals map[string]json.RawMessage, qkeys []string, qvals map[string]json.RawMessage, choices map[string]bool, shift int) ([]byte, error) {
	nq := map[string]json.RawMessage{}
	for _, name := range qkeys {
		if !choices[name] {
			nq[name] = qvals[name]
			continue
		}
		fk, fv, err := orderedObject(qvals[name])
		if err != nil {
			return nil, err
		}
		ck, cv, err := orderedObject(fv["criteria"])
		if err != nil {
			return nil, err
		}
		s := shift % len(ck)
		rot := append(append([]string(nil), ck[s:]...), ck[:s]...)
		fv["criteria"] = writeObject(rot, cv)
		nq[name] = writeObject(fk, fv)
	}
	vals := map[string]json.RawMessage{}
	for k, v := range topVals {
		vals[k] = v
	}
	vals["questions"] = writeObject(qkeys, nq)
	return writeObject(top, vals), nil
}

// AskPermuted asks the same request K times with the options of every choice question rotated
// cyclically (call i lists option j at position (j-i) mod n), then reports the order-AVERAGED
// answer: probabilities averaged per option key, the argmax as the choice, the confidence recomputed
// from the average, flags and bounds merged. Questions that cannot be permuted (noul, score: their
// options are not interchangeable) are taken from the first call. K is capped at the largest option
// count (more would only repeat an order). Any failed call fails the whole answer.
func (c *Client) AskPermuted(ctx context.Context, body []byte, k int) (*Result, *PermuteStats, error) {
	if k < 1 || k > MaxPermute {
		return nil, nil, errf(KindUsage, "--permute needs a whole number between 1 and "+strconv.Itoa(MaxPermute))
	}
	top, topVals, err := orderedObject(body)
	if err != nil {
		return nil, nil, errf(KindUsage, "the request is not a JSON object")
	}
	qkeys, qvals, err := orderedObject(topVals["questions"])
	if err != nil {
		return nil, nil, errf(KindUsage, "the request has no questions object")
	}
	choices := map[string]bool{}
	maxN := 1
	for _, name := range qkeys {
		_, fv, err := orderedObject(qvals[name])
		if err != nil {
			continue
		}
		var typ string
		if json.Unmarshal(fv["type"], &typ) != nil || typ != contract.TypeChoice {
			continue
		}
		ck, _, err := orderedObject(fv["criteria"])
		if err != nil || len(ck) < 2 {
			continue
		}
		choices[name] = true
		if len(ck) > maxN {
			maxN = len(ck)
		}
	}
	runs := min(k, maxN)
	if runs <= 1 {
		res, err := c.Ask(ctx, body)
		return res, &PermuteStats{K: 1}, err
	}
	results := make([]*Result, runs)
	for i := 0; i < runs; i++ {
		rb, err := rotateBody(top, topVals, qkeys, qvals, choices, i)
		if err != nil {
			return nil, nil, errf(KindUsage, "the criteria of a choice question are not a JSON object")
		}
		if results[i], err = c.Ask(ctx, rb); err != nil {
			return nil, nil, err
		}
	}
	return mergePermuted(results, qkeys, qvals, choices)
}

type permAnswer struct {
	Choice        string             `json:"choice"`
	Probabilities map[string]float64 `json:"probabilities"`
	Flags         []string           `json:"flags"`
	UpperBounds   map[string]float64 `json:"upper_bounds"`
	Confidence    *float64           `json:"confidence"`
	Calibration   json.RawMessage    `json:"calibration"`
}

// calMeta is the calibration verdict of the calls averaged into one permuted answer.
type calMeta struct {
	any, uniform bool
	obj          string  // the (compacted) calibration object every call carried, when uniform
	sumConf      float64 // sum of the calls' calibrated confidences, when uniform
}

func mergePermuted(results []*Result, qkeys []string, qvals map[string]json.RawMessage, choices map[string]bool) (*Result, *PermuteStats, error) {
	bad := errf(KindBackend, "the gateway answered a permuted call with a malformed result")
	var first struct {
		Model string `json:"model"`
	}
	if json.Unmarshal(results[0].Body, &first) != nil {
		return nil, nil, bad
	}
	type resp struct {
		answers map[string]json.RawMessage
	}
	all := make([]map[string]json.RawMessage, len(results))
	var akeys []string
	usageIn, usageOut := 0, 0
	var lat time.Duration
	trunc := false
	for i, r := range results {
		_, top, err := orderedObject(r.Body)
		if err != nil {
			return nil, nil, bad
		}
		ks, av, err := orderedObject(top["answers"])
		if err != nil {
			return nil, nil, bad
		}
		if i == 0 {
			akeys = ks
		}
		all[i] = av
		var u struct {
			In  int `json:"input_tokens"`
			Out int `json:"output_tokens"`
		}
		if json.Unmarshal(top["usage"], &u) != nil {
			return nil, nil, bad
		}
		usageIn += u.In
		usageOut += u.Out
		lat += r.Latency
		trunc = trunc || r.Truncated
	}
	merged := map[string]json.RawMessage{}
	flips, trials := 0, 0
	for _, name := range akeys {
		if !choices[name] {
			merged[name] = all[0][name]
			continue
		}
		// the option order of the ORIGINAL request
		_, fv, _ := orderedObject(qvals[name])
		order, _, _ := orderedObject(fv["criteria"])
		n := len(order)
		avg := map[string]float64{}
		var flags []string
		ub := map[string]float64{}
		boundedRuns := map[string]int{}
		// A question is averaged over a whole number of cycles of ITS OWN option count: a call beyond the
		// last whole cycle would count one listed order twice and leave the position bias uncancelled
		// (B2-10). With fewer calls than options only part of one cycle exists: all calls are averaged
		// and the bias is cancelled only partially (documented in cli.md).
		used := len(results)
		if used >= n {
			used = (used / n) * n
		}
		runProbs := make([]map[string]float64, used)
		cal := calMeta{uniform: true}
		calCount := 0
		for i := 0; i < used; i++ {
			var a permAnswer
			if json.Unmarshal(all[i][name], &a) != nil || len(a.Probabilities) != n {
				return nil, nil, bad
			}
			runProbs[i] = a.Probabilities
			if o, isObj := compactCal(a.Calibration); isObj && a.Confidence != nil {
				calCount++
				cal.any = true
				if calCount == 1 {
					cal.obj = o
				} else if o != cal.obj {
					cal.uniform = false
				}
				cal.sumConf += *a.Confidence
			}
			for _, key := range order {
				p, ok := a.Probabilities[key]
				if !ok {
					return nil, nil, bad
				}
				avg[key] += p / float64(used)
			}
			for _, f := range a.Flags {
				seen := false
				for _, g := range flags {
					seen = seen || g == f
				}
				if !seen {
					flags = append(flags, f)
				}
			}
			for key, v := range a.UpperBounds {
				if v > ub[key] {
					ub[key] = v
				}
				boundedRuns[key]++
			}
		}
		// the winner is an option some call LISTED: one that held only worst-case mass (an
		// upper bound in EVERY averaged run) was never measured (B3-01); the first key wins an exact tie
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
		// a call FLIPPED when it clearly preferred another option than the averaged answer: a call
		// that ties best with its own top is not a flip (it broke the tie by its listed order)
		for _, rp := range runProbs {
			top := 0.0
			for _, key := range order {
				top = math.Max(top, rp[key])
			}
			trials++
			if rp[best] < top-2e-9 { // probabilities are rounded to 9 decimals: one rounding step is a tie
				flips++
			}
		}
		conf := (avg[best] - 1/float64(n)) / (1 - 1/float64(n))
		conf = contract.Round9(math.Max(0, math.Min(1, conf)))
		var b bytes.Buffer
		b.WriteString(`{"type":"choice","choice":`)
		b.Write(jstr(best))
		b.WriteString(`,"probabilities":{`)
		for i, key := range order {
			if i > 0 {
				b.WriteByte(',')
			}
			b.Write(jstr(key))
			b.WriteByte(':')
			b.WriteString(strconv.FormatFloat(contract.Round9(avg[key]), 'f', -1, 64))
		}
		// Calibration metadata (FR-080). Every averaged call carrying the SAME calibration object: the
		// object is kept, `confidence` is the mean of the calls' calibrated confidences (the averaged
		// probabilities are RAW, so the shaped value recomputed from them goes to `confidence_raw`).
		// Calls that disagree (different object, or only some calibrated): "mixed" - `confidence` is
		// the shaped value from the averaged probabilities and the client does not treat it as calibrated.
		switch {
		case cal.any && cal.uniform && calCount == used:
			cc := contract.Round9(math.Max(0, math.Min(1, cal.sumConf/float64(used))))
			b.WriteString(`},"confidence":` + strconv.FormatFloat(cc, 'f', -1, 64))
			b.WriteString(`,"confidence_raw":` + strconv.FormatFloat(conf, 'f', -1, 64))
			b.WriteString(`,"calibration":` + cal.obj)
		case cal.any:
			b.WriteString(`},"confidence":` + strconv.FormatFloat(conf, 'f', -1, 64))
			b.WriteString(`,"confidence_raw":` + strconv.FormatFloat(conf, 'f', -1, 64))
			b.WriteString(`,"calibration":"mixed"`)
		default:
			b.WriteString(`},"confidence":` + strconv.FormatFloat(conf, 'f', -1, 64))
		}
		if len(flags) > 0 {
			fb, _ := json.Marshal(flags)
			b.WriteString(`,"flags":` + string(fb) + `,"upper_bounds":{`)
			firstUB := true
			for _, key := range order {
				if v, ok := ub[key]; ok {
					if !firstUB {
						b.WriteByte(',')
					}
					firstUB = false
					b.Write(jstr(key))
					b.WriteByte(':')
					b.WriteString(strconv.FormatFloat(v, 'f', -1, 64))
				}
			}
			b.WriteByte('}')
		}
		b.WriteByte('}')
		merged[name] = b.Bytes()
	}
	out := `{"model":` + string(jstr(first.Model)) + `,"answers":` + string(writeObject(akeys, merged)) +
		`,"usage":{"input_tokens":` + strconv.Itoa(usageIn) + `,"output_tokens":` + strconv.Itoa(usageOut) + `}}`
	if !json.Valid([]byte(out)) {
		return nil, nil, bad
	}
	st := &PermuteStats{K: len(results)}
	if trials > 0 {
		st.FlipRate = float64(flips) / float64(trials)
	}
	r0 := results[0]
	inst := r0.Instance
	for _, r := range results {
		if r.Instance != inst {
			inst = "mixed" // the rotations were answered by different instances
		}
	}
	return &Result{Body: []byte(out), Latency: lat, Truncated: trunc, Port: r0.Port, Mode: r0.Mode, Instance: inst}, st, nil
}

// compactCal returns the compact form of a calibration JSON object, and whether it is one.
func compactCal(raw json.RawMessage) (string, bool) {
	t := bytes.TrimSpace(raw)
	if len(t) == 0 || t[0] != '{' {
		return "", false
	}
	var b bytes.Buffer
	if json.Compact(&b, t) != nil {
		return "", false
	}
	return b.String(), true
}
