package client

import (
	"bytes"
	"encoding/json"
	"strings"
	"unicode/utf8"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// MaxInputBytes caps any one input read by the client (state, question file, batch line).
const MaxInputBytes = 256 << 20

// DefaultQuestionName keys the single question built from flags or a question file.
const DefaultQuestionName = "q"

// Input is what the command line collected for one request.
type Input struct {
	Model        string // profile / model id; "" = the gateway default
	State        string // state text; HasState tells "" from absent
	HasState     bool
	Type         string          // noul | choice | score (flags path)
	Instructions string          // flags path
	Criteria     json.RawMessage // flags path: raw JSON, order preserved; nil = none
	QuestionFile []byte          // a Typed Question object, or a full request object
}

// Built is a validated, serialised request.
type Built struct {
	Body       []byte // what is POSTed
	Local      []byte // the same request without "model", for local validation
	Model      string
	StateBytes int
	Questions  int
}

func compactRaw(raw json.RawMessage) (json.RawMessage, error) {
	var b bytes.Buffer
	if err := json.Compact(&b, raw); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func jstr(s string) []byte {
	b, _ := json.Marshal(s)
	return b
}

// Build serialises an Input into a /v1/systemone body. Errors are usage errors (exit 2).
func Build(in Input) (*Built, error) {
	if !utf8.ValidString(in.State) {
		return nil, errf(KindUsage, "the state is not valid UTF-8 text")
	}
	var questions, state json.RawMessage
	var top map[string]json.RawMessage
	if len(in.QuestionFile) > 0 {
		if err := json.Unmarshal(in.QuestionFile, &top); err != nil || top == nil {
			return nil, errf(KindUsage, "the question file is not a JSON object")
		}
		if m, ok := top["model"]; ok { // a wrongly typed model must never silently become the default
			var ms string
			if json.Unmarshal(m, &ms) != nil || bytes.Equal(bytes.TrimSpace(m), []byte("null")) {
				return nil, errf(KindUsage, `"model" in the request must be a string (a profile id)`)
			}
			if ms == "" { // an explicit empty model must not silently become the default profile (B2-09)
				return nil, errf(KindUsage, `"model" in the request must not be empty (omit it for the default profile)`)
			}
		}
		if q, ok := top["questions"]; ok {
			// a full request object: questions (and maybe state / model) come from the file
			if t := bytes.TrimSpace(q); len(t) == 0 || t[0] != '{' {
				return nil, errf(KindUsage, `"questions" in the request must be an object of name -> question`)
			}
			questions = q
			if s, ok := top["state"]; ok {
				if t := bytes.TrimSpace(s); len(t) == 0 || (t[0] != '"' && t[0] != '{' && t[0] != '[') {
					return nil, errf(KindUsage, `"state" in the request must be text, an object or an array`)
				}
				state = s
			}
		} else {
			one, err := compactRaw(in.QuestionFile)
			if err != nil {
				return nil, errf(KindUsage, "the question file is not valid JSON")
			}
			questions = json.RawMessage(`{"` + DefaultQuestionName + `":` + string(one) + `}`)
		}
	} else {
		switch in.Type {
		case contract.TypeNoul, contract.TypeChoice, contract.TypeScore:
		case "":
			return nil, errf(KindUsage, "--type {noul|choice|score} (or --question-file) is required")
		default:
			return nil, errf(KindUsage, "unknown type "+quoteShort(in.Type)+" (noul|choice|score)")
		}
		if strings.TrimSpace(in.Instructions) == "" {
			return nil, errf(KindUsage, "--instructions is required")
		}
		var q bytes.Buffer
		q.WriteString(`{"type":`)
		q.Write(jstr(in.Type))
		q.WriteString(`,"instructions":`)
		q.Write(jstr(in.Instructions))
		if len(bytes.TrimSpace(in.Criteria)) > 0 {
			c, err := compactRaw(in.Criteria)
			if err != nil {
				return nil, errf(KindUsage, "--criteria is not valid JSON")
			}
			q.WriteString(`,"criteria":`)
			q.Write(c)
		}
		q.WriteByte('}')
		questions = json.RawMessage(`{"` + DefaultQuestionName + `":` + q.String() + `}`)
	}
	if in.HasState {
		state = json.RawMessage(jstr(in.State))
	}
	if state == nil {
		return nil, errf(KindUsage, "a state is required: --state TEXT, --state-file FILE or --stdin")
	}
	cq, err := compactRaw(questions)
	if err != nil {
		return nil, errf(KindUsage, "the questions are not valid JSON")
	}
	cs, err := compactRaw(state)
	if err != nil {
		return nil, errf(KindUsage, "the state is not valid JSON")
	}
	mk := func(model string) []byte {
		var b bytes.Buffer
		b.WriteByte('{')
		if model != "" {
			b.WriteString(`"model":`)
			b.Write(jstr(model))
			b.WriteByte(',')
		}
		b.WriteString(`"state":`)
		b.Write(cs)
		b.WriteString(`,"questions":`)
		b.Write(cq)
		b.WriteByte('}')
		return b.Bytes()
	}
	model := in.Model
	if model == "" && top != nil {
		if m, ok := top["model"]; ok {
			var s string
			if json.Unmarshal(m, &s) == nil {
				model = s
			}
		}
	}
	n := 0
	var qm map[string]json.RawMessage
	if json.Unmarshal(cq, &qm) == nil {
		n = len(qm)
	}
	return &Built{Body: mk(model), Local: mk(""), Model: model, StateBytes: len(cs), Questions: n}, nil
}

func quoteShort(s string) string {
	if len(s) > 24 {
		s = s[:24] + "..."
	}
	b, _ := json.Marshal(s)
	return string(b)
}
