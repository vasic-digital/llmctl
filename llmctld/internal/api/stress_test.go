// Package api (stress_test.go): 008-full-test-coverage T013/T014
// (spec.md FR-004/SC-002) - a sustained-load stress test against a REAL,
// locally-listening HTTP server wrapping the real gin engine + the real
// GET /v1/cluster/status handler (routes_cluster.go), driven at
// escalating concurrency levels across successive fixed-duration windows
// until either a documented ceiling is reached or the observed success
// rate drops below a documented threshold - recording the OBSERVATION
// (per-window attempted/succeeded/failed counts plus p50/p95/p99
// latency), never asserting a fixed pass/fail against an assumed
// capacity number (research.md's "records whatever the host
// demonstrates").
//
// Honest transport-layer boundary (Constitution §11.4.6/§11.4.27): this
// test drives the request through net/http/httptest.NewServer, which
// serves the SAME real gin.Engine + the SAME real, unmodified
// RegisterClusterRoutes handler this project ships - the handler logic
// under test is 100% real and unmocked - but over a real HTTP/1.1 TCP
// listener, NOT the production HTTP/3+QUIC+mTLS transport
// server.go/NewServer wires for the cluster API's real deployment. That
// transport substitution is deliberate and documented here rather than
// silently implied: reproducing genuine mTLS+HTTP/3 for thousands of
// concurrent flood connections would exercise QUIC/TLS handshake cost
// instead of the daemon's own request-handling capacity, and this
// project's own existing test convention (routes_*_test.go) already
// treats the gin engine's real routing+middleware+handler chain as the
// object under test, independent of which transport carries it.
package api

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// requestOutcome is one HTTP round-trip's observed result.
type requestOutcome struct {
	ok      bool
	latency time.Duration
}

// windowResult is one escalating-concurrency window's aggregated
// observation.
type windowResult struct {
	concurrency int
	duration    time.Duration
	attempted   int64
	succeeded   int64
	failed      int64
	latencies   []time.Duration // successful requests only
}

func (w windowResult) successRate() float64 {
	if w.attempted == 0 {
		return 0
	}
	return float64(w.succeeded) / float64(w.attempted)
}

func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(p * float64(len(sorted)-1))
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

// runLoadWindow drives concurrency goroutines against url for duration,
// each issuing back-to-back real GET requests (via a shared *http.Client
// with a bounded per-request timeout so a single hung connection cannot
// stall the whole window past its own deadline), and returns the
// aggregated observation. now (time.Now, never faked) bounds the window.
func runLoadWindow(client *http.Client, url string, concurrency int, duration time.Duration) windowResult {
	deadline := time.Now().Add(duration)
	var attempted, succeeded, failed int64
	outcomes := make(chan requestOutcome, 4096)
	done := make(chan struct{})

	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for time.Now().Before(deadline) {
				start := time.Now()
				resp, err := client.Get(url)
				lat := time.Since(start)
				atomic.AddInt64(&attempted, 1)
				ok := err == nil && resp != nil && resp.StatusCode == http.StatusOK
				if resp != nil {
					_ = resp.Body.Close()
				}
				if ok {
					atomic.AddInt64(&succeeded, 1)
				} else {
					atomic.AddInt64(&failed, 1)
				}
				select {
				case outcomes <- requestOutcome{ok: ok, latency: lat}:
				default:
					// Observation channel is a bounded best-effort
					// latency sample; the atomic counters above remain
					// the authoritative attempted/succeeded/failed
					// totals regardless of channel backpressure.
				}
			}
		}()
	}
	go func() {
		wg.Wait()
		close(done)
	}()
	<-done
	close(outcomes)

	var lat []time.Duration
	for o := range outcomes {
		if o.ok {
			lat = append(lat, o.latency)
		}
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })

	return windowResult{
		concurrency: concurrency,
		duration:    duration,
		attempted:   atomic.LoadInt64(&attempted),
		succeeded:   atomic.LoadInt64(&succeeded),
		failed:      atomic.LoadInt64(&failed),
		latencies:   lat,
	}
}

// TestStress_SustainedLoad_CapacityObservation is spec.md SC-002: drives
// GET /v1/cluster/status (a cheap, always-available, unauthenticated
// route - routes_cluster.go's RegisterClusterRoutes) at escalating
// concurrency levels against a real, locally-bootstrapped single-node
// raft.Node (newClusterRoutesTestNode, routes_cluster_test.go) served
// over a real httptest.Server, until EITHER the documented concurrency
// ceiling is reached OR the observed success rate for a window drops
// below the documented threshold - whichever comes first - and asserts
// only that a genuine, non-empty observation was captured at every
// window, never a fixed target number (host capacity is not knowable in
// advance, Constitution §11.4.6).
func TestStress_SustainedLoad_CapacityObservation(t *testing.T) {
	if testing.Short() {
		t.Skip("stress test: skipped under -short")
	}

	engine, _ := newClusterRoutesTestNode(t)
	srv := newHTTPTestServerImpl(engine)
	defer srv.Close()

	url := srv.URL + "/v1/cluster/status"
	client := &http.Client{Timeout: 2 * time.Second}

	// Escalating concurrency levels and the per-window duration. Bounded
	// deliberately (host-safety, Constitution §12.6/§12.12): this is a
	// shared development host, not a dedicated load-test rig, so the
	// ceiling here is a documented, reproducible choice - not an assumed
	// "this host can definitely handle more" claim.
	const (
		windowDuration  = 750 * time.Millisecond
		successFloor    = 0.90 // below this, the window is the ceiling
		concurrencyStop = 800  // hard upper bound on this run
	)
	levels := []int{5, 10, 25, 50, 100, 200, 400, concurrencyStop}

	var results []windowResult
	var stoppedReason string
	for _, c := range levels {
		w := runLoadWindow(client, url, c, windowDuration)
		results = append(results, w)
		t.Logf("window concurrency=%d attempted=%d succeeded=%d failed=%d success_rate=%.4f p50=%s p95=%s p99=%s",
			w.concurrency, w.attempted, w.succeeded, w.failed, w.successRate(),
			percentile(w.latencies, 0.50), percentile(w.latencies, 0.95), percentile(w.latencies, 0.99))

		if w.attempted == 0 {
			t.Fatalf("window concurrency=%d attempted ZERO requests - the load generator itself is broken, not a capacity observation", c)
		}
		if w.successRate() < successFloor {
			stoppedReason = fmt.Sprintf("success rate %.4f fell below the %.2f floor at concurrency=%d", w.successRate(), successFloor, c)
			break
		}
	}
	if stoppedReason == "" {
		stoppedReason = fmt.Sprintf("reached the documented concurrency ceiling (%d) with every window's success rate >= %.2f", concurrencyStop, successFloor)
	}

	writeStressObservation(t, results, stoppedReason)

	// The required observation IS the per-window table above: assert it
	// was genuinely captured (non-empty, every window attempted real
	// requests) - never a pass/fail on an assumed number.
	if len(results) == 0 {
		t.Fatal("no windows were run - no capacity observation was captured")
	}
}

// writeStressObservation persists results as the durable,
// human-and-machine-readable evidence artefact T014 requires
// (docs/qa/008-full-test-coverage/stress_capacity_observation.txt) -
// this IS SC-002's "documented capacity observation", captured from a
// REAL run against this host, not invented.
func writeStressObservation(t *testing.T, results []windowResult, stoppedReason string) {
	t.Helper()
	root, err := repoRootForEvidence()
	if err != nil {
		t.Logf("writeStressObservation: could not locate repo root, evidence file not written: %v", err)
		return
	}
	dir := filepath.Join(root, "docs", "qa", "008-full-test-coverage")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Logf("writeStressObservation: mkdir %s: %v", dir, err)
		return
	}
	path := filepath.Join(dir, "stress_capacity_observation.txt")

	var b strings.Builder
	fmt.Fprintf(&b, "llmctld stress test capacity observation\n")
	fmt.Fprintf(&b, "captured: %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&b, "route: GET /v1/cluster/status (unauthenticated, real gin engine, real net/http httptest.Server, real single-node raft.Node)\n")
	fmt.Fprintf(&b, "host: %s\n\n", hostSummary())
	fmt.Fprintf(&b, "%-12s %-10s %-10s %-10s %-12s %-10s %-10s %-10s\n",
		"concurrency", "attempted", "succeeded", "failed", "success_rate", "p50", "p95", "p99")
	for _, w := range results {
		fmt.Fprintf(&b, "%-12d %-10d %-10d %-10d %-12.4f %-10s %-10s %-10s\n",
			w.concurrency, w.attempted, w.succeeded, w.failed, w.successRate(),
			percentile(w.latencies, 0.50), percentile(w.latencies, 0.95), percentile(w.latencies, 0.99))
	}
	fmt.Fprintf(&b, "\nstop condition: %s\n", stoppedReason)

	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Logf("writeStressObservation: write %s: %v", path, err)
		return
	}
	t.Logf("stress capacity observation written to %s", path)
}
