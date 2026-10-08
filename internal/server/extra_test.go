package server

import (
	"context"

	"encoding/json"
	"errors"
	"github.com/vasic-digital/llmctl/internal/contract"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestFromOSEnvReadsProcessEnvironment(t *testing.T) {
	t.Setenv("LLMCTL_DECIDE_MAX_CONNS", "12")
	l, err := FromOSEnv()
	if err != nil || l.MaxConns != 12 {
		t.Fatalf("%+v %v", l, err)
	}
	t.Setenv("LLMCTL_DECIDE_MAX_CONNS", "twelve")
	if _, err := FromOSEnv(); err == nil {
		t.Fatal("bad process env must be rejected")
	}
}

func TestLimitErrorTruncatesLongValuesAndNamesTheVariable(t *testing.T) {
	_, err := FromEnv(map[string]string{"LLMCTL_DECIDE_QUEUE": strings.Repeat("9", 500) + "x"})
	if err == nil || len(err.Error()) > 200 || !strings.Contains(err.Error(), "LLMCTL_DECIDE_QUEUE") {
		t.Fatalf("%v", err)
	}
}

func TestListenAndServeAndClose(t *testing.T) {
	s := mustNewForInternal(t)
	done := make(chan error, 1)
	go func() { done <- s.ListenAndServe("127.0.0.1:0") }()
	time.Sleep(100 * time.Millisecond)
	_ = s.Close()
	select {
	case err := <-done:
		if !errors.Is(err, http.ErrServerClosed) {
			t.Fatalf("%v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("ListenAndServe did not return after Close")
	}
	if err := mustNewForInternal(t).ListenAndServe("256.256.256.256:1"); err == nil {
		t.Fatal("bad address must fail")
	}
}

func TestModelsWithNilAliasesIsEmptyArray(t *testing.T) {
	h := startServer(t)
	h.be.models = []ModelInfo{{ID: "x", Protocol: "nli-onnx", Status: "ready", MaxOptions: 3, ScoreLevels: [2]int{2, 5}, Notes: "experimental"}}
	r := h.do(h.client(), "GET", "/v1/models", "", nil)
	if r.status != 200 || !strings.Contains(string(r.body), `"aliases":[]`) || !strings.Contains(string(r.body), `"notes":"experimental"`) {
		t.Fatalf("%d %s", r.status, r.body)
	}
}

func TestSrvConnDeadlinesAreRememberedAcrossTheHandshake(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	c := &srvConn{raw: a}
	d := time.Now().Add(time.Hour)
	if err := c.SetDeadline(d); err != nil || !c.rd.Equal(d) || !c.wd.Equal(d) {
		t.Fatalf("SetDeadline not remembered: %v", err)
	}
	if c.tlsVersion() != "" {
		t.Error("no TLS version before the handshake")
	}
	if c.LocalAddr() == nil || c.RemoteAddr() == nil {
		t.Error("addresses")
	}
	if clientIPText("not-an-addr") != "not-an-addr" || clientIPText("[::ffff:10.0.0.1]:5") != "10.0.0.1" {
		t.Error("clientIPText")
	}
}

// G-038: the hosted SDKs (typesafe-sdk py 0.7.2 / @typesafe-ai/sdk js 0.6.0) read
// GET /v1/models as {"models":[{"name","description","release_date"}]} and reject anything else.
// The body therefore carries BOTH that shape and the llmctl `object`/`data` listing.
func TestModelsBodyCarriesTheSDKShapeAndTheLocalShape(t *testing.T) {
	h := startServer(t)
	r := h.do(h.client(), "GET", "/v1/models", "", nil)
	if r.status != 200 {
		t.Fatalf("%d %s", r.status, r.body)
	}
	var body struct {
		Object string `json:"object"`
		Data   []struct {
			ID string `json:"id"`
		} `json:"data"`
		Models []map[string]any `json:"models"`
	}
	if err := json.Unmarshal(r.body, &body); err != nil {
		t.Fatal(err)
	}
	if body.Object != "list" || len(body.Data) != 1 || body.Data[0].ID != "decide-tiny" {
		t.Errorf("local listing lost: %s", r.body)
	}
	// one SDK entry per accepted name: the profile id and each alias
	names := map[string]bool{}
	for _, m := range body.Models {
		if len(m) != 3 {
			t.Errorf("SDK entry must be exactly name/description/release_date: %v", m)
		}
		n, _ := m["name"].(string)
		d, _ := m["description"].(string)
		rd, _ := m["release_date"].(string)
		if n == "" || d == "" {
			t.Errorf("empty name/description: %v", m)
		}
		if _, err := time.Parse("2006-01-02", rd); err != nil {
			t.Errorf("release_date %q is not YYYY-MM-DD", rd)
		}
		names[n] = true
	}
	for _, want := range []string{"decide-tiny", "jev-latest", "llmctl-decide-tiny"} {
		if !names[want] {
			t.Errorf("SDK listing lacks %q: %v", want, names)
		}
	}
	// the release date is stable (not stamped per request)
	r2 := h.do(h.client(), "GET", "/v1/models", "", nil)
	if string(r2.body) != string(r.body) {
		t.Errorf("listing changed between requests:\n%s\n%s", r.body, r2.body)
	}
}

func TestModelsUsesTheBackendsDescriptionAndReleaseDate(t *testing.T) {
	h := startServer(t)
	h.be.models = []ModelInfo{{ID: "x", Aliases: []string{"y"}, Protocol: "nli-onnx", Status: "ready", MaxOptions: 3,
		ScoreLevels: [2]int{2, 5}, Description: "Zero-shot NLI encoder.", ReleaseDate: "2026-01-02"}}
	r := h.do(h.client(), "GET", "/v1/models", "", nil)
	if !strings.Contains(string(r.body), `{"name":"x","description":"Zero-shot NLI encoder.","release_date":"2026-01-02"}`) ||
		!strings.Contains(string(r.body), `"name":"y"`) || !strings.Contains(string(r.body), `Alias of x`) {
		t.Fatalf("%s", r.body)
	}
	h.be.models = []ModelInfo{{ID: "z", Protocol: "letter-logit", Status: "ready", MaxOptions: 3, ScoreLevels: [2]int{2, 5}, ReleaseDate: "not-a-date"}}
	r = h.do(h.client(), "GET", "/v1/models", "", nil)
	if strings.Contains(string(r.body), "not-a-date") || !strings.Contains(string(r.body), `"release_date":"`+DefaultReleaseDate+`"`) {
		t.Fatalf("an invalid backend date must fall back to the documented default: %s", r.body)
	}
}

// G-039: a backend that truncated the state itself (encoder runtime truncated[] under opt-in)
// reports it through NoteTruncated and the response carries x-llmctl-decide-truncated: true.
func TestBackendNoteTruncatedSetsTheHeaderOnlyForThatRequest(t *testing.T) {
	h := startServer(t)
	h.be.setDecide(func(ctx context.Context, r *contract.ParsedRequest) ([]contract.NamedAnswer, contract.Usage, error) {
		if strings.Contains(r.StateText, "TRUNCATE-ME") {
			NoteTruncated(ctx)
		}
		return uniformAnswers(r)
	})
	r := h.do(h.client(), "POST", "/v1/systemone", strings.Replace(sampleBody, "the printer is on fire", "TRUNCATE-ME", 1), nil)
	if r.status != 200 || r.hdr.Get("x-llmctl-decide-truncated") != "true" {
		t.Fatalf("%d hdr=%q %s", r.status, r.hdr.Get("x-llmctl-decide-truncated"), r.body)
	}
	r = h.do(h.client(), "POST", "/v1/systemone", sampleBody, nil)
	if r.status != 200 || r.hdr.Get("x-llmctl-decide-truncated") != "" {
		t.Fatalf("an untruncated request must not carry the header: %d %q", r.status, r.hdr.Get("x-llmctl-decide-truncated"))
	}
	NoteTruncated(context.Background()) // outside the gateway it is a harmless no-op
}
