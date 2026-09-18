# llmctld Benchmark Baseline

**Revision:** 1
**Last modified:** 2026-09-18T08:42:29Z
**Status:** active
**Feature:** [008-full-test-coverage](../../specs/008-full-test-coverage/spec.md) User Story 3 (FR-006, SC-004)

## Purpose

This document is the consolidated, documented performance baseline for
`llmctld`'s three existing benchmark suites:

- `internal/tenancy/quota_bench_test.go` — `BenchmarkAllowRequest`
- `internal/auth/jwt_bench_test.go` — `BenchmarkValidateToken`
- `internal/auth/rbac_bench_test.go` — `BenchmarkCheck`

These three benchmark functions already existed, already passed, and
already used Go's standard `testing.B` convention before this feature
(research.md R3) — nothing about their own logic changed. What this
feature adds is the **consolidation** (one runnable entry point, one
combined report) and this **documented baseline** (a real, captured
set of numbers plus a stated acceptable variance), so a future change's
performance impact can be compared against a known number instead of
being re-measured from scratch every time.

## How to run it

From the repository root:

```bash
make bench-all
```

This runs `go test -bench=. -benchmem -run='^$' ./...` from `llmctld/`
(Go's own tooling requires no per-file registration — `-bench=.`
matches every `BenchmarkXxx` function in the module) and writes the
combined, timestamped raw output to `docs/testing/bench_runs/bench_<UTC
timestamp>.txt`.

## Baseline numbers (captured 2026-09-18, this host)

**Host:** `GOOS=linux GOARCH=amd64`, CPU: AMD Ryzen 7 2700X Eight-Core
Processor, `GOMAXPROCS=16`. These numbers are **host-dependent** — a
different host (different CPU, different load, different GPU-enablement
state per the spec's own Assumptions section) will produce different
absolute numbers. This baseline documents what THIS host demonstrated,
not a universal target.

Two consecutive runs (raw output: `docs/qa/008-full-test-coverage/bench_run_1.txt`
and `docs/qa/008-full-test-coverage/bench_run_2.txt`):

| Benchmark | Run 1 | Run 2 | Observed variance |
|---|---|---|---|
| `BenchmarkValidateToken-16` (internal/auth) | 10492 ns/op, 2976 B/op, 54 allocs/op | 9973 ns/op, 2976 B/op, 54 allocs/op | ns/op: 4.95% |
| `BenchmarkCheck-16` (internal/auth, RBAC) | 26.62 ns/op, 0 B/op, 0 allocs/op | 25.94 ns/op, 0 B/op, 0 allocs/op | ns/op: 2.55% |
| `BenchmarkAllowRequest-16` (internal/tenancy) | 43.63 ns/op, 0 B/op, 0 allocs/op | 45.53 ns/op, 0 B/op, 0 allocs/op | ns/op: 4.17% |

Allocation counts (`B/op`, `allocs/op`) are **deterministic** across
both runs for all three benchmarks — only the timing (`ns/op`) varies,
which is expected Go-benchmark noise on a shared host (CPU frequency
scaling, scheduler jitter, background processes), not a measurement-
methodology defect.

## Documented acceptable variance

**±15% on `ns/op`**, run-to-run, on the same host under normal
conditions. This is a **project decision**, not a derived constant —
Go benchmark noise on a shared, non-isolated host is real, and this
project's own no-guessing discipline (Constitution §11.4.6) requires
this tolerance be stated explicitly rather than silently assumed. The
two captured runs above are well within this tolerance (max observed:
4.95%), confirmed per T023.

`B/op` and `allocs/op` are expected to be **exactly** reproducible
(these three benchmarks perform no host-load-dependent allocation
patterns) — any change in allocation count for the same code is a
signal worth investigating on its own, not covered by the ±15% timing
tolerance.

## Re-running and comparing against this baseline

1. Run `make bench-all` from the repository root.
2. Open the newly-written `docs/testing/bench_runs/bench_<timestamp>.txt`.
3. For each of the three benchmarks above, compute
   `abs(new_ns_op - baseline_ns_op) / baseline_ns_op`.
4. A result within ±15% is a **pass** (no regression detected within
   this host's normal noise floor).
5. A result outside ±15%:
   - First, re-run `make bench-all` again under quieter host conditions
     (no other heavy build/process running) to rule out host-load noise
     (per this project's own systematic-debugging discipline — confirm
     before concluding).
   - If it reproduces under quiet conditions, treat it as a genuine
     performance regression (or improvement) and investigate the
     underlying code change, per Constitution §11.4.102.
   - Never widen this document's ±15% tolerance to make a bad run
     "pass" without that investigation and without real evidence
     justifying the wider figure (Constitution §11.4.6/§11.4.201).
6. A change in `B/op` or `allocs/op` for any of these three benchmarks
   is investigated regardless of the timing result — these are not
   expected to vary run-to-run on unchanged code.

## Honest scope

This baseline covers exactly the three benchmark functions that existed
before this feature. It is not a claim of comprehensive performance
coverage across the whole daemon — see
[`TEST_TYPE_CLASSIFICATION.md`](TEST_TYPE_CLASSIFICATION.md)'s
performance/benchmarking row for the full, honest classification
(including what is and is not benchmarked today).
