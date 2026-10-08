package client

import (
	"io"
	"math"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

// probeGateway answers every choice question of a request. pick receives the question name and
// the option keys in the order they are LISTED in this call and returns each option's probability.
func probeGateway(t *testing.T, hits *atomic.Int32, pick func(q string, listed []string) []float64) *Client {
	t.Helper()
	srv := newTLSServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		b, _ := io.ReadAll(r.Body)
		_, qvals, err := orderedObject(mustField(t, b, "questions"))
		if err != nil {
			t.Fatal(err)
		}
		var parts []string
		for name, raw := range qvals {
			_, fv, _ := orderedObject(raw)
			if string(fv["type"]) != `"choice"` {
				parts = append(parts, string(jstr(name))+`:{"type":"noul","noul":0.9}`)
				continue
			}
			keys := criteriaOrder(t, b, name)
			ps := pick(name, keys)
			var pr []string
			best := 0
			for i, k := range keys {
				pr = append(pr, string(jstr(k))+":"+jsonFloat(ps[i]))
				if ps[i] > ps[best] {
					best = i
				}
			}
			parts = append(parts, string(jstr(name))+`:{"type":"choice","choice":`+string(jstr(keys[best]))+`,"probabilities":{`+strings.Join(pr, ",")+`},"confidence":0.5}`)
		}
		_, _ = w.Write([]byte(`{"model":"m","answers":{` + strings.Join(parts, ",") + `},"usage":{"input_tokens":1,"output_tokens":1}}`))
	}))
	c, _ := newTestClient(t, srv, nil)
	return c
}

func mustField(t *testing.T, body []byte, k string) []byte {
	t.Helper()
	_, v, err := orderedObject(body)
	if err != nil {
		t.Fatal(err)
	}
	return v[k]
}

const probeReq = `{"state":"s","questions":{"d":{"type":"choice","instructions":"p","criteria":{"x":"1","y":"2","z":"3"}}}}`

func near(t *testing.T, what string, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 1e-9 {
		t.Errorf("%s = %v, want %v", what, got, want)
	}
}

// A model that prefers the CONTENT "y" whatever the order: no flips, the answer sits at every
// listing position equally often (y is listed 2nd, 1st, 3rd in the three rotations x,y,z / y,z,x / z,x,y).
func TestProbeOrderContentRobustModelHasNoFlipsAndUniformPositions(t *testing.T) {
	var hits atomic.Int32
	c := probeGateway(t, &hits, func(_ string, listed []string) []float64 {
		out := make([]float64, len(listed))
		for i, k := range listed {
			out[i] = 0.1
			if k == "y" {
				out[i] = 0.8
			}
		}
		return out
	})
	res, err := c.ProbeOrder(t.Context(), []byte(probeReq), 0)
	if err != nil {
		t.Fatal(err)
	}
	if hits.Load() != 3 || res.Calls != 3 {
		t.Fatalf("calls = %d (hits %d), want a full cycle of 3", res.Calls, hits.Load())
	}
	q := res.Questions[0]
	if !q.Permutable || q.Name != "d" || q.Options != 3 || q.Orders != 3 || q.PartialCycle {
		t.Fatalf("question = %+v", q)
	}
	if q.Answer != "y" || q.Flips != 0 || !q.Unanimous {
		t.Errorf("answer %q flips %d unanimous %v", q.Answer, q.Flips, q.Unanimous)
	}
	near(t, "flip rate", q.FlipRate, 0)
	for p, s := range q.PositionShare {
		near(t, "position share", s, 1.0/3)
		_ = p
	}
	near(t, "max deviation", q.MaxPositionDeviation, 0)
	near(t, "summary flip", res.Summary.FlipRate, 0)
}

// A pure position-bias model: the first LISTED option always gets 0.7. Hand count over the three
// rotations: its own answer is the content x, y, z in turn; the order-averaged probabilities are all
// 1/3, so whichever option is the averaged answer, 2 of the 3 calls preferred a different one:
// flip rate 2/3. The answer sits at listing position 0 in 3 of 3 calls: share [1,0,0], deviation 1-1/3.
func TestProbeOrderPositionBiasedModelFlipsAndConcentratesOnPositionZero(t *testing.T) {
	var hits atomic.Int32
	c := probeGateway(t, &hits, func(_ string, listed []string) []float64 {
		out := make([]float64, len(listed))
		for i := range listed {
			out[i] = 0.15
		}
		out[0] = 0.7
		return out
	})
	res, err := c.ProbeOrder(t.Context(), []byte(probeReq), 3)
	if err != nil {
		t.Fatal(err)
	}
	q := res.Questions[0]
	if q.Flips != 2 || q.Unanimous {
		t.Errorf("flips %d unanimous %v", q.Flips, q.Unanimous)
	}
	near(t, "flip rate", q.FlipRate, 2.0/3)
	want := []float64{1, 0, 0}
	for i, s := range q.PositionShare {
		near(t, "position share", s, want[i])
	}
	near(t, "expected", q.PositionExpected, 1.0/3)
	near(t, "max deviation", q.MaxPositionDeviation, 2.0/3)
	near(t, "summary max deviation", res.Summary.MaxPositionDeviation, 2.0/3)
	if res.Summary.Trials != 3 || res.Summary.Flips != 2 {
		t.Errorf("summary = %+v", res.Summary)
	}
}

func TestProbeOrderPartialCycleIsMarkedAndBiasNotClaimedCancelled(t *testing.T) {
	var hits atomic.Int32
	c := probeGateway(t, &hits, func(_ string, l []string) []float64 { return []float64{0.5, 0.3, 0.2}[:len(l)] })
	res, err := c.ProbeOrder(t.Context(), []byte(probeReq), 2)
	if err != nil {
		t.Fatal(err)
	}
	q := res.Questions[0]
	if q.Orders != 2 || !q.PartialCycle || hits.Load() != 2 {
		t.Errorf("orders %d partial %v hits %d", q.Orders, q.PartialCycle, hits.Load())
	}
}

const mixedReq = `{"state":"s","questions":{"a":{"type":"choice","instructions":"p","criteria":{"x":"1","y":"2"}},"b":{"type":"choice","instructions":"p","criteria":{"p":"1","q":"2","r":"3"}},"n":{"type":"noul","instructions":"yes?"},"s":{"type":"score","instructions":"how","criteria":["lo","hi"]}}}`

func TestProbeOrderMixedQuestionsEachUsesWholeCyclesAndOthersAreNotPermutable(t *testing.T) {
	var hits atomic.Int32
	c := probeGateway(t, &hits, func(_ string, l []string) []float64 {
		out := make([]float64, len(l))
		for i := range out {
			out[i] = 1 / float64(len(l))
		}
		out[len(out)-1] += 0.0
		return out
	})
	res, err := c.ProbeOrder(t.Context(), []byte(mixedReq), 0)
	if err != nil {
		t.Fatal(err)
	}
	if hits.Load() != 3 {
		t.Fatalf("hits %d: the largest option count (3) sets the number of calls", hits.Load())
	}
	by := map[string]QuestionProbe{}
	for _, q := range res.Questions {
		by[q.Name] = q
	}
	if q := by["a"]; q.Orders != 2 || q.PartialCycle { // 3 calls -> one whole cycle of 2 options
		t.Errorf("a = %+v", q)
	}
	if q := by["b"]; q.Orders != 3 {
		t.Errorf("b = %+v", q)
	}
	for _, name := range []string{"n", "s"} {
		q := by[name]
		if q.Permutable || q.Reason == "" || q.Orders != 0 {
			t.Errorf("%s must be reported as not permutable with a reason: %+v", name, q)
		}
	}
	if len(res.Questions) != 4 || res.Questions[0].Name != "a" {
		t.Errorf("questions must keep the request order: %+v", res.Questions)
	}
}

func TestProbeOrderWithNothingPermutableMakesNoCall(t *testing.T) {
	var hits atomic.Int32
	c := probeGateway(t, &hits, func(_ string, l []string) []float64 { return make([]float64, len(l)) })
	res, err := c.ProbeOrder(t.Context(), []byte(`{"state":"s","questions":{"n":{"type":"noul","instructions":"yes?"}}}`), 0)
	if err != nil {
		t.Fatal(err)
	}
	if hits.Load() != 0 || res.Calls != 0 || res.Questions[0].Permutable {
		t.Errorf("hits %d res %+v", hits.Load(), res)
	}
}

func TestProbeOrderRejectsBadK(t *testing.T) {
	var hits atomic.Int32
	c := probeGateway(t, &hits, func(_ string, l []string) []float64 { return make([]float64, len(l)) })
	for _, k := range []int{1, -1, MaxPermute + 1} {
		_, err := c.ProbeOrder(t.Context(), []byte(probeReq), k)
		if err == nil || kindOf(err) != KindUsage {
			t.Errorf("k=%d: err %v kind %v, want a usage error", k, err, kindOf(err))
		}
	}
	if hits.Load() != 0 {
		t.Error("an invalid K must not reach the network")
	}
}

func TestProbeOrderBackendFailureAbortsWithItsKind(t *testing.T) {
	srv := newTLSServer(t, jsonHandler(500, `{"message":"boom","error_type":"internal_error"}`, nil))
	c, _ := newTestClient(t, srv, nil)
	_, err := c.ProbeOrder(t.Context(), []byte(probeReq), 0)
	if err == nil || kindOf(err) != KindBackend {
		t.Errorf("err %v kind %v, want backend", err, kindOf(err))
	}
}

func TestProbeOrderMalformedAnswerIsABackendError(t *testing.T) {
	srv := newTLSServer(t, jsonHandler(200, `{"model":"m","answers":{"d":{"type":"choice","choice":"x","probabilities":{"x":1}}},"usage":{"input_tokens":1,"output_tokens":1}}`, nil))
	c, _ := newTestClient(t, srv, nil)
	_, err := c.ProbeOrder(t.Context(), []byte(probeReq), 0)
	if err == nil || kindOf(err) != KindBackend {
		t.Errorf("err %v kind %v", err, kindOf(err))
	}
}
