package client

import (
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strings"
	"testing"
)

// multiGateway answers every choice question with a pure POSITION bias (the first listed option
// gets `first`, the rest share the remainder) and reports the listed first option as the choice -
// or, with tie, a uniform distribution whose choice is the first listed option.
func multiGateway(t *testing.T, qs map[string]int, tie bool) *Client {
	t.Helper()
	srv := newTLSServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var parts []string
		for name := range qs {
			keys := criteriaOrder(t, b, name)
			n := float64(len(keys))
			var probs []string
			for i, k := range keys {
				p := 1 / n
				if !tie {
					if i == 0 {
						p = 0.7
					} else {
						p = 0.3 / (n - 1)
					}
				}
				kb, _ := json.Marshal(k)
				probs = append(probs, string(kb)+":"+jsonFloat(p))
			}
			fk, _ := json.Marshal(keys[0])
			nb, _ := json.Marshal(name)
			parts = append(parts, string(nb)+`:{"type":"choice","choice":`+string(fk)+`,"probabilities":{`+strings.Join(probs, ",")+`},"confidence":0.5}`)
		}
		_, _ = w.Write([]byte(`{"model":"m","answers":{` + strings.Join(parts, ",") + `},"usage":{"input_tokens":1,"output_tokens":1}}`))
	}))
	c, _ := newTestClient(t, srv, nil)
	return c
}

const twoChoiceReq = `{"state":"s","questions":{"c":{"type":"choice","instructions":"p","criteria":{"a":"1","b":"2","c":"3","d":"4"}},"d":{"type":"choice","instructions":"p","criteria":{"x":"1","y":"2","z":"3"}}}}`

// B2-10: a question is averaged over a whole number of cycles of ITS OWN option count, so a pure
// position bias cancels exactly; the unbalanced 4th call (order 0 again) is not averaged into the
// 3-option question.
func TestPermuteAveragesOnlyWholeCyclesPerQuestion(t *testing.T) {
	c := multiGateway(t, map[string]int{"c": 4, "d": 3}, false)
	res, stats, err := c.AskPermuted(t.Context(), []byte(twoChoiceReq), 4)
	if err != nil {
		t.Fatal(err)
	}
	if stats.K != 4 {
		t.Fatalf("K %d: four gateway calls are made", stats.K)
	}
	var out struct {
		Answers map[string]struct {
			Probabilities map[string]float64 `json:"probabilities"`
		} `json:"answers"`
	}
	if err := json.Unmarshal(res.Body, &out); err != nil {
		t.Fatal(err)
	}
	for q, want := range map[string][]string{"c": {"a", "b", "c", "d"}, "d": {"x", "y", "z"}} {
		p := out.Answers[q].Probabilities
		for _, k := range want[1:] {
			if math.Abs(p[k]-p[want[0]]) > 1e-6 {
				t.Errorf("question %s: a pure position bias must cancel over whole cycles, got %v", q, p)
			}
		}
	}
}

// B2-10: exact ties are not flips (each call breaks a tie by its own listed order).
func TestPermuteExactTiesAreNotFlips(t *testing.T) {
	c := multiGateway(t, map[string]int{"c": 4, "d": 3}, true)
	_, stats, err := c.AskPermuted(t.Context(), []byte(twoChoiceReq), 4)
	if err != nil {
		t.Fatal(err)
	}
	if stats.FlipRate != 0 {
		t.Fatalf("a model with no preference at all must have flip rate 0, got %v", stats.FlipRate)
	}
}

// B2-09: an explicit empty model is a usage error, never the default profile.
func TestBuildRejectsAnEmptyStringModel(t *testing.T) {
	file := `{"model":"","state":"s","questions":{"q":{"type":"noul","instructions":"i"}}}`
	_, err := Build(Input{QuestionFile: []byte(file)})
	if kindOf(err) != KindUsage || !strings.Contains(err.Error(), "model") {
		t.Fatalf("an empty model must be a usage error naming the model, got %v", err)
	}
	if _, err := Build(Input{Model: "decide-tiny", QuestionFile: []byte(file)}); kindOf(err) != KindUsage {
		t.Fatalf("the flag does not paper over an empty model in the file: %v", err)
	}
	// a missing model is still fine
	if _, err := Build(Input{QuestionFile: []byte(`{"state":"s","questions":{"q":{"type":"noul","instructions":"i"}}}`)}); err != nil {
		t.Fatal(err)
	}
}

// B2-11: the serving instance (x-llmctl-decide-instance) is reported in the evidence.
func TestResultAndEvidenceCarryTheServingInstance(t *testing.T) {
	srv := newTLSServer(t, jsonHandler(200, `{"model":"m","answers":{},"usage":{"input_tokens":0,"output_tokens":0}}`,
		map[string]string{"x-llmctl-decide-mode": "deterministic", "x-llmctl-decide-instance": "decide-tiny.2"}))
	c, _ := newTestClient(t, srv, nil)
	res, err := c.Ask(t.Context(), []byte(`{"state":"s","questions":{}}`))
	if err != nil || res.Instance != "decide-tiny.2" {
		t.Fatalf("%v %+v", err, res)
	}
	out, err := Annotate([]byte(`{"model":"m"}`), Annotation{Profile: "m", Port: 1, Latency: 1, Instance: res.Instance})
	if err != nil || !strings.Contains(string(out), `"instance":"decide-tiny.2"`) {
		t.Fatalf("%s %v", out, err)
	}
	// an unsafe value is never echoed
	srv2 := newTLSServer(t, jsonHandler(200, `{"model":"m","answers":{},"usage":{"input_tokens":0,"output_tokens":0}}`,
		map[string]string{"x-llmctl-decide-instance": "a b;<script>"}))
	c2, _ := newTestClient(t, srv2, nil)
	if res, err := c2.Ask(t.Context(), []byte(`{"state":"s","questions":{}}`)); err != nil || res.Instance != "" {
		t.Fatalf("%v %+v", err, res)
	}
	plain, _ := Annotate([]byte(`{"model":"m"}`), Annotation{Profile: "m", Port: 1, Latency: 1})
	if strings.Contains(string(plain), `"instance"`) {
		t.Fatalf("absent stays absent: %s", plain)
	}
}

// A "tie" of probabilities rounded to 9 decimals differs by at most one rounding step (1e-9):
// that is still a tie, not an order preference.
func TestPermuteRoundingNoiseIsNotAFlip(t *testing.T) {
	srv := newTLSServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		keys := criteriaOrder(t, b, "d")
		var probs []string
		for i, k := range keys {
			p := 0.333333333
			if i == 0 {
				p = 0.333333334 // the first listed option is one rounding step higher
			}
			kb, _ := json.Marshal(k)
			probs = append(probs, string(kb)+":"+jsonFloat(p))
		}
		fk, _ := json.Marshal(keys[0])
		_, _ = w.Write([]byte(`{"model":"m","answers":{"d":{"type":"choice","choice":` + string(fk) + `,"probabilities":{` + strings.Join(probs, ",") +
			`},"confidence":0.0}},"usage":{"input_tokens":1,"output_tokens":1}}`))
	}))
	c, _ := newTestClient(t, srv, nil)
	_, stats, err := c.AskPermuted(t.Context(), []byte(`{"state":"s","questions":{"d":{"type":"choice","instructions":"p","criteria":{"x":"1","y":"2","z":"3"}}}}`), 3)
	if err != nil {
		t.Fatal(err)
	}
	if stats.FlipRate != 0 {
		t.Fatalf("one rounding step of difference is a tie, got flip rate %v", stats.FlipRate)
	}
}

// B3-10 (M7): an exact tie of the averaged probabilities is broken by the ORIGINAL option order:
// the first key wins (the same convention as a single call).
func TestPermuteAveragedExactTieGoesToTheFirstOriginalKey(t *testing.T) {
	c := multiGateway(t, map[string]int{"c": 4, "d": 3}, true)
	res, _, err := c.AskPermuted(t.Context(), []byte(twoChoiceReq), 4)
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Answers map[string]struct {
			Choice string `json:"choice"`
		} `json:"answers"`
	}
	if err := json.Unmarshal(res.Body, &out); err != nil {
		t.Fatal(err)
	}
	if out.Answers["c"].Choice != "a" || out.Answers["d"].Choice != "x" {
		t.Fatalf("a tie must go to the first original key: %+v", out.Answers)
	}
}
