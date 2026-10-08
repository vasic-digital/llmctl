package main

import (
	"encoding/json"
	"strings"
	"testing"
)

const askCalObj = `{"method":"temperature","n":240,"profile_id":"decide-tiny"}`

// a calibrated answer: confidence = calibrated probability 0.8, confidence_raw = shaped 0.4
const askCalBody = `{"model":"decide-tiny","answers":{"q":{"type":"choice","choice":"billing","probabilities":{"billing":0.7,"legal":0.3},"confidence":0.8,"confidence_raw":0.4,"calibration":` + askCalObj + `}},"usage":{"input_tokens":4,"output_tokens":1}}`

type calOut struct {
	Answers map[string]struct {
		Confidence    float64         `json:"confidence"`
		ConfidenceRaw *float64        `json:"confidence_raw"`
		Calibration   json.RawMessage `json:"calibration"`
	} `json:"answers"`
	Evidence struct {
		Calibrated *bool `json:"calibrated"`
	} `json:"evidence"`
	Abstained *bool `json:"abstained"`
}

func TestAskPassesCalibrationFieldsThroughAndMarksEvidence(t *testing.T) {
	r := newAskRig(t)
	r.body = askCalBody
	rc, out, e := r.run("", append(askChoiceArgs, "--json")...)
	if rc != 0 {
		t.Fatalf("rc=%d %s", rc, e)
	}
	var d calOut
	if err := json.Unmarshal([]byte(out), &d); err != nil {
		t.Fatal(err)
	}
	a := d.Answers["q"]
	if a.ConfidenceRaw == nil || *a.ConfidenceRaw != 0.4 || string(a.Calibration) != askCalObj || a.Confidence != 0.8 {
		t.Fatalf("the gateway's additive fields must reach the output: %s", out)
	}
	if d.Evidence.Calibrated == nil || !*d.Evidence.Calibrated {
		t.Fatalf("evidence.calibrated must be true: %s", out)
	}
	// uncalibrated answer: evidence.calibrated is present and false
	r.body = askChoiceBody
	_, out, _ = r.run("", append(askChoiceArgs, "--json")...)
	d = calOut{}
	_ = json.Unmarshal([]byte(out), &d)
	if d.Evidence.Calibrated == nil || *d.Evidence.Calibrated {
		t.Fatalf("evidence.calibrated must be false for an uncalibrated answer: %s", out)
	}
}

// --min-confidence compares the CALIBRATED confidence (0.8) when present, never the shaped 0.4.
func TestMinConfidenceComparesTheCalibratedConfidence(t *testing.T) {
	r := newAskRig(t)
	r.body = askCalBody
	if rc, out, e := r.run("", append(askChoiceArgs, "--json", "--min-confidence", "0.6")...); rc != 0 {
		t.Fatalf("calibrated 0.8 >= 0.6 must pass (shaped 0.4 would abstain): rc=%d %s %s", rc, out, e)
	}
	rc, out, _ := r.run("", append(askChoiceArgs, "--json", "--min-confidence", "0.9")...)
	if rc != 10 || !strings.Contains(out, `"abstained":true`) {
		t.Fatalf("calibrated 0.8 < 0.9 must abstain: rc=%d %s", rc, out)
	}
	// batch uses the same rule
	line := `{"id":1,"state":"s","questions":{"q":{"type":"choice","instructions":"q","criteria":{"billing":"a","legal":"b"}}}}` + "\n"
	if rc, _, _ := r.run(line, "batch", "--min-confidence", "0.6"); rc != 0 {
		t.Fatalf("batch gate rc=%d", rc)
	}
	_, out, _ = r.run(line, "batch")
	if !strings.Contains(out, `"confidence_raw":0.4`) || !strings.Contains(out, `"calibrated":true`) {
		t.Fatalf("batch output lacks the calibration fields: %s", out)
	}
}

func TestExplainShowsRawAndCalibratedConfidence(t *testing.T) {
	r := newAskRig(t)
	r.body = askCalBody
	_, _, e := r.run("", append(askChoiceArgs, "--json", "--explain")...)
	if !strings.Contains(e, "confidence=0.8") || !strings.Contains(e, "confidence_raw=0.4") || !strings.Contains(e, "temperature") {
		t.Fatalf("--explain must show both confidences and the calibration method:\n%s", e)
	}
}

func TestModelsShowsTemplateHashAndCalibration(t *testing.T) {
	r := newAskRig(t)
	h := strings.Repeat("ab", 32)
	r.models = `{"object":"list","data":[` +
		`{"id":"decide-tiny","aliases":["jev-latest"],"protocol":"letter-logit","status":"ready","template_hash":"` + h + `","calibration":{"applied":true,"method":"temperature","n":240,"profile_id":"decide-tiny"}},` +
		`{"id":"decide-big","aliases":[],"protocol":"letter-logit","status":"ready","template_hash":"` + h + `","calibration":{"applied":false,"reason":"mismatch"}},` +
		`{"id":"decide-old","aliases":[],"protocol":"nli-onnx","status":"ready"}]}`
	rc, out, e := r.run("", "models")
	if rc != 0 {
		t.Fatalf("rc=%d %s", rc, e)
	}
	for _, want := range []string{"calibration", "applied", "not applied (mismatch)", "abababababab"} {
		if !strings.Contains(out, want) {
			t.Errorf("models table lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, h) {
		t.Errorf("the table shortens the hash:\n%s", out)
	}
	_, js, _ := r.run("", "models", "--json")
	if !strings.Contains(js, h) || !strings.Contains(js, `"reason":"mismatch"`) {
		t.Errorf("--json passes the gateway body through: %s", js)
	}
}
