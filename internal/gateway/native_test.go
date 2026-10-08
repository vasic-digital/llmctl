package gateway

import (
	"context"
	"encoding/json"
	"math"
	"net/http"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

func nativeResp(answers string) []byte {
	return []byte(`{"model":"laya","answers":` + answers + `,"usage":{"input_tokens":11,"output_tokens":2}}`)
}

func TestNativeProxiesAndShapesAnswers(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(nativeResp(`{"n":{"type":"noul","noul":0.8},"c":{"type":"choice","choice":"support","probabilities":{"billing":0.2,"support":0.7,"sales":0.1},"confidence":0.5}}`))
	})
	body := `{"model":"decide-laya","state":{"b":1,"a":[1,2]},"questions":{"n":{"type":"noul","instructions":"Is it urgent?","criteria":{"true":"fire","false":"calm"}},` +
		`"c":{"type":"choice","instructions":"Which?","criteria":{"billing":"money","support":"help","sales":"deals"}}}}`
	n := &NativeBackend{Enabled: true}
	ans, usage, err := n.Decide(context.Background(), ep(srv.URL), specByID(t, "decide-laya"), parseFor(t, body))
	if err != nil {
		t.Fatal(err)
	}
	if len(ans) != 2 || ans[0].Name != "n" || math.Abs(ans[0].Answer.Noul-0.8) > 1e-9 || ans[1].Answer.Choice != "support" {
		t.Fatalf("%+v", ans)
	}
	if usage.InputTokens != 11 || usage.OutputTokens != 2 {
		t.Fatalf("usage %+v", usage)
	}
	if rec.path != "/v1/systemone" || rec.auth != "Bearer internal-k" {
		t.Fatalf("%s %s", rec.path, rec.auth)
	}
	if rec.body["model"] != "decide-laya" {
		t.Fatalf("model %v", rec.body["model"])
	}
	qs := rec.body["questions"].(map[string]any)
	cc := qs["c"].(map[string]any)["criteria"].(map[string]any)
	if cc["billing"] != "money" || cc["sales"] != "deals" {
		t.Fatalf("criteria not reconstructed: %v", cc)
	}
	nc := qs["n"].(map[string]any)["criteria"].(map[string]any)
	if nc["true"] != "fire" || nc["false"] != "calm" {
		t.Fatalf("noul criteria %v", nc)
	}
	if st, _ := rec.body["state"].(string); !strings.Contains(st, `"a":[1,2]`) {
		t.Fatalf("state %v", rec.body["state"])
	}
}

func TestNativeScoreKeepsLegend(t *testing.T) {
	srv, rec := fakeServer(t, func(_ *recorded, w http.ResponseWriter) {
		_, _ = w.Write(nativeResp(`{"s":{"type":"score","score":1.1,"probabilities":{"0":0.1,"1":0.7,"2":0.2},"legend":{},"confidence":0.4}}`))
	})
	n := &NativeBackend{Enabled: true}
	ans, _, err := n.Decide(context.Background(), ep(srv.URL), specByID(t, "decide-laya"), parseFor(t, strings.Replace(scoreBody, "decide-tiny", "decide-laya", 1)))
	if err != nil {
		t.Fatal(err)
	}
	if a := ans[0].Answer; a.Type != "score" || len(a.Legend) != 3 || math.Abs(a.Score-1.1) > 1e-6 {
		t.Fatalf("%+v", a)
	}
	crit := rec.body["questions"].(map[string]any)["s"].(map[string]any)["criteria"].([]any)
	if len(crit) != 3 || crit[2] != "good" {
		t.Fatalf("%v", crit)
	}
	_ = json.Valid
}

func TestNativeDisabledByDefault(t *testing.T) {
	srv, rec := fakeServer(t, func(*recorded, http.ResponseWriter) {})
	_, _, err := (&NativeBackend{}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-laya"), parseFor(t, strings.Replace(noulBody, "decide-tiny", "decide-laya", 1)))
	if c := ce(t, err); c.Status != 503 || c.ErrorType != contract.ErrTypeNotReady {
		t.Fatalf("%+v", c)
	}
	if rec.n != 0 {
		t.Fatal("a disabled native backend must not touch the engine")
	}
}

func TestNativeRefusesNonNativeProfile(t *testing.T) {
	if _, _, err := (&NativeBackend{Enabled: true}).Decide(context.Background(), ep("http://127.0.0.1:1"), specByID(t, "decide-tiny"), parseFor(t, noulBody)); err == nil {
		t.Fatal("must refuse")
	}
}

func TestNativeBadResponses(t *testing.T) {
	for name, resp := range map[string]string{
		"missing":   `{"answers":{},"usage":{}}`,
		"badprob":   `{"answers":{"q":{"type":"noul","noul":2}},"usage":{}}`,
		"notjson":   `nope`,
		"wrongtype": `{"answers":{"q":{"type":"choice","choice":"x","probabilities":{"yes":1}}},"usage":{}}`,
	} {
		srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) { _, _ = w.Write([]byte(resp)) })
		_, _, err := (&NativeBackend{Enabled: true}).Decide(context.Background(), ep(srv.URL), specByID(t, "decide-laya"), parseFor(t, strings.Replace(noulBody, "decide-tiny", "decide-laya", 1)))
		if c := ce(t, err); c.Status != 502 {
			t.Errorf("%s: %+v", name, c)
		}
	}
}
