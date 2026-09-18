# Implementation Plan: Honest Full Test-Type Coverage Classification and Gap Closure

**Branch**: `008-full-test-coverage` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/008-full-test-coverage/spec.md`

## Summary

This feature produces one checked-in classification document scoring
llmctl/llmctld/claude_toolkit against the Constitution's 14-class
test-type taxonomy, then closes the two classes with genuinely zero
existing coverage (stress, DDoS-style). Research this phase surfaced a
load-bearing finding (research.md R1): `llmctld`'s quota-enforcement logic
(`Enforcer.AllowRequest`/`AcquireConcurrencySlot`) is fully implemented
and unit-tested but is NEVER invoked from any HTTP route — meaning a real
flood test today would observe whatever Go/gin/OS defaults happen to do,
not any deliberate daemon policy. This plan therefore runs the flood test
first, against the daemon as-is, and conditionally wires the existing
quota logic into new gin middleware only if that observation shows
uncontrolled failure — never adding untested new enforcement logic, only
wiring what already exists and is already proven correct in isolation.

## Technical Context

**Language/Version**: Go (`llmctld`, standard library `net/http` +
`testing` only, no new dependency per research.md R2), Bash (the
classification document's own evidence citations are verified against
existing bash test files, no code change to them)

**Primary Dependencies**: None new (research.md R2) — reuses `gin`
(already a daemon dependency) for the conditional middleware, and the
standard library for the new load-generating test clients

**Storage**: N/A

**Testing**: Go `testing`/`testing.B` (existing convention, extended per
research.md R3 for the consolidated benchmark suite), new Go stress/flood
test files following the same convention

**Target Platform**: This host, for the live stress/DDoS/benchmark
numbers (SC-002/SC-003/SC-004 are explicitly host-dependent per the
spec's own Assumptions section)

**Project Type**: Same two-component system (bash CLI + Go daemon) plus
the sibling claude_toolkit bash toolkit — this feature classifies all
three, adds code only to the Go daemon (llmctld) and the daemon's own
`docs/scripts/`-adjacent test suite

**Performance Goals**: The stress/DDoS tests themselves define, rather
than assume, the daemon's actual capacity limit (SC-002) — no target
number is imposed ahead of measurement, per the spec's own Assumptions
section ("records whatever the real, current host actually demonstrates")

**Constraints**: The classification document (FR-001/FR-002/FR-003) must
be written and delivered even if a gap-closure task is not yet complete
(User Story 1 is independently valuable and independently testable per
the spec's own framing) — sequencing matters, honesty first; any new
middleware (if research.md R1's conditional branch fires) must be
additive and reuse the ALREADY-TESTED `Enforcer` logic verbatim, never
duplicate or reimplement quota-enforcement math

**Scale/Scope**: One classification document (14 rows x up to 3
components), two new stress/DDoS Go test files, one consolidated
benchmark-suite entry point + baseline doc, a per-mechanism adversarial
test audit (mTLS/JWT/RBAC) landing only the genuinely-missing cases per
research.md R4

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Deterministic V&V)**: SATISFIED BY DESIGN — the entire
  point of User Story 1 is replacing implicit/undocumented coverage
  claims with cited, verifiable evidence; FR-002 makes an uncited COVERED
  claim itself a defect in the document.
- **Principle III (Test-First, four-layer)**: the new stress/DDoS tests
  are themselves the "test" layer for a previously-untested daemon
  behavior — RED here means: first run the flood test against the
  CURRENT (possibly-unprotected) daemon and observe/record what genuinely
  happens (this observation IS data, not a placeholder to fill in later);
  if research.md R1's conditional middleware lands, its own paired
  behavioral test (legitimate requests still succeed while excess ones
  are refused) is the GREEN, and a meta-test mutation removing the
  middleware's gin registration MUST make that GREEN test FAIL again,
  proving the gate is real. The adversarial security tests (FR-007)
  follow the same RED-first shape: each new negative-path test is
  authored to first prove the CURRENT (unpatched, if any patch is even
  needed — most of these mechanisms are already correct per research.md
  R4) behavior, then confirms the correct rejection.
- **Principle IV (Real Environment Execution)**: SATISFIED — all new
  tests run against a real, live `llmctld` process (never a mocked HTTP
  layer) per this project's own no-mocking-above-unit-tests discipline.
- No violations requiring Complexity Tracking — the conditional
  middleware (if it lands) is the smallest possible correct wiring of
  ALREADY-EXISTING, ALREADY-TESTED logic, not new complexity.

## Project Structure

### Documentation (this feature)

```text
specs/008-full-test-coverage/
├── plan.md              # This file
├── research.md          # Phase 0 output (complete)
└── tasks.md             # Phase 2 output (/speckit-tasks)

docs/testing/
└── TEST_TYPE_CLASSIFICATION.md   # NEW: the User Story 1 deliverable itself -
                                    # the checked-in 14-class classification
                                    # document (FR-001..FR-003), per-component,
                                    # linked from the main README per this
                                    # project's own doc-entrypoint convention
```

(No `data-model.md`/`contracts/` — this feature's only "entity" is the
classification document itself, which is fully specified by its own
required structure above; no new external interface is introduced unless
research.md R1's conditional middleware lands, in which case its shape is
simply "the same request/response the route already returns, now
sometimes a 429 instead of the route's normal response" — not a new
interface needing separate contract documentation.)

### Source Code

```text
llmctld/internal/api/
└── middleware_quota.go (CONDITIONAL, only if research.md R1's flood-test
    observation requires it) - NEW: thin gin middleware calling the
    ALREADY-EXISTING decider.Quota.AllowRequest/AcquireConcurrencySlot
    per request, returning 429 with Retry-After (the value AllowRequest
    already computes) on refusal - zero new enforcement math

llmctld/internal/api/
├── stress_test.go             # NEW: sustained real-HTTP-request-rate test
│                                # against a live llmctld, records the
│                                # capacity observation (SC-002)
└── ddos_test.go                # NEW: excess-request-flood test, confirms
                                 # controlled degradation or documents the
                                 # specific real refusal behavior (SC-003)

llmctld/internal/mtls/  (or wherever the existing rotation tests live)
└── <adversarial test additions per research.md R4's mTLS case>

llmctld/internal/auth/
└── jwt_adversarial_test.go    # NEW: invalid-signature / expired / tampered-claim rejection cases

llmctld/
└── Makefile (or equivalent)   # MODIFY: add a `bench-all` target running
                                 # all three existing *_bench_test.go files
                                 # together and writing one report

docs/testing/
└── BENCHMARK_BASELINE.md       # NEW: the User Story 3 deliverable - the
                                 # documented baseline numbers + acceptable
                                 # variance, generated from a real run
```

**Structure Decision**: Same repository layout already established;
every new file lands beside the existing file whose responsibility it
extends (stress/DDoS tests beside the existing `routes_*_test.go` files
in `internal/api/`; the adversarial JWT test beside the existing
`internal/auth` package; the conditional middleware, if needed, in the
same `internal/api` package the other route middleware already lives in).

## Complexity Tracking

*No Constitution Check violations — table intentionally omitted.*
