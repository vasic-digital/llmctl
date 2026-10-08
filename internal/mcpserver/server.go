// Package mcpserver is llmctl's minimal local MCP server (FR-086): newline-delimited JSON-RPC 2.0
// on stdio (MCP 2025-06-18 stdio transport; 2025-03-26 and 2024-11-05 are accepted in the
// version negotiation) exposing exactly one tool, `decide`, that forwards a typed decision call
// to the HTTPS gateway through internal/client.
//
// Rules, each pinned by a test:
//   - stdout carries only JSON-RPC messages, one per line; diagnostics go to stderr (the caller's).
//   - The server never panics and never exits on malformed input: bad JSON, batches, wrong types,
//     oversize lines and panicking backends all become well-formed error responses.
//   - FAIL CLOSED: every gateway/transport/key/TLS/parse failure, every malformed gateway answer
//     and every answer below min_confidence is a tool result with isError true and NO
//     structuredContent - there is no default answer, so a caller can never read "allow" from a
//     failure.
//   - Invalid tool input is rejected locally and never reaches the gateway.
//   - Resources and prompts are not declared; their methods are -32601.
package mcpserver

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"time"

	"github.com/vasic-digital/llmctl/internal/client"
	"github.com/vasic-digital/llmctl/internal/contract"
	"github.com/vasic-digital/llmctl/internal/schema"
)

// Asker is what the server needs from the gateway client (*client.Client satisfies it).
type Asker interface {
	Ask(ctx context.Context, body []byte) (*client.Result, error)
}

// DefaultMaxLine bounds one incoming JSON-RPC message.
const DefaultMaxLine = 8 << 20

// LatestProtocol is the newest MCP revision this server speaks.
const LatestProtocol = "2025-06-18"

var supported = map[string]bool{"2025-06-18": true, "2025-03-26": true, "2024-11-05": true}

// JSON-RPC error codes.
const (
	codeParse          = -32700
	codeInvalidRequest = -32600
	codeNoMethod       = -32601
	codeInvalidParams  = -32602
	codeInternal       = -32603
)

// Server is one stdio session. It is not safe for concurrent use; Serve is sequential.
type Server struct {
	Asker   Asker
	Version string
	Timeout time.Duration // per decision call; 0 = 60s
	MaxLine int           // 0 = DefaultMaxLine

	initialized bool
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

var nullID = json.RawMessage("null")

func encode(r response) []byte {
	b, err := json.Marshal(r)
	if err != nil { // only possible for an unmarshalable result: answer with a plain internal error
		b, _ = json.Marshal(response{JSONRPC: "2.0", ID: nullID, Error: &rpcError{codeInternal, "internal error"}})
	}
	return b
}

func fail(id json.RawMessage, code int, msg string) []byte {
	return encode(response{JSONRPC: "2.0", ID: id, Error: &rpcError{code, msg}})
}

func ok(id json.RawMessage, result any) []byte {
	if result == nil {
		result = map[string]any{}
	}
	return encode(response{JSONRPC: "2.0", ID: id, Result: result})
}

// validID: a request id is a string or a number (never null, boolean, object or array).
func validID(raw json.RawMessage) bool {
	t := bytes.TrimSpace(raw)
	if len(t) == 0 {
		return false
	}
	return t[0] == '"' || t[0] == '-' || (t[0] >= '0' && t[0] <= '9')
}

// Handle processes one message line and returns the response line (without newline), or nil when
// nothing is to be sent (notifications, blank lines). It never panics.
func (s *Server) Handle(ctx context.Context, line []byte) (out []byte) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return nil
	}
	defer func() {
		if r := recover(); r != nil {
			out = fail(nullID, codeInternal, "internal error")
		}
	}()
	if !json.Valid(line) {
		return fail(nullID, codeParse, "parse error: the message is not valid JSON")
	}
	if line[0] == '[' {
		return fail(nullID, codeInvalidRequest, "batch requests are not supported")
	}
	var msg map[string]json.RawMessage
	if line[0] != '{' || json.Unmarshal(line, &msg) != nil || msg == nil {
		return fail(nullID, codeInvalidRequest, "invalid request: expected a JSON object")
	}
	var ver string
	if json.Unmarshal(msg["jsonrpc"], &ver) != nil || ver != "2.0" {
		return fail(nullID, codeInvalidRequest, `invalid request: "jsonrpc" must be "2.0"`)
	}
	var method string
	if json.Unmarshal(msg["method"], &method) != nil {
		return fail(nullID, codeInvalidRequest, `invalid request: "method" must be a string`)
	}
	rawID, isRequest := msg["id"]
	if !isRequest { // a notification: never answered
		if method == "notifications/initialized" {
			s.initialized = true
		}
		return nil
	}
	if !validID(rawID) {
		return fail(nullID, codeInvalidRequest, `invalid request: "id" must be a string or a number`)
	}
	id := rawID
	switch method {
	case "ping":
		return ok(id, nil)
	case "initialize":
		return s.initialize(id, msg["params"])
	case "tools/list", "tools/call":
		if !s.initialized {
			return fail(id, codeInvalidRequest, "server not initialized: send initialize first")
		}
		if method == "tools/list" {
			return s.list(id)
		}
		return s.callTool(ctx, id, msg["params"])
	}
	return fail(id, codeNoMethod, "method not found: "+shorten(method))
}

func shorten(s string) string {
	r := []rune(s)
	if len(r) > 64 {
		return string(r[:64]) + "..."
	}
	return s
}

func (s *Server) initialize(id, params json.RawMessage) []byte {
	var p struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil || p.ProtocolVersion == "" {
		return fail(id, codeInvalidParams, `initialize needs params.protocolVersion (a string)`)
	}
	v := LatestProtocol
	if supported[p.ProtocolVersion] {
		v = p.ProtocolVersion
	}
	s.initialized = true
	ver := s.Version
	if ver == "" {
		ver = "dev"
	}
	return ok(id, map[string]any{
		"protocolVersion": v,
		"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
		"serverInfo":      map[string]any{"name": "llmctl-decide", "title": "llmctl decision gateway", "version": ver},
		"instructions":    "One tool, decide: a typed (noul/choice/score) question about a state, answered by the local decision model over HTTPS. Failures are errors, never a default answer.",
	})
}

func (s *Server) list(id json.RawMessage) []byte {
	t, err := schema.MCPTool()
	if err != nil {
		return fail(id, codeInternal, "internal error")
	}
	return ok(id, map[string]any{"tools": []any{t}})
}

// toolError is a tool execution error: isError true, text only, never structured content.
func toolError(id json.RawMessage, format string, a ...any) []byte {
	return ok(id, map[string]any{
		"isError": true,
		"content": []any{map[string]any{"type": "text", "text": fmt.Sprintf(format, a...)}},
	})
}

var allowedArgs = map[string]bool{"model": true, "state": true, "questions": true, "min_confidence": true}

func (s *Server) callTool(ctx context.Context, id, params json.RawMessage) (out []byte) {
	var p struct {
		Name      json.RawMessage `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if len(params) == 0 || json.Unmarshal(params, &p) != nil {
		return fail(id, codeInvalidParams, "tools/call needs params {name, arguments}")
	}
	var name string
	if json.Unmarshal(p.Name, &name) != nil {
		return fail(id, codeInvalidParams, "tools/call: name must be a string")
	}
	if name != schema.ToolName {
		return fail(id, codeInvalidParams, "unknown tool: "+shorten(name))
	}
	args := map[string]json.RawMessage{}
	if a := bytes.TrimSpace(p.Arguments); len(a) > 0 && !bytes.Equal(a, []byte("null")) {
		if a[0] != '{' || json.Unmarshal(a, &args) != nil || args == nil {
			return fail(id, codeInvalidParams, "tools/call: arguments must be an object")
		}
	}
	defer func() {
		if r := recover(); r != nil {
			out = toolError(id, "decision call failed: internal error")
		}
	}()
	for k := range args {
		if !allowedArgs[k] {
			return toolError(id, "invalid arguments: unknown argument %q (allowed: model, state, questions, min_confidence)", shorten(k))
		}
	}
	minConf, haveMin := 0.0, false
	if raw, present := args["min_confidence"]; present {
		if json.Unmarshal(raw, &minConf) != nil || math.IsNaN(minConf) || minConf < 0 || minConf > 1 {
			return toolError(id, "invalid arguments: min_confidence must be a number between 0 and 1")
		}
		haveMin = true
		delete(args, "min_confidence")
	}
	if raw, present := args["model"]; present {
		var m string
		if json.Unmarshal(raw, &m) != nil {
			return toolError(id, "invalid arguments: model must be a string")
		}
	}
	if _, has := args["state"]; !has {
		return toolError(id, `invalid arguments: "state" is required`)
	}
	if msg := checkQuestions(args["questions"]); msg != "" {
		return toolError(id, "invalid arguments: %s", msg)
	}
	file, err := json.Marshal(args)
	if err != nil {
		return toolError(id, "invalid arguments: not serialisable")
	}
	built, err := client.Build(client.Input{QuestionFile: file})
	if err != nil {
		return toolError(id, "invalid arguments: %v", err)
	}
	timeout := s.Timeout
	if timeout <= 0 {
		timeout = 60 * time.Second
	}
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	res, err := s.Asker.Ask(cctx, built.Body)
	if err != nil {
		var ce *client.Error
		if errors.As(err, &ce) {
			return toolError(id, "decision call failed (exit code %d): %s", ce.ExitCode(), ce.Msg)
		}
		return toolError(id, "decision call failed: %v", err)
	}
	if res == nil {
		return toolError(id, "decision call failed: empty response from the gateway")
	}
	model, _, err := client.Answers(res.Body)
	if err != nil {
		return toolError(id, "decision call failed: malformed response from the gateway")
	}
	if model == "" {
		model = built.Model
	}
	flagged, _ := client.AnyFlagged(res.Body)
	a := client.Annotation{Profile: model, Port: res.Port, Latency: float64(res.Latency) / float64(time.Millisecond), Truncated: res.Truncated,
		Mode: res.Mode, Instance: res.Instance, Flagged: flagged}
	if haveMin {
		min, err := client.MinConfidence(res.Body)
		if err != nil {
			return toolError(id, "decision call failed: malformed response from the gateway")
		}
		if min < minConf {
			why := ""
			if flagged {
				why = "; an option was absent from the model's readout, so the confidence is the worst case over what that option could have held"
			}
			return toolError(id, "answer withheld: lowest confidence %g is below min_confidence %g%s (fail closed: treat as undecided)", min, minConf, why)
		}
		f := false
		a.Abstained = &f
	}
	annotated, err := client.Annotate(res.Body, a)
	if err != nil {
		return toolError(id, "decision call failed: malformed response from the gateway")
	}
	return ok(id, map[string]any{
		"isError":           false,
		"content":           []any{map[string]any{"type": "text", "text": string(annotated)}},
		"structuredContent": json.RawMessage(annotated),
	})
}

// checkQuestions is the local, structural validation (the gateway remains authoritative for
// limits): questions is a non-empty object whose members are objects with a known type.
func checkQuestions(raw json.RawMessage) string {
	if len(raw) == 0 {
		return `"questions" is required`
	}
	var qs map[string]json.RawMessage
	if json.Unmarshal(raw, &qs) != nil || len(qs) == 0 {
		return `"questions" must be a non-empty object of name -> question`
	}
	for name, qr := range qs {
		var q struct {
			Type         string `json:"type"`
			Instructions string `json:"instructions"`
		}
		if name == "" || json.Unmarshal(qr, &q) != nil {
			return fmt.Sprintf("question %q must be an object with a non-empty name", shorten(name))
		}
		switch q.Type {
		case contract.TypeNoul, contract.TypeChoice, contract.TypeScore:
		default:
			return fmt.Sprintf("question %q: type must be noul, choice or score", shorten(name))
		}
		if q.Instructions == "" {
			return fmt.Sprintf("question %q: instructions are required", shorten(name))
		}
	}
	return ""
}

// readLine returns the next line (without its terminator). tooLong reports an oversize line that
// was consumed and dropped. io.EOF is returned only when no data remains.
func readLine(r *bufio.Reader, max int) (line []byte, tooLong bool, err error) {
	var buf []byte
	for {
		chunk, e := r.ReadSlice('\n')
		if !tooLong {
			if len(buf)+len(chunk) > max+2 { // +2: the terminator (\r\n)
				tooLong, buf = true, nil
			} else {
				buf = append(buf, chunk...)
			}
		}
		switch {
		case e == nil:
			return bytes.TrimRight(buf, "\r\n"), tooLong, nil
		case errors.Is(e, bufio.ErrBufferFull):
			continue
		case errors.Is(e, io.EOF):
			if len(buf) == 0 && !tooLong {
				return nil, false, io.EOF
			}
			return bytes.TrimRight(buf, "\r\n"), tooLong, nil
		default:
			return nil, false, e
		}
	}
}

// Serve reads messages from in until EOF and writes responses to out. It returns nil on EOF, the
// context's error when cancelled between messages, or the first read/write error.
func (s *Server) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	max := s.MaxLine
	if max <= 0 {
		max = DefaultMaxLine
	}
	r := bufio.NewReaderSize(in, 64<<10)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		line, tooLong, err := readLine(r, max)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		var resp []byte
		if tooLong {
			resp = fail(nullID, codeInvalidRequest, fmt.Sprintf("message larger than %d bytes", max))
		} else {
			resp = s.Handle(ctx, line)
		}
		if resp == nil {
			continue
		}
		if _, err := out.Write(append(resp, '\n')); err != nil {
			return err
		}
	}
}
