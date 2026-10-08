package metrics_test

import (
	"math"
	"math/rand"
	"regexp"
	"strings"
	"sync"
	"testing"

	"github.com/vasic-digital/llmctl/internal/metrics"
)

func newReg() *metrics.Registry { return metrics.New("decide-tiny", "decide-big") }

func sampleLines(text string) []string {
	var out []string
	for _, l := range strings.Split(text, "\n") {
		if l != "" && !strings.HasPrefix(l, "#") {
			out = append(out, l)
		}
	}
	return out
}

func TestRequestCounterAndLabels(t *testing.T) {
	r := newReg()
	r.Observe("/v1/systemone", "decide-tiny", 200, "", 0.02)
	r.Observe("/v1/systemone", "decide-tiny", 200, "", 0.03)
	r.Observe("/v1/systemone", "decide-tiny", 422, "", 0.001)
	s := string(r.Render())
	for _, w := range []string{
		`llmctl_decide_requests_total{endpoint="/v1/systemone",profile="decide-tiny",status_class="2xx"} 2`,
		`llmctl_decide_requests_total{endpoint="/v1/systemone",profile="decide-tiny",status_class="4xx"} 1`,
	} {
		if !strings.Contains(s, w) {
			t.Fatalf("missing %s in\n%s", w, s)
		}
	}
}

func TestUnknownValuesBecomeOther(t *testing.T) {
	r := newReg()
	r.Observe("/v1/secret-path?key=abc", "attacker-profile\n", 999, "weird type", 0.1)
	s := string(r.Render())
	for _, w := range []string{`endpoint="other"`, `profile="other"`, `status_class="other"`, `type="other"`} {
		if !strings.Contains(s, w) {
			t.Fatalf("missing %s", w)
		}
	}
	for _, bad := range []string{"attacker", "secret-path", "weird"} {
		if strings.Contains(s, bad) {
			t.Fatalf("leaked %s", bad)
		}
	}
}

func TestEmptyProfileIsOther(t *testing.T) {
	r := newReg()
	r.Observe("/healthz", "", 200, "", 0)
	if !strings.Contains(string(r.Render()), `profile="other"`) {
		t.Fatal("blank profile not other")
	}
}

func TestStatusClass(t *testing.T) {
	cases := map[int]string{200: "2xx", 204: "2xx", 302: "3xx", 401: "4xx", 429: "4xx", 502: "5xx", 529: "5xx", 599: "5xx",
		0: "other", 100: "other", 199: "other", 600: "other", 700: "other", -5: "other"}
	for st, want := range cases {
		if got := metrics.StatusClass(st); got != want {
			t.Errorf("%d: got %s want %s", st, got, want)
		}
	}
}

func TestQuestionCounterAllowList(t *testing.T) {
	r := newReg()
	r.Observe("/v1/systemone", "decide-tiny", 200, "choice", 0.1)
	r.ObserveQuestion("decide-tiny", "weird type")
	s := string(r.Render())
	if !strings.Contains(s, `llmctl_decide_questions_total{profile="decide-tiny",type="choice"} 1`) {
		t.Fatal(s)
	}
	if !strings.Contains(s, `type="other"`) || strings.Contains(s, "weird") {
		t.Fatal(s)
	}
	// empty qtype on Observe records no question
	r2 := newReg()
	r2.Observe("/healthz", "decide-tiny", 200, "", 0.1)
	if strings.Contains(string(r2.Render()), "llmctl_decide_questions_total{") {
		t.Fatal("empty qtype counted")
	}
}

func bucketVal(t *testing.T, text, le string) int {
	t.Helper()
	re := regexp.MustCompile(regexp.QuoteMeta(`llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="`+le+`"} `) + `(\d+)`)
	m := re.FindStringSubmatch(text)
	if m == nil {
		t.Fatalf("no bucket %s", le)
	}
	n := 0
	for _, c := range m[1] {
		n = n*10 + int(c-'0')
	}
	return n
}

func TestHistogramCumulativeSumCount(t *testing.T) {
	r := newReg()
	for _, s := range []float64{0.004, 0.2, 0.2, 7.0, 100.0} {
		r.Observe("/v1/systemone", "decide-tiny", 200, "", s)
	}
	s := string(r.Render())
	if bucketVal(t, s, "0.005") != 1 || bucketVal(t, s, "0.25") != 3 || bucketVal(t, s, "10") != 4 || bucketVal(t, s, "+Inf") != 5 {
		t.Fatal(s)
	}
	prev := -1
	for _, le := range append(metrics.BucketLabels(), "+Inf") {
		v := bucketVal(t, s, le)
		if v < prev {
			t.Fatalf("not cumulative at %s", le)
		}
		prev = v
	}
	if !strings.Contains(s, `llmctl_decide_request_duration_seconds_count{endpoint="/v1/systemone",profile="decide-tiny"} 5`) {
		t.Fatal(s)
	}
	if !strings.Contains(s, `_seconds_sum{endpoint="/v1/systemone",profile="decide-tiny"} 107.404`) {
		t.Fatal(s)
	}
}

func TestBucketsFixed(t *testing.T) {
	b := metrics.Buckets()
	if len(b) < 8 {
		t.Fatal("too few buckets")
	}
	for i := 1; i < len(b); i++ {
		if b[i] <= b[i-1] {
			t.Fatal("unsorted")
		}
	}
	b[0] = 999 // returned slice is a copy
	if metrics.Buckets()[0] == 999 {
		t.Fatal("Buckets leaks internal slice")
	}
}

func TestBadDurationsDoNotCorrupt(t *testing.T) {
	r := newReg()
	r.Observe("/healthz", "decide-tiny", 200, "", math.NaN())
	r.Observe("/healthz", "decide-tiny", 200, "", -3)
	r.Observe("/healthz", "decide-tiny", 200, "", math.Inf(1))
	s := string(r.Render())
	if !strings.Contains(s, `llmctl_decide_requests_total{endpoint="/healthz",profile="decide-tiny",status_class="2xx"} 3`) {
		t.Fatal(s)
	}
	if !strings.Contains(s, "llmctl_decide_metric_invalid_total 3\n") {
		t.Fatal(s)
	}
	low := strings.ToLower(strings.ReplaceAll(s, "llmctl", ""))
	if strings.Contains(low, "nan") || strings.Contains(strings.ReplaceAll(s, "+Inf", ""), "Inf") {
		t.Fatalf("non-finite leaked:\n%s", s)
	}
	if strings.Contains(s, "request_duration_seconds_bucket{") {
		t.Fatal("invalid durations produced a histogram")
	}
}

func TestHelpTypeAndTrailingNewline(t *testing.T) {
	s := string(newReg().Render())
	for fam, typ := range map[string]string{"llmctl_decide_requests_total": "counter", "llmctl_decide_request_duration_seconds": "histogram",
		"llmctl_decide_questions_total": "counter", "llmctl_decide_metric_invalid_total": "counter"} {
		if !strings.Contains(s, "# HELP "+fam+" ") || !strings.Contains(s, "# TYPE "+fam+" "+typ+"\n") {
			t.Fatalf("family %s", fam)
		}
		if strings.Index(s, "# HELP "+fam) > strings.Index(s, "# TYPE "+fam) {
			t.Fatalf("HELP after TYPE for %s", fam)
		}
	}
	if !strings.HasSuffix(s, "\n") {
		t.Fatal("no trailing newline")
	}
	if metrics.ContentType != "text/plain; version=0.0.4; charset=utf-8" {
		t.Fatal(metrics.ContentType)
	}
}

func TestEverySampleLineWellFormed(t *testing.T) {
	r := newReg()
	r.Observe("/v1/models", "decide-big", 200, "noul", 0.1)
	r.Observe("/v1/systemone", "decide-tiny", 503, "score", 2.5)
	pat := regexp.MustCompile(`^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[a-zA-Z_][a-zA-Z0-9_]*="[^"\\\n]*"(,[a-zA-Z_][a-zA-Z0-9_]*="[^"\\\n]*")*\})? [0-9.e+-]+$`)
	for _, l := range sampleLines(string(r.Render())) {
		if !pat.MatchString(l) {
			t.Fatalf("malformed: %q", l)
		}
	}
}

func TestDeterministicOrder(t *testing.T) {
	a, b := newReg(), newReg()
	for _, ep := range []string{"/healthz", "/v1/models", "/metrics"} {
		a.Observe(ep, "decide-tiny", 200, "choice", 0.1)
	}
	for _, ep := range []string{"/metrics", "/v1/models", "/healthz"} {
		b.Observe(ep, "decide-tiny", 200, "choice", 0.1)
	}
	if string(a.Render()) != string(b.Render()) {
		t.Fatal("render depends on insertion order")
	}
	if string(a.Render()) != string(a.Render()) {
		t.Fatal("unstable")
	}
}

func TestLabelValueEscaping(t *testing.T) {
	r := metrics.New("we\"ird\\p\nx")
	r.Observe("/healthz", "we\"ird\\p\nx", 200, "", 0)
	s := string(r.Render())
	if !strings.Contains(s, `profile="we\"ird\\p\nx"`) {
		t.Fatal(s)
	}
	if strings.Count(s, "\n") != len(strings.Split(strings.TrimSuffix(s, "\n"), "\n")) {
		t.Fatal("raw newline inside label")
	}
}

const golden = `# HELP llmctl_decide_requests_total Requests by endpoint, profile and status class.
# TYPE llmctl_decide_requests_total counter
llmctl_decide_requests_total{endpoint="/healthz",profile="other",status_class="2xx"} 2
llmctl_decide_requests_total{endpoint="/v1/systemone",profile="decide-tiny",status_class="2xx"} 2
llmctl_decide_requests_total{endpoint="/v1/systemone",profile="decide-tiny",status_class="4xx"} 1
# HELP llmctl_decide_request_duration_seconds Request duration in seconds.
# TYPE llmctl_decide_request_duration_seconds histogram
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="0.005"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="0.01"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="0.025"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="0.05"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="0.1"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="0.25"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="0.5"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="1"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="2.5"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="5"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="10"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="30"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/healthz",profile="other",le="+Inf"} 1
llmctl_decide_request_duration_seconds_sum{endpoint="/healthz",profile="other"} 0.001
llmctl_decide_request_duration_seconds_count{endpoint="/healthz",profile="other"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="0.005"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="0.01"} 1
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="0.025"} 2
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="0.05"} 3
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="0.1"} 3
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="0.25"} 3
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="0.5"} 3
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="1"} 3
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="2.5"} 3
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="5"} 3
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="10"} 3
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="30"} 3
llmctl_decide_request_duration_seconds_bucket{endpoint="/v1/systemone",profile="decide-tiny",le="+Inf"} 3
llmctl_decide_request_duration_seconds_sum{endpoint="/v1/systemone",profile="decide-tiny"} 0.051
llmctl_decide_request_duration_seconds_count{endpoint="/v1/systemone",profile="decide-tiny"} 3
# HELP llmctl_decide_questions_total Questions answered by profile and type.
# TYPE llmctl_decide_questions_total counter
llmctl_decide_questions_total{profile="decide-tiny",type="choice"} 2
llmctl_decide_questions_total{profile="decide-tiny",type="other"} 1
# HELP llmctl_decide_metric_invalid_total Observations with an unusable duration.
# TYPE llmctl_decide_metric_invalid_total counter
llmctl_decide_metric_invalid_total 1
# HELP llmctl_decide_audit_write_failures_total Request-log records that could not be written.
# TYPE llmctl_decide_audit_write_failures_total counter
llmctl_decide_audit_write_failures_total 0
# HELP llmctl_decide_key_source_errors_total Failed or unusable reads of the access-key source.
# TYPE llmctl_decide_key_source_errors_total counter
llmctl_decide_key_source_errors_total 0
`

func TestGoldenExposition(t *testing.T) {
	r := newReg()
	r.Observe("/v1/systemone", "decide-tiny", 200, "choice", 0.02)
	r.Observe("/v1/systemone", "decide-tiny", 200, "choice", 0.03)
	r.Observe("/v1/systemone", "decide-tiny", 422, "zzz", 0.001)
	r.Observe("/healthz", "", 200, "", 0.001)
	r.Observe("/healthz", "", 200, "", math.NaN())
	if got := string(r.Render()); got != golden {
		t.Fatalf("golden mismatch\n--- got ---\n%s\n--- want ---\n%s", got, golden)
	}
}

func TestEmptyRegistryRendersFamilies(t *testing.T) {
	s := string(metrics.New().Render())
	if !strings.Contains(s, "# TYPE llmctl_decide_metric_invalid_total counter\nllmctl_decide_metric_invalid_total 0\n") {
		t.Fatal(s)
	}
}

func TestSeriesBoundedUnderHostileLabels(t *testing.T) {
	r := newReg()
	rnd := rand.New(rand.NewSource(7))
	junk := func() string {
		n := rnd.Intn(30) + 1
		b := make([]byte, n)
		for i := range b {
			b[i] = byte(rnd.Intn(256))
		}
		return string(b)
	}
	for i := 0; i < 5000; i++ {
		r.Observe(junk(), junk(), rnd.Intn(1006)-5, junk(), rnd.Float64())
		r.ObserveQuestion(junk(), junk())
	}
	n := len(sampleLines(string(r.Render())))
	if n > r.MaxSeries() {
		t.Fatalf("series %d > bound %d", n, r.MaxSeries())
	}
	if r.MaxSeries() >= 2000 {
		t.Fatalf("bound too loose: %d", r.MaxSeries())
	}
}

func TestProfilesCappedAndDeduped(t *testing.T) {
	ps := make([]string, 1000)
	for i := range ps {
		ps[i] = "p" + string(rune('a'+i%26)) + strings.Repeat("x", i/26)
	}
	ps = append(ps, "", "other", "pa", "pa")
	r := metrics.New(ps...)
	if got := len(r.Profiles()); got != metrics.MaxProfiles {
		t.Fatalf("profiles %d", got)
	}
	r2 := metrics.New("a", "a", "", "other", "b")
	if got := r2.Profiles(); len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("%v", got)
	}
}

func TestExactTotalsUnderContention(t *testing.T) {
	r := newReg()
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 500; i++ {
				r.Observe("/v1/systemone", "decide-tiny", 200, "noul", 0.01)
			}
		}()
	}
	for i := 0; i < 20; i++ {
		_ = r.Render() // concurrent renders must not race
	}
	wg.Wait()
	s := string(r.Render())
	for _, w := range []string{`status_class="2xx"} 4000`, `type="noul"} 4000`, `_duration_seconds_count{endpoint="/v1/systemone",profile="decide-tiny"} 4000`} {
		if !strings.Contains(s, w) {
			t.Fatalf("missing %s", w)
		}
	}
}

// A-13/A-14: operational error counters are rendered, bounded (no labels) and ignore unknown events.
func TestEventCountersRenderAndAreBounded(t *testing.T) {
	r := metrics.New("decide-tiny")
	before := r.MaxSeries()
	r.Inc(metrics.AuditWriteFailure)
	r.Inc(metrics.AuditWriteFailure)
	r.Inc(metrics.KeySourceError)
	r.Inc(metrics.Event(99))
	r.Inc(metrics.Event(-1))
	if r.Count(metrics.AuditWriteFailure) != 2 || r.Count(metrics.KeySourceError) != 1 || r.Count(metrics.Event(99)) != 0 {
		t.Fatalf("counts: %d %d", r.Count(metrics.AuditWriteFailure), r.Count(metrics.KeySourceError))
	}
	out := string(r.Render())
	for _, want := range []string{"llmctl_decide_audit_write_failures_total 2\n", "llmctl_decide_key_source_errors_total 1\n"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if r.MaxSeries() != before {
		t.Error("events must not change the series bound")
	}
}
