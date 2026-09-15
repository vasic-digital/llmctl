package tenancy

import (
	"testing"
	"time"
)

// TestAllowRequest_UnlimitedWhenRequestsPerSecondIsZero proves the
// documented zero-means-unlimited convention: a tenant with no
// RequestsPerSecond configured is never rate-limited.
func TestAllowRequest_UnlimitedWhenRequestsPerSecondIsZero(t *testing.T) {
	e := NewEnforcer()
	now := time.Unix(0, 0)
	for i := 0; i < 1000; i++ {
		allowed, _ := e.AllowRequest("tenant-a", now)
		if !allowed {
			t.Fatalf("request %d denied for a tenant with no configured RequestsPerSecond limit", i)
		}
	}
}

// TestAllowRequest_ExceedingRateQuotaReturnsRetryAfter is the literal
// T070 deliverable (US9 Acceptance Scenario 3, SC-023): exceeding the
// request-rate quota returns a denial with a real, positive Retry-After
// duration, driven entirely by synthetic time.Time values (no real
// sleeping) so the test stays fast and deterministic.
func TestAllowRequest_ExceedingRateQuotaReturnsRetryAfter(t *testing.T) {
	e := NewEnforcer()
	e.SetLimits("tenant-a", Limits{RequestsPerSecond: 2})

	start := time.Unix(1_700_000_000, 0)

	allowed1, _ := e.AllowRequest("tenant-a", start)
	if !allowed1 {
		t.Fatal("first request denied under a fresh 2 req/s budget")
	}
	allowed2, _ := e.AllowRequest("tenant-a", start)
	if !allowed2 {
		t.Fatal("second request denied under a fresh 2 req/s budget (limit is 2)")
	}

	// The third request in the same instant exceeds the 2 req/s budget.
	allowed3, retryAfter := e.AllowRequest("tenant-a", start)
	if allowed3 {
		t.Fatal("third request allowed despite exceeding the 2 req/s quota")
	}
	if retryAfter <= 0 {
		t.Fatalf("Retry-After was %v, want a positive duration", retryAfter)
	}

	// Advancing synthetic time by the reported Retry-After must free up
	// budget again - proving retryAfter is the REAL wait, not a
	// placeholder value.
	later := start.Add(retryAfter)
	allowedAfterWait, _ := e.AllowRequest("tenant-a", later)
	if !allowedAfterWait {
		t.Fatalf("request denied even after waiting the reported Retry-After duration (%v)", retryAfter)
	}
}

// TestAllowRequest_IsolatedPerTenant proves one tenant exhausting its
// own rate quota never denies a different tenant's request.
func TestAllowRequest_IsolatedPerTenant(t *testing.T) {
	e := NewEnforcer()
	e.SetLimits("tenant-a", Limits{RequestsPerSecond: 1})
	now := time.Unix(1_700_000_000, 0)

	e.AllowRequest("tenant-a", now)
	if allowed, _ := e.AllowRequest("tenant-a", now); allowed {
		t.Fatal("tenant-a's second immediate request was allowed under a 1 req/s limit")
	}

	if allowed, _ := e.AllowRequest("tenant-b", now); !allowed {
		t.Fatal("tenant-b's first request was denied because tenant-a exhausted ITS OWN quota")
	}
}

// TestAcquireConcurrencySlot_DeniesBeyondLimit proves the (N+1)th
// concurrent acquisition is denied when MaxConcurrentRequests=N, and
// that it never blocks - denial is immediate.
func TestAcquireConcurrencySlot_DeniesBeyondLimit(t *testing.T) {
	e := NewEnforcer()
	e.SetLimits("tenant-a", Limits{MaxConcurrentRequests: 2})

	_, ok1 := e.AcquireConcurrencySlot("tenant-a")
	if !ok1 {
		t.Fatal("1st of 2 allowed concurrent slots was denied")
	}
	_, ok2 := e.AcquireConcurrencySlot("tenant-a")
	if !ok2 {
		t.Fatal("2nd of 2 allowed concurrent slots was denied")
	}
	_, ok3 := e.AcquireConcurrencySlot("tenant-a")
	if ok3 {
		t.Fatal("3rd concurrent slot acquired despite MaxConcurrentRequests=2")
	}
}

// TestAcquireConcurrencySlot_ReleaseFreesSlotForNextAcquisition proves
// the release() closure genuinely frees the slot for a subsequent
// caller, rather than being a no-op.
func TestAcquireConcurrencySlot_ReleaseFreesSlotForNextAcquisition(t *testing.T) {
	e := NewEnforcer()
	e.SetLimits("tenant-a", Limits{MaxConcurrentRequests: 1})

	release, ok := e.AcquireConcurrencySlot("tenant-a")
	if !ok {
		t.Fatal("1st of 1 allowed concurrent slot was denied")
	}
	if _, ok := e.AcquireConcurrencySlot("tenant-a"); ok {
		t.Fatal("2nd concurrent slot acquired despite MaxConcurrentRequests=1 and the 1st slot still held")
	}

	release()

	if _, ok := e.AcquireConcurrencySlot("tenant-a"); !ok {
		t.Fatal("slot acquisition denied after release() was called to free the held slot")
	}
}

// TestAcquireConcurrencySlot_UnlimitedWhenMaxConcurrentRequestsIsZero
// proves the documented zero-means-unlimited convention for
// concurrency, mirroring the rate-limit convention.
func TestAcquireConcurrencySlot_UnlimitedWhenMaxConcurrentRequestsIsZero(t *testing.T) {
	e := NewEnforcer()
	for i := 0; i < 100; i++ {
		if _, ok := e.AcquireConcurrencySlot("tenant-a"); !ok {
			t.Fatalf("acquisition %d denied for a tenant with no configured MaxConcurrentRequests limit", i)
		}
	}
}

// TestCheckResourceBudget_AllowsWithinBudget proves usage strictly
// within every configured ceiling is allowed.
func TestCheckResourceBudget_AllowsWithinBudget(t *testing.T) {
	e := NewEnforcer()
	e.SetLimits("tenant-a", Limits{
		MaxGPUBytes:     1 << 30,
		MaxCPUCores:     8,
		MaxRAMBytes:     1 << 30,
		MaxStorageBytes: 1 << 30,
	})

	if !e.CheckResourceBudget("tenant-a", 1<<20, 4, 1<<20, 1<<20) {
		t.Fatal("usage well within every configured ceiling was denied")
	}
}

// TestCheckResourceBudget_DeniesOverBudgetPerDimensionIndependently
// proves a request can be denied for exceeding just ONE of the 4
// resource dimensions, checked independently of the other 3.
func TestCheckResourceBudget_DeniesOverBudgetPerDimensionIndependently(t *testing.T) {
	e := NewEnforcer()
	limits := Limits{
		MaxGPUBytes:     1000,
		MaxCPUCores:     10,
		MaxRAMBytes:     1000,
		MaxStorageBytes: 1000,
	}

	cases := []struct {
		name                                    string
		gpuBytes, cpuCores, ramBytes, storBytes int64
	}{
		{"over GPU only", 1001, 5, 500, 500},
		{"over CPU only", 500, 11, 500, 500},
		{"over RAM only", 500, 5, 1001, 500},
		{"over storage only", 500, 5, 500, 1001},
	}
	for _, tc := range cases {
		e.SetLimits("tenant-a", limits)
		if e.CheckResourceBudget("tenant-a", tc.gpuBytes, tc.cpuCores, tc.ramBytes, tc.storBytes) {
			t.Fatalf("%s: usage exceeding a single dimension's ceiling was allowed", tc.name)
		}
	}

	// Sanity: exactly at every ceiling (not over) must still be allowed.
	if !e.CheckResourceBudget("tenant-a", 1000, 10, 1000, 1000) {
		t.Fatal("usage exactly at every ceiling (not exceeding) was denied")
	}
}

// TestCheckResourceBudget_UnlimitedWhenCeilingsAreZero proves the
// documented zero-means-unlimited convention applies independently to
// each of the 4 resource dimensions.
func TestCheckResourceBudget_UnlimitedWhenCeilingsAreZero(t *testing.T) {
	e := NewEnforcer()
	// No SetLimits call at all: every ceiling defaults to zero/unset.
	if !e.CheckResourceBudget("tenant-a", 1<<40, 1<<20, 1<<40, 1<<40) {
		t.Fatal("huge usage was denied for a tenant with no configured resource ceilings")
	}
}
