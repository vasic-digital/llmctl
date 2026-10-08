package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/server"
)

// The encoder runtime answers scores[i] = the FULL softmax over `labels` (id2label order) plus a
// label_source (contracts/encoder-runtime.md). dist builds such a response from per-pair
// (entailment, neutral, contradiction) probabilities, laid out in the requested label order.
func dist(order []string, source string, trunc []bool, pairs ...[3]float64) []byte {
	rows := make([][]float64, len(pairs))
	for i, p := range pairs {
		row := make([]float64, len(order))
		for j, l := range order {
			switch strings.ToLower(l) {
			case "entailment", "entails", "entail":
				row[j] = p[0]
			case "neutral":
				row[j] = p[1]
			default:
				row[j] = p[2]
			}
		}
		rows[i] = row
	}
	b, _ := json.Marshal(map[string]any{"labels": order, "label_source": source, "scores": rows, "truncated": trunc, "model": "nli-x", "max_tokens": 512})
	return b
}

var (
	ordCanon = []string{"entailment", "neutral", "contradiction"}
	ordPerm  = []string{"contradiction", "neutral", "entailment"} // permuted id2label
)

func TestNLINoulUsesTheEntailmentColumnInEveryLabelOrder(t *testing.T) {
	orders := [][]string{
		{"entailment", "neutral", "contradiction"}, {"entailment", "contradiction", "neutral"},
		{"neutral", "entailment", "contradiction"}, {"neutral", "contradiction", "entailment"},
		{"contradiction", "entailment", "neutral"}, {"contradiction", "neutral", "entailment"},
		{"ENTAILMENT", "Neutral", "CONTRADICTION"}, {"entails", "neutral", "contradicts"},
		{"contradiction", "entailment"}, // a two-class NLI head without neutral
	}
	for _, ord := range orders {
		t.Run(strings.Join(ord, "_"), func(t *testing.T) {
			// pair 0 (yes-hypothesis): entail .6 neutral .3 contra .1 ; pair 1 (no-hypothesis): entail .2 neutral .1 contra .7
			// a decoder that read column 0 (or the last column) would answer differently in most orders
			yes, no := [3]float64{.6, .3, .1}, [3]float64{.2, .1, .7}
			if len(ord) == 2 {
				yes, no = [3]float64{.6, 0, .4}, [3]float64{.2, 0, .8}
			}
			srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
				_, _ = w.Write(dist(ord, "config:onnx/config.json", []bool{false, false}, yes, no))
			})
			ans, _, err := (&NLIBackend{}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, noulBody))
			if err != nil {
				t.Fatal(err)
			}
			if want := 0.6 / (0.6 + 0.2); math.Abs(ans[0].Answer.Noul-want) > 1e-9 {
				t.Fatalf("noul %v want %v (entailment column not selected by name)", ans[0].Answer.Noul, want)
			}
		})
	}
}

func TestNLINoulSendsOneYesAndOneNoPairWithTheKeyAndPath(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(dist(ordCanon, "config:onnx/config.json", []bool{false, false}, [3]float64{.9, .05, .05}, [3]float64{.1, .1, .8}))
	})
	ans, usage, err := (&NLIBackend{}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, noulBody))
	if err != nil {
		t.Fatal(err)
	}
	if rec.path != "/v1/score" || rec.auth != "Bearer internal-k" {
		t.Fatalf("%s %s", rec.path, rec.auth)
	}
	pairs := rec.body["pairs"].([]any)
	p0 := pairs[0].(map[string]any)
	if len(pairs) != 2 || p0["premise"] != "the printer is on fire" || p0["hypothesis"] == "" || p0["hypothesis"] == pairs[1].(map[string]any)["hypothesis"] {
		t.Fatalf("pairs %v", pairs)
	}
	if got := ans[0].Answer.Noul; math.Abs(got-0.9) > 1e-9 {
		t.Fatalf("noul %v", got)
	}
	if usage.InputTokens <= 0 {
		t.Fatalf("usage %+v", usage)
	}
}

func TestNLIChoiceAndScoreNormaliseTheEntailmentProbabilityPerOption(t *testing.T) {
	// three options; entailment .1/.7/.2 -> normalised choice probabilities; the contradiction column
	// is deliberately LARGEST for option 1 so a wrong-column reader would pick another option
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(dist(ordPerm, "config:onnx/config.json", []bool{false, false, false},
			[3]float64{.1, .1, .8}, [3]float64{.7, .2, .1}, [3]float64{.2, .1, .7}))
	})
	ans, _, err := (&NLIBackend{}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, choiceBody))
	if err != nil {
		t.Fatal(err)
	}
	a := ans[0].Answer
	if a.Choice != "support" || len(a.Probabilities) != 3 || math.Abs(probOf(a, "support")-0.7) > 1e-9 || math.Abs(probOf(a, "billing")-0.1) > 1e-9 {
		t.Fatalf("%+v", a)
	}
	if len(rec.body["pairs"].([]any)) != 3 {
		t.Fatal("one pair per option")
	}
	ans, _, err = (&NLIBackend{}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, scoreBody))
	if err != nil || ans[0].Answer.Type != "score" {
		t.Fatalf("%v %v", ans, err)
	}
}

func TestNLICustomHypothesisBuilder(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(dist(ordCanon, "config:x", []bool{false, false}, [3]float64{.5, .25, .25}, [3]float64{.5, .25, .25}))
	})
	n := &NLIBackend{Hypothesis: func(q contract.ParsedQuestion, o contract.Option) string { return "H:" + o.Key }}
	if _, _, err := n.Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, noulBody)); err != nil {
		t.Fatal(err)
	}
	if h := rec.body["pairs"].([]any)[0].(map[string]any)["hypothesis"]; h != "H:yes" {
		t.Fatal(h)
	}
}

func TestNLITruncatedOnlyAllowedWhenOptedInAndThenReportedToTheGateway(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(dist(ordCanon, "config:x", []bool{true, true}, [3]float64{.6, .2, .2}, [3]float64{.4, .3, .3}))
	})
	ctx, truncated := server.WithTruncationNote(context.Background())
	_, _, err := (&NLIBackend{}).Decide(ctx, ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, noulBody))
	if c := ce(t, err); c.Status != 422 || c.ErrorType != contract.ErrTypeValidationFailed {
		t.Fatalf("silent truncation must be refused by default: %+v", c)
	}
	if truncated() {
		t.Fatal("a refused request must not claim truncation")
	}
	if _, _, err := (&NLIBackend{Truncate: true}).Decide(ctx, ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, noulBody)); err != nil {
		t.Fatalf("opted in: %v", err)
	}
	if !truncated() { // G-039: the response then carries x-llmctl-decide-truncated: true
		t.Fatal("opt-in truncation must be reported through server.NoteTruncated")
	}
	// untruncated answers never set the note
	srv2, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(dist(ordCanon, "config:x", []bool{false, false}, [3]float64{.6, .2, .2}, [3]float64{.4, .3, .3}))
	})
	ctx2, truncated2 := server.WithTruncationNote(context.Background())
	if _, _, err := (&NLIBackend{Truncate: true}).Decide(ctx2, ep(srv2.URL), specByID(t, "decide-nli"), parseFor(t, noulBody)); err != nil || truncated2() {
		t.Fatalf("%v truncated=%v", err, truncated2())
	}
}

func TestNLIZeroEntailmentIsReadoutFailed(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(dist(ordCanon, "config:x", []bool{false, false}, [3]float64{0, .5, .5}, [3]float64{0, .5, .5}))
	})
	_, _, err := (&NLIBackend{}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, noulBody))
	if c := ce(t, err); c.ErrorType != contract.ErrTypeReadoutFailed {
		t.Fatalf("%+v", c)
	}
}

func TestNLIBackendFailures(t *testing.T) {
	good := [3]float64{.6, .2, .2}
	for name, h := range map[string]func(*recorded, http.ResponseWriter){
		"500":     func(_ *recorded, w http.ResponseWriter) { w.WriteHeader(500) },
		"badjson": func(_ *recorded, w http.ResponseWriter) { _, _ = w.Write([]byte("{")) },
		"short": func(_ *recorded, w http.ResponseWriter) {
			_, _ = w.Write(dist(ordCanon, "config:x", []bool{false}, good))
		},
		"legacy-scalar": func(_ *recorded, w http.ResponseWriter) {
			_, _ = w.Write([]byte(`{"labels":["entailment","contradiction"],"scores":[0.9,0.3],"truncated":[false,false]}`))
		},
		"negative": func(_ *recorded, w http.ResponseWriter) {
			_, _ = w.Write([]byte(`{"labels":["entailment","contradiction"],"label_source":"config:x","scores":[[1.5,-0.5],[0.5,0.5]],"truncated":[false,false]}`))
		},
		"row-not-a-distribution": func(_ *recorded, w http.ResponseWriter) {
			_, _ = w.Write([]byte(`{"labels":["entailment","contradiction"],"label_source":"config:x","scores":[[0.9,0.9],[0.5,0.5]],"truncated":[false,false]}`))
		},
		"row-width-mismatch": func(_ *recorded, w http.ResponseWriter) {
			_, _ = w.Write([]byte(`{"labels":["entailment","neutral","contradiction"],"label_source":"config:x","scores":[[0.5,0.5],[0.5,0.5]],"truncated":[false,false]}`))
		},
		"truncated-length": func(_ *recorded, w http.ResponseWriter) {
			_, _ = w.Write(dist(ordCanon, "config:x", []bool{false}, good, good))
		},
	} {
		srv, _ := fakeServer(t, h)
		_, _, err := (&NLIBackend{Logf: func(string, ...any) {}}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, noulBody))
		if c := ce(t, err); c.Status != 502 {
			t.Errorf("%s: %+v", name, c)
		}
	}
	_, _, err := (&NLIBackend{}).Decide(context.Background(), Endpoint{URL: "http://192.0.2.1:1"}, specByID(t, "decide-nli"), parseFor(t, noulBody))
	if c := ce(t, err); c.Status != 502 {
		t.Fatal("non-loopback")
	}
	if _, _, err := (&NLIBackend{}).Decide(context.Background(), ep("http://127.0.0.1:1"), specByID(t, "decide-tiny"), parseFor(t, noulBody)); err == nil {
		t.Fatal("nli driver must refuse a letter profile")
	}
}

// G-044: labels that do not name entailment/contradiction (generic LABEL_n config, no id2label at
// all, a missing or ambiguous required label) are a CONFIGURATION error. The gateway never guesses
// a column: 502 backend_failed with a generic body, the reason logged server-side only.
func TestNLIRefusesLabelsItCannotMapAndNeverGuesses(t *testing.T) {
	cases := map[string]struct {
		labels []string
		source string
	}{
		"generic-config":         {[]string{"LABEL_0", "LABEL_1", "LABEL_2"}, "generic-config:onnx/config.json (LABEL_n names)"},
		"none":                   {[]string{"LABEL_0", "LABEL_1", "LABEL_2"}, "none (no id2label)"},
		"generic-with-real-name": {ordCanon, "generic-config:onnx/config.json (LABEL_n names)"},
		"missing-contradiction":  {[]string{"entailment", "neutral", "other"}, "config:x"},
		"missing-entailment":     {[]string{"yes", "neutral", "contradiction"}, "config:x"},
		"duplicate-entailment":   {[]string{"entailment", "entails", "contradiction"}, "config:x"},
		"not-entailment-is-not":  {[]string{"not_entailment", "neutral", "contradiction"}, "config:x"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			row := [3]float64{.5, .25, .25}
			srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
				rows := [][]float64{{.34, .33, .33}, {.34, .33, .33}}
				b, _ := json.Marshal(map[string]any{"labels": tc.labels, "label_source": tc.source, "scores": rows, "truncated": []bool{false, false}})
				_ = row
				_, _ = w.Write(b)
			})
			var logged bytes.Buffer
			n := &NLIBackend{Logf: func(f string, a ...any) { fmt.Fprintf(&logged, f+"\n", a...) }}
			_, _, err := n.Decide(context.Background(), ep(srv.URL), specByID(t, "decide-nli"), parseFor(t, noulBody))
			c := ce(t, err)
			if c.Status != 502 || c.ErrorType != contract.ErrTypeBackendFailed {
				t.Fatalf("%+v", c)
			}
			if strings.Contains(strings.ToLower(c.Message), "label") || strings.Contains(c.Message, "LABEL") {
				t.Errorf("the client body must stay generic: %q", c.Message)
			}
			if !strings.Contains(logged.String(), "label") {
				t.Errorf("the reason must be logged server-side: %q", logged.String())
			}
			if !n.Degraded(ep(srv.URL)) {
				t.Error("a label configuration error must degrade the instance (readiness), not be guessed around")
			}
		})
	}
}

func TestNLIDegradedExpiresAndClearsOnAValidAnswer(t *testing.T) {
	bad := true
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		if bad {
			b, _ := json.Marshal(map[string]any{"labels": []string{"LABEL_0", "LABEL_1"}, "label_source": "generic-config:x", "scores": [][]float64{{.5, .5}, {.5, .5}}, "truncated": []bool{false, false}})
			_, _ = w.Write(b)
			return
		}
		_, _ = w.Write(dist(ordCanon, "config:x", []bool{false, false}, [3]float64{.6, .2, .2}, [3]float64{.4, .3, .3}))
	})
	now := time.Unix(1_000_000, 0)
	n := &NLIBackend{Logf: func(string, ...any) {}, Now: func() time.Time { return now }}
	e := ep(srv.URL)
	if _, _, err := n.Decide(context.Background(), e, specByID(t, "decide-nli"), parseFor(t, noulBody)); err == nil {
		t.Fatal("bad labels must fail")
	}
	if !n.Degraded(e) {
		t.Fatal("must be degraded")
	}
	now = now.Add(NLIDegradedFor + time.Second) // the runtime may have been fixed: one request re-tests it
	if n.Degraded(e) {
		t.Fatal("the degraded verdict must expire so the instance is re-tested")
	}
	bad = false
	if _, _, err := n.Decide(context.Background(), e, specByID(t, "decide-nli"), parseFor(t, noulBody)); err != nil {
		t.Fatal(err)
	}
	if n.Degraded(e) {
		t.Fatal("a valid answer clears the verdict")
	}
}

func TestNLIRouterReportsADegradedInstanceInsteadOfServingGuesses(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		b, _ := json.Marshal(map[string]any{"labels": []string{"LABEL_0", "LABEL_1"}, "label_source": "generic-config:x", "scores": [][]float64{{.5, .5}, {.5, .5}}, "truncated": []bool{false, false}})
		_, _ = w.Write(b)
	})
	res := NewStaticResolver()
	res.Set(KindDecide, "decide-nli", Endpoint{URL: srv.URL, Key: "k", Healthy: true})
	nli := &NLIBackend{Logf: func(string, ...any) {}}
	rt, err := NewRouter(RouterConfig{Specs: []ProfileSpec{specByID(t, "decide-nli")}, Resolver: res, Profiles: nil,
		Drivers: map[string]Driver{ProtoNLI: nli}})
	if err != nil {
		t.Fatal(err)
	}
	if !rt.Ready() || rt.Models()[0].Status != "ready" {
		t.Fatal("before any call the instance is presumed fine")
	}
	req := parseFor(t, strings.Replace(noulBody, "decide-tiny", "decide-nli", 1))
	if _, _, err := rt.Decide(context.Background(), req); ce(t, err).Status != 502 {
		t.Fatalf("first call: %v", err)
	}
	if rt.Ready() {
		t.Error("readiness must fail while the only NLI instance is mis-configured")
	}
	ms := rt.Models()
	if len(ms) != 1 || ms[0].Status != "degraded" {
		t.Errorf("models: %+v", ms)
	}
	if _, _, err := rt.Decide(context.Background(), req); ce(t, err).Status != 503 {
		t.Errorf("a degraded instance answers 503 not_ready instead of being called again: %v", err)
	}
}

func probOf(a contract.Answer, key string) float64 {
	for _, p := range a.Probabilities {
		if p.Key == key {
			return p.Value
		}
	}
	return math.NaN()
}
