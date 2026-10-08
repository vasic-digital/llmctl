package gateway

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/vasic-digital/llmctl/internal/contract"
)

// The real first-token behaviour of decide-tiny (Jev-Style-0.8B-Decision-v3 Q4_K_M) on the gateway's
// letter prompt, captured on 2026-10-08 (specs/009-jev-decision-models/evidence/live-models/decide-tiny/
// decide-tiny-smoke-capture.txt and letter_probe.out): the first token is the model's VERDICT token
// " no"/" yes" - letter mass ~0 under the chat template, with thinking disabled, and with no template
// at all. The model card says decisions are read at one " ->" verdict slot per option
// (readout_config.json "readout": "verdict"), never by generation.
func jevTinyLetterPromptResponse() []byte {
	return llamaResponse(
		lpEntry{" no", -0.8050930500030518},
		lpEntry{" yes", -0.9733259677886963},
		lpEntry{" Yes", -2.5362274646759033},
		lpEntry{" No", -2.7984182834625244},
		lpEntry{"yes", -4.9556565284729},
		lpEntry{"no", -6.350057125091553},
		lpEntry{"Yes", -6.788815021514893},
		lpEntry{" NO", -6.804041862487793},
		lpEntry{" YES", -6.910959720611572},
		lpEntry{"\n\n", -7.374401569366455},
	)
}

// Characterisation: the letter-logit readout cannot serve this model - its real first-token
// distribution is the opaque 422 the live run saw. (This is WHY the profile must not be letter-logit.)
func TestJevTinyRealFirstTokenDefeatsLetterReadout(t *testing.T) {
	srv, _ := fakeServer(t, func(_ *recorded, w http.ResponseWriter) { _, _ = w.Write(jevTinyLetterPromptResponse()) })
	_, _, err := newLetter().Decide(context.Background(), ep(srv.URL), specByID(t, "decide-tiny"), parseFor(t, choiceBody))
	if c := ce(t, err); c.Status != 422 || c.ErrorType != contract.ErrTypeReadoutFailed {
		t.Fatalf("got %d %s", c.Status, c.ErrorType)
	}
}

// The shipped catalog must classify decide-tiny by the protocol its vendor documents (jev-verdict),
// not letter-logit, and the gateway must know it cannot serve that protocol.
func TestShippedCatalogDecideTinyIsJevVerdictUnsupported(t *testing.T) {
	specs, err := LoadCatalog("../../models/catalog.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range specs {
		if s.ID != "decide-tiny" {
			continue
		}
		if s.Protocol != ProtoJevVerdict {
			t.Fatalf("decide-tiny protocol = %q, want %q (its readout is a per-option verdict slot, not a letter)", s.Protocol, ProtoJevVerdict)
		}
		if s.Unsupported == "" {
			t.Fatal("decide-tiny: the gateway must mark the jev-verdict protocol as not implemented")
		}
		return
	}
	t.Fatal("decide-tiny missing from the shipped catalog")
}

func TestCatalogAcceptsJevVerdictAndMarksItUnsupported(t *testing.T) {
	specs, err := ParseCatalog([]byte(`{"profiles":{"decide-j":{"port":8092,"capability":["decide"],
		"decision":{"protocol":"jev-verdict","max_options":20,"score_levels":[2,10]}}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(specs) != 1 || specs[0].Protocol != ProtoJevVerdict || !strings.Contains(specs[0].Unsupported, "jev-verdict") {
		t.Fatalf("spec = %+v", specs)
	}
	// a protocol the gateway implements is never marked unsupported
	for _, s := range testSpecs() {
		if unsupportedReason(s.Protocol) != "" {
			t.Fatalf("%s: implemented protocol %s marked unsupported", s.ID, s.Protocol)
		}
	}
}

// The router serves a catalog that contains an unsupported profile (no driver needed for it), never
// lists or routes it, and refuses a request for it with a clear, NON-retryable error before any
// engine contact - instead of an opaque "no usable answer".
func TestRouterRefusesUnsupportedProfileClearly(t *testing.T) {
	calls := 0
	srv := newRecordedServer(t, func(w http.ResponseWriter, r *http.Request) { calls++; _, _ = w.Write(jevTinyLetterPromptResponse()) })
	specs := append(testSpecs(), ProfileSpec{ID: "decide-jev", Protocol: ProtoJevVerdict, Port: 8092, MaxOptions: 20,
		ScoreLevels: [2]int{2, 10}, Unsupported: unsupportedReason(ProtoJevVerdict)})
	profiles, err := BuildProfiles(specs, "decide-tiny", contract.DefaultLimits())
	if err != nil {
		t.Fatal(err)
	}
	res := NewStaticResolver()
	res.Set(KindDecide, "decide-jev", Endpoint{URL: srv.URL, Healthy: true, Key: "k"})
	d := &fakeDriver{}
	r, err := NewRouter(RouterConfig{Specs: specs, Resolver: res, Profiles: profiles,
		Drivers: map[string]Driver{ProtoLetter: d, ProtoNLI: d, ProtoNative: d}})
	if err != nil {
		t.Fatalf("a catalog with an unsupported profile must still serve the others: %v", err)
	}
	for _, m := range r.Models() {
		if m.ID == "decide-jev" {
			t.Fatal("an unsupported profile must not be listed as servable")
		}
	}
	if r.Ready() {
		t.Fatal("an unsupported profile's instance must not make the gateway ready")
	}
	req, err := contract.ParseRequest([]byte(strings.Replace(choiceBody, "decide-tiny", "decide-jev", 1)), contract.DefaultLimits(), profiles)
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = r.Decide(context.Background(), req)
	c := ce(t, err)
	if c.Status != 500 || c.Retryable() || c.ErrorType != contract.ErrTypeBackendFailed {
		t.Fatalf("want a non-retryable 500 backend_failed, got %d %s retryable=%v", c.Status, c.ErrorType, c.Retryable())
	}
	if !strings.Contains(c.Message, "decide-jev") || !strings.Contains(c.Message, "jev-verdict") || !strings.Contains(c.Message, "not implemented") {
		t.Fatalf("the refusal must name the profile, the protocol and the reason: %q", c.Message)
	}
	if calls != 0 || len(d.served) != 0 {
		t.Fatalf("no engine/driver contact for an unsupported profile (engine calls %d, driver calls %d)", calls, len(d.served))
	}
}
