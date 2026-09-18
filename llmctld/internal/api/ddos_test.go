// Package api (ddos_test.go): 008-full-test-coverage T015/T016
// (spec.md FR-005/SC-003) - a burst-flood test issuing a large number of
// concurrent requests FAR exceeding stress_test.go's observed sustained
// capacity in one short window, while a SEPARATE, low-rate "legitimate
// traffic" goroutine runs throughout - recording whether the legitimate
// traffic's success rate/latency is preserved during the flood. Run
// FIRST against the CURRENT (as-of-Phase-2/pre-middleware) daemon per
// research.md R1's decision procedure: this observation, captured with
// NO new middleware in place, is what T017 decides on.
//
// See stress_test.go's package doc comment for this file's identical,
// honestly-documented transport-layer boundary (real gin engine + real
// unmodified route handlers, served over a real net/http/httptest.Server
// TCP listener rather than the production HTTP/3+mTLS transport).
package api

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// TestDDoS_FloodDuringLegitimateTraffic_BaselineObservation is spec.md
// SC-003's raw, pre-middleware observation: a legitimate-traffic
// goroutine issues one request every legitimateInterval for the whole
// test duration while a large flood of concurrent goroutines hammers the
// SAME route as fast as possible for a short burst window - the
// legitimate goroutine's own success rate and latency, measured
// independently of the flood goroutines' own counters, is the signal
// FR-005/SC-003 cares about ("does the daemon continue serving
// legitimate requests correctly while under an excessive-request
// flood").
//
// This test makes NO pass/fail assertion about degradation - it is
// explicitly the BASELINE OBSERVATION research.md R1 says decides
// whether T018/T019's middleware is needed at all (a test that already
// asserted "legitimate traffic must survive" here would be asserting
// the OUTCOME research.md says must be measured, not assumed). The
// conditional, assertion-bearing test lives in ddos_protected_test.go
// (T018), added or not added depending on what THIS test's captured
// evidence shows.
func TestDDoS_FloodDuringLegitimateTraffic_BaselineObservation(t *testing.T) {
	if testing.Short() {
		t.Skip("ddos baseline test: skipped under -short")
	}

	engine, _ := newClusterRoutesTestNode(t)
	srv := newHTTPTestServerImpl(engine)
	defer srv.Close()

	url := srv.URL + "/v1/cluster/status"

	const (
		// floodConcurrency is chosen to be FAR beyond
		// stress_test.go's observed sustained-capacity ceiling
		// (800 concurrent workers sustained cleanly at 100% success)
		// - this is a deliberate multiple of that ceiling, not an
		// arbitrarily huge number, so the flood is genuinely
		// "excessive" relative to this daemon's own measured
		// behavior rather than an assumed round figure.
		floodConcurrency  = 3000
		floodDuration     = 3 * time.Second
		legitimateEvery   = 50 * time.Millisecond
		legitimateTimeout = 5 * time.Second
	)

	var legitAttempted, legitSucceeded, legitFailed int64
	var legitLatencies []time.Duration
	var legitMu sync.Mutex

	legitClient := &http.Client{Timeout: legitimateTimeout}
	legitStop := make(chan struct{})
	legitDone := make(chan struct{})
	go func() {
		defer close(legitDone)
		ticker := time.NewTicker(legitimateEvery)
		defer ticker.Stop()
		for {
			select {
			case <-legitStop:
				return
			case <-ticker.C:
				start := time.Now()
				resp, err := legitClient.Get(url)
				lat := time.Since(start)
				atomic.AddInt64(&legitAttempted, 1)
				ok := err == nil && resp != nil && resp.StatusCode == http.StatusOK
				if resp != nil {
					_ = resp.Body.Close()
				}
				if ok {
					atomic.AddInt64(&legitSucceeded, 1)
					legitMu.Lock()
					legitLatencies = append(legitLatencies, lat)
					legitMu.Unlock()
				} else {
					atomic.AddInt64(&legitFailed, 1)
				}
			}
		}
	}()

	// Let the legitimate goroutine establish a healthy pre-flood
	// baseline before the flood starts.
	time.Sleep(200 * time.Millisecond)

	floodClient := &http.Client{Timeout: legitimateTimeout}
	floodResult := runLoadWindow(floodClient, url, floodConcurrency, floodDuration)

	// Give the legitimate goroutine a little more time to record
	// post-flood requests before stopping it.
	time.Sleep(300 * time.Millisecond)
	close(legitStop)
	<-legitDone

	legitMu.Lock()
	sortedLegit := append([]time.Duration(nil), legitLatencies...)
	legitMu.Unlock()
	// sort ascending for percentile()
	for i := 1; i < len(sortedLegit); i++ {
		for j := i; j > 0 && sortedLegit[j-1] > sortedLegit[j]; j-- {
			sortedLegit[j-1], sortedLegit[j] = sortedLegit[j], sortedLegit[j-1]
		}
	}

	la := atomic.LoadInt64(&legitAttempted)
	ls := atomic.LoadInt64(&legitSucceeded)
	lf := atomic.LoadInt64(&legitFailed)
	legitSuccessRate := 0.0
	if la > 0 {
		legitSuccessRate = float64(ls) / float64(la)
	}

	t.Logf("flood: concurrency=%d attempted=%d succeeded=%d failed=%d success_rate=%.4f",
		floodResult.concurrency, floodResult.attempted, floodResult.succeeded, floodResult.failed, floodResult.successRate())
	t.Logf("legitimate traffic during+around flood: attempted=%d succeeded=%d failed=%d success_rate=%.4f p50=%s p95=%s p99=%s",
		la, ls, lf, legitSuccessRate,
		percentile(sortedLegit, 0.50), percentile(sortedLegit, 0.95), percentile(sortedLegit, 0.99))

	writeDDoSBaselineObservation(t, floodResult, la, ls, lf, legitSuccessRate, sortedLegit)

	// This baseline test's only hard assertion: the observation itself
	// was genuinely captured (both goroutines actually ran real
	// requests) - the DEGRADATION/NO-DEGRADATION verdict is recorded as
	// evidence for T017's decision, never asserted as pass/fail here.
	if floodResult.attempted == 0 {
		t.Fatal("flood goroutines attempted ZERO requests - the load generator is broken, not a DDoS observation")
	}
	if la == 0 {
		t.Fatal("the legitimate-traffic goroutine attempted ZERO requests - the observation captured nothing about legitimate-traffic survival")
	}
}

// writeDDoSBaselineObservation persists the raw, pre-middleware
// observation T016 requires
// (docs/qa/008-full-test-coverage/ddos_baseline_observation.txt) -
// research.md R1's decision procedure (T017) is decided from this real,
// captured file, not from eyeballing the test log.
func writeDDoSBaselineObservation(t *testing.T, flood windowResult, legitAttempted, legitSucceeded, legitFailed int64, legitSuccessRate float64, legitLatencies []time.Duration) {
	t.Helper()
	root, err := repoRootForEvidence()
	if err != nil {
		t.Logf("writeDDoSBaselineObservation: could not locate repo root, evidence file not written: %v", err)
		return
	}
	dir := filepath.Join(root, "docs", "qa", "008-full-test-coverage")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Logf("writeDDoSBaselineObservation: mkdir %s: %v", dir, err)
		return
	}
	path := filepath.Join(dir, "ddos_baseline_observation.txt")

	var b strings.Builder
	fmt.Fprintf(&b, "llmctld DDoS-style flood baseline observation (NO middleware in place - research.md R1 decision input)\n")
	fmt.Fprintf(&b, "captured: %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&b, "route: GET /v1/cluster/status (unauthenticated, real gin engine, real net/http httptest.Server, real single-node raft.Node)\n")
	fmt.Fprintf(&b, "host: %s\n\n", hostSummary())

	fmt.Fprintf(&b, "flood window: concurrency=%d duration=%s attempted=%d succeeded=%d failed=%d success_rate=%.4f\n\n",
		flood.concurrency, flood.duration, flood.attempted, flood.succeeded, flood.failed, flood.successRate())

	fmt.Fprintf(&b, "legitimate traffic (one request per ~50ms, running before/during/after the flood):\n")
	fmt.Fprintf(&b, "  attempted=%d succeeded=%d failed=%d success_rate=%.4f\n", legitAttempted, legitSucceeded, legitFailed, legitSuccessRate)
	fmt.Fprintf(&b, "  p50=%s p95=%s p99=%s\n\n", percentile(legitLatencies, 0.50), percentile(legitLatencies, 0.95), percentile(legitLatencies, 0.99))

	fmt.Fprintf(&b, "R1 decision-input verdict: ")
	if legitAttempted == 0 {
		fmt.Fprintf(&b, "INCONCLUSIVE - legitimate-traffic goroutine captured zero attempts.\n")
	} else if legitSuccessRate >= 0.95 && legitFailed == 0 {
		fmt.Fprintf(&b, "legitimate traffic remained fully healthy (success_rate=%.4f, zero failures) under a %dx-flood burst - the existing Go/gin/OS-level defaults already provide acceptable degradation for this route; per research.md R1's decision procedure, no additional quota middleware is required for THIS route/observation.\n", legitSuccessRate, flood.concurrency/800)
	} else {
		fmt.Fprintf(&b, "legitimate traffic was degraded (success_rate=%.4f, failed=%d) under the flood - per research.md R1's decision procedure, this indicates the existing Go/gin/OS-level defaults are NOT sufficient and wiring the already-implemented, already-tested tenancy.Enforcer into new gin middleware is warranted.\n", legitSuccessRate, legitFailed)
	}

	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Logf("writeDDoSBaselineObservation: write %s: %v", path, err)
		return
	}
	t.Logf("ddos baseline observation written to %s", path)
}
