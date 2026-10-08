package client

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

func parse(t *testing.T, body []byte, lim contract.Limits) (*contract.ParsedRequest, error) {
	t.Helper()
	p, err := contract.NewProfiles([]string{"decide-tiny"}, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	return contract.ParseRequest(body, lim, p)
}

func TestBuildFlagsChoicePreservesCriteriaOrderAndRoundTrips(t *testing.T) {
	b, err := Build(Input{State: "Line one\nline \"two\" — ünï", HasState: true, Type: "choice",
		Instructions: "Which team?", Criteria: json.RawMessage(` { "zeta": "last alphabetically", "alpha":"first",
		"mid": null } `)})
	if err != nil {
		t.Fatal(err)
	}
	req, err := parse(t, b.Local, contract.DefaultLimits())
	if err != nil {
		t.Fatalf("contract rejects the built body: %v\n%s", err, b.Local)
	}
	var keys []string
	for _, o := range req.Questions[0].Options {
		keys = append(keys, o.Key)
	}
	if strings.Join(keys, ",") != "zeta,alpha,mid" {
		t.Fatalf("option order not preserved: %v", keys)
	}
	if req.StateText != "Line one\nline \"two\" — ünï" || b.Questions != 1 || b.Model != "" {
		t.Fatalf("state/questions/model: %q %d %q", req.StateText, b.Questions, b.Model)
	}
}

func TestBuildModelIncludedOnlyInBody(t *testing.T) {
	b, err := Build(Input{Model: "decide-tiny", State: "s", HasState: true, Type: "noul", Instructions: "ok?"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b.Body), `"model":"decide-tiny"`) || strings.Contains(string(b.Local), `"model"`) {
		t.Fatalf("body=%s local=%s", b.Body, b.Local)
	}
	if b.Model != "decide-tiny" {
		t.Fatal(b.Model)
	}
}

func TestBuildScoreAndNoulCriteria(t *testing.T) {
	sc, err := Build(Input{State: "s", HasState: true, Type: "score", Instructions: "q", Criteria: json.RawMessage(`["bad","ok","good"]`)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parse(t, sc.Local, contract.DefaultLimits()); err != nil {
		t.Fatal(err)
	}
	nl, err := Build(Input{State: "s", HasState: true, Type: "noul", Instructions: "q", Criteria: json.RawMessage(`{"true":"yes means","false":"no means"}`)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parse(t, nl.Local, contract.DefaultLimits()); err != nil {
		t.Fatal(err)
	}
}

func TestBuildQuestionFileSingleAndFullRequest(t *testing.T) {
	one := []byte(`{"type":"choice","instructions":"Pick","criteria":{"b":"second","a":"first"}}`)
	b, err := Build(Input{State: "hello", HasState: true, QuestionFile: one})
	if err != nil {
		t.Fatal(err)
	}
	req, err := parse(t, b.Local, contract.DefaultLimits())
	if err != nil || req.Questions[0].Name != DefaultQuestionName || req.Questions[0].Options[0].Key != "b" {
		t.Fatalf("%v %+v", err, req)
	}
	full := []byte(`{"model":"decide-tiny","state":"from file","questions":{"x":{"type":"noul","instructions":"q"},"y":{"type":"noul","instructions":"r"}}}`)
	f, err := Build(Input{QuestionFile: full})
	if err != nil {
		t.Fatal(err)
	}
	if f.Questions != 2 || f.Model != "decide-tiny" {
		t.Fatalf("%+v", f)
	}
	over, err := Build(Input{State: "flag wins", HasState: true, QuestionFile: full})
	if err != nil || !strings.Contains(string(over.Body), `"flag wins"`) {
		t.Fatalf("%v %s", err, over.Body)
	}
}

func TestBuildUsageErrors(t *testing.T) {
	cases := map[string]Input{
		"no state":        {Type: "noul", Instructions: "q"},
		"no type":         {State: "s", HasState: true, Instructions: "q"},
		"bad type":        {State: "s", HasState: true, Type: "maybe", Instructions: "q"},
		"no instructions": {State: "s", HasState: true, Type: "noul"},
		"bad criteria":    {State: "s", HasState: true, Type: "choice", Instructions: "q", Criteria: json.RawMessage(`{"a":`)},
		"file not object": {State: "s", HasState: true, QuestionFile: []byte(`[1,2]`)},
		"file not json":   {State: "s", HasState: true, QuestionFile: []byte(`{`)},
		"state not utf8":  {State: "bad\xff\xfe", HasState: true, Type: "noul", Instructions: "q"},
	}
	for name, in := range cases {
		if _, err := Build(in); kindOf(err) != KindUsage {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestBuildFiveMegabyteStateIsData(t *testing.T) {
	state := strings.Repeat("0123456789abcdef\n", 5<<20/17+1)[:5<<20]
	b, err := Build(Input{State: state, HasState: true, Type: "noul", Instructions: "ok?"})
	if err != nil {
		t.Fatal(err)
	}
	lim := contract.DefaultLimits()
	lim.MaxStateChars = 8 << 20
	req, err := parse(t, b.Local, lim)
	if err != nil || len(req.StateText) != len(state) {
		t.Fatalf("len=%d err=%v", len(req.StateText), err)
	}
	if b.StateBytes < len(state) {
		t.Fatalf("StateBytes=%d", b.StateBytes)
	}
}

func TestBuildDefaultLimitRejectsOversizeStateLocally(t *testing.T) {
	b, _ := Build(Input{State: strings.Repeat("x", 9000), HasState: true, Type: "noul", Instructions: "q"})
	if _, err := parse(t, b.Local, contract.DefaultLimits()); err == nil {
		t.Fatal("the default 8192-char budget must reject a 9000-char state")
	}
}
