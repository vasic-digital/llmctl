package tenancy

import (
	"sync"
	"time"
)

// Limits describes one tenant's resource ceilings (FR-034/FR-038):
// request rate, concurrent requests, and GPU/CPU/RAM/storage. Every
// field's zero value means unlimited for that dimension - this package
// never invents a numeric default (mirrors internal/replication's
// CheckpointConfig.MaxWALSizeBytes convention: zero/unset = disabled/
// no-limit, never a silently guessed threshold).
//
// MaxGPUBytes/MaxRAMBytes/MaxStorageBytes are byte ceilings and
// MaxCPUCores counts whole or fractional cores as int64 (matching this
// package's other resource fields' units) - actually querying real
// hardware for current usage is out of scope for this task; Enforcer
// only accounts caller-supplied "current usage" values against these
// ceilings, exactly like a quota-accounting library would.
// JSON tags added for 006-cli-daemon-wiring (FR-007, data-model.md's
// wire shape for GET/PUT /v1/tenants/:id/quota) - Limits had no prior
// JSON consumer anywhere in this codebase (confirmed by inspection), so
// this is a purely additive change with no existing serialization to
// break.
type Limits struct {
	RequestsPerSecond     float64 `json:"requests_per_second"`
	MaxConcurrentRequests int     `json:"max_concurrent_requests"`
	MaxGPUBytes           int64   `json:"max_gpu_bytes"`
	MaxCPUCores           int64   `json:"max_cpu_cores"`
	MaxRAMBytes           int64   `json:"max_ram_bytes"`
	MaxStorageBytes       int64   `json:"max_storage_bytes"`
}

// rateBucket is a token-bucket rate limiter's per-tenant state. Capacity
// equals the tenant's RequestsPerSecond (a burst of up to one second's
// worth of requests may land in the same instant, then refills
// continuously at RequestsPerSecond tokens/sec) - a documented design
// choice, not a spec-mandated number (FR-034/FR-038 name the dimension,
// not a burst policy).
type rateBucket struct {
	tokens     float64
	lastUpdate time.Time
}

// concurrencyState tracks how many concurrent slots a tenant currently
// holds.
type concurrencyState struct {
	held int
}

// Enforcer is the per-tenant quota enforcement point (FR-034/FR-038):
// request rate, concurrent requests, and GPU/CPU/RAM/storage budgets.
// All state is in-memory and mutex-protected; a real persistent backing
// store is out of scope for this task per tasks.md's file list
// (internal/tenancy/quota.go only).
type Enforcer struct {
	mu sync.Mutex

	limits      map[string]Limits
	buckets     map[string]*rateBucket
	concurrency map[string]*concurrencyState
}

// NewEnforcer returns an Enforcer with no configured limits - every
// tenant is unlimited on every dimension until SetLimits is called for
// it.
func NewEnforcer() *Enforcer {
	return &Enforcer{
		limits:      make(map[string]Limits),
		buckets:     make(map[string]*rateBucket),
		concurrency: make(map[string]*concurrencyState),
	}
}

// SetLimits replaces tenantID's configured Limits.
func (e *Enforcer) SetLimits(tenantID string, limits Limits) {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.limits[tenantID] = limits
	// Reset the rate bucket so a changed RequestsPerSecond takes effect
	// immediately rather than being reconciled against a bucket sized
	// for the previous limit.
	delete(e.buckets, tenantID)
}

// GetLimits returns tenantID's currently-configured Limits and whether
// any were ever set for it (006-cli-daemon-wiring FR-007, data-model.md).
// A tenant with no prior SetLimits call reports the zero Limits{} plus
// ok=false, distinguishing "never configured" (ok=false) from
// "configured, unlimited on every dimension" (ok=true, Limits{}) - the
// SAME zero-means-unlimited convention this package's other methods
// already document, extended one level so a caller reading the value
// back (e.g. GET /v1/tenants/:id/quota) never has to guess which case it
// is looking at.
func (e *Enforcer) GetLimits(tenantID string) (Limits, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()

	limits, ok := e.limits[tenantID]
	return limits, ok
}

// AllowRequest applies tenantID's RequestsPerSecond limit via a
// token-bucket algorithm, evaluated at the caller-supplied now (never
// time.Now() internally) so tests can drive it deterministically without
// real sleeping. When the limit is exceeded, allowed is false and
// retryAfter is the real duration until the next request would be
// allowed (SC-023's "429 with Retry-After": this value is exactly what
// an HTTP layer wiring this in would put in the Retry-After header).
//
// A tenant with no configured RequestsPerSecond (zero, the default) is
// never rate-limited.
func (e *Enforcer) AllowRequest(tenantID string, now time.Time) (allowed bool, retryAfter time.Duration) {
	e.mu.Lock()
	defer e.mu.Unlock()

	rate := e.limits[tenantID].RequestsPerSecond
	if rate <= 0 {
		return true, 0
	}

	b, exists := e.buckets[tenantID]
	if !exists {
		// A fresh bucket starts full, so a tenant's first burst up to
		// its configured rate is never denied by a cold start.
		b = &rateBucket{tokens: rate, lastUpdate: now}
		e.buckets[tenantID] = b
	} else {
		elapsed := now.Sub(b.lastUpdate).Seconds()
		if elapsed > 0 {
			b.tokens += elapsed * rate
			if b.tokens > rate {
				b.tokens = rate
			}
			b.lastUpdate = now
		}
	}

	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}

	deficit := 1 - b.tokens
	retryAfter = time.Duration(deficit / rate * float64(time.Second))
	return false, retryAfter
}

// AcquireConcurrencySlot enforces tenantID's MaxConcurrentRequests. It
// never blocks: if the tenant is already at its limit, ok is false
// immediately. On success, ok is true and the caller MUST call the
// returned release() when the request finishes, freeing the slot for a
// subsequent acquisition.
//
// A tenant with no configured MaxConcurrentRequests (zero, the default)
// is never limited; release is still safe to call in that case (it is a
// no-op).
func (e *Enforcer) AcquireConcurrencySlot(tenantID string) (release func(), ok bool) {
	e.mu.Lock()
	defer e.mu.Unlock()

	max := e.limits[tenantID].MaxConcurrentRequests
	if max <= 0 {
		return func() {}, true
	}

	c, exists := e.concurrency[tenantID]
	if !exists {
		c = &concurrencyState{}
		e.concurrency[tenantID] = c
	}
	if c.held >= max {
		return nil, false
	}

	c.held++
	var once sync.Once
	release = func() {
		once.Do(func() {
			e.mu.Lock()
			defer e.mu.Unlock()
			if c.held > 0 {
				c.held--
			}
		})
	}
	return release, true
}

// CheckResourceBudget is a stateless check: does the given prospective
// usage exceed tenantID's configured ceiling for any of the 4 resource
// dimensions (GPU/CPU/RAM/storage)? It returns false if ANY dimension is
// over budget, checked independently, so a request exceeding just one
// dimension is correctly denied even if the other three are well within
// budget.
//
// A ceiling of zero (the default) means that dimension is unlimited.
func (e *Enforcer) CheckResourceBudget(tenantID string, gpuBytes, cpuCores, ramBytes, storageBytes int64) bool {
	e.mu.Lock()
	limits := e.limits[tenantID]
	e.mu.Unlock()

	if limits.MaxGPUBytes > 0 && gpuBytes > limits.MaxGPUBytes {
		return false
	}
	if limits.MaxCPUCores > 0 && cpuCores > limits.MaxCPUCores {
		return false
	}
	if limits.MaxRAMBytes > 0 && ramBytes > limits.MaxRAMBytes {
		return false
	}
	if limits.MaxStorageBytes > 0 && storageBytes > limits.MaxStorageBytes {
		return false
	}
	return true
}
