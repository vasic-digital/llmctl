package gateway

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// NativeBackend proxies to a llama-server's native POST /v1/systemone (engine build b11361+; request
// {model,state,questions}, response {model,answers,usage}, the hosted wire shape). It is DISABLED
// until the engine advance gate (OD-1) is passed: with Enabled false it answers 503 not_ready and
// never contacts the engine. The gateway re-validates and re-shapes the engine's answer through
// contract.BuildAnswer, so a native engine cannot emit a response the contract would refuse.
type NativeBackend struct {
	Enabled bool
	HTTP    *http.Client
}

// Decide implements Driver.
func (n *NativeBackend) Decide(ctx context.Context, ep Endpoint, spec ProfileSpec, req *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
	if spec.Protocol != ProtoNative {
		return nil, contract.Usage{}, wrongProtocol(ProtoNative, spec.Protocol)
	}
	if !n.Enabled {
		return nil, contract.Usage{}, notReady()
	}
	body, err := nativeBody(spec.ID, req)
	if err != nil {
		return nil, contract.Usage{}, backendFailed()
	}
	resp, err := postJSON(ctx, n.HTTP, ep, "/v1/systemone", body)
	if err != nil {
		return nil, contract.Usage{}, err
	}
	var env struct {
		Answers map[string]json.RawMessage `json:"answers"`
		Usage   struct {
			In  int `json:"input_tokens"`
			Out int `json:"output_tokens"`
		} `json:"usage"`
	}
	if json.Unmarshal(resp, &env) != nil || env.Usage.In < 0 || env.Usage.Out < 0 {
		return nil, contract.Usage{}, backendFailed()
	}
	var out []contract.NamedAnswer
	for _, q := range req.Questions {
		raw, ok := env.Answers[q.Name]
		if !ok {
			return nil, contract.Usage{}, backendFailed()
		}
		a, err := nativeAnswer(q, raw)
		if err != nil {
			return nil, contract.Usage{}, backendFailed()
		}
		out = append(out, contract.NamedAnswer{Name: q.Name, Answer: a})
	}
	return out, contract.Usage{InputTokens: env.Usage.In, OutputTokens: env.Usage.Out}, nil
}

func nativeAnswer(q contract.ParsedQuestion, raw json.RawMessage) (contract.Answer, error) {
	var a struct {
		Type          string             `json:"type"`
		Noul          *float64           `json:"noul"`
		Probabilities map[string]float64 `json:"probabilities"`
	}
	if err := json.Unmarshal(raw, &a); err != nil || a.Type != q.Type {
		return contract.Answer{}, errBadNative
	}
	probs := make([]float64, len(q.Options))
	if q.Type == contract.TypeNoul {
		if a.Noul == nil {
			return contract.Answer{}, errBadNative
		}
		probs[0], probs[1] = *a.Noul, 1-*a.Noul
	} else {
		for i, o := range q.Options {
			p, ok := a.Probabilities[o.Key]
			if !ok {
				return contract.Answer{}, errBadNative
			}
			probs[i] = p
		}
	}
	return contract.BuildAnswer(q, probs)
}

type nativeErr string

func (e nativeErr) Error() string { return string(e) }

const errBadNative = nativeErr("gateway: unusable native answer")

// nativeBody rebuilds the hosted-shape request from the validated one (question order preserved).
func nativeBody(model string, req *contract.ParsedRequest) ([]byte, error) {
	var b bytes.Buffer
	enc := func(v any) []byte { x, _ := json.Marshal(v); return bytes.TrimRight(x, "\n") }
	b.WriteString(`{"model":`)
	b.Write(enc(model))
	b.WriteString(`,"state":`)
	b.Write(enc(req.StateText))
	b.WriteString(`,"questions":{`)
	for i, q := range req.Questions {
		if i > 0 {
			b.WriteByte(',')
		}
		b.Write(enc(q.Name))
		b.WriteString(`:{"type":`)
		b.Write(enc(q.Type))
		b.WriteString(`,"instructions":`)
		b.Write(enc(q.Instructions))
		if crit := nativeCriteria(q); crit != nil {
			b.WriteString(`,"criteria":`)
			b.Write(crit)
		}
		b.WriteByte('}')
	}
	b.WriteString(`}}`)
	return b.Bytes(), nil
}

func optDesc(o contract.Option, prefix string) string {
	if d, ok := strings.CutPrefix(o.Label, prefix+" - "); ok {
		return d
	}
	return ""
}

func nativeCriteria(q contract.ParsedQuestion) []byte {
	enc := func(v any) []byte { x, _ := json.Marshal(v); return bytes.TrimRight(x, "\n") }
	switch q.Type {
	case contract.TypeNoul:
		t, f := optDesc(q.Options[0], "yes"), optDesc(q.Options[1], "no")
		if t == "" && f == "" {
			return nil
		}
		return []byte(`{"true":` + string(enc(t)) + `,"false":` + string(enc(f)) + `}`)
	case contract.TypeChoice:
		var b bytes.Buffer
		b.WriteByte('{')
		for i, o := range q.Options {
			if i > 0 {
				b.WriteByte(',')
			}
			b.Write(enc(o.Key))
			b.WriteByte(':')
			b.Write(enc(optDesc(o, o.Key)))
		}
		b.WriteByte('}')
		return b.Bytes()
	default: // score: the original JSON values, in order
		var b bytes.Buffer
		b.WriteByte('[')
		for i, l := range q.Legend {
			if i > 0 {
				b.WriteByte(',')
			}
			b.Write(l.Value)
		}
		b.WriteByte(']')
		return b.Bytes()
	}
}
