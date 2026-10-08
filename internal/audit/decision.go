package audit

import (
	"math"
	"time"

	"github.com/vasic-digital/llmctl/internal/placement"
)

// The decision log (FR-080, 2-I05) is the opt-in record of what the gateway DECIDED, kept for
// external calibration and quality review. It is a different file from the request log: the
// request log never carries text, this one carries the state, the question text and the chosen
// option key ONLY when the operator consented (LLMCTL_DECIDE_LOG_STATE=1). Without consent a record
// holds only closed-vocabulary and numeric facts - the answer is summarised by the INDEX of the
// chosen option, never its key. Credentials have no field here: there is nothing to log.

// DecisionAnswer is one answered question as the builder receives it. Name, Question and ChoiceKey
// are client-supplied text and are dropped unless DecisionFields.Consent is true.
type DecisionAnswer struct {
	Name          string
	Question      string // the question's instructions
	Type          string // noul | choice | score
	ChoiceIndex   int    // index of the winning option among the question's options; < 0 = none (noul)
	ChoiceKey     string
	Value         *float64 // noul probability, or score value
	Confidence    *float64 // the served confidence (calibrated when Calibrated)
	ConfidenceRaw *float64 // the shaped confidence before calibration (set when Calibrated)
	Calibrated    bool
	Flags         []string // subset of {option_missing}; anything else collapses to "other"
}

// DecisionFields is the complete input of NewDecisionRecord.
type DecisionFields struct {
	RequestID          string
	Profile            string
	Status             int
	Millis             float64
	Now                time.Time
	ModelSHA256        string // 64 lowercase hex of the model file ("" = unknown)
	TemplateHash       string // 64 lowercase hex ("" = unknown)
	CalibrationProfile string // the calibration profile applied ("" = none)
	Answers            []DecisionAnswer
	// Consent is LLMCTL_DECIDE_LOG_STATE=1: only then are State, Name, Question and ChoiceKey kept.
	Consent bool
	State   string
}

// DecisionAnswerRecord is the serialised answer summary (keys in alphabetical order).
type DecisionAnswerRecord struct {
	Calibrated    bool     `json:"calibrated"`
	Choice        *string  `json:"choice,omitempty"`
	ChoiceIndex   *int     `json:"choice_index,omitempty"`
	Confidence    *float64 `json:"confidence,omitempty"`
	ConfidenceRaw *float64 `json:"confidence_raw,omitempty"`
	Flags         []string `json:"flags,omitempty"`
	Name          *string  `json:"name,omitempty"`
	Question      *string  `json:"question,omitempty"`
	Type          string   `json:"type"`
	Value         *float64 `json:"value,omitempty"`
}

// DecisionTypes counts the questions by type.
type DecisionTypes struct {
	Choice int `json:"choice"`
	Noul   int `json:"noul"`
	Score  int `json:"score"`
}

// DecisionRecord is one decision-log entry (keys in alphabetical order).
type DecisionRecord struct {
	Answers            []DecisionAnswerRecord `json:"answers"`
	CalibrationProfile *string                `json:"calibration_profile"`
	LatencyMS          float64                `json:"latency_ms"`
	ModelSHA256        *string                `json:"model_sha256"`
	Profile            *string                `json:"profile"`
	RequestID          string                 `json:"request_id"`
	State              *string                `json:"state,omitempty"`
	StateLogged        bool                   `json:"state_logged"`
	Status             int                    `json:"status"`
	TemplateHash       *string                `json:"template_hash"`
	TS                 string                 `json:"ts"`
	Types              DecisionTypes          `json:"types"`
}

func finitePtr(p *float64) *float64 {
	if p == nil || math.IsNaN(*p) || math.IsInf(*p, 0) {
		return nil
	}
	v := *p
	return &v
}

func hexOrInvalid(s string) *string {
	if s == "" {
		return nil
	}
	if !hex64Re.MatchString(s) {
		s = "invalid"
	}
	return &s
}

func profileOrOther(s string) *string {
	if s == "" {
		return nil
	}
	if !profileRe.MatchString(s) {
		s = "other"
	}
	return &s
}

// NewDecisionRecord sanitises f into a DecisionRecord. Every closed-vocabulary member collapses to
// a safe constant when unexpected; free text (state, question, name, choice key) is carried only
// when f.Consent is true.
func NewDecisionRecord(f DecisionFields) DecisionRecord {
	now := f.Now
	if now.IsZero() {
		now = time.Now()
	}
	r := DecisionRecord{
		TS: now.UTC().Format("2006-01-02T15:04:05Z"), RequestID: "invalid", LatencyMS: num(f.Millis, 3),
		Answers: []DecisionAnswerRecord{}, StateLogged: f.Consent,
		CalibrationProfile: profileOrOther(f.CalibrationProfile), Profile: profileOrOther(f.Profile),
		ModelSHA256: hexOrInvalid(f.ModelSHA256), TemplateHash: hexOrInvalid(f.TemplateHash),
	}
	if reqIDRe.MatchString(f.RequestID) {
		r.RequestID = f.RequestID
	}
	if f.Status >= 100 && f.Status <= 599 {
		r.Status = f.Status
	}
	if f.Consent {
		st := f.State
		r.State = &st
	}
	for _, a := range f.Answers {
		ar := DecisionAnswerRecord{Calibrated: a.Calibrated, Type: "other",
			Value: finitePtr(a.Value), Confidence: finitePtr(a.Confidence), ConfidenceRaw: finitePtr(a.ConfidenceRaw)}
		switch a.Type {
		case "choice":
			r.Types.Choice++
			ar.Type = a.Type
		case "score":
			r.Types.Score++
			ar.Type = a.Type
		case "noul":
			r.Types.Noul++
			ar.Type = a.Type
		}
		if a.ChoiceIndex >= 0 {
			i := a.ChoiceIndex
			ar.ChoiceIndex = &i
		}
		for _, fl := range a.Flags {
			if fl != "option_missing" {
				fl = "other"
			}
			ar.Flags = append(ar.Flags, fl)
		}
		if f.Consent {
			n, q := a.Name, a.Question
			ar.Name, ar.Question = &n, &q
			if a.ChoiceKey != "" {
				k := a.ChoiceKey
				ar.Choice = &k
			}
		}
		r.Answers = append(r.Answers, ar)
	}
	return r
}

// DecisionLine renders r as one ASCII-escaped JSON line (no trailing newline).
func DecisionLine(r DecisionRecord) string { return asciiJSON(r) }

// NewDecisionSink opens the decision log. It refuses, BEFORE creating anything, a path inside an
// unignored git work tree (the FR-087 placement guard: this file may hold the state text), then
// opens it exactly like the request log - mode 0600 (a looser pre-existing file is tightened),
// parents 0700, O_NOFOLLOW (a symlink is refused), reopened after rotation.
func NewDecisionSink(path string) (*Sink, error) {
	if err := placement.Check(placement.Spec{
		Path: path,
		What: "the decision log",
		Fix:  "set LLMCTL_DECIDE_DECISION_LOG to a path outside the repository, or add the log directory to .gitignore",
	}); err != nil {
		return nil, err
	}
	return NewSink(path)
}
