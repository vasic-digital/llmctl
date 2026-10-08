// Package metrics renders Prometheus text exposition format 0.0.4 with BOUNDED
// label sets (FR-079), without any client library.
//
// Label values come only from allow-lists: endpoint (fixed paths), profile (the
// configured profile ids, capped at MaxProfiles), status_class (2xx..5xx) and
// question type. Anything else is recorded as "other", so a hostile client
// cannot create series, and state text, question names, request identifiers and
// key material have no route into a label at all (Observe takes no such
// parameter). Output is sorted and therefore deterministic. A Registry is safe
// for concurrent use.
//
// Design choice (same as the prototype): the openapi mentions an "outcome"
// label; it is derivable from status_class, so it is not a separate label.
package metrics

import (
	"bytes"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// ContentType is the HTTP Content-Type for Render output.
const ContentType = "text/plain; version=0.0.4; charset=utf-8"

// MaxProfiles caps the number of distinct profile label values.
const MaxProfiles = 64

// Other is the fallback label value for anything outside an allow-list.
const Other = "other"

var (
	endpoints     = []string{"/v1/systemone", "/v1/models", "/healthz", "/readyz", "/metrics"}
	statusClasses = []string{"2xx", "3xx", "4xx", "5xx"}
	questionTypes = []string{"noul", "choice", "score"}
	buckets       = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0}
)

const (
	famReq = "llmctl_decide_requests_total"
	famDur = "llmctl_decide_request_duration_seconds"
	famQst = "llmctl_decide_questions_total"
	famInv = "llmctl_decide_metric_invalid_total"
	famAud = "llmctl_decide_audit_write_failures_total"
	famKey = "llmctl_decide_key_source_errors_total"
)

// Event names a closed set of operational error counters (no labels, so no series growth).
type Event int

const (
	// AuditWriteFailure counts request-log records that could not be written (full disk, EACCES, a
	// refused symlinked path...). The request itself is never failed because of it.
	AuditWriteFailure Event = iota
	// KeySourceError counts reads of the access-key source that failed or produced no usable key
	// (an unreadable, unsafe or emptied key file): the gateway then fails closed.
	KeySourceError
	numEvents
)

// Buckets returns a copy of the fixed latency bucket upper bounds (seconds).
func Buckets() []float64 { return append([]float64(nil), buckets...) }

// BucketLabels returns the `le` label text of each bucket (without +Inf).
func BucketLabels() []string {
	out := make([]string, len(buckets))
	for i, b := range buckets {
		out[i] = fmtFloat(b)
	}
	return out
}

func fmtFloat(v float64) string { return strconv.FormatFloat(v, 'g', -1, 64) }

// StatusClass maps an HTTP status to "2xx".."5xx", or "other" outside 200..599.
func StatusClass(status int) string {
	if status >= 200 && status < 600 {
		return strconv.Itoa(status/100) + "xx"
	}
	return Other
}

func esc(v string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(v)
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

type reqKey struct{ ep, pf, sc string }
type pairKey struct{ a, b string }

type hist struct {
	counts []uint64 // len(buckets)+1; the last element is the +Inf (== total) count
	sum    float64
}

// Registry accumulates counters and a latency histogram.
type Registry struct {
	profiles []string
	mu       sync.Mutex
	req      map[reqKey]uint64
	qst      map[pairKey]uint64 // (profile, type)
	hist     map[pairKey]*hist  // (endpoint, profile)
	invalid  uint64
	events   [numEvents]uint64
}

// New returns a Registry. profiles is the allow-list of profile label values;
// empty strings, "other" and duplicates are dropped and the list is capped at
// MaxProfiles (first wins).
func New(profiles ...string) *Registry {
	var seen []string
	for _, p := range profiles {
		if p != "" && p != Other && !contains(seen, p) && len(seen) < MaxProfiles {
			seen = append(seen, p)
		}
	}
	return &Registry{profiles: seen, req: map[reqKey]uint64{}, qst: map[pairKey]uint64{}, hist: map[pairKey]*hist{}}
}

// Profiles returns a copy of the profile allow-list.
func (r *Registry) Profiles() []string { return append([]string(nil), r.profiles...) }

func (r *Registry) ep(e string) string {
	if contains(endpoints, e) {
		return e
	}
	return Other
}

func (r *Registry) pf(p string) string {
	if contains(r.profiles, p) {
		return p
	}
	return Other
}

func qt(t string) string {
	if contains(questionTypes, t) {
		return t
	}
	return Other
}

// MaxSeries is an upper bound on the number of sample lines Render can emit,
// derived from the allow-lists alone (independent of traffic).
func (r *Registry) MaxSeries() int {
	eps, pfs := len(endpoints)+1, len(r.profiles)+1
	scs, qts := len(statusClasses)+1, len(questionTypes)+1
	h := eps * pfs * (len(buckets) + 1 + 2)
	return eps*pfs*scs + h + pfs*qts + 1 + int(numEvents)
}

// Inc increments an operational error counter (unknown events are ignored).
func (r *Registry) Inc(e Event) {
	if e < 0 || e >= numEvents {
		return
	}
	r.mu.Lock()
	r.events[e]++
	r.mu.Unlock()
}

// Count reports an operational error counter.
func (r *Registry) Count(e Event) uint64 {
	if e < 0 || e >= numEvents {
		return 0
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.events[e]
}

// Observe records one served request: the request counter and, when seconds is a
// finite non-negative number, the latency histogram. A non-empty qtype also
// increments the question counter (unknown types count as "other"). Unknown
// endpoint/profile values and out-of-range statuses collapse to "other". An
// unusable duration increments llmctl_decide_metric_invalid_total instead of the
// histogram and never corrupts sum/count.
func (r *Registry) Observe(endpoint, profile string, status int, qtype string, seconds float64) {
	ep, pf, sc := r.ep(endpoint), r.pf(profile), StatusClass(status)
	valid := !math.IsNaN(seconds) && !math.IsInf(seconds, 0) && seconds >= 0
	r.mu.Lock()
	defer r.mu.Unlock()
	r.req[reqKey{ep, pf, sc}]++
	if qtype != "" {
		r.qst[pairKey{pf, qt(qtype)}]++
	}
	if !valid {
		r.invalid++
		return
	}
	k := pairKey{ep, pf}
	h := r.hist[k]
	if h == nil {
		h = &hist{counts: make([]uint64, len(buckets)+1)}
		r.hist[k] = h
	}
	for i, b := range buckets {
		if seconds <= b {
			h.counts[i]++
		}
	}
	h.counts[len(buckets)]++
	h.sum += seconds
}

// ObserveQuestion increments only the question counter.
func (r *Registry) ObserveQuestion(profile, qtype string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.qst[pairKey{r.pf(profile), qt(qtype)}]++
}

// Render returns the Prometheus text exposition (format 0.0.4): HELP and TYPE
// lines per family, samples sorted by label values, trailing newline.
func (r *Registry) Render() []byte {
	r.mu.Lock()
	req := make(map[reqKey]uint64, len(r.req))
	for k, v := range r.req {
		req[k] = v
	}
	qst := make(map[pairKey]uint64, len(r.qst))
	for k, v := range r.qst {
		qst[k] = v
	}
	hs := make(map[pairKey]hist, len(r.hist))
	for k, v := range r.hist {
		hs[k] = hist{counts: append([]uint64(nil), v.counts...), sum: v.sum}
	}
	invalid := r.invalid
	events := r.events
	r.mu.Unlock()

	var b bytes.Buffer
	fmt.Fprintf(&b, "# HELP %s Requests by endpoint, profile and status class.\n# TYPE %s counter\n", famReq, famReq)
	rk := make([]reqKey, 0, len(req))
	for k := range req {
		rk = append(rk, k)
	}
	sort.Slice(rk, func(i, j int) bool {
		a, c := rk[i], rk[j]
		if a.ep != c.ep {
			return a.ep < c.ep
		}
		if a.pf != c.pf {
			return a.pf < c.pf
		}
		return a.sc < c.sc
	})
	for _, k := range rk {
		fmt.Fprintf(&b, "%s{endpoint=\"%s\",profile=\"%s\",status_class=\"%s\"} %d\n", famReq, esc(k.ep), esc(k.pf), k.sc, req[k])
	}

	fmt.Fprintf(&b, "# HELP %s Request duration in seconds.\n# TYPE %s histogram\n", famDur, famDur)
	for _, k := range sortedPairs(hs) {
		h := hs[k]
		lbl := fmt.Sprintf("endpoint=\"%s\",profile=\"%s\"", esc(k.a), esc(k.b))
		for i, bk := range buckets {
			fmt.Fprintf(&b, "%s_bucket{%s,le=\"%s\"} %d\n", famDur, lbl, fmtFloat(bk), h.counts[i])
		}
		total := h.counts[len(buckets)]
		fmt.Fprintf(&b, "%s_bucket{%s,le=\"+Inf\"} %d\n", famDur, lbl, total)
		fmt.Fprintf(&b, "%s_sum{%s} %s\n", famDur, lbl, fmtFloat(math.Round(h.sum*1e9)/1e9))
		fmt.Fprintf(&b, "%s_count{%s} %d\n", famDur, lbl, total)
	}

	fmt.Fprintf(&b, "# HELP %s Questions answered by profile and type.\n# TYPE %s counter\n", famQst, famQst)
	for _, k := range sortedPairs(qst) {
		fmt.Fprintf(&b, "%s{profile=\"%s\",type=\"%s\"} %d\n", famQst, esc(k.a), k.b, qst[k])
	}

	fmt.Fprintf(&b, "# HELP %s Observations with an unusable duration.\n# TYPE %s counter\n%s %d\n", famInv, famInv, famInv, invalid)
	fmt.Fprintf(&b, "# HELP %s Request-log records that could not be written.\n# TYPE %s counter\n%s %d\n", famAud, famAud, famAud, events[AuditWriteFailure])
	fmt.Fprintf(&b, "# HELP %s Failed or unusable reads of the access-key source.\n# TYPE %s counter\n%s %d\n", famKey, famKey, famKey, events[KeySourceError])
	return b.Bytes()
}

func sortedPairs[V any](m map[pairKey]V) []pairKey {
	ks := make([]pairKey, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Slice(ks, func(i, j int) bool {
		if ks[i].a != ks[j].a {
			return ks[i].a < ks[j].a
		}
		return ks[i].b < ks[j].b
	})
	return ks
}
