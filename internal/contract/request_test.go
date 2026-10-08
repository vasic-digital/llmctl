package contract_test

import (
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/vasic-digital/llmctl/internal/contract"
)

func letters(q contract.ParsedQuestion) string {
	var s []string
	for _, o := range q.Options {
		s = append(s, o.Letter)
	}
	return strings.Join(s, "")
}

func keys(q contract.ParsedQuestion) []string {
	var s []string
	for _, o := range q.Options {
		s = append(s, o.Key)
	}
	return s
}

func TestParseNoulDefaults(t *testing.T) {
	p := mustParse(t, body())
	if p.Model != "decide-tiny" || p.Truncated {
		t.Fatalf("%+v", p)
	}
	q := p.Questions[0]
	if q.Name != "q" || q.Type != "noul" || letters(q) != "AB" || strings.Join(keys(q), ",") != "yes,no" {
		t.Fatalf("%+v", q)
	}
}

func TestParseChoiceLettersAndLabels(t *testing.T) {
	q := mustParse(t, body("questions", qs("c", choiceQ(4)))).Questions[0]
	if letters(q) != "ABCD" || strings.Join(keys(q), ",") != "opt0,opt1,opt2,opt3" || q.Options[1].Label != "opt1 - desc 1" {
		t.Fatalf("%+v", q)
	}
	// option order is the JSON order, not sorted order (opt10 sorts before opt2)
	q = mustParse(t, body("questions", qs("c", choiceQ(12)))).Questions[0]
	if q.Options[2].Key != "opt2" || q.Options[10].Key != "opt10" {
		t.Fatalf("order not preserved: %v", keys(q))
	}
	q = mustParse(t, body("questions", qs("c", `{"type":"choice","instructions":"x","criteria":{"a":null,"b":"bee"}}`))).Questions[0]
	if q.Options[0].Label != "a" || q.Options[1].Label != "b - bee" {
		t.Fatalf("%+v", q.Options)
	}
	q = mustParse(t, body("questions", qs("c", `{"type":"choice","instructions":"x","criteria":{"a":{"z":1,"b":2},"b":[1,2]}}`))).Questions[0]
	if q.Options[0].Label != `a - {"b":2,"z":1}` || q.Options[1].Label != "b - [1,2]" {
		t.Fatalf("%+v", q.Options)
	}
}

func TestParseScoreLevels(t *testing.T) {
	for _, n := range []int{2, 10} {
		q := mustParse(t, body("questions", qs("s", scoreQ(n)))).Questions[0]
		if len(q.Options) != n || q.Options[0].Key != "0" || q.Options[n-1].Key != fmt.Sprint(n-1) || q.Options[0].Label != "l0" {
			t.Fatalf("n=%d %+v", n, q.Options)
		}
		if string(q.Legend[0].Value) != `"l0"` || q.Legend[0].Key != "0" || len(q.Legend) != n {
			t.Fatalf("legend %+v", q.Legend)
		}
	}
	q := mustParse(t, body("questions", qs("s", `{"type":"score","criteria":["",null,{"b":1,"a":2}]}`))).Questions[0]
	if q.Options[0].Label != "level 0" || q.Options[1].Label != "level 1" || q.Options[2].Label != `{"a":2,"b":1}` {
		t.Fatalf("%+v", q.Options)
	}
	if string(q.Legend[1].Value) != "null" || string(q.Legend[2].Value) != `{"b":1,"a":2}` {
		t.Fatalf("legend keeps the original value and order: %+v", q.Legend)
	}
}

func TestQuestionOrderKept(t *testing.T) {
	p := mustParse(t, body("questions", `{"zeta":{"type":"noul","instructions":"a"},"alpha":`+choiceQ(3)+`}`))
	if p.Questions[0].Name != "zeta" || p.Questions[1].Name != "alpha" {
		t.Fatal(p.Questions)
	}
}

func TestStateFormsDeterministic(t *testing.T) {
	a := mustParse(t, body("state", `{"b":1,"a":[3,2]}`)).StateText
	b := mustParse(t, []byte(`{"state": {"a": [3, 2], "b": 1}, "questions": {"q": {"type": "noul", "instructions": "x"}}}`)).StateText
	if a != b || a != `{"a":[3,2],"b":1}` {
		t.Fatalf("%q %q", a, b)
	}
	if got := mustParse(t, body("state", `[1,"x"]`)).StateText; got != `[1,"x"]` {
		t.Fatal(got)
	}
	if got := mustParse(t, body("state", `"plain"`)).StateText; got != "plain" {
		t.Fatal(got)
	}
	if got := mustParse(t, body("state", `""`)).StateText; got != "" {
		t.Fatalf("empty string state is accepted, got %q", got)
	}
}

// Serialisation of nested state follows Python's json.dumps(sort_keys, compact, ensure_ascii=False).
func TestStateSerialisationMatchesPythonDumps(t *testing.T) {
	cases := map[string]string{
		`[1.0]`:                                   `[1.0]`,
		`[100.0, 1E2, 1e2]`:                       `[100.0,100.0,100.0]`,
		`[1e16, 1e15]`:                            `[1e+16,1000000000000000.0]`,
		`[0.0001, 0.00001, 1.5e-5]`:               `[0.0001,1e-05,1.5e-05]`,
		`[-0, -0.0, 0]`:                           `[0,-0.0,0]`,
		`[123456789012345678901234567890]`:        `[123456789012345678901234567890]`,
		`[123456789012345680000.0]`:               `[1.2345678901234568e+20]`,
		`[0.1, 12345.678, 1e22]`:                  `[0.1,12345.678,1e+22]`,
		`[true,false,null]`:                       `[true,false,null]`,
		`{"\u0001":"\u0001\"\\\n\r\t\b\f\u007f"}`: "{\"\\u0001\":\"\\u0001\\\"\\\\\\n\\r\\t\\b\\f\u007f\"}",
		`["é", "</script>&", "\u2028"]`:           "[\"é\",\"</script>&\",\"\u2028\"]",
		`{"b":{"y":1,"x":2},"a":{}}`:              `{"a":{},"b":{"x":2,"y":1}}`,
		`{"é":1,"z":2,"a":3}`:                     `{"a":3,"z":2,"é":1}`,
	}
	for in, want := range cases {
		got := mustParse(t, body("state", in)).StateText
		if got != want {
			t.Errorf("state %s -> %q, want %q", in, got, want)
		}
	}
}

func TestInstructionsForms(t *testing.T) {
	cases := map[string]string{`"txt"`: "txt", `{"b":1,"a":2}`: `{"a":2,"b":1}`, `[1,2]`: "[1,2]", `null`: ""}
	for in, want := range cases {
		q := mustParse(t, body("questions", qs("q", `{"type":"noul","instructions":`+in+`}`))).Questions[0]
		if q.Instructions != want {
			t.Errorf("%s -> %q want %q", in, q.Instructions, want)
		}
	}
	if q := mustParse(t, body("questions", qs("q", `{"type":"noul"}`))).Questions[0]; q.Instructions != "" {
		t.Fatal("instructions optional")
	}
}

func TestModelMapping(t *testing.T) {
	cases := map[string]string{"jev-latest": "decide-tiny", "jev-1.13.0": "decide-tiny", "jev-preview": "decide-tiny",
		"decide-big": "decide-big", "llmctl-decide-big": "decide-big", "decide-tiny": "decide-tiny"}
	for m, want := range cases {
		if got := mustParse(t, body("model", js(m))).Model; got != want {
			t.Errorf("%s -> %s want %s", m, got, want)
		}
	}
	if mustParse(t, body()).Model != "decide-tiny" {
		t.Fatal("absent model is the default")
	}
}

func TestUnknownModelNotEchoed(t *testing.T) {
	hostile := "evil<script>alert(1)</script>\r\nX: y"
	_, err := parse(body("model", js(hostile)))
	if outcomeOf(err) != (outcome{422, "unknown_model"}) {
		t.Fatal(err)
	}
	for _, s := range []string{err.Error(), fmt.Sprintf("%+v", err)} {
		if strings.Contains(s, "evil") {
			t.Fatalf("hostile model echoed: %q", s)
		}
	}
	for _, m := range []string{"llmctl-", "llmctl-nope", "decide", "DECIDE-TINY", " decide-tiny", "llmctl-llmctl-decide-tiny"} {
		if _, err := parse(body("model", js(m))); outcomeOf(err) != (outcome{422, "unknown_model"}) {
			t.Errorf("%q: %v", m, err)
		}
	}
}

func TestNonStringModel(t *testing.T) {
	for _, m := range []string{`5`, `null`, `["jev-latest"]`, `{"a":1}`, `true`} {
		if _, err := parse(body("model", m)); outcomeOf(err) != (outcome{422, "validation_failed"}) {
			t.Errorf("%s: %v", m, err)
		}
	}
}

func TestProfilesResolveAny(t *testing.T) {
	if got, err := tinyBig.Resolve("jev-latest"); err != nil || got != "decide-tiny" {
		t.Fatal(got, err)
	}
	for _, v := range []any{5, nil, 1.5, []any{}, map[string]any{}, true} {
		if _, err := tinyBig.Resolve(v); outcomeOf(err) != (outcome{422, "validation_failed"}) {
			t.Errorf("%#v: %v", v, err)
		}
	}
}

func TestProfilesConstruction(t *testing.T) {
	bad := []struct {
		ids []string
		def string
	}{{nil, ""}, {[]string{"a"}, "b"}, {[]string{"A"}, "A"}, {[]string{""}, ""}, {[]string{"a b"}, "a b"}, {[]string{"a_b"}, "a_b"}, {[]string{"é"}, "é"}}
	for _, c := range bad {
		if _, err := contract.NewProfiles(c.ids, c.def, nil); err == nil {
			t.Errorf("%v/%q accepted", c.ids, c.def)
		}
	}
	p, err := contract.NewProfiles([]string{"a", "b"}, "", nil)
	if err != nil || p.Default() != "a" {
		t.Fatal("first profile is the default when none is named", p, err)
	}
	if got := strings.Join(p.Aliases("a"), ","); got != "jev-latest,jev-1.13.0,jev-preview,llmctl-a" {
		t.Fatal(got)
	}
	if got := strings.Join(p.Aliases("b"), ","); got != "llmctl-b" {
		t.Fatal(got)
	}
	if got := strings.Join(p.IDs(), ","); got != "a,b" {
		t.Fatal(got)
	}
	badLim := contract.DefaultLimits()
	badLim.MaxOptions = 1
	if _, err := contract.NewProfiles([]string{"a"}, "a", map[string]contract.Limits{"a": badLim}); err == nil {
		t.Fatal("invalid per-profile limits accepted")
	}
	if _, err := contract.NewProfiles([]string{"a"}, "a", map[string]contract.Limits{"zzz": contract.DefaultLimits()}); err == nil {
		t.Fatal("limits for an unserved profile accepted")
	}
}

func TestPerProfileLimitsOverride(t *testing.T) {
	l := contract.DefaultLimits()
	l.MaxOptions = 255
	profs := mustProfiles([]string{"a", "b"}, "a", map[string]contract.Limits{"b": l})
	p, err := contract.ParseRequest(body("model", `"b"`, "questions", qs("c", choiceQ(100))), lim, profs)
	if err != nil || len(p.Questions[0].Options) != 100 {
		t.Fatal(err)
	}
	_, err = contract.ParseRequest(body("model", `"a"`, "questions", qs("c", choiceQ(100))), lim, profs)
	if outcomeOf(err) != (outcome{422, "validation_failed"}) {
		t.Fatal(err)
	}
}

func TestLimitsValidation(t *testing.T) {
	if err := contract.DefaultLimits().Validate(); err != nil {
		t.Fatal(err)
	}
	d := contract.DefaultLimits()
	if d.MaxOptions != 20 || d.MinScale != 2 || d.MaxScale != 10 || d.MaxStateChars != 8192 || d.MaxQuestions != 32 || d.Truncate {
		t.Fatalf("%+v", d)
	}
	mut := []func(*contract.Limits){
		func(l *contract.Limits) { l.MaxOptions = 1 }, func(l *contract.Limits) { l.MaxOptions = 256 },
		func(l *contract.Limits) { l.MinScale = 1 }, func(l *contract.Limits) { l.MaxScale = 11 },
		func(l *contract.Limits) { l.MinScale, l.MaxScale = 5, 4 }, func(l *contract.Limits) { l.MaxStateChars = 0 },
		func(l *contract.Limits) { l.MaxQuestions = 0 },
	}
	for i, m := range mut {
		l := contract.DefaultLimits()
		m(&l)
		if l.Validate() == nil {
			t.Errorf("mutation %d accepted", i)
		}
		if _, err := contract.ParseRequest(body(), l, tinyBig); err == nil || outcomeOf(err).Status == 400 || outcomeOf(err).Status == 422 {
			t.Errorf("mutation %d: invalid limits must be a programming error, not a client status: %v", i, err)
		}
	}
	if _, err := contract.ParseRequest(body(), lim, nil); err == nil {
		t.Fatal("nil profiles accepted")
	}
}

func TestRejections400(t *testing.T) {
	raws := []string{"", "   ", "not json", "{", "\xff\xfe\x00", "[1,2]", `"s"`, "42", "null", "true",
		`{"state":NaN,"questions":{}}`, `{"state":Infinity,"questions":{}}`, `{"state":-Infinity,"questions":{}}`,
		`{"state":[1e999],"questions":{"q":{"type":"noul"}}}`, `{"state":[-1e999],"questions":{"q":{"type":"noul"}}}`,
		`{} x`, `{}{}`, `{"a":1,}`, `[1,]`, `{"state":"a\u0000b`, "{\"state\":\"a\x01b\"}", `{'a':1}`,
		`{"state":"x","state":"y","questions":{"q":{"type":"noul"}}}`,                // duplicate top-level key
		`{"state":{"a":1,"a":2},"questions":{"q":{"type":"noul"}}}`,                  // duplicate inside state
		`{"state":"s","questions":{"q":{"type":"noul"},"q":{"type":"noul"}}}`,        // duplicate question
		`{"state":"s","questions":{"q":{"type":"choice","criteria":{"a":1,"a":2}}}}`, // duplicate option
		`{"state":"s","questions":{"q":{"type":"noul","type":"noul"}}}`,              // duplicate inside question
		"{\"state\":\"\xc3\x28\",\"questions\":{\"q\":{\"type\":\"noul\"}}}",         // invalid UTF-8
		strings.Repeat("[", 5000) + strings.Repeat("]", 5000),                        // depth bomb
		`{"state":` + strings.Repeat("[", 5000) + strings.Repeat("]", 5000) + `,"questions":{}}`,
	}
	for _, r := range raws {
		_, err := parse([]byte(r))
		if outcomeOf(err) != (outcome{400, "invalid_request"}) {
			t.Errorf("%.60q: %v", r, outcomeOf(err))
		}
	}
	// the same escape in valid position is fine; a large integer is accepted exactly
	mustParse(t, []byte(`{"state":"a\u0000b","questions":{"q":{"type":"noul"}}}`))
	if got := mustParse(t, body("state", `[`+strings.Repeat("9", 400)+`]`)).StateText; got != `[`+strings.Repeat("9", 400)+`]` {
		t.Fatal("big integers are kept exactly")
	}
}

func TestMoreThan255Options400(t *testing.T) {
	for _, l := range []contract.Limits{lim, bigLimit} {
		_, err := parseL(body("questions", qs("c", choiceQ(256))), l)
		if outcomeOf(err) != (outcome{400, "invalid_request"}) {
			t.Errorf("256 options: %v", err)
		}
	}
	// the 400 wins over a malformed sibling question that would be a 422 later
	_, err := parseL(body("questions", `{"c":`+choiceQ(300)+`,"d":{"type":"bogus"}}`), bigLimit)
	if outcomeOf(err) != (outcome{400, "invalid_request"}) {
		t.Fatal(err)
	}
	p, err := parseL(body("questions", qs("c", choiceQ(255))), bigLimit)
	if err != nil || len(p.Questions[0].Options) != 255 {
		t.Fatal(err)
	}
	// letters exist for the first 26 only
	q := p.Questions[0]
	if q.Options[25].Letter != "Z" || q.Options[26].Letter != "" {
		t.Fatalf("%q %q", q.Options[25].Letter, q.Options[26].Letter)
	}
}

func TestRejections422(t *testing.T) {
	v := outcome{422, "validation_failed"}
	cases := map[string][]byte{
		"choice 1 option":       body("questions", qs("c", choiceQ(1))),
		"choice over profile":   body("questions", qs("c", choiceQ(21))),
		"choice no criteria":    body("questions", qs("c", `{"type":"choice","instructions":"x"}`)),
		"choice list criteria":  body("questions", qs("c", `{"type":"choice","instructions":"x","criteria":["a","b"]}`)),
		"choice empty key":      body("questions", qs("c", `{"type":"choice","criteria":{"":"x","b":"y"}}`)),
		"choice number desc":    body("questions", qs("c", `{"type":"choice","criteria":{"a":1,"b":"y"}}`)),
		"choice bool desc":      body("questions", qs("c", `{"type":"choice","criteria":{"a":true,"b":"y"}}`)),
		"score 0":               body("questions", qs("s", `{"type":"score","criteria":[]}`)),
		"score 1":               body("questions", qs("s", scoreQ(1))),
		"score 11":              body("questions", qs("s", scoreQ(11))),
		"score dict criteria":   body("questions", qs("s", `{"type":"score","criteria":{"a":1,"b":2}}`)),
		"score no criteria":     body("questions", qs("s", `{"type":"score"}`)),
		"score number level":    body("questions", qs("s", `{"type":"score","criteria":[1,2]}`)),
		"extra top-level field": body("extra", "1"),
		"extra question field":  body("questions", qs("q", `{"type":"noul","instructions":"x","bogus":1}`)),
		"missing state":         []byte(`{"questions":{"q":{"type":"noul"}}}`),
		"missing questions":     []byte(`{"state":"s"}`),
		"empty questions":       body("questions", `{}`),
		"questions list":        body("questions", `[1]`),
		"empty question name":   body("questions", qs("", `{"type":"noul"}`)),
		"question not object":   body("questions", qs("q", `"str"`)),
		"unknown type":          body("questions", qs("q", `{"type":"bogus"}`)),
		"type missing":          body("questions", qs("q", `{}`)),
		"type not string":       body("questions", qs("q", `{"type":["noul"]}`)),
		"state number":          body("state", `5`),
		"state bool":            body("state", `true`),
		"state null":            body("state", `null`),
		"instructions number":   body("questions", qs("q", `{"type":"noul","instructions":5}`)),
		"noul unknown criteria": body("questions", qs("q", `{"type":"noul","criteria":{"maybe":"x"}}`)),
		"noul list criteria":    body("questions", qs("q", `{"type":"noul","criteria":["x"]}`)),
		"noul number criteria":  body("questions", qs("q", `{"type":"noul","criteria":{"true":5}}`)),
		"noul empty list crit":  body("questions", qs("q", `{"type":"noul","criteria":[]}`)),
	}
	for name, b := range cases {
		if _, err := parse(b); outcomeOf(err) != v {
			t.Errorf("%s: %v", name, outcomeOf(err))
		}
	}
	l := contract.DefaultLimits()
	l.MinScale, l.MaxScale = 2, 5
	if _, err := parseL(body("questions", qs("s", scoreQ(6))), l); outcomeOf(err) != v {
		t.Fatal("configurable score levels")
	}
	if _, err := parseL(body("questions", qs("s", scoreQ(5))), l); err != nil {
		t.Fatal(err)
	}
}

func TestTooManyQuestions(t *testing.T) {
	mk := func(n int) []byte {
		var parts []string
		for i := 0; i < n; i++ {
			parts = append(parts, fmt.Sprintf(`"q%d":{"type":"noul","instructions":"x"}`, i))
		}
		return body("questions", "{"+strings.Join(parts, ",")+"}")
	}
	if _, err := parse(mk(33)); outcomeOf(err) != (outcome{422, "validation_failed"}) {
		t.Fatal(err)
	}
	if p, err := parse(mk(32)); err != nil || len(p.Questions) != 32 {
		t.Fatal(err)
	}
	l := contract.DefaultLimits()
	l.MaxQuestions = 2
	if _, err := parseL(mk(3), l); outcomeOf(err) != (outcome{422, "validation_failed"}) {
		t.Fatal(err)
	}
}

func TestNoulCriteria(t *testing.T) {
	q := mustParse(t, body("questions", qs("q", `{"type":"noul","instructions":"x","criteria":{"true":"yes!","false":null}}`))).Questions[0]
	if q.Options[0].Label != "yes - yes!" || q.Options[1].Label != "no" {
		t.Fatalf("%+v", q.Options)
	}
	q = mustParse(t, body("questions", qs("q", `{"type":"noul","criteria":{"true":"","false":"nope"}}`))).Questions[0]
	if q.Options[0].Label != "yes" || q.Options[1].Label != "no - nope" {
		t.Fatalf("empty description adds nothing: %+v", q.Options)
	}
	if q := mustParse(t, body("questions", qs("q", `{"type":"noul","criteria":null}`))).Questions[0]; q.Type != "noul" {
		t.Fatal(q)
	}
	if q := mustParse(t, body("questions", qs("q", `{"type":"noul","criteria":{}}`))).Questions[0]; q.Options[0].Label != "yes" {
		t.Fatal(q)
	}
}

func TestMessagesGenericAndStable(t *testing.T) {
	_, err := parse(body("questions", qs("SECRETNAME", choiceQ(1))))
	if err == nil || strings.Contains(err.Error(), "SECRETNAME") || strings.Contains(err.Error(), "Traceback") || strings.Contains(err.Error(), "goroutine") {
		t.Fatal(err)
	}
	_, err = parse([]byte(`{"state":"SECRETSTATE","state":1}`))
	if err == nil || strings.Contains(err.Error(), "SECRETSTATE") {
		t.Fatal(err)
	}
	_, err = parse([]byte(`{"state":"s","questions":{"q":{"type":"noul","instructions":"i"}},"SECRETKEY":1}`))
	if err == nil || strings.Contains(err.Error(), "SECRETKEY") {
		t.Fatal(err)
	}
}

func TestStateBudget(t *testing.T) {
	small := contract.DefaultLimits()
	small.MaxStateChars = 100
	if _, err := parseL(body("state", js(strings.Repeat("x", 200))), small); outcomeOf(err) != (outcome{422, "validation_failed"}) {
		t.Fatal("over budget is rejected by default", err)
	}
	// noul: instructions (50) + labels "yes"+"no" (5) = 55
	q55 := qs("q", `{"type":"noul","instructions":"`+strings.Repeat("i", 50)+`"}`)
	if n := contract.QuestionChars(mustParse(t, body("questions", q55)).Questions[0]); n != 55 {
		t.Fatalf("question chars %d", n)
	}
	for _, c := range []struct {
		state int
		ok    bool
	}{{40, true}, {45, true}, {46, false}, {50, false}} {
		_, err := parseL(body("state", js(strings.Repeat("x", c.state)), "questions", q55), small)
		if (err == nil) != c.ok {
			t.Errorf("state %d: ok=%v err=%v", c.state, c.ok, err)
		}
	}
}

func TestBudgetCountsCodePointsNotBytes(t *testing.T) {
	small := contract.DefaultLimits()
	small.MaxStateChars = 100
	q := qs("q", `{"type":"noul"}`) // 5 chars of labels
	if _, err := parseL(body("state", js(strings.Repeat("é", 95)), "questions", q), small); err != nil {
		t.Fatalf("95 code points + 5 fits exactly: %v", err)
	}
	if _, err := parseL(body("state", js(strings.Repeat("é", 96)), "questions", q), small); err == nil {
		t.Fatal("96 code points must not fit")
	}
}

func TestTruncateOptIn(t *testing.T) {
	l := contract.DefaultLimits()
	l.MaxStateChars, l.Truncate = 200, true
	state := "HEAD" + strings.Repeat("m", 1000) + "TAIL"
	ins := strings.Repeat("keep me whole ", 3)
	p, err := parseL(body("state", js(state), "questions", qs("q", `{"type":"noul","instructions":`+js(ins)+`}`)), l)
	if err != nil {
		t.Fatal(err)
	}
	st := p.StateText
	if !p.Truncated || !strings.HasPrefix(st, "HEAD") || !strings.HasSuffix(st, "TAIL") || !strings.Contains(st, contract.TruncationMarker) {
		t.Fatalf("truncated=%v %q", p.Truncated, st)
	}
	if utf8.RuneCountInString(st)+utf8.RuneCountInString(p.Questions[0].Instructions) > 200 {
		t.Fatal("budget exceeded")
	}
	if p.Questions[0].Instructions != ins {
		t.Fatal("question shortened")
	}
	// exactly the available room is used: state + question == budget
	if got := utf8.RuneCountInString(st) + contract.QuestionChars(p.Questions[0]); got != 200 {
		t.Fatalf("expected the budget to be filled exactly, got %d", got)
	}
}

func TestTruncateNotFlaggedWhenFits(t *testing.T) {
	l := contract.DefaultLimits()
	l.MaxStateChars, l.Truncate = 200, true
	p, _ := parseL(body("state", `"short"`), l)
	if p.Truncated || p.StateText != "short" {
		t.Fatalf("%+v", p)
	}
}

func TestTruncateNeverShortensQuestion(t *testing.T) {
	l := contract.DefaultLimits()
	l.MaxStateChars, l.Truncate = 100, true
	_, err := parseL(body("state", js(strings.Repeat("x", 500)), "questions", qs("q", `{"type":"noul","instructions":"`+strings.Repeat("i", 100)+`"}`)), l)
	if outcomeOf(err) != (outcome{422, "validation_failed"}) {
		t.Fatal(err)
	}
	// room for the marker plus fewer than two state characters is still refused
	markerLen := utf8.RuneCountInString(contract.TruncationMarker)
	pad := 100 - 5 - markerLen - 1 // leaves keep == 1
	_, err = parseL(body("state", js(strings.Repeat("x", 500)), "questions", qs("q", `{"type":"noul","instructions":"`+strings.Repeat("i", pad)+`"}`)), l)
	if outcomeOf(err) != (outcome{422, "validation_failed"}) {
		t.Fatalf("keep=1 must be refused: %v", err)
	}
	_, err = parseL(body("state", js(strings.Repeat("x", 500)), "questions", qs("q", `{"type":"noul","instructions":"`+strings.Repeat("i", pad-1)+`"}`)), l)
	if err != nil {
		t.Fatalf("keep=2 is the smallest accepted: %v", err)
	}
}

func TestTruncateKeepsOptionTextAndCountsCodePoints(t *testing.T) {
	l := contract.DefaultLimits()
	l.MaxStateChars, l.Truncate = 300, true
	p, err := parseL(body("state", js(strings.Repeat("é", 5000)), "questions", qs("c", choiceQ(5))), l)
	if err != nil {
		t.Fatal(err)
	}
	if p.Questions[0].Options[0].Label != "opt0 - desc 0" {
		t.Fatal("option text shortened")
	}
	if utf8.RuneCountInString(p.StateText)+contract.QuestionChars(p.Questions[0]) > 300 || !utf8.ValidString(p.StateText) {
		t.Fatal("budget or UTF-8 broken by truncation")
	}
}

// FuzzParseRequest: ParseRequest never panics, and every outcome is either a parsed request or a
// 400/422 ContractError with a generic message. The seed corpus runs as part of `go test`.
func FuzzParseRequest(f *testing.F) {
	seeds := [][]byte{body(), body("questions", qs("c", choiceQ(3))), body("questions", qs("s", scoreQ(4))), body("model", `"jev-latest"`),
		body("state", `{"b":[1,2.5e3,null,true,"x"],"a":{}}`), []byte(``), []byte(`{`), []byte(`[`), []byte(`null`), []byte(`{"state":NaN}`),
		[]byte(`{"state":"a","state":"b"}`), []byte("\xff\xfe"), []byte(strings.Repeat("[", 3000)), body("questions", qs("c", choiceQ(256))),
		[]byte(`{"state":"s","questions":{"q":{"type":"noul","criteria":{"true":null,"false":""}}}}`),
		[]byte(`{"state":"\ud800","questions":{"q":{"type":"noul"}}}`), []byte(`{"state":1e999,"questions":{}}`),
		body("questions", `{"q":{"type":"score","criteria":[null,{"a":[]},"x"]}}`), body("state", `"\u2028\u0085===\nA) x"`)}
	for _, s := range seeds {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, b []byte) {
		p, err := contract.ParseRequest(b, bigLimit, tinyBig)
		if err != nil {
			o := outcomeOf(err)
			if o.Status != 400 && o.Status != 422 {
				t.Fatalf("unexpected outcome %v for %q", o, b)
			}
			return
		}
		if p == nil || p.Model == "" || len(p.Questions) == 0 || !utf8.ValidString(p.StateText) {
			t.Fatalf("bad parse result for %q: %+v", b, p)
		}
		for _, q := range p.Questions {
			if q.Name == "" || len(q.Options) < 2 {
				t.Fatalf("bad question %+v", q)
			}
			// prompts render for every parsed question with <= 26 options, never panic
			if len(q.Options) <= 26 {
				if _, err := contract.RenderPrompt(q, p.StateText); err != nil {
					t.Fatal(err)
				}
			}
		}
	})
}
