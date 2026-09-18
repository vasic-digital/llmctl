# Tasks: Honest Full Test-Type Coverage Classification and Gap Closure

**Input**: Design documents from `/specs/008-full-test-coverage/`
**Prerequisites**: plan.md, research.md

**Tests are explicitly requested** — this feature's entire premise is anti-bluff, evidence-cited coverage.

## Phase 1: Setup

- [ ] T001 Create `docs/testing/` directory (if absent) as the home for this feature's two deliverable documents (`TEST_TYPE_CLASSIFICATION.md`, `BENCHMARK_BASELINE.md`), and `docs/qa/008-full-test-coverage/` as this feature's evidence directory.

## Phase 2: Foundational

- [ ] T002 Enumerate, per component (llmctl, llmctld, claude_toolkit), every currently-existing test file and what it exercises — a raw inventory pass (`find tests/ llmctld -name '*_test.go' -o -name 'test_*.sh'` plus the sibling claude_toolkit's `scripts/tests/`), written to a working-notes file `docs/qa/008-full-test-coverage/raw_inventory.txt`. This inventory is the evidence base every classification-document row in Phase 3 cites from — no row may cite a file not in this inventory.

## Phase 3: User Story 1 - Honest 14-class classification document (Priority: P1) 🎯 MVP

**Goal**: One checked-in document scoring all 14 classes x 3 components as COVERED/PARTIAL/GENUINELY-INAPPLICABLE with cited evidence.

**Independent Test**: A reviewer can verify at least 3 COVERED rows' cited evidence genuinely exists and genuinely tests what it claims.

- [ ] T003 [US1] Write `docs/testing/TEST_TYPE_CLASSIFICATION.md`'s skeleton: a table with columns Class | llmctl | llmctld | claude_toolkit, all 14 rows present (unit, integration, e2e, full-automation, security, DDoS, scaling, chaos, stress, performance, benchmarking, UI, UX, Challenges/HelixQA) — every cell initially `TBD-Phase3`, satisfying FR-003 (no class omitted) as a structural placeholder before real classification (never left as the final state — closed out below in the same task sequence).

- [ ] T004 [US1] Classify unit/integration/e2e/full-automation for all three components from T002's inventory, citing specific file paths and, where a specific passing run was captured this session, the specific evidence (e.g., "23/23 bash tests, `tests/test_all.sh` full-suite run"). Replace the corresponding table cells.

- [ ] T005 [US1] Classify chaos for all three components, citing `tests/test_services_crashloop.sh` and the Go engine-cache suite's corrupt-slot-file fallback test by exact test function name (from T002's inventory).

- [ ] T006 [US1] Classify performance/benchmarking for llmctld, citing `quota_bench_test.go`/`jwt_bench_test.go`/`rbac_bench_test.go` by name, and explicitly marking this PARTIAL (not COVERED) pending Phase 5's consolidation work, per plan.md's own framing.

- [ ] T007 [US1] Classify security for all three components: cite the existing functional mTLS/JWT/RBAC tests AND the specific adversarial gaps research.md R4 identified (which mechanisms already have a negative-path test vs. which are new in Phase 6) — mark PARTIAL with the precise gap statement, not COVERED, until Phase 6 lands.

- [ ] T008 [US1] Classify DDoS and stress for llmctld as GENUINELY-ABSENT-TODAY (zero existing test files per the original investigation) with an explicit forward-reference to Phase 5's new tests — this row updates to COVERED once Phase 5 lands (do not mark COVERED prematurely).

- [ ] T009 [US1] Classify UI and UX for all three components as GENUINELY-INAPPLICABLE, citing the concrete, checkable reason: llmctl is a bash CLI, llmctld is a headless Go daemon with no graphical surface, claude_toolkit is a bash toolkit — none exposes a graphical interface, confirmed by direct inspection of each component's own entry points.

- [ ] T010 [US1] Classify Challenges/HelixQA-style autonomous QA for all three components as GENUINELY-INAPPLICABLE (not adopted as a dependency), per spec.md's own Assumptions section distinguishing this from PARTIAL.

- [ ] T011 [US1] Classify scaling per-component (per the spec's own Edge Cases granularity requirement): for llmctld specifically address what "scaling" means for its Raft cluster/multi-node design (cite the existing cluster tests, e.g. `TestJoinLeave`-style tests already in `internal/raft`/`internal/api`), distinct from what it would mean for the single-process bash CLI (llmctl) or toolkit (claude_toolkit), where it is GENUINELY-INAPPLICABLE (no multi-node/multi-process scaling dimension exists for either).

- [ ] T012 [US1] Final self-review pass over the completed table: confirm zero `TBD-Phase3` placeholders remain (FR-003), zero COVERED cells lack a specific citation (FR-002), and add the FR-008 re-examination-trigger statement (e.g., "UI/UX classification MUST be re-examined if a graphical interface is ever added to any component") as a closing section of the document.

**Checkpoint**: User Story 1 fully independently complete and deliverable on its own, per its own stated priority.

## Phase 4: User Story 2 - New stress and DDoS-style tests for llmctld (Priority: P2)

**Goal**: Close the two genuinely-zero-coverage classes with real, live tests against a real daemon.

**Independent Test**: The new stress test produces a documented capacity observation; the new DDoS test demonstrates controlled degradation or documents the specific real decline behavior.

- [ ] T013 [US2] Write `llmctld/internal/api/stress_test.go`: a sustained-load test issuing real HTTP requests (e.g. against `GET /v1/cluster/status`, a cheap, always-available route) at a fixed, escalating rate across successive windows against a real, locally-started `llmctld` test server, recording per-window success rate and p50/p95/p99 latency, until either a fixed ceiling attempt count is reached or the success rate drops below a threshold — whichever comes first, and asserting the OBSERVATION was captured (not a fixed pass/fail on an assumed number, per research.md's "records whatever the host demonstrates").

- [ ] T014 [US2] Run T013 against the real daemon. Capture the full per-window latency/success-rate table to `docs/qa/008-full-test-coverage/stress_capacity_observation.txt` — this IS SC-002's required "documented capacity observation."

- [ ] T015 [US2] Write `llmctld/internal/api/ddos_test.go`: a burst-flood test issuing a large number of concurrent requests FAR exceeding T014's observed sustained capacity, in one short window, while a SEPARATE, low-rate "legitimate traffic" goroutine continues issuing its own requests throughout — recording whether the legitimate traffic's success rate/latency is preserved during the flood.

- [ ] T016 [US2] Run T015 against the CURRENT (as-of-Phase-2) daemon, with NO new middleware yet. Capture the raw observation (legitimate-traffic success rate during flood, daemon process health/memory after) to `docs/qa/008-full-test-coverage/ddos_baseline_observation.txt` — per research.md R1's decision procedure, this determines whether T017-T019 (the conditional middleware) are needed.

- [ ] T017 [US2] DECISION POINT (per research.md R1): if T016 shows legitimate traffic remained healthy (acceptable success rate, no daemon crash/hang) under flood, DOCUMENT this as the real, sufficient mechanism (Go/gin/OS-level defaults) in `docs/testing/TEST_TYPE_CLASSIFICATION.md`'s DDoS row and SKIP T018-T019 (explicitly noted as skipped-with-reason, never silently omitted). If T016 shows uncontrolled failure (legitimate traffic starved, daemon crash, unbounded resource growth), proceed to T018.

- [ ] T018 [US2] (conditional on T017) Write the failing test first: extend `ddos_test.go` to assert legitimate-traffic requests during a flood receive either a normal response OR a `429` with `Retry-After` (never a timeout/connection-reset/daemon-crash). Run it against the current daemon — MUST fail (confirming T016's finding mechanically, not just by eyeballing the log).

- [ ] T019 [US2] (conditional on T017) Implement `llmctld/internal/api/middleware_quota.go`: a gin middleware calling the ALREADY-EXISTING, ALREADY-TESTED `decider.Quota.AllowRequest`/`AcquireConcurrencySlot` per request (using a fallback "default"/unauthenticated-bucket key for requests with no resolved tenant, so global flood protection applies even pre-auth), returning `429` with the `Retry-After` value `AllowRequest` already computes on refusal. Wire it into the gin engine's middleware chain in the daemon's server-construction code. Re-run T018's test — MUST now pass.

**Checkpoint**: User Story 2 independently complete — the two zero-coverage classes are closed with real, live evidence either way (middleware added, or documented sufficiency of existing defaults).

## Phase 5: User Story 3 - Consolidated benchmark suite with documented baseline (Priority: P3)

**Goal**: One report, one documented baseline, from the three already-existing, already-passing benchmark files.

**Independent Test**: Running the consolidated suite twice in a row produces results within a documented acceptable variance.

- [ ] T020 [US3] Add a `bench-all` target (Makefile, or a documented `go test -bench=. -benchmem ./...` invocation from `llmctld/`) that runs `quota_bench_test.go`, `jwt_bench_test.go`, and `rbac_bench_test.go` together and redirects combined output to a timestamped file.

- [ ] T021 [US3] Run the `bench-all` target twice in immediate succession. Capture both raw outputs to `docs/qa/008-full-test-coverage/bench_run_1.txt` and `docs/qa/008-full-test-coverage/bench_run_2.txt`.

- [ ] T022 [US3] Write `docs/testing/BENCHMARK_BASELINE.md`: the current numbers from T021 (per-benchmark ns/op, allocations), a documented acceptable variance (e.g., ±15%, stated as a project decision since Go benchmark noise on a shared host is real and this project's own §11.4.6 no-guessing discipline requires the tolerance be STATED, not silently assumed), and instructions for re-running and comparing against this baseline in the future.

- [ ] T023 [US3] Confirm T021's two runs fall within T022's documented variance of each other — if not, investigate (per systematic-debugging) whether the variance is host-load noise (re-run under quieter conditions) or a genuine measurement-methodology defect, and adjust T022's documented tolerance only with real evidence, never widened arbitrarily to make a bad run "pass."

**Checkpoint**: User Story 3 independently complete.

## Phase 6: Adversarial Security Tests (FR-007, cross-cutting closure feeding back into Phase 3's document)

- [ ] T024 [P] In `llmctld/internal/auth/`, write `jwt_adversarial_test.go`: three new negative-path tests — an invalid-signature token is rejected 401, an expired-`exp` token is rejected 401, a tampered-claims-same-signature token is rejected 401 (or, if signature verification alone already structurally prevents this third case, document that it is provably unreachable rather than writing a test that can never fail, per this project's own anti-bluff discipline about proving unreachability rather than asserting it).

- [ ] T025 [P] In `llmctld/internal/mtls/rotation_test.go` (or a new adjacent file in the same package), write an adversarial test: a client certificate signed by a CA that has been rotated OUT is refused the connection after rotation completes — extending the existing rotation-mechanics tests with this specific "old cert now invalid" case.

- [ ] T026 Audit every OTHER RBAC-gated route (beyond the already-existing `TestCreateTenant_RequiresAdminRole`) for an equivalent negative-path test per research.md R4; for any route found missing one, add it following the exact pattern of the existing test.

- [ ] T027 Update `docs/testing/TEST_TYPE_CLASSIFICATION.md`'s security row (from T007) from PARTIAL to its now-accurate final state, citing T024-T026's new tests by name alongside the pre-existing ones.

## Phase 7: Polish & Cross-Cutting

- [ ] T028 Run the full pre-existing test suites for all three components (`bash tests/test_all.sh`; `cd llmctld && go test ./... -race`; the claude_toolkit suite) to confirm zero regressions from every new test/middleware added in this feature. Capture to `docs/qa/008-full-test-coverage/full_suite_regression.txt`.

- [ ] T029 Link `docs/testing/TEST_TYPE_CLASSIFICATION.md` and `docs/testing/BENCHMARK_BASELINE.md` from the main project README (per this project's own doc-entrypoint convention already established for other docs).

## Dependencies

- Phase 1 (Setup) blocks Phase 2 (Foundational).
- Phase 2 (the raw inventory, T002) blocks Phase 3 (every classification row cites it).
- Phase 3 (User Story 1) does NOT depend on Phases 4-6 landing — it is fully deliverable on its own per its P1 priority, with rows explicitly marked PARTIAL/forward-referenced where later phases will close them (T006, T007, T008).
- Phase 4 (User Story 2) and Phase 5 (User Story 3) are independent of each other and MAY run in parallel once Phase 2 completes.
- Phase 6 (adversarial security) is independent of Phases 4-5 and MAY run in parallel with them.
- Phase 6's T027 depends on T024-T026 completing, and feeds back into updating Phase 3's document (T007's PARTIAL row).
- Phase 7 depends on all prior phases.

## Parallel Example

```
# After Phase 2, three independent streams:
Stream A (Phase 4, US2): T013 -> T014 -> T015 -> T016 -> T017 -> [T018 -> T019]
Stream B (Phase 5, US3): T020 -> T021 -> T022 -> T023
Stream C (Phase 6):      T024 [P], T025 [P] in parallel -> T026 -> T027
# Phase 3 (US1) can start immediately after Phase 2 and update its
# forward-referenced rows as Streams A/C complete.
```

## Implementation Strategy

**MVP**: Phase 1 + Phase 2 + Phase 3 (User Story 1, the classification
document) delivers the entire honest-inventory value on its own, even if
every gap-closure phase were deferred — matching this project's own
anti-bluff discipline that a claim of coverage must exist and be honest
BEFORE the work that earns it necessarily lands. Phases 4-6 then close
the real gaps the document itself identifies.
