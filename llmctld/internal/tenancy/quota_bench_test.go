package tenancy

import (
	"sort"
	"testing"
	"time"
)

func BenchmarkAllowRequest(b *testing.B) {
	e := NewEnforcer()
	e.SetLimits("tenant-a", Limits{RequestsPerSecond: 1e9}) // effectively unbounded so the benchmark measures overhead, not intentional throttling
	now := time.Now()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		e.AllowRequest("tenant-a", now)
	}
}

// TestAllowRequest_P99LatencyUnderCeiling proves SC-021's literal "quota
// enforcement < 1ms overhead" requirement: 1000 real AllowRequest calls
// against an effectively-unbounded rate limit (so the call always takes
// the real allow path, not the deny/Retry-After path), sorted, p99
// asserted under 1ms - the same explicit-p99 methodology as
// internal/auth's jwt_bench_test.go/rbac_bench_test.go.
func TestAllowRequest_P99LatencyUnderCeiling(t *testing.T) {
	e := NewEnforcer()
	e.SetLimits("tenant-a", Limits{RequestsPerSecond: 1e9})
	now := time.Now()

	const samples = 1000
	durations := make([]time.Duration, samples)
	for i := 0; i < samples; i++ {
		start := time.Now()
		e.AllowRequest("tenant-a", now)
		durations[i] = time.Since(start)
	}
	sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
	p99 := durations[int(float64(samples)*0.99)-1]

	const ceiling = time.Millisecond
	if p99 > ceiling {
		t.Fatalf("AllowRequest p99 latency %s exceeds SC-021's %s ceiling", p99, ceiling)
	}
	t.Logf("AllowRequest p99 latency over %d samples: %s (ceiling %s)", samples, p99, ceiling)
}
