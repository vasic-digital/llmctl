package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// B-08: a wrongly typed field in a batch line is a per-line usage error; the line is never sent
// with the default profile.
func TestBatchRejectsWronglyTypedFieldsWithoutSending(t *testing.T) {
	r := newAskRig(t)
	line := func(model string) string {
		return `{"id":7,"model":` + model + `,"state":"s","questions":{"q":{"type":"choice","instructions":"q","criteria":{"billing":"a","legal":"b"}}}}`
	}
	for _, m := range []string{`5`, `null`, `[]`, `{}`, `true`} {
		before := r.hits.Load()
		rc, out, _ := r.run(line(m)+"\n", "batch")
		if rc != 2 {
			t.Errorf("model %s: exit %d, want 2", m, rc)
		}
		var l struct {
			ID    json.RawMessage `json:"id"`
			Error *struct {
				Code int    `json:"exit_code"`
				Msg  string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &l); err != nil || l.Error == nil || l.Error.Code != 2 || !strings.Contains(l.Error.Msg, "model") || string(l.ID) != "7" {
			t.Errorf("model %s: %s", m, out)
		}
		if r.hits.Load() != before {
			t.Errorf("model %s: the line reached the gateway", m)
		}
	}
	bad := []string{`{"id":8,"state":5,"questions":{"q":{}}}`, `{"id":9,"state":"s","questions":[]}`, `{"id":10,"state":null,"questions":{"q":{}}}`}
	for _, b := range bad {
		before := r.hits.Load()
		if rc, _, _ := r.run(b+"\n", "batch"); rc != 2 || r.hits.Load() != before {
			t.Errorf("%s: rc=%d", b, rc)
		}
	}
	if rc, out, _ := r.run(line(`"decide-tiny"`)+"\n", "batch"); rc != 0 || !strings.Contains(out, `"result"`) {
		t.Fatalf("a string model still works: %d %s", rc, out)
	}
	if !strings.Contains(string(r.last), `"model":"decide-tiny"`) {
		t.Fatalf("model forwarded: %s", r.last)
	}
}

func TestQuestionFileWithNonStringModelExits2(t *testing.T) {
	r := newAskRig(t)
	dir := t.TempDir()
	f := dir + "/q.json"
	_ = os.WriteFile(f, []byte(`{"model":5,"state":"s","questions":{"q":{"type":"noul","instructions":"i"}}}`), 0o600)
	before := r.hits.Load()
	rc, _, e := r.run("", "ask", "--question-file", f)
	if rc != 2 || !strings.Contains(e, "model") || r.hits.Load() != before {
		t.Fatalf("rc=%d %s", rc, e)
	}
}

// B-16: --permute K.
func TestAskPermuteAsksKRotationsAndReportsFlipRate(t *testing.T) {
	r := newAskRig(t)
	rc, out, e := r.run("", append(askChoiceArgs, "--json", "--permute", "2")...)
	if rc != 0 {
		t.Fatalf("rc=%d %s", rc, e)
	}
	if r.hits.Load() != 2 {
		t.Fatalf("K=2 is two gateway calls, got %d", r.hits.Load())
	}
	if !strings.Contains(string(r.last), `"criteria":{"legal":"contracts","billing":"invoices"}`) {
		t.Fatalf("the second call lists the options rotated by one: %s", r.last)
	}
	var d struct {
		Evidence struct {
			Permute struct {
				K        int     `json:"k"`
				FlipRate float64 `json:"flip_rate"`
			} `json:"permute"`
		} `json:"evidence"`
		Answers map[string]struct {
			Choice string `json:"choice"`
		} `json:"answers"`
	}
	if err := json.Unmarshal([]byte(out), &d); err != nil || d.Evidence.Permute.K != 2 || d.Answers["q"].Choice != "billing" {
		t.Fatalf("%v %s", err, out)
	}
	// no --permute: a single call, no permute evidence
	r2 := newAskRig(t)
	_, out2, _ := r2.run("", append(askChoiceArgs, "--json")...)
	if r2.hits.Load() != 1 || strings.Contains(out2, `"permute"`) {
		t.Fatalf("%d %s", r2.hits.Load(), out2)
	}
	for _, bad := range []string{"0", "-3", "x", "1000"} {
		if rc, _, _ := r2.run("", append(askChoiceArgs, "--permute", bad)...); rc != 2 {
			t.Errorf("--permute %s: exit %d, want 2", bad, rc)
		}
	}
}

// B-01/B3-01: a flagged answer is visible in the evidence and held back by --min-confidence at its worst case.
func TestFlaggedAnswerIsEvidencedAndHeldByTheGate(t *testing.T) {
	r := newAskRig(t)
	r.body = `{"model":"decide-tiny","answers":{"q":{"type":"choice","choice":"billing","probabilities":{"billing":0.75,"legal":0.25},"confidence":0.5,"flags":["option_missing"],"upper_bounds":{"legal":0.25}}},"usage":{"input_tokens":4,"output_tokens":1}}`
	rc, out, _ := r.run("", append(askChoiceArgs, "--json", "--min-confidence", "0.8")...)
	if rc != 10 || !strings.Contains(out, `"flagged":true`) || !strings.Contains(out, `"abstained":true`) {
		t.Fatalf("the worst case (absent option at 0.25) leaves confidence 0.5: rc=%d %s", rc, out)
	}
	if rc, out, _ = r.run("", append(askChoiceArgs, "--json", "--min-confidence", "0.4")...); rc != 0 || !strings.Contains(out, `"flagged":true`) {
		t.Fatalf("rc=%d %s", rc, out)
	}
}

// B2-09: "model":"" in a batch line or a question file is a usage error, never the default profile.
func TestEmptyModelIsAUsageErrorInBatchAndQuestionFile(t *testing.T) {
	r := newAskRig(t)
	before := r.hits.Load()
	line := `{"id":3,"model":"","state":"s","questions":{"q":{"type":"noul","instructions":"i"}}}`
	rc, out, _ := r.run(line+"\n", "batch")
	if rc != 2 || !strings.Contains(out, `"error"`) || !strings.Contains(out, "model") || r.hits.Load() != before {
		t.Fatalf("batch: rc=%d out=%s hits=%d", rc, out, r.hits.Load()-before)
	}
	f := t.TempDir() + "/q.json"
	_ = os.WriteFile(f, []byte(line), 0o600)
	rc, _, e := r.run("", "ask", "--question-file", f)
	if rc != 2 || !strings.Contains(e, "model") || r.hits.Load() != before {
		t.Fatalf("question file: rc=%d %s", rc, e)
	}
}
