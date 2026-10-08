package audit_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/audit"
)

func f64(x float64) *float64 { return &x }

func decisionFields(consent bool) audit.DecisionFields {
	return audit.DecisionFields{
		RequestID: "0123456789abcdef", Profile: "decide-tiny", Status: 200, Millis: 12.3456,
		Now:         time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC),
		ModelSHA256: strings.Repeat("a", 64), TemplateHash: strings.Repeat("b", 64), CalibrationProfile: "decide-tiny",
		Consent: consent, State: secretState,
		Answers: []audit.DecisionAnswer{
			{Name: "urgent-question-name", Question: "Is SECRET-QUESTION urgent?", Type: "noul", ChoiceIndex: -1, Value: f64(0.7)},
			{Name: "team", Question: "Which SECRET-TEAM?", Type: "choice", ChoiceIndex: 1, ChoiceKey: "SECRET-KEY-support",
				Confidence: f64(0.61), ConfidenceRaw: f64(0.5), Calibrated: true, Flags: []string{"option_missing"}},
			{Name: "rate", Question: "Rate", Type: "score", ChoiceIndex: 2, ChoiceKey: "2", Value: f64(2.4), Confidence: f64(0.4), ConfidenceRaw: f64(0.4)},
		},
	}
}

func TestDecisionRecordWithoutConsentCarriesNoText(t *testing.T) {
	line := audit.DecisionLine(audit.NewDecisionRecord(decisionFields(false)))
	for _, leak := range []string{secretState, "SECRET-QUESTION", "SECRET-TEAM", "SECRET-KEY", "urgent-question-name", `"state"`, `"question"`, `"name"`, `"choice":"`} {
		if strings.Contains(line, leak) {
			t.Errorf("record without consent leaked %q: %s", leak, line)
		}
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, line)
	}
	for k, want := range map[string]any{"request_id": "0123456789abcdef", "profile": "decide-tiny", "status": 200.0,
		"model_sha256": strings.Repeat("a", 64), "template_hash": strings.Repeat("b", 64), "calibration_profile": "decide-tiny",
		"ts": "2026-10-08T12:00:00Z", "latency_ms": 12.346, "state_logged": false} {
		if m[k] != want {
			t.Errorf("%s = %v, want %v", k, m[k], want)
		}
	}
	types := m["types"].(map[string]any)
	if types["noul"] != 1.0 || types["choice"] != 1.0 || types["score"] != 1.0 {
		t.Errorf("types = %v", types)
	}
	ans := m["answers"].([]any)
	if len(ans) != 3 {
		t.Fatalf("answers = %v", ans)
	}
	c := ans[1].(map[string]any)
	if c["choice_index"] != 1.0 || c["confidence"] != 0.61 || c["confidence_raw"] != 0.5 || c["calibrated"] != true {
		t.Errorf("choice summary = %v", c)
	}
	if fl := c["flags"].([]any); len(fl) != 1 || fl[0] != "option_missing" {
		t.Errorf("flags = %v", c["flags"])
	}
	if ans[0].(map[string]any)["value"] != 0.7 || ans[2].(map[string]any)["value"] != 2.4 {
		t.Errorf("values: %v", ans)
	}
}

func TestDecisionRecordWithConsentCarriesStateAndQuestions(t *testing.T) {
	line := audit.DecisionLine(audit.NewDecisionRecord(decisionFields(true)))
	for _, want := range []string{secretState, "SECRET-QUESTION", "SECRET-TEAM", "SECRET-KEY-support", "urgent-question-name"} {
		if !strings.Contains(line, want) {
			t.Errorf("consenting record lacks %q: %s", want, line)
		}
	}
	var m map[string]any
	_ = json.Unmarshal([]byte(line), &m)
	if m["state_logged"] != true || m["state"] != secretState {
		t.Errorf("state fields: %v", m["state_logged"])
	}
}

func TestDecisionRecordIsOneLineAndHostileValuesAreContained(t *testing.T) {
	f := decisionFields(true)
	f.State = "line1\nline2\r\n{\"fake\":\"record\"} é\x00"
	f.RequestID = "../../etc/passwd"
	f.Profile = "bad profile\n"
	f.ModelSHA256 = "not-hex"
	f.TemplateHash = "also not"
	f.CalibrationProfile = "x\ny"
	f.Status = 99999
	f.Answers[1].Flags = []string{"option_missing", "inject\nme"}
	line := audit.DecisionLine(audit.NewDecisionRecord(f))
	if strings.ContainsAny(line, "\n\r") {
		t.Fatalf("a record must be one line: %q", line)
	}
	for _, r := range line {
		if r >= 0x80 {
			t.Fatalf("record must be ASCII-escaped: %q", line)
		}
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		t.Fatal(err)
	}
	if m["request_id"] != "invalid" || m["profile"] != "other" || m["model_sha256"] != "invalid" ||
		m["template_hash"] != "invalid" || m["calibration_profile"] != "other" || m["status"] != 0.0 {
		t.Errorf("closed vocabularies did not collapse: %v", m)
	}
	if fl := m["answers"].([]any)[1].(map[string]any)["flags"].([]any); len(fl) != 2 || fl[1] != "other" {
		t.Errorf("flags: %v", fl)
	}
	if m["state"] != f.State {
		t.Errorf("state did not round-trip through JSON escaping")
	}
}

func TestDecisionRecordNullsAndNoKeyMaterial(t *testing.T) {
	f := audit.DecisionFields{RequestID: "0123456789abcdef", Status: 422, Now: time.Unix(0, 0)}
	line := audit.DecisionLine(audit.NewDecisionRecord(f))
	var m map[string]any
	_ = json.Unmarshal([]byte(line), &m)
	if m["profile"] != nil || m["calibration_profile"] != nil || m["model_sha256"] != nil || m["template_hash"] != nil {
		t.Errorf("unset optional fields must be null: %v", m)
	}
	if a, ok := m["answers"].([]any); !ok || len(a) != 0 {
		t.Errorf("answers must be an empty list on a failed request: %v", m["answers"])
	}
	for _, banned := range []string{"authorization", "bearer", "api_key", "apikey", "x-api-key"} {
		if strings.Contains(strings.ToLower(line), banned) {
			t.Errorf("record mentions %q", banned)
		}
	}
}

func TestNewDecisionSinkModeSymlinkAndPlacement(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sub", "decisions.jsonl")
	s, err := audit.NewDecisionSink(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.WriteLine(audit.DecisionLine(audit.NewDecisionRecord(decisionFields(false)))); err != nil {
		t.Fatal(err)
	}
	s.Close()
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v err %v, want 0600", st.Mode().Perm(), err)
	}
	b, _ := os.ReadFile(path)
	if strings.Count(string(b), "\n") != 1 {
		t.Errorf("want one line, got %q", b)
	}
	// a pre-existing loose file is tightened; a symlink is refused
	loose := filepath.Join(dir, "loose.jsonl")
	if err := os.WriteFile(loose, nil, 0o666); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(loose, 0o666); err != nil {
		t.Fatal(err)
	}
	if s2, err := audit.NewDecisionSink(loose); err != nil {
		t.Fatal(err)
	} else {
		s2.Close()
	}
	if st, _ := os.Stat(loose); st.Mode().Perm() != 0o600 {
		t.Errorf("loose file not tightened: %v", st.Mode().Perm())
	}
	link := filepath.Join(dir, "link.jsonl")
	if err := os.Symlink(loose, link); err != nil {
		t.Fatal(err)
	}
	if _, err := audit.NewDecisionSink(link); err == nil {
		t.Error("a symlinked decision log must be refused")
	}
	// FR-087 placement guard: refused inside an unignored work tree, allowed once ignored
	repo := t.TempDir()
	if out, err := exec.Command("git", "-C", repo, "init", "-q").CombinedOutput(); err != nil {
		t.Skipf("git unavailable: %v %s", err, out)
	}
	_, err = audit.NewDecisionSink(filepath.Join(repo, "logs", "decisions.jsonl"))
	if err == nil || !strings.Contains(err.Error(), "decision log") {
		t.Fatalf("an unignored work tree must be refused with a message naming the decision log, got %v", err)
	}
	if _, serr := os.Stat(filepath.Join(repo, "logs")); serr == nil {
		t.Error("nothing may be created before the placement refusal")
	}
	if err := os.WriteFile(filepath.Join(repo, ".gitignore"), []byte("logs/\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s3, err := audit.NewDecisionSink(filepath.Join(repo, "logs", "decisions.jsonl"))
	if err != nil {
		t.Fatalf("an ignored path is allowed: %v", err)
	}
	s3.Close()
}
