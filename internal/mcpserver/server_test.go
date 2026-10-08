package mcpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/client"
)

// fakeAsker records the body it was given and answers with a canned result.
type fakeAsker struct {
	body []byte
	res  *client.Result
	err  error
	pan  bool
	n    int
}

func (f *fakeAsker) Ask(_ context.Context, body []byte) (*client.Result, error) {
	f.n++
	f.body = body
	if f.pan {
		panic("boom")
	}
	return f.res, f.err
}

const okBody = `{"model":"decide-tiny","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":0.8,"b":0.2},"confidence":0.6}},"usage":{"input_tokens":4,"output_tokens":1}}`

func newSrv(a Asker) *Server { return &Server{Asker: a, Version: "test", Timeout: 5 * time.Second} }

func call(t *testing.T, s *Server, line string) map[string]any {
	t.Helper()
	out := s.Handle(context.Background(), []byte(line))
	if out == nil {
		return nil
	}
	if bytes.ContainsAny(out, "\n") {
		t.Fatalf("response contains a newline: %q", out)
	}
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatalf("response is not JSON: %v: %q", err, out)
	}
	if m["jsonrpc"] != "2.0" {
		t.Fatalf("jsonrpc field %v", m["jsonrpc"])
	}
	return m
}

func errCode(t *testing.T, m map[string]any) int {
	t.Helper()
	e, ok := m["error"].(map[string]any)
	if !ok {
		t.Fatalf("no error in %v", m)
	}
	return int(e["code"].(float64))
}

func initialized(t *testing.T, s *Server) {
	t.Helper()
	m := call(t, s, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}`)
	if m["result"] == nil {
		t.Fatalf("initialize failed: %v", m)
	}
	if call(t, s, `{"jsonrpc":"2.0","method":"notifications/initialized"}`) != nil {
		t.Fatal("a notification got a response")
	}
}

func TestProtocolErrors(t *testing.T) {
	s := newSrv(&fakeAsker{})
	cases := []struct {
		name, line string
		code       int
	}{
		{"parse error", `{bad`, -32700},
		{"truncated", `{"jsonrpc":"2.0","id":1,"meth`, -32700},
		{"empty object", `{}`, -32600},
		{"batch", `[{"jsonrpc":"2.0","id":1,"method":"ping"}]`, -32600},
		{"scalar", `7`, -32600},
		{"null", `null`, -32600},
		{"wrong version", `{"jsonrpc":"1.0","id":1,"method":"ping"}`, -32600},
		{"no version", `{"id":1,"method":"ping"}`, -32600},
		{"method not string", `{"jsonrpc":"2.0","id":1,"method":5}`, -32600},
		{"null id", `{"jsonrpc":"2.0","id":null,"method":"ping"}`, -32600},
		{"object id", `{"jsonrpc":"2.0","id":{},"method":"ping"}`, -32600},
		{"bool id", `{"jsonrpc":"2.0","id":true,"method":"ping"}`, -32600},
		{"unknown method", `{"jsonrpc":"2.0","id":1,"method":"nope"}`, -32601},
		{"initialize without params", `{"jsonrpc":"2.0","id":1,"method":"initialize"}`, -32602},
		{"initialize bad params", `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":5}}`, -32602},
		{"tools/list before initialize", `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`, -32600},
		{"tools/call before initialize", `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decide"}}`, -32600},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := errCode(t, call(t, s, c.line)); got != c.code {
				t.Fatalf("code %d, want %d", got, c.code)
			}
		})
	}
}

func TestParseErrorHasNullID(t *testing.T) {
	m := call(t, newSrv(&fakeAsker{}), `{bad`)
	if v, ok := m["id"]; !ok || v != nil {
		t.Fatalf("id must be present and null, got %v (present=%v)", v, ok)
	}
}

func TestPingAnyTimeAndIDEcho(t *testing.T) {
	s := newSrv(&fakeAsker{})
	m := call(t, s, `{"jsonrpc":"2.0","id":"abc","method":"ping"}`)
	if m["id"] != "abc" || m["result"] == nil {
		t.Fatalf("ping: %v", m)
	}
	m = call(t, s, `{"jsonrpc":"2.0","id":42,"method":"ping"}`)
	if m["id"] != float64(42) {
		t.Fatalf("numeric id lost: %v", m["id"])
	}
}

func TestInitializeNegotiation(t *testing.T) {
	for req, want := range map[string]string{
		"2025-06-18": "2025-06-18", "2025-03-26": "2025-03-26", "2024-11-05": "2024-11-05", "1999-01-01": "2025-06-18",
	} {
		s := newSrv(&fakeAsker{})
		m := call(t, s, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"`+req+`","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}`)
		r := m["result"].(map[string]any)
		if r["protocolVersion"] != want {
			t.Fatalf("requested %s: got %v want %s", req, r["protocolVersion"], want)
		}
		caps := r["capabilities"].(map[string]any)
		if _, ok := caps["tools"]; !ok {
			t.Fatal("tools capability missing")
		}
		if _, ok := caps["resources"]; ok {
			t.Fatal("resources capability must not be declared")
		}
		if r["serverInfo"].(map[string]any)["name"] == "" {
			t.Fatal("serverInfo.name empty")
		}
	}
}

func TestToolsList(t *testing.T) {
	s := newSrv(&fakeAsker{})
	initialized(t, s)
	m := call(t, s, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	tools := m["result"].(map[string]any)["tools"].([]any)
	if len(tools) != 1 {
		t.Fatalf("%d tools", len(tools))
	}
	tool := tools[0].(map[string]any)
	if tool["name"] != "decide" || tool["inputSchema"] == nil {
		t.Fatalf("tool %v", tool)
	}
	if _, ok := m["result"].(map[string]any)["nextCursor"]; ok {
		t.Fatal("nextCursor on a single page")
	}
}

func callTool(t *testing.T, s *Server, args string) map[string]any {
	t.Helper()
	m := call(t, s, `{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"decide","arguments":`+args+`}}`)
	if m["result"] == nil {
		t.Fatalf("expected a result, got %v", m)
	}
	return m["result"].(map[string]any)
}

const validArgs = `{"state":"disk is at 97%","questions":{"q":{"type":"choice","instructions":"what now?","criteria":{"a":"clean","b":"ignore"}}}}`

func TestCallSuccess(t *testing.T) {
	f := &fakeAsker{res: &client.Result{Body: []byte(okBody), Latency: 12 * time.Millisecond, Port: 8095}}
	s := newSrv(f)
	initialized(t, s)
	r := callTool(t, s, validArgs)
	if r["isError"] == true {
		t.Fatalf("isError: %v", r)
	}
	sc := r["structuredContent"].(map[string]any)
	if sc["model"] != "decide-tiny" || sc["evidence"] == nil {
		t.Fatalf("structured %v", sc)
	}
	text := r["content"].([]any)[0].(map[string]any)["text"].(string)
	var again map[string]any
	if err := json.Unmarshal([]byte(text), &again); err != nil {
		t.Fatalf("text content is not the JSON: %v", err)
	}
	var sent map[string]json.RawMessage
	if err := json.Unmarshal(f.body, &sent); err != nil {
		t.Fatal(err)
	}
	if _, ok := sent["questions"]; !ok {
		t.Fatalf("body sent: %s", f.body)
	}
	if _, ok := sent["min_confidence"]; ok {
		t.Fatal("min_confidence leaked to the gateway")
	}
}

func TestCallModelPassedThrough(t *testing.T) {
	f := &fakeAsker{res: &client.Result{Body: []byte(okBody)}}
	s := newSrv(f)
	initialized(t, s)
	callTool(t, s, `{"model":"decide-tiny","state":"x","questions":{"q":{"type":"noul","instructions":"ok?"}}}`)
	if !strings.Contains(string(f.body), `"model":"decide-tiny"`) {
		t.Fatalf("model not forwarded: %s", f.body)
	}
}

// Every failure path is an isError tool result with NO structured answer: never a default allow.
func TestFailClosed(t *testing.T) {
	good := &client.Result{Body: []byte(okBody)}
	cases := []struct {
		name string
		a    *fakeAsker
		args string
		want string
	}{
		{"gateway unreachable", &fakeAsker{err: &client.Error{Kind: client.KindUnreachable, Msg: "connection refused"}}, validArgs, "exit code 6"},
		{"401 key", &fakeAsker{err: &client.Error{Kind: client.KindKey, Msg: "the gateway rejected the access key", Status: 401}}, validArgs, "exit code 4"},
		{"529 overloaded", &fakeAsker{err: &client.Error{Kind: client.KindBackend, Msg: "overloaded", Status: 529}}, validArgs, "exit code 1"},
		{"tls", &fakeAsker{err: &client.Error{Kind: client.KindTLS, Msg: "certificate"}}, validArgs, "exit code 5"},
		{"plain error", &fakeAsker{err: errors.New("weird")}, validArgs, "weird"},
		{"nil result", &fakeAsker{}, validArgs, "empty"},
		{"malformed gateway body", &fakeAsker{res: &client.Result{Body: []byte(`not json`)}}, validArgs, "malformed"},
		{"panicking asker", &fakeAsker{pan: true}, validArgs, "internal error"},
		{"low confidence", &fakeAsker{res: good}, `{"min_confidence":0.99,"state":"x","questions":{"q":{"type":"choice","instructions":"?","criteria":{"a":"1","b":"2"}}}}`, "withheld"},
		{"min_confidence not a number", &fakeAsker{res: good}, `{"min_confidence":"high","state":"x","questions":{"q":{"type":"noul","instructions":"?"}}}`, "min_confidence"},
		{"min_confidence out of range", &fakeAsker{res: good}, `{"min_confidence":2,"state":"x","questions":{"q":{"type":"noul","instructions":"?"}}}`, "min_confidence"},
		{"missing arguments", &fakeAsker{res: good}, `{}`, "state"},
		{"unknown argument", &fakeAsker{res: good}, `{"state":"x","questions":{"q":{"type":"noul","instructions":"?"}},"evil":1}`, "evil"},
		{"bad question type", &fakeAsker{res: good}, `{"state":"x","questions":{"q":{"type":"chat","instructions":"?"}}}`, "type"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			s := newSrv(c.a)
			initialized(t, s)
			r := callTool(t, s, c.args)
			if r["isError"] != true {
				t.Fatalf("not an error: %v", r)
			}
			if _, ok := r["structuredContent"]; ok {
				t.Fatalf("structuredContent on a failure: %v", r)
			}
			text := r["content"].([]any)[0].(map[string]any)["text"].(string)
			if !strings.Contains(text, c.want) {
				t.Fatalf("text %q lacks %q", text, c.want)
			}
		})
	}
}

func TestLocalValidationNeverReachesGateway(t *testing.T) {
	f := &fakeAsker{res: &client.Result{Body: []byte(okBody)}}
	s := newSrv(f)
	initialized(t, s)
	callTool(t, s, `{}`)
	callTool(t, s, `{"state":"x","questions":{"q":{"type":"chat","instructions":"?"}}}`)
	if f.n != 0 {
		t.Fatalf("gateway was called %d times for invalid input", f.n)
	}
}

func TestToolCallProtocolErrors(t *testing.T) {
	s := newSrv(&fakeAsker{})
	initialized(t, s)
	for name, line := range map[string]string{
		"unknown tool":      `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}`,
		"no params":         `{"jsonrpc":"2.0","id":3,"method":"tools/call"}`,
		"name not string":   `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":7}}`,
		"args not object":   `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"decide","arguments":[1]}}`,
		"params not object": `{"jsonrpc":"2.0","id":3,"method":"tools/call","params":"x"}`,
	} {
		t.Run(name, func(t *testing.T) {
			if c := errCode(t, call(t, s, line)); c != -32602 {
				t.Fatalf("code %d", c)
			}
		})
	}
}

func TestUnknownNotificationIgnored(t *testing.T) {
	s := newSrv(&fakeAsker{})
	if call(t, s, `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}`) != nil {
		t.Fatal("notification answered")
	}
	if call(t, s, `{"jsonrpc":"2.0","method":"whatever"}`) != nil {
		t.Fatal("unknown notification answered")
	}
}

func TestServeLoop(t *testing.T) {
	f := &fakeAsker{res: &client.Result{Body: []byte(okBody)}}
	s := newSrv(f)
	in := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		``,
		`garbage`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"decide","arguments":` + validArgs + `}}`,
	}, "\n") + "\n"
	var out bytes.Buffer
	if err := s.Serve(context.Background(), strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if len(lines) != 4 { // initialize, parse error, tools/list, tools/call (blank + notification: none)
		t.Fatalf("%d output lines:\n%s", len(lines), out.String())
	}
	for _, l := range lines {
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil || m["jsonrpc"] != "2.0" {
			t.Fatalf("bad stdout line %q", l)
		}
	}
}

func TestServeLastLineWithoutNewlineAndCRLF(t *testing.T) {
	s := newSrv(&fakeAsker{})
	var out bytes.Buffer
	in := "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}"
	if err := s.Serve(context.Background(), strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(out.String(), "\n"); n != 2 {
		t.Fatalf("%d responses:\n%s", n, out.String())
	}
}

func TestOversizeLineIsRejectedAndServerContinues(t *testing.T) {
	s := newSrv(&fakeAsker{})
	s.MaxLine = 1024
	big := `{"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":"` + strings.Repeat("a", 5000) + `"}}`
	in := big + "\n" + `{"jsonrpc":"2.0","id":2,"method":"ping"}` + "\n"
	var out bytes.Buffer
	if err := s.Serve(context.Background(), strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("%d lines: %s", len(lines), out.String())
	}
	var first, second map[string]any
	_ = json.Unmarshal([]byte(lines[0]), &first)
	_ = json.Unmarshal([]byte(lines[1]), &second)
	if first["error"] == nil || second["result"] == nil {
		t.Fatalf("first=%v second=%v", first, second)
	}
}

type errWriter struct{}

func (errWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestServeReportsWriteFailure(t *testing.T) {
	s := newSrv(&fakeAsker{})
	err := s.Serve(context.Background(), strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`+"\n"), errWriter{})
	if err == nil {
		t.Fatal("write failure swallowed")
	}
}

func TestServeStopsOnCancelledContextBetweenMessages(t *testing.T) {
	s := newSrv(&fakeAsker{})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var out bytes.Buffer
	if err := s.Serve(ctx, strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"ping"}`+"\n"), &out); err == nil {
		t.Fatal("cancelled context ignored")
	}
}

// Seed corpus for the fuzz target; `go test` runs the seeds as ordinary unit tests.
func FuzzHandle(f *testing.F) {
	for _, s := range []string{
		``, ` `, `{`, `}`, `[`, `[]`, `{}`, `null`, `"x"`, `1e999`, `{"jsonrpc":"2.0"}`,
		`{"jsonrpc":"2.0","id":1,"method":"ping"}`,
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decide","arguments":{"state":null,"questions":null}}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decide","arguments":{"state":"x","questions":{"":{"type":"noul","instructions":""}}}}}`,
		`{"jsonrpc":"2.0","id":9999999999999999999999,"method":"ping"}`,
		`{"jsonrpc":"2.0","id":1,"method":"ping","method":"tools/list"}`,
		"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\xff\xfe\"}",
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"decide","arguments":{"state":"x","questions":{"q":{"type":"score","instructions":"?","criteria":[1,2,3]}}}}}`,
		strings.Repeat(`[`, 5000), strings.Repeat(`{"a":`, 3000),
	} {
		f.Add([]byte(s))
	}
	f.Fuzz(func(t *testing.T, line []byte) {
		s := newSrv(&fakeAsker{res: &client.Result{Body: []byte(okBody)}})
		s.initialized = true
		out := s.Handle(context.Background(), line)
		if out == nil {
			return
		}
		if bytes.ContainsAny(out, "\n\r") {
			t.Fatalf("multi-line response %q", out)
		}
		var m map[string]any
		if err := json.Unmarshal(out, &m); err != nil {
			t.Fatalf("invalid JSON response %q", out)
		}
		if m["jsonrpc"] != "2.0" || (m["result"] == nil) == (m["error"] == nil) {
			t.Fatalf("not exactly one of result/error: %q", out)
		}
	})
}

func TestMoreInvalidInputs(t *testing.T) {
	s := newSrv(&fakeAsker{res: &client.Result{Body: []byte(okBody)}})
	initialized(t, s)
	for name, args := range map[string]string{
		"questions array":    `{"state":"x","questions":[1]}`,
		"questions empty":    `{"state":"x","questions":{}}`,
		"questions missing":  `{"state":"x"}`,
		"question not obj":   `{"state":"x","questions":{"q":5}}`,
		"empty name":         `{"state":"x","questions":{"":{"type":"noul","instructions":"?"}}}`,
		"no instructions":    `{"state":"x","questions":{"q":{"type":"noul"}}}`,
		"model not a string": `{"state":"x","model":5,"questions":{"q":{"type":"noul","instructions":"?"}}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if r := callTool(t, s, args); r["isError"] != true {
				t.Fatalf("accepted: %v", r)
			}
		})
	}
	long := strings.Repeat("m", 200)
	m := call(t, s, `{"jsonrpc":"2.0","id":1,"method":"`+long+`"}`)
	if msg := m["error"].(map[string]any)["message"].(string); len(msg) > 120 {
		t.Fatalf("method echoed unbounded: %d bytes", len(msg))
	}
}

func TestNilAskerIsAToolErrorNotAPanic(t *testing.T) {
	s := newSrv(nil)
	initialized(t, s)
	if r := callTool(t, s, validArgs); r["isError"] != true {
		t.Fatalf("nil asker: %v", r)
	}
}

func TestInitializedFlagViaNotificationOnly(t *testing.T) {
	s := newSrv(&fakeAsker{})
	if errCode(t, call(t, s, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)) != -32600 {
		t.Fatal("tools/list allowed before init")
	}
	call(t, s, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	if call(t, s, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)["result"] == nil {
		t.Fatal("tools/list refused after the initialized notification")
	}
}

func TestMinConfidenceNeverReachesTheGatewayBody(t *testing.T) {
	f := &fakeAsker{res: &client.Result{Body: []byte(okBody)}}
	s := newSrv(f)
	initialized(t, s)
	r := callTool(t, s, `{"min_confidence":0.1,"state":"x","questions":{"q":{"type":"choice","instructions":"?","criteria":{"a":"1","b":"2"}}}}`)
	if r["isError"] == true {
		t.Fatalf("unexpected error: %v", r)
	}
	if strings.Contains(string(f.body), "min_confidence") {
		t.Fatalf("leaked: %s", f.body)
	}
	if r["structuredContent"].(map[string]any)["abstained"] != false {
		t.Fatalf("abstained annotation missing: %v", r["structuredContent"])
	}
}

// B-17 (reviewer mutation M5: `min < minConf` -> `min < minConf-0.05` opened a fail-OPEN band): the
// gate is pinned at its exact boundary on both sides.
func TestMinConfidenceBoundaryIsExact(t *testing.T) {
	good := &client.Result{Body: []byte(okBody)} // lowest confidence 0.6
	args := func(min string) string {
		return `{"min_confidence":` + min + `,"state":"x","questions":{"q":{"type":"choice","instructions":"?","criteria":{"a":"1","b":"2"}}}}`
	}
	for _, c := range []struct {
		min      string
		withheld bool
	}{{"0", false}, {"0.5", false}, {"0.59", false}, {"0.6", false}, {"0.601", true}, {"0.61", true}, {"0.65", true}, {"1", true}} {
		s := newSrv(&fakeAsker{res: good})
		initialized(t, s)
		r := callTool(t, s, args(c.min))
		if got := r["isError"] == true; got != c.withheld {
			t.Errorf("min_confidence %s with confidence 0.6: withheld=%v, want %v", c.min, got, c.withheld)
		}
	}
}

// B-01/B3-01: a flagged answer reaches the gate at its worst case (its shares already hold the
// absent option's bound) and the evidence says so; a tiny bound clears the gate, a large one does not.
func TestFlaggedAnswerIsGatedAtItsWorstCase(t *testing.T) {
	mk := func(pa, pb, conf string) *client.Result {
		return &client.Result{Mode: "throughput", Body: []byte(`{"model":"decide-tiny","answers":{"q":{"type":"choice","choice":"a","probabilities":{"a":` + pa + `,"b":` + pb + `},"confidence":` + conf + `,"flags":["option_missing"],"upper_bounds":{"b":` + pb + `}}},"usage":{"input_tokens":1,"output_tokens":1}}`)}
	}
	args := `{"min_confidence":0.9,"state":"x","questions":{"q":{"type":"choice","instructions":"?","criteria":{"a":"1","b":"2"}}}}`
	s := newSrv(&fakeAsker{res: mk("0.8", "0.2", "0.6")})
	initialized(t, s)
	r := callTool(t, s, args)
	if r["isError"] != true {
		t.Fatalf("0.6 worst-case confidence cannot clear 0.9: %v", r)
	}
	text := r["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, "absent") {
		t.Fatalf("the withheld message must say why: %q", text)
	}
	s = newSrv(&fakeAsker{res: mk("0.98", "0.02", "0.96")})
	initialized(t, s)
	r = callTool(t, s, args)
	if r["isError"] == true {
		t.Fatalf("a worst case above the threshold clears the gate: %v", r)
	}
	ev := r["structuredContent"].(map[string]any)["evidence"].(map[string]any)
	if ev["flagged"] != true || ev["mode"] != "throughput" {
		t.Fatalf("evidence %v", ev)
	}
}

// B2-09: an explicit empty model is a tool error, never the default profile.
func TestEmptyModelIsAToolErrorNotTheDefaultProfile(t *testing.T) {
	f := &fakeAsker{res: &client.Result{Body: []byte(okBody)}}
	s := newSrv(f)
	initialized(t, s)
	r := callTool(t, s, `{"model":"","state":"x","questions":{"q":{"type":"noul","instructions":"ok?"}}}`)
	if r["isError"] != true || f.n != 0 {
		t.Fatalf("an empty model must be refused before any gateway call: isError=%v asked=%d", r["isError"], f.n)
	}
}
