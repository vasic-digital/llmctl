package client

// Review-2 scope B: B-01 (flagged answers reach the gate), B-07 (mode in the evidence), B-08
// (strict model typing), B-12 (message sanitiser), B-16 (--permute). Written first, observed RED.

import (
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func newTLSServer(t *testing.T, h http.Handler) *httptest.Server {
	t.Helper()
	srv := httptest.NewTLSServer(h)
	t.Cleanup(srv.Close)
	return srv
}

func TestSanitizeMessageDropsC1AndBidiControls(t *testing.T) {
	in := "ok\x1b[31m red\u009b2J ‮evil⁦ x‎ y\u0085 z\x7f end  more"
	got := sanitizeMessage(in)
	for _, r := range got {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) || (r >= 0x200e && r <= 0x200f) ||
			(r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) || r == 0x2028 || r == 0x2029 {
			t.Fatalf("control/bidi U+%04X survived: %q", r, got)
		}
	}
	if !strings.Contains(got, "ok") || !strings.Contains(got, "end") || !strings.Contains(got, "evil") {
		t.Fatalf("ordinary text must survive: %q", got)
	}
	if sanitizeMessage("Žluťoučký kůň ünïcode") != "Žluťoučký kůň ünïcode" {
		t.Fatal("non-ASCII text must be preserved")
	}
}

func TestBuildRejectsAWronglyTypedModelInAFullRequest(t *testing.T) {
	for _, m := range []string{`5`, `null`, `[]`, `{}`, `true`, `["a"]`} {
		file := `{"model":` + m + `,"state":"s","questions":{"q":{"type":"noul","instructions":"i"}}}`
		_, err := Build(Input{QuestionFile: []byte(file)})
		if kindOf(err) != KindUsage || !strings.Contains(err.Error(), "model") {
			t.Errorf("model %s must be a usage error naming the model, got %v", m, err)
		}
		// the flag does not paper over a broken file
		if _, err := Build(Input{Model: "decide-tiny", QuestionFile: []byte(file)}); kindOf(err) != KindUsage {
			t.Errorf("model %s with --profile: %v", m, err)
		}
	}
	if b, err := Build(Input{QuestionFile: []byte(`{"model":"decide-tiny","state":"s","questions":{"q":{"type":"noul","instructions":"i"}}}`)}); err != nil || b.Model != "decide-tiny" {
		t.Fatalf("%v %+v", err, b)
	}
	for _, bad := range []string{`{"state":5,"questions":{"q":{"type":"noul","instructions":"i"}}}`,
		`{"state":"s","questions":[]}`, `{"state":"s","questions":"x"}`, `{"state":null,"questions":{"q":{}}}`} {
		if _, err := Build(Input{QuestionFile: []byte(bad)}); kindOf(err) != KindUsage {
			t.Errorf("%s: want a usage error, got %v", bad, err)
		}
	}
}

func TestFlaggedAnswersNeverSilentlyPassTheConfidenceGate(t *testing.T) {
	flagged := func(conf, ub float64) []byte {
		b, _ := json.Marshal(map[string]any{"model": "m", "answers": map[string]any{"q": map[string]any{
			"type": "choice", "choice": "a", "probabilities": map[string]float64{"a": 0.95, "b": 0.05},
			"confidence": conf, "flags": []string{"option_missing"}, "upper_bounds": map[string]float64{"b": ub}}}})
		return b
	}
	// B3-01: the shares already ARE the worst case (the absent option sits at its bound inside them),
	// so the gate reads the listed winner's confidence and does not scale by the bound a second time
	got, err := MinConfidence(flagged(0.9, 0.05))
	if err != nil || math.Abs(got-0.9) > 1e-9 {
		t.Fatalf("a flagged answer's confidence is the listed winner's worst-case confidence: %v %v", got, err)
	}
	// the wire confidence is never trusted above what the listed shares give
	if got, _ := MinConfidence(flagged(0.99, 0.05)); math.Abs(got-0.9) > 1e-9 { // (0.95-1/2)/(1/2)
		t.Fatalf("%v", got)
	}
	// an unflagged answer is untouched
	plain := []byte(`{"model":"m","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":0.95,"b":0.05},"confidence":0.95}}}`)
	if got, _ := MinConfidence(plain); got != 0.95 {
		t.Fatal(got)
	}
	// noul: 'no' missing: the winner is 'yes', the option the engine listed
	n := []byte(`{"model":"m","answers":{"q":{"type":"noul","noul":0.85,"flags":["option_missing"],"upper_bounds":{"no":0.15}}}}`)
	if got, _ := MinConfidence(n); math.Abs(got-0.7) > 1e-9 {
		t.Fatalf("a flagged noul is the listed option's confidence: %v", got)
	}
	// noul: 'yes' missing and holding most of the worst-case mass: the listed 'no' is NOT confident
	n = []byte(`{"model":"m","answers":{"q":{"type":"noul","noul":0.8,"flags":["option_missing"],"upper_bounds":{"yes":0.8}}}}`)
	if got, _ := MinConfidence(n); got != 0 {
		t.Fatalf("an absent option never gives a flagged answer its confidence: %v", got)
	}
	fl, err := AnyFlagged(flagged(0.9, 0.1))
	if err != nil || !fl {
		t.Fatal(fl, err)
	}
	if fl, _ := AnyFlagged(plain); fl {
		t.Fatal("unflagged")
	}
}

func TestAnnotateCarriesModeFlaggedAndPermute(t *testing.T) {
	out, err := Annotate([]byte(`{"model":"m"}`), Annotation{Profile: "m", Port: 1, Latency: 1, Mode: "throughput", Flagged: true,
		Permute: &PermuteStats{K: 3, FlipRate: 0.25}})
	if err != nil {
		t.Fatal(err)
	}
	var d struct {
		Evidence struct {
			Mode    string `json:"mode"`
			Flagged bool   `json:"flagged"`
			Permute struct {
				K        int     `json:"k"`
				FlipRate float64 `json:"flip_rate"`
			} `json:"permute"`
		} `json:"evidence"`
	}
	if err := json.Unmarshal(out, &d); err != nil || d.Evidence.Mode != "throughput" || !d.Evidence.Flagged || d.Evidence.Permute.K != 3 || d.Evidence.Permute.FlipRate != 0.25 {
		t.Fatalf("%s %v", out, err)
	}
	plain, _ := Annotate([]byte(`{"model":"m"}`), Annotation{Profile: "m", Port: 1, Latency: 1})
	if strings.Contains(string(plain), `"mode":`) || strings.Contains(string(plain), `"flagged"`) || strings.Contains(string(plain), `"permute"`) {
		t.Fatalf("absent fields stay absent: %s", plain)
	}
}

func TestResultCarriesTheGatewayMode(t *testing.T) {
	srv := newTLSServer(t, jsonHandler(200, `{"model":"m","answers":{},"usage":{"input_tokens":0,"output_tokens":0}}`, map[string]string{"x-llmctl-decide-mode": "throughput"}))
	c, _ := newTestClient(t, srv, nil)
	res, err := c.Ask(t.Context(), []byte(`{}`))
	if err != nil || res.Mode != "throughput" {
		t.Fatalf("%v %+v", err, res)
	}
}

// ---- B-16: --permute ----------------------------------------------------------------------------

func criteriaOrder(t *testing.T, body []byte, q string) []string {
	t.Helper()
	var doc struct {
		Questions map[string]struct {
			Criteria json.RawMessage `json:"criteria"`
		} `json:"questions"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		t.Fatal(err)
	}
	keys, _, err := orderedObject(doc.Questions[q].Criteria)
	if err != nil {
		t.Fatal(err)
	}
	return keys
}

func permuteGateway(t *testing.T, bias []float64, base map[string]float64) (*Client, *[][]string) {
	t.Helper()
	var mu sync.Mutex
	seen := &[][]string{}
	srv := newTLSServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		keys := criteriaOrder(t, b, "c")
		mu.Lock()
		*seen = append(*seen, keys)
		mu.Unlock()
		// probability = base[key] + positional bias, normalised: a model with an order preference
		raw := make([]float64, len(keys))
		sum := 0.0
		for i, k := range keys {
			raw[i] = base[k] + bias[i]
			sum += raw[i]
		}
		var probs strings.Builder
		best, bi := -1.0, 0
		for i, k := range keys {
			p := raw[i] / sum
			if p > best {
				best, bi = p, i
			}
			if i > 0 {
				probs.WriteByte(',')
			}
			b, _ := json.Marshal(k)
			probs.WriteString(string(b) + ":" + jsonFloat(p))
		}
		n := float64(len(keys))
		conf := (best - 1/n) / (1 - 1/n)
		bk, _ := json.Marshal(keys[bi])
		w.Header().Set("x-llmctl-decide-mode", "deterministic")
		_, _ = w.Write([]byte(`{"model":"decide-tiny","answers":{"c":{"type":"choice","choice":` + string(bk) + `,"probabilities":{` + probs.String() +
			`},"confidence":` + jsonFloat(conf) + `},"n":{"type":"noul","noul":0.5}},"usage":{"input_tokens":10,"output_tokens":1}}`))
	}))
	c, _ := newTestClient(t, srv, nil)
	return c, seen
}

func jsonFloat(f float64) string { b, _ := json.Marshal(f); return string(b) }

const permuteReq = `{"model":"decide-tiny","state":"s","questions":{"c":{"type":"choice","instructions":"pick","criteria":{"a":"1","b":"2","c":"3"}},"n":{"type":"noul","instructions":"yes?"}}}`

func TestPermuteRotatesCriteriaCyclicallyAndAveragesBackToTheOriginalOrder(t *testing.T) {
	// the model genuinely prefers b, and has a strong preference for whatever is listed first
	c, seen := permuteGateway(t, []float64{0.5, 0.2, 0.0}, map[string]float64{"a": 0.1, "b": 0.5, "c": 0.1})
	res, stats, err := c.AskPermuted(t.Context(), []byte(permuteReq), 3)
	if err != nil {
		t.Fatal(err)
	}
	if got := *seen; len(got) != 3 || strings.Join(got[0], "") != "abc" || strings.Join(got[1], "") != "bca" || strings.Join(got[2], "") != "cab" {
		t.Fatalf("k=3 must issue the three cyclic rotations, got %v", got)
	}
	var out struct {
		Model   string `json:"model"`
		Answers map[string]struct {
			Type          string             `json:"type"`
			Choice        string             `json:"choice"`
			Probabilities map[string]float64 `json:"probabilities"`
			Confidence    float64            `json:"confidence"`
		} `json:"answers"`
		Usage struct {
			In  int `json:"input_tokens"`
			Out int `json:"output_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(res.Body, &out); err != nil {
		t.Fatal(err)
	}
	if out.Answers["c"].Choice != "b" {
		t.Fatalf("the order-averaged answer is the model's real preference: %+v", out.Answers["c"])
	}
	sum := 0.0
	for _, p := range out.Answers["c"].Probabilities {
		sum += p
	}
	if math.Abs(sum-1) > 1e-6 {
		t.Fatalf("averaged probabilities sum to %v", sum)
	}
	if out.Answers["n"].Type != "noul" {
		t.Fatal("non-choice questions pass through unchanged")
	}
	if out.Usage.In != 30 || out.Usage.Out != 3 {
		t.Fatalf("usage is summed over the calls: %+v", out.Usage)
	}
	if res.Mode != "deterministic" {
		t.Fatal(res.Mode)
	}
	// run 0 picked a (position bias); runs 1 and 2: bca -> b first (b wins), cab -> b second (a? ) - flips are counted
	if stats.K != 3 || stats.FlipRate <= 0 || stats.FlipRate > 1 {
		t.Fatalf("the order sensitivity must be reported: %+v", stats)
	}
	// the answer keeps the ORIGINAL option order
	keys, _, _ := orderedObject(mustRaw(t, res.Body, "answers", "c", "probabilities"))
	if strings.Join(keys, "") != "abc" {
		t.Fatalf("probabilities back in the original order: %v", keys)
	}
}

func mustRaw(t *testing.T, body []byte, path ...string) json.RawMessage {
	t.Helper()
	cur := json.RawMessage(body)
	for _, p := range path {
		var m map[string]json.RawMessage
		if err := json.Unmarshal(cur, &m); err != nil {
			t.Fatal(err)
		}
		cur = m[p]
	}
	return cur
}

func TestPermuteWithoutBiasHasZeroFlipRate(t *testing.T) {
	c, _ := permuteGateway(t, []float64{0, 0, 0}, map[string]float64{"a": 0.1, "b": 0.6, "c": 0.1})
	_, stats, err := c.AskPermuted(t.Context(), []byte(permuteReq), 3)
	if err != nil || stats.FlipRate != 0 {
		t.Fatalf("%v %+v", err, stats)
	}
}

func TestPermuteBoundsAndPassThrough(t *testing.T) {
	c, seen := permuteGateway(t, []float64{0, 0, 0}, map[string]float64{"a": 0.1, "b": 0.6, "c": 0.1})
	if _, _, err := c.AskPermuted(t.Context(), []byte(permuteReq), 1); err != nil || len(*seen) != 1 {
		t.Fatalf("k=1 is a single plain call: %v %d", err, len(*seen))
	}
	*seen = nil
	// k above the option count: only distinct rotations are worth asking
	if _, stats, err := c.AskPermuted(t.Context(), []byte(permuteReq), 10); err != nil || len(*seen) != 3 || stats.K != 3 {
		t.Fatalf("%v %d %+v", err, len(*seen), stats)
	}
	if _, _, err := c.AskPermuted(t.Context(), []byte(permuteReq), 0); kindOf(err) != KindUsage {
		t.Fatalf("k=0: %v", err)
	}
	if _, _, err := c.AskPermuted(t.Context(), []byte(permuteReq), 100000); kindOf(err) != KindUsage {
		t.Fatalf("absurd k: %v", err)
	}
	// no choice question: nothing to permute, one call
	*seen = nil
	srv := newTLSServer(t, jsonHandler(200, `{"model":"m","answers":{"n":{"type":"noul","noul":0.5}},"usage":{"input_tokens":1,"output_tokens":1}}`, nil))
	c2, _ := newTestClient(t, srv, nil)
	if _, stats, err := c2.AskPermuted(t.Context(), []byte(`{"state":"s","questions":{"n":{"type":"noul","instructions":"i"}}}`), 4); err != nil || stats.K != 1 {
		t.Fatalf("%v %+v", err, stats)
	}
}

func TestPermuteFailsClosedWhenACallFails(t *testing.T) {
	calls := 0
	srv := newTLSServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 2 {
			w.WriteHeader(422)
			_, _ = w.Write([]byte(`{"message":"x","error_type":"readout_failed"}`))
			return
		}
		b, _ := io.ReadAll(r.Body)
		_ = b
		_, _ = w.Write([]byte(`{"model":"m","answers":{"c":{"type":"choice","choice":"a","probabilities":{"a":0.5,"b":0.3,"c":0.2},"confidence":0.25}},"usage":{"input_tokens":1,"output_tokens":1}}`))
	}))
	c, _ := newTestClient(t, srv, nil)
	if _, _, err := c.AskPermuted(t.Context(), []byte(`{"state":"s","questions":{"c":{"type":"choice","instructions":"i","criteria":{"a":"","b":"","c":""}}}}`), 3); err == nil {
		t.Fatal("one failed permuted call must fail the whole answer, never a silent partial average")
	}
}

var _ = time.Second

// B3-01 (reviewer probe) end to end through the client gate: the answer the gateway builds from
// [" A"=.6, x, y, z, " C"=.05] has A at its worst case .6/.7, so its gate confidence is
// (.857-1/3)/(2/3) = .786 and the TRUE worst case (A=.75 share) is not smaller than that.
func TestGateConfidenceOfALowRankedPresentLetterIsTheWorstCase(t *testing.T) {
	b := []byte(`{"model":"m","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":0.857142857,"b":0.071428571,"c":0.071428571},"confidence":0.785714286,"flags":["option_missing"],"upper_bounds":{"b":0.0714285}}}}`)
	got, err := MinConfidence(b)
	if err != nil || math.Abs(got-0.785714286) > 1e-6 {
		t.Fatalf("%v %v", got, err)
	}
}

// B3-10 (M1f): an absent option is never the winner of the gate, even when it holds the largest
// worst-case share and the wire confidence (say, from an older gateway) is high.
func TestGateNeverTreatsAnAbsentOptionAsTheWinner(t *testing.T) {
	b := []byte(`{"model":"m","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":0.2,"b":0.8},"confidence":0.9,"flags":["option_missing"],"upper_bounds":{"b":0.8}}}}`)
	if got, err := MinConfidence(b); err != nil || got != 0 {
		t.Fatalf("the listed option holds 0.2 of 2: confidence 0, got %v %v", got, err)
	}
}
