# Tasks: claude_toolkit Residual Test-Isolation Fixes

**Input**: Design documents from `/specs/007-claude-toolkit-test-fixes/`
**Prerequisites**: plan.md, research.md

**Implementation location**: all file paths below are in the sibling
repository `/home/milosvasic/Projects/claude_toolkit`, per this spec's own
documented cross-repo scope.

**Tests are the deliverable itself** for this feature — every task below
follows the "prove the gap, then close it, then prove the closure" shape.

## Phase 1: Setup

- [ ] T001 In `/home/milosvasic/Projects/claude_toolkit`, run the full existing test suite (`bash scripts/tests/run-all.sh` or the project's established entry point) once, clean, and record the baseline pass count to `/home/milosvasic/Projects/llmctl/docs/qa/007-claude-toolkit-test-fixes/baseline_full_suite.txt` (expected: 71/74, per this feature's own Input description of the current known state).

## Phase 2: Foundational

*(No foundational/blocking work shared across both user stories — each is independently addressable. This phase is intentionally empty; proceed directly to Phase 3.)*

## Phase 3: User Story 1 - CA-cert isolation genuinely proven, not accidental (Priority: P1) 🎯 MVP

**Goal**: `test_ccr_upstream_ca.sh` and `test_kimi_alias_file.sh`'s "WITHOUT CA" scenarios pass regardless of ambient host contamination.

**Independent Test**: Deliberately export `CMA_PROVIDER_CA_CERT=/tmp/some-unrelated.pem` in the invoking shell before running these two test files; they must still pass.

- [ ] T002 [US1] Reproduce the gap with a deliberate, captured repro (per Constitution §11.4.199 exact-reproduction-sequence — use the SAME invocation the affected tests already use, just with contamination added): `export CMA_PROVIDER_CA_CERT=/tmp/fake-ambient.pem NODE_EXTRA_CA_CERTS=/tmp/fake-ambient.pem SSL_CERT_FILE=/tmp/fake-ambient.pem; touch /tmp/fake-ambient.pem; bash scripts/tests/test_ccr_upstream_ca.sh; bash scripts/tests/test_kimi_alias_file.sh`. Capture the FAILING output (the currently-broken "WITHOUT CA" assertions) to `/home/milosvasic/Projects/llmctl/docs/qa/007-claude-toolkit-test-fixes/red_repro_ca_leak.txt` — this is the RED.

- [ ] T003 [US1] In `scripts/tests/test_ccr_upstream_ca.sh`, add an explicit `unset CMA_PROVIDER_CA_CERT NODE_EXTRA_CA_CERTS SSL_CERT_FILE` immediately before the "WITHOUT CA" scenario's setup block (the block that writes `$pdir/*.env` fixtures WITHOUT a `CMA_PROVIDER_CA_CERT=` line, around the negative-control section per research.md R1/R3) — the "WITH CA" scenarios (which explicitly write `CMA_PROVIDER_CA_CERT=` into their own `.env` fixtures) are untouched.

- [ ] T004 [US1] Apply the identical `unset CMA_PROVIDER_CA_CERT NODE_EXTRA_CA_CERTS SSL_CERT_FILE` fix to `scripts/tests/test_kimi_alias_file.sh`'s own negative-control block (around line 233's "no CA pin" scenario, per research.md R1).

- [ ] T005 [US1] Re-run T002's EXACT contaminated-environment repro command against the now-fixed test files. Both MUST now pass. Capture the passing output to `/home/milosvasic/Projects/llmctl/docs/qa/007-claude-toolkit-test-fixes/green_ca_leak_fixed.txt` — this is the GREEN, under the SAME conditions that produced the RED (Constitution §11.4.7 demotion-evidence: same conditions, not a different, easier run).

- [ ] T006 [US1] Confirm the "clean" (no ambient contamination) case is unaffected: run both files again in a shell with no `CMA_PROVIDER_CA_CERT`/`NODE_EXTRA_CA_CERTS`/`SSL_CERT_FILE` set at all — both MUST still pass exactly as before this feature (FR-002, the "WITH CA" and pre-existing clean-case behavior is unchanged).

**Checkpoint**: User Story 1 independently complete and proven under BOTH conditions (contaminated and clean), per SC-001.

## Phase 4: User Story 2 - the intermittently-failing assertion is root-caused and made deterministic (Priority: P2)

**Goal**: `test_providers.sh`'s "non-quiet refresh logs 'refreshed'" assertion passes on every run, for a known, documented reason.

**Independent Test**: 10 consecutive runs of `test_providers.sh` with no code changes between them all pass.

- [ ] T007 [US2] Systematic-debugging Phase 1 (root cause investigation): run `test_providers.sh` in a tight loop (`for i in $(seq 1 20); do bash scripts/tests/test_providers.sh || echo "FAILED run $i"; done`) to establish a real, reproducible failure RATE first (not assumed from the one prior observation) — capture the loop's full output to `/home/milosvasic/Projects/llmctl/docs/qa/007-claude-toolkit-test-fixes/flake_rate_baseline.txt`.

- [ ] T008 [US2] Add temporary diagnostic instrumentation around the "non-quiet refresh logs 'refreshed'" assertion (timestamped log lines at: refresh-triggering call issued, refresh process/subshell completion detected, log file read, grep executed) per systematic-debugging's multi-component evidence-gathering technique. Re-run the T007 loop with instrumentation active until at least one FAILING run is captured with full diagnostic output — this is the evidence, not a guess, per research.md R4's three candidate mechanisms.

- [ ] T009 [US2] From T008's captured evidence, identify which of research.md R4's three candidates (write-completion race, test-ordering dependency, log-buffering artifact) is the REAL mechanism — or a fourth mechanism the evidence reveals that research.md did not anticipate (documented honestly either way, never forced to fit a pre-listed candidate that the evidence doesn't support).

- [ ] T010 [US2] Remove the temporary diagnostic instrumentation from T008 (or leave it in a `-v`/verbose-gated form only if it has permanent debugging value — a project decision, not a requirement) once T009's root cause is confirmed.

- [ ] T011 [US2] Implement the fix matching T009's confirmed root cause: if a completion race, replace any implicit timing assumption with a real condition-based wait (poll for the specific log line's presence with a bounded timeout, never a bare `sleep N`); if a test-ordering dependency, isolate the assertion's fixture setup so it no longer depends on another test's side effect; if a buffering artifact, add an explicit flush/sync point before the read.

- [ ] T012 [US2] Re-run T007's exact 20-iteration loop against the fix. It MUST show 0 failures across all 20 (exceeding SC-002's 10-consecutive-run bar for extra confidence). Capture to `/home/milosvasic/Projects/llmctl/docs/qa/007-claude-toolkit-test-fixes/flake_fixed_20x.txt`.

**Checkpoint**: User Story 2 independently complete — root cause documented with evidence, fix proven deterministic across 20 runs.

## Phase 5: Polish & Cross-Cutting

- [ ] T013 Run the full claude_toolkit test suite twice in immediate succession (per SC-004): `bash scripts/tests/run-all.sh; bash scripts/tests/run-all.sh`. Both runs MUST show 74/74 (zero failures, matching SC-003's target). Capture both run summaries to `/home/milosvasic/Projects/llmctl/docs/qa/007-claude-toolkit-test-fixes/final_74_of_74_x2.txt`.

- [ ] T014 Update `docs/CONTINUATION.md` (in `llmctl`, which already tracks this cross-repo work per this project's existing convention) noting the claude_toolkit test suite is now genuinely 74/74 with the CA-isolation and flake root causes documented and closed.

## Dependencies

- Phase 1 (Setup) blocks both user story phases (need the baseline count first).
- User Story 1 (Phase 3) and User Story 2 (Phase 4) are FULLY INDEPENDENT — different files, different mechanisms, no shared state. They MAY run in parallel.
- Phase 5 (Polish) depends on both user stories being complete (74/74 requires both fixes landed).

## Parallel Example

```
# After Phase 1, both stories run independently and in parallel:
Stream A (Phase 3, US1): T002 -> T003 -> T004 -> T005 -> T006
Stream B (Phase 4, US2): T007 -> T008 -> T009 -> T010 -> T011 -> T012
```

## Implementation Strategy

**MVP**: User Story 1 (the CA-cert isolation fix) is the smaller, more
certain fix (root cause already confirmed this session) and should land
first. User Story 2 (the flaky-assertion root-cause) is scoped separately
specifically because its root cause is NOT yet known — it must not block
User Story 1's independently-valuable, already-understood fix.
