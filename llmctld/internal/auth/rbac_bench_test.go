package auth

import (
	"sort"
	"testing"
	"time"
)

func BenchmarkCheck(b *testing.B) {
	roles := []string{RoleModelOperator}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		Check(roles, ActionModelDelete)
	}
}

// TestCheck_P99LatencyUnderCeiling proves SC-021's <5ms AuthN/AuthZ
// decision ceiling for the RBAC-check decision path, the same
// 1000-sample explicit-p99 methodology as jwt_bench_test.go's
// TestValidateToken_P99LatencyUnderCeiling.
func TestCheck_P99LatencyUnderCeiling(t *testing.T) {
	roles := []string{RoleModelOperator}

	const samples = 1000
	durations := make([]time.Duration, samples)
	for i := 0; i < samples; i++ {
		start := time.Now()
		Check(roles, ActionModelDelete)
		durations[i] = time.Since(start)
	}
	sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
	p99 := durations[int(float64(samples)*0.99)-1]

	const ceiling = 5 * time.Millisecond
	if p99 > ceiling {
		t.Fatalf("Check p99 latency %s exceeds SC-021's %s ceiling", p99, ceiling)
	}
	t.Logf("Check p99 latency over %d samples: %s (ceiling %s)", samples, p99, ceiling)
}
