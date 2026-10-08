package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// probeRig is the ask rig (key, CA, isolated environment) pointed at an order-dependent fake
// gateway: with positionBias every choice question gives 0.7 to the option LISTED first, otherwise
// 0.8 to the option "billing" (or the first key when there is none) wherever it is listed.
type probeRig struct {
	*askRig
	hits      atomic.Int32
	bodies    [][]byte
	positionB bool
}

func newProbeRig(t *testing.T, positionBias bool) *probeRig {
	t.Helper()
	p := &probeRig{askRig: newAskRig(t), positionB: positionBias}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.hits.Add(1)
		b, _ := io.ReadAll(r.Body)
		p.bodies = append(p.bodies, b)
		var doc struct {
			Questions map[string]struct {
				Type     string          `json:"type"`
				Criteria json.RawMessage `json:"criteria"`
			} `json:"questions"`
		}
		_ = json.Unmarshal(b, &doc)
		var parts []string
		for name, q := range doc.Questions {
			nb, _ := json.Marshal(name)
			if q.Type != "choice" {
				parts = append(parts, string(nb)+`:{"type":"noul","noul":0.9}`)
				continue
			}
			keys := probeKeys(q.Criteria)
			var pr []string
			best, bp := 0, -1.0
			for i, k := range keys {
				pv := 0.1
				if (p.positionB && i == 0) || (!p.positionB && (k == "billing" || (i == 0 && !contains(keys, "billing")))) {
					pv = 0.7
				}
				kb, _ := json.Marshal(k)
				fb, _ := json.Marshal(pv)
				pr = append(pr, string(kb)+":"+string(fb))
				if pv > bp {
					best, bp = i, pv
				}
			}
			cb, _ := json.Marshal(keys[best])
			parts = append(parts, string(nb)+`:{"type":"choice","choice":`+string(cb)+`,"probabilities":{`+strings.Join(pr, ",")+`},"confidence":0.5}`)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"model":"decide-tiny","answers":{` + strings.Join(parts, ",") + `},"usage":{"input_tokens":1,"output_tokens":1}}`))
	}))
	t.Cleanup(srv.Close)
	p.env["LLMCTL_ENDPOINT"] = srv.URL
	return p
}

func contains(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

func probeKeys(raw json.RawMessage) []string {
	dec := json.NewDecoder(bytes.NewReader(raw))
	_, _ = dec.Token()
	var keys []string
	for dec.More() {
		kt, _ := dec.Token()
		keys = append(keys, kt.(string))
		var skip json.RawMessage
		_ = dec.Decode(&skip)
	}
	return keys
}

func (p *probeRig) file(name, content string) string {
	p.t.Helper()
	f := filepath.Join(p.t.TempDir(), name)
	if err := os.WriteFile(f, []byte(content), 0o600); err != nil {
		p.t.Fatal(err)
	}
	return f
}

const probeDoc = `{"id":"t1","state":"The invoice is overdue.","questions":{"team":{"type":"choice","instructions":"Which team?","criteria":{"billing":"invoices","legal":"contracts","sales":"deals"}}}}`

type probeOut struct {
	Calls     int `json:"calls"`
	Documents []struct {
		ID        string `json:"id"`
		Calls     int    `json:"calls"`
		Questions []struct {
			Name       string    `json:"name"`
			Permutable bool      `json:"permutable"`
			Reason     string    `json:"reason"`
			Orders     int       `json:"orders"`
			Answer     string    `json:"answer"`
			Flips      int       `json:"flips"`
			FlipRate   float64   `json:"flip_rate"`
			PosShare   []float64 `json:"position_share"`
			MaxDev     float64   `json:"max_position_deviation"`
		} `json:"questions"`
	} `json:"documents"`
	Summary struct {
		Trials   int     `json:"trials"`
		Flips    int     `json:"flips"`
		FlipRate float64 `json:"flip_rate"`
		MaxDev   float64 `json:"max_position_deviation"`
	} `json:"summary"`
}

func TestProbeOrderContentRobustModel(t *testing.T) {
	p := newProbeRig(t, false)
	rc, out, errs := p.run("", "probe-order", "--questions", p.file("q.json", probeDoc), "--json")
	if rc != 0 {
		t.Fatalf("rc=%d %s", rc, errs)
	}
	var o probeOut
	if err := json.Unmarshal([]byte(out), &o); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, out)
	}
	q := o.Documents[0].Questions[0]
	if o.Calls != 3 || p.hits.Load() != 3 || q.Orders != 3 || q.Answer != "billing" || q.Flips != 0 || o.Summary.FlipRate != 0 {
		t.Errorf("out = %+v hits %d", o, p.hits.Load())
	}
	if o.Documents[0].ID != "t1" {
		t.Errorf("id = %q", o.Documents[0].ID)
	}
	// the three requests list the options in the three cyclic orders
	var orders []string
	for _, b := range p.bodies {
		var d struct {
			Q map[string]struct{ Criteria json.RawMessage } `json:"questions"`
		}
		json.Unmarshal(b, &d)
		orders = append(orders, strings.Join(probeKeys(d.Q["team"].Criteria), ","))
	}
	if strings.Join(orders, "|") != "billing,legal,sales|legal,sales,billing|sales,billing,legal" {
		t.Errorf("orders = %v", orders)
	}
}

func TestProbeOrderPositionBiasedModelShowsFlipsAndBias(t *testing.T) {
	p := newProbeRig(t, true)
	rc, out, errs := p.run("", "probe-order", "--questions", p.file("q.json", probeDoc), "--json", "--profile", "decide-tiny")
	if rc != 0 {
		t.Fatalf("rc=%d %s", rc, errs)
	}
	var o probeOut
	json.Unmarshal([]byte(out), &o)
	q := o.Documents[0].Questions[0]
	// hand count: see internal/client TestProbeOrderPositionBiasedModel...: 2 of 3 orders flip, share [1,0,0]
	if q.Flips != 2 || q.PosShare[0] != 1 || o.Summary.FlipRate < 0.666 || o.Summary.FlipRate > 0.667 || o.Summary.MaxDev < 0.666 {
		t.Errorf("out = %+v", o)
	}
	var sent struct {
		Model string `json:"model"`
	}
	json.Unmarshal(p.bodies[0], &sent)
	if sent.Model != "decide-tiny" {
		t.Errorf("--profile not sent as model: %q", sent.Model)
	}
}

func TestProbeOrderTextReport(t *testing.T) {
	p := newProbeRig(t, true)
	rc, out, errs := p.run("", "probe-order", "--questions", p.file("q.json", probeDoc))
	if rc != 0 {
		t.Fatalf("rc=%d %s", rc, errs)
	}
	for _, want := range []string{"probe-order:", "3 gateway calls", "team", "flip rate 0.667", "position", "1.000", "overall:"} {
		if !strings.Contains(out, want) {
			t.Errorf("text report lacks %q:\n%s", want, out)
		}
	}
}

func TestProbeOrderInputShapes(t *testing.T) {
	p := newProbeRig(t, false)
	// NDJSON of two requests
	nd := probeDoc + "\n" + strings.Replace(probeDoc, `"t1"`, `"t2"`, 1) + "\n"
	rc, out, errs := p.run("", "probe-order", "--questions", p.file("q.ndjson", nd), "--json")
	var o probeOut
	if rc != 0 || json.Unmarshal([]byte(out), &o) != nil || len(o.Documents) != 2 || o.Documents[1].ID != "t2" || o.Calls != 6 {
		t.Fatalf("ndjson: rc=%d %v\n%s", rc, errs, out)
	}
	// a JSON array of requests without an id
	noID := strings.Replace(probeDoc, `"id":"t1",`, "", 1)
	rc, out, errs = p.run("", "probe-order", "--questions", p.file("q.json", "["+noID+","+noID+"]"), "--json")
	o = probeOut{}
	if rc != 0 || json.Unmarshal([]byte(out), &o) != nil || len(o.Documents) != 2 {
		t.Fatalf("array: rc=%d %v\n%s", rc, errs, out)
	}
	if o.Documents[0].ID != "1" || o.Documents[1].ID != "2" {
		t.Errorf("documents without an id are numbered: %q %q", o.Documents[0].ID, o.Documents[1].ID)
	}
	// a bare Typed Question needs the state from --state-file
	bare := `{"type":"choice","instructions":"Which team?","criteria":{"billing":"i","legal":"c"}}`
	st := p.file("state.txt", "overdue invoice")
	rc, out, errs = p.run("", "probe-order", "--questions", p.file("b.json", bare), "--state-file", st, "--json")
	o = probeOut{}
	if rc != 0 || json.Unmarshal([]byte(out), &o) != nil || o.Documents[0].Questions[0].Name != "q" || o.Calls != 2 {
		t.Fatalf("bare question: rc=%d %v\n%s", rc, errs, out)
	}
	// stdin
	rc, _, errs = p.run(probeDoc, "probe-order", "--questions", "-", "--json")
	if rc != 0 {
		t.Fatalf("stdin: rc=%d %s", rc, errs)
	}
}

func TestProbeOrderNonChoiceQuestionsAreReportedNotPermutable(t *testing.T) {
	p := newProbeRig(t, false)
	doc := `{"state":"s","questions":{"team":{"type":"choice","instructions":"w","criteria":{"billing":"i","legal":"c"}},"n":{"type":"noul","instructions":"yes?"},"s":{"type":"score","instructions":"how","criteria":["lo","hi"]}}}`
	rc, out, errs := p.run("", "probe-order", "--questions", p.file("q.json", doc), "--json")
	var o probeOut
	if rc != 0 || json.Unmarshal([]byte(out), &o) != nil {
		t.Fatalf("rc=%d %s %s", rc, errs, out)
	}
	byName := map[string]bool{}
	for _, q := range o.Documents[0].Questions {
		byName[q.Name] = q.Permutable
		if !q.Permutable && q.Reason == "" {
			t.Errorf("%s: no reason", q.Name)
		}
	}
	if !byName["team"] || byName["n"] || byName["s"] || len(byName) != 3 {
		t.Errorf("permutable map = %v", byName)
	}
	// nothing permutable at all: a usage error, and no call is made
	before := p.hits.Load()
	rc, _, errs = p.run("", "probe-order", "--questions", p.file("n.json", `{"state":"s","questions":{"n":{"type":"noul","instructions":"yes?"}}}`))
	if rc != 2 || !strings.Contains(errs, "nothing to probe") || p.hits.Load() != before {
		t.Errorf("rc=%d hits +%d %s", rc, p.hits.Load()-before, errs)
	}
}

func TestProbeOrderPermuteFlag(t *testing.T) {
	p := newProbeRig(t, false)
	rc, out, errs := p.run("", "probe-order", "--questions", p.file("q.json", probeDoc), "--permute", "2", "--json")
	var o probeOut
	if rc != 0 || json.Unmarshal([]byte(out), &o) != nil || o.Calls != 2 || !strings.Contains(out, `"partial_cycle":true`) {
		t.Fatalf("--permute 2: rc=%d %s\n%s", rc, errs, out)
	}
}

func TestProbeOrderUsageErrorsExit2AndNeverReachTheNetwork(t *testing.T) {
	p := newProbeRig(t, false)
	good := p.file("q.json", probeDoc)
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"no questions", nil, "--questions"},
		{"missing file", []string{"--questions", filepath.Join(t.TempDir(), "none.json")}, "cannot read"},
		{"not json", []string{"--questions", p.file("x.json", "{nope")}, "JSON"},
		{"empty file", []string{"--questions", p.file("e.json", "  \n")}, "empty"},
		{"permute 1", []string{"--questions", good, "--permute", "1"}, "--permute"},
		{"permute 65", []string{"--questions", good, "--permute", "65"}, "--permute"},
		{"permute word", []string{"--questions", good, "--permute", "many"}, "--permute"},
		{"unknown flag", []string{"--questions", good, "--nope"}, "nope"},
		{"stray arg", []string{"--questions", good, "extra"}, "unexpected argument"},
		{"no state", []string{"--questions", p.file("ns.json", `{"questions":{"q":{"type":"choice","instructions":"w","criteria":{"a":"1","b":"2"}}}}`)}, "state"},
		{"questions not object", []string{"--questions", p.file("qn.json", `{"state":"s","questions":[1]}`)}, "questions"},
		{"one option", []string{"--questions", p.file("o.json", `{"state":"s","questions":{"q":{"type":"choice","instructions":"w","criteria":{"a":"1"}}}}`)}, "invalid request"},
		{"empty profile", []string{"--questions", good, "--profile", ""}, "profile"},
	}
	for _, c := range cases {
		rc, out, errs := p.run("", append([]string{"probe-order"}, c.args...)...)
		if rc != 2 || !strings.Contains(errs, c.want) || out != "" {
			t.Errorf("%s: rc=%d stdout=%q stderr=%q (want exit 2 mentioning %q)", c.name, rc, out, errs, c.want)
		}
	}
	if p.hits.Load() != 0 {
		t.Errorf("usage errors reached the network %d times", p.hits.Load())
	}
}

func TestProbeOrderExitCodesFromTheClient(t *testing.T) {
	p := newProbeRig(t, false)
	q := p.file("q.json", probeDoc)
	delete(p.env, "LLMCTL_API_KEY")
	if rc, _, e := p.run("", "probe-order", "--questions", q); rc != 4 || !strings.Contains(e, "key") {
		t.Errorf("no key: rc=%d %s", rc, e)
	}
	p.env["LLMCTL_API_KEY"] = askTestKey
	bad := filepath.Join(t.TempDir(), "garbage.crt")
	os.WriteFile(bad, []byte("garbage"), 0o644)
	p.env["LLMCTL_CACERT"] = bad
	if rc, _, _ := p.run("", "probe-order", "--questions", q); rc != 5 {
		t.Errorf("bad CA: rc=%d", rc)
	}
	p.env["LLMCTL_CACERT"] = p.ca
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	ln.Close()
	p.env["LLMCTL_ENDPOINT"] = "https://" + addr
	if rc, _, _ := p.run("", "probe-order", "--questions", q, "--retries", "0"); rc != 6 {
		t.Errorf("closed port: rc=%d", rc)
	}
	// backend failure: the gateway answers every call with a readout failure
	fail := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(422)
		_, _ = w.Write([]byte(`{"message":"The model produced no usable answer for this question.","error_type":"readout_failed"}`))
	}))
	defer fail.Close()
	p.env["LLMCTL_ENDPOINT"] = fail.URL
	rc, out, _ := p.run("", "probe-order", "--questions", q)
	if rc != 1 || out != "" {
		t.Errorf("backend failure: rc=%d stdout=%q (a failed probe prints no partial result)", rc, out)
	}
}

func TestProbeOrderIsDeterministicAndNeverPrintsTheKey(t *testing.T) {
	p := newProbeRig(t, true)
	args := []string{"probe-order", "--questions", p.file("q.json", probeDoc), "--json"}
	_, a, _ := p.run("", args...) // run() fails the test if the key leaks
	_, b, _ := p.run("", args...)
	if a != b || a == "" {
		t.Errorf("two runs differ:\n%s\n%s", a, b)
	}
}
