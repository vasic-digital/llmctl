package auth

import (
	"sort"
	"testing"
	"time"
)

func BenchmarkValidateToken(b *testing.B) {
	token, err := IssueToken(newTestClaims(), testSigningKey)
	if err != nil {
		b.Fatalf("issue token: %v", err)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := ValidateToken(token, testSigningKey); err != nil {
			b.Fatalf("validate token: %v", err)
		}
	}
}

// TestValidateToken_P99LatencyUnderCeiling proves SC-021's literal
// requirement ("AuthN/AuthZ decisions < 5ms latency") for the JWT-validate
// decision path specifically: 1000 real ValidateToken calls, sorted, p99
// (the 990th of 1000 sorted samples) asserted under 5ms. A b.N-based
// benchmark reports a MEAN, which a single slow outlier can hide - a
// fixed N=1000 sample with an explicit p99 assertion is what actually
// proves the tail-latency ceiling this success criterion states.
func TestValidateToken_P99LatencyUnderCeiling(t *testing.T) {
	token, err := IssueToken(newTestClaims(), testSigningKey)
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}

	const samples = 1000
	durations := make([]time.Duration, samples)
	for i := 0; i < samples; i++ {
		start := time.Now()
		if _, err := ValidateToken(token, testSigningKey); err != nil {
			t.Fatalf("validate token: %v", err)
		}
		durations[i] = time.Since(start)
	}
	sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
	p99 := durations[int(float64(samples)*0.99)-1]

	const ceiling = 5 * time.Millisecond
	if p99 > ceiling {
		t.Fatalf("ValidateToken p99 latency %s exceeds SC-021's %s ceiling", p99, ceiling)
	}
	t.Logf("ValidateToken p99 latency over %d samples: %s (ceiling %s)", samples, p99, ceiling)
}
