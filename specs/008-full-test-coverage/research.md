# Phase 0 Research: Honest Full Test-Type Coverage Classification and Gap Closure

**Feature**: [spec.md](./spec.md) | **Date**: 2026-09-18

## R1: Does `llmctld` have ANY request-rate or concurrency backpressure mechanism wired into its HTTP layer today?

**Decision**: No — confirmed. This is a load-bearing finding that changes
this feature's real scope for User Story 2 (the DDoS-style test).

**Evidence gathered this phase**: `internal/tenancy/quota.go`'s
`Enforcer.AllowRequest` and `Enforcer.AcquireConcurrencySlot` are fully
implemented and unit-tested in isolation (`quota_test.go`,
`quota_bench_test.go`) — but a repo-wide search of
`internal/api/*.go` (excluding test files) for any call to
`AllowRequest`, `AcquireConcurrencySlot`, or `.Quota.` returns ZERO
matches. The quota-enforcement logic exists and is correct in isolation
but is never invoked from any HTTP request path — no gin middleware, no
per-route check, nothing. A real flood of requests against a running
`llmctld` today would be limited only by whatever Go's `net/http`/gin
runtime defaults and the OS's own connection backlog happen to provide,
not by any deliberate, tested, documented daemon-level policy.

**Consequence for this feature's scope**: FR-005 (SC-003) requires the
daemon to demonstrably "degrade or refuse excess load in a controlled,
documented way rather than crashing or becoming unresponsive to
legitimate requests" — a requirement about DAEMON BEHAVIOR, not merely
about a test file existing. A test that floods the daemon and merely
records "whatever happens today" would not satisfy FR-005 if what
happens today is uncontrolled (resource exhaustion, unresponsiveness to
legitimate concurrent requests). This feature's real, honest scope
therefore includes: (a) run the flood test FIRST against the daemon
AS-IS and capture what actually happens (this is itself the required
"observed behavior at and beyond a documented capacity limit", SC-002);
(b) IF that observation shows uncontrolled failure (crash, legitimate
requests also refused/hung, unbounded memory growth), wire the ALREADY-
EXISTING, ALREADY-TESTED `Enforcer.AllowRequest`/`AcquireConcurrencySlot`
into a small piece of new gin middleware (not new quota LOGIC — that
already exists and is already proven correct in isolation, only new
WIRING) so the daemon's behavior becomes the controlled, documented
outcome FR-005 requires; (c) IF the observation instead shows the
existing Go/gin/OS defaults already degrade acceptably (e.g., legitimate
requests continue to succeed while excess connections queue or are
refused at the OS backlog level), document that honestly as the real
mechanism and do not add unneeded middleware only to "look thorough."
Which branch applies is decided by the actual measurement, not assumed
here — per this project's own no-guessing discipline (Constitution
§11.4.6), this research phase records the DECISION PROCEDURE, not a
predicted outcome.

**Alternatives considered**: Treating the classification-document work
(User Story 1) as fully separable from the daemon-behavior discovery
above, and pushing the middleware question to some future feature: 
rejected — FR-005 is explicit that the DDoS-style test must CONFIRM
controlled degradation, and a test that cannot confirm it (because no
such control exists) would itself be a new gap this feature discovered
and then silently walked past, which is exactly the "coverage without
correctness" bluff this project's anti-bluff discipline forbids
(Constitution §11.4/§11.4.1). The classification document (User Story 1)
is still written and delivered independently per its own priority; the
middleware wiring is conditional, gated on what the flood test actually
finds, not a separate always-required task.

## R2: What tool/approach builds the new stress and DDoS-style tests without adding a new external dependency?

**Decision**: Hand-rolled Go `net/http` client code inside new
`_test.go` files (or a small `cmd/loadtest`-style internal test helper),
using goroutines for concurrency and the standard library's `net/http`
client — no new vendored load-testing tool (no `vegeta`, `hey`, `k6`,
etc.).

**Evidence gathered this phase**: every existing Go test in `llmctld`
(`quota_bench_test.go`, `jwt_bench_test.go`, `rbac_bench_test.go`,
`routes_*_test.go`) uses only the standard library `testing` package plus
`net/http/httptest` — no third-party load-testing tool is already
vendored in `go.mod`. Introducing one for this feature alone would be a
new dependency this project's own Constitution (§11.4.28 decoupling,
§11.4.75 mechanical enforcement without exception — "extend, don't
reinvent" cuts both ways: extend existing patterns before reaching for a
new tool) does not justify when the standard library is already
sufficient for both a sustained-load test (a fixed-duration loop of
goroutines issuing real HTTP requests, recording latency/success/failure
per request) and a flood test (a burst of concurrent goroutines
exceeding the sustained rate, same recording mechanism).

## R3: How is the "consolidated benchmark suite" (User Story 3) actually assembled from the three existing `*_bench_test.go` files?

**Decision**: A single new `make`/shell target (or a documented `go test
-bench` invocation covering all three existing benchmark files by
package path) that runs all three together and writes one combined,
timestamped report — not a rewrite of the three existing benchmark
functions themselves.

**Evidence gathered this phase**: `quota_bench_test.go`,
`jwt_bench_test.go`, and `rbac_bench_test.go` already exist, already
pass, and already use Go's standard `testing.B` benchmark convention —
`go test -bench=. ./...` from `llmctld/` already runs all three together
today (confirmed: Go's own tooling requires no per-file registration,
`-bench=.` matches every `BenchmarkXxx` function in the module). The gap
is purely the "one report + a documented baseline" half of User Story 3,
not the underlying benchmark code, which is already correct and requires
no changes.

## R4: What counts as a "dedicated adversarial test per mechanism" (FR-007) that isn't already covered by existing happy-path tests?

**Decision**: One new negative-path test per named mechanism, added
alongside (not replacing) the existing happy-path tests, each proving a
REJECTION rather than an acceptance:
- **mTLS**: a client presenting a certificate signed by a CA the daemon
  does NOT trust (or a certificate past a rotated-out CA's validity
  window) is refused the connection — extending the existing rotation
  test suite (`internal/mtls` package, confirmed already covers rotation
  mechanics) with the specific "old cert now invalid" adversarial case.
- **JWT**: a token with an invalid signature, an expired `exp` claim, or
  a tampered payload (same signature, mutated claims) is refused with
  401 — extending `jwt_bench_test.go`'s sibling functional tests (already
  covering valid-token issuance/verification) with these specific
  malformed-input cases.
- **RBAC**: a caller holding a role that does NOT grant the attempted
  action (e.g., a `viewer` role attempting `tenant:manage`) is refused
  with 403 — `routes_tenants_test.go` already has ONE such case
  (`TestCreateTenant_RequiresAdminRole`, confirmed present); FR-007's
  requirement is satisfied for RBAC largely already, and this feature's
  real RBAC gap (if any) is auditing whether every OTHER
  role-gated route has an equivalent negative test, not inventing a new
  mechanism.

**Evidence gathered this phase**: confirmed by direct read of
`routes_tenants_test.go` (line 52's `TestCreateTenant_RequiresAdminRole`)
and `routes_auth_test.go` (lines 146, 207, 210, 245 already cover several
authorization-denial and unauthenticated-request cases) — meaning FR-007's
RBAC and JWT halves are PARTIALLY already covered by existing tests; this
feature's classification document (User Story 1) must state this
precisely (which specific adversarial cases already exist vs. which are
newly added) rather than either claiming RBAC/JWT adversarial coverage is
totally absent (false) or fully complete without auditing every route
(unverified).
