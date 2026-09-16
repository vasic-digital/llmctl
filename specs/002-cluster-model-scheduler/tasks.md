---
description: "Task list for Cluster-Wide Model-Placement Scheduling"
---

# Tasks: Cluster-Wide Model-Placement Scheduling

**Input**: Design documents from `specs/002-cluster-model-scheduler/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md (all present)

## Task Format

```
[ID] [markers] [Story] Description
```

**Markers**: `[P]` parallel-safe · `[TDD]` strict RED-GREEN-REFACTOR (RED
confirmed via a real `go vet`/`go test` failure before implementation,
matching every existing task in `specs/001-llmctl-completion/tasks.md`'s
Phase 9-11) · `[REVIEW]` human/independent-review gate before proceeding ·
`[SUBAGENT]` candidate for parallel subagent dispatch.

## Path Conventions

All paths are relative to `llmctld/` unless stated otherwise (this feature
touches only the existing `llmctld` Go module and `docs/`).

---

## Phase 1: Setup

**Purpose**: No new project scaffolding is needed — this feature extends an
existing Go module with existing dependencies (plan.md's Technical Context:
zero new third-party dependencies). Setup is limited to the new
integration-test skeleton and confirming the baseline is green before any
change lands.

- [ ] T001 Confirm baseline: `go vet ./...`, `gofmt -l .`, `go test ./...`
      all clean on `main` before this feature's first commit (captures the
      "zero regressions" starting point every subsequent task's own
      "zero regressions" claim is measured against).
- [ ] T002 [P] Create the empty test file
      `test/integration/cluster_placement_test.go` with the package
      declaration and a `testCluster` harness reuse import from
      `cluster_bootstrap_test.go` (no test functions yet — those land per
      user-story phase below).

**Execution notes**: No special discipline required.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Make `cluster.ClusterState.Nodes` genuinely populated by a real
running cluster, keep it fresh, and make placement-then-reservation
atomic. Confirmed via source-reading (research.md Decision 3) that NONE of
this exists today — `Join`/`Leave` never reach the FSM. Every user story
below is meaningless without this phase, since `Place()` would have no
real candidates to choose from.

**CRITICAL**: No user-story work can begin until this phase's Checkpoint
passes.

### Node registry: make Join/Leave genuinely reach the FSM

- [x] T003 [TDD] Extend `internal/raft/fsm.go`'s `Command` struct: no new
      fields needed for `CommandJoinNode`/`CommandLeaveNode` (they already
      carry `Node`/`NodeID` per the existing schema) — write
      `TestApply_JoinNode_PopulatesClusterStateNodes` and
      `TestApply_LeaveNode_RemovesFromClusterStateNodes` in
      `internal/raft/fsm_test.go` asserting `fsm.State().Nodes` reflects
      the command, confirming RED is impossible here (these commands
      already exist and already pass) — this task is a **verification
      task**, not new code: it exists to prove the FSM layer itself is
      already correct so the next tasks can safely assume `Apply` is not
      the bug, only the fact that nothing ever calls it with real data is.
- [x] T004 [TDD] Modify `internal/raft/node.go`'s `Join(peerID, peerAddr
      string) error` signature to `Join(peerID, peerAddr string, resources
      cluster.Resources) error`: after the existing `n.raft.AddVoter(...)`
      succeeds, additionally call
      `n.raft.Apply(marshal(Command{Type: CommandJoinNode, Node:
      &cluster.Node{ID: peerID, Addr: peerAddr, Health: "healthy",
      Resources: resources}}), applyTimeout)` and return its `.Error()`.
      RED first: write `TestJoin_PopulatesRealClusterStateNodesEntry` in
      `internal/raft/node_test.go` asserting that AFTER a real `Join` call
      on a real bootstrapped node, `node.State().Nodes[peerID]` is
      genuinely present with the exact `resources` passed in — confirm
      this FAILS against the current (pre-change) `Join` (since it never
      calls `Apply`) before implementing.
- [x] T005 [TDD] Modify `internal/raft/node.go`'s `Leave() error`: after the
      existing `n.raft.RemoveServer(...)` succeeds, additionally call
      `n.raft.Apply(marshal(Command{Type: CommandLeaveNode, NodeID:
      n.localID}), applyTimeout)`. RED first:
      `TestLeave_RemovesRealClusterStateNodesEntry` in `node_test.go`,
      confirmed failing against current `Leave` before implementing.
- [x] T006 Update every existing call site of `Join`/`Leave` for the new
      signature: `internal/api/routes_cluster.go`'s `POST
      /v1/cluster/join` handler, `internal/api/client.go`'s
      `RequestJoin`/`joinRequest` (add a required `Resources
      cluster.Resources` field per contracts/cluster-model-api.md's
      extended request body), and `cmd/llmctld/main.go`'s `cluster join`
      subcommand (source the real value from the SAME hardware-probe JSON
      `bin/llmctl` already produces — the exact invocation mechanism,
      e.g. shelling out to `bin/llmctl hardware probe --json` or an
      equivalent already-existing subcommand, MUST be confirmed by reading
      `lib/hardware.sh`'s real current CLI surface before wiring it, never
      assumed). Every pre-existing test at each of these call sites
      (T051/T054/T058's real multi-process tests) MUST still pass
      unmodified in behavior — only the new required field is added.

### Resource freshness: keep `Resources` current, not just join-time-stale

- [x] T007 [TDD] Add `CommandUpdateResources` to `internal/raft/fsm.go`'s
      `CommandType` const block and `Command` struct (`NodeID string`,
      `Resources cluster.Resources`); `Apply` case replaces
      `f.state.Nodes[cmd.NodeID].Resources` in place (no-op, returning an
      explicit error, if `cmd.NodeID` is not a currently-known node — a
      resource update for a node that isn't a member is a real error
      condition, never silently accepted). RED first:
      `TestApply_UpdateResources_RefreshesExistingNode` and
      `TestApply_UpdateResources_UnknownNodeRefused` in `fsm_test.go`,
      confirmed failing (`undefined: CommandUpdateResources`) via `go vet`
      before implementation. Extend
      `TestApply_DeterministicGivenSameLogSequence` to include this new
      command type in its replay sequence.
- [x] T008 [TDD] [P] Extend `internal/cluster/health.go`'s `Monitor`: on
      each existing 10s tick (the SAME ticker `Start()` already runs — no
      second ticker introduced), each node submits its own current
      hardware-probe-derived `cluster.Resources` via
      `CommandUpdateResources` to the current leader (reusing whatever
      "am I the leader, and if not who is" resolution `IsLeader()`/T058's
      routes already provide — a follower forwards to the leader via the
      existing HTTP/3+mTLS channel rather than calling `Apply` locally,
      since only the leader's `Apply` is authoritative). RED first:
      `TestMonitor_PeriodicTick_SubmitsResourceUpdate` in `health_test.go`
      (inject a fake resource-source + fake submit function, matching the
      existing `StatusChecker`/`Rescheduler` function-type-injection
      pattern already used in this file), confirmed failing before
      implementation.

### Placement reservation: close the TOCTOU race (FR-005, SC-004)

- [x] T009 [TDD] Add `RunningProfile` to `internal/cluster/state.go`
      (`Profile, TenantID, NodeID string`, `StartedAt time.Time`,
      `Footprint PlacementRequest`) and `ClusterState.RunningProfiles
      []RunningProfile`; extend `NewClusterState`/`Clone` for the new
      field (matching the existing `Nodes`/`Locks` clone pattern exactly).
      RED first: a `state_test.go` test asserting `Clone()` deep-copies
      `RunningProfiles` (mutating the clone must not affect the original),
      confirmed failing before implementation.
- [x] T010 [TDD] Add `CommandRecordRunningProfile` and
      `CommandClearRunningProfile` to `internal/raft/fsm.go`. Per
      data-model.md's Concurrency-safety note:
      `CommandRecordRunningProfile`'s `Apply` computes the target node's
      CURRENTLY-uncommitted capacity as `Node.Resources` minus the sum of
      every existing `RunningProfile.Footprint` already recorded against
      that `NodeID` (computed fresh inside `Apply`, never trusted from the
      proposer), and refuses with a distinct, matchable error (mirroring
      `errLockHeldByAnother`) if the new `Footprint` no longer fits — this
      is the exact mechanism that makes FR-005/SC-004's "never double-book
      a node" guarantee real rather than aspirational.
      `CommandClearRunningProfile` removes the matching entry
      (`Profile`+`TenantID`+`NodeID`), an idempotent no-op if already
      absent (matching `CommandReleaseLock`'s own already-established
      idempotent-release pattern). RED first, in `fsm_test.go`:
      `TestApply_RecordRunningProfile_RefusedWhenNoLongerFits` (the
      load-bearing race-closing test — construct a node at exactly its
      remaining capacity, record one profile that fully consumes it, then
      attempt to record a second profile requesting any additional
      capacity on the SAME node and assert refusal),
      `TestApply_RecordRunningProfile_MultipleDistinctNodesSucceed`,
      `TestApply_ClearRunningProfile_IdempotentOnAbsent`, all confirmed
      failing before implementation. Extend the determinism replay test
      (T007) to also cover these two commands.
- [x] T011 [REVIEW] Review T003-T010 together before any HTTP-layer code
      depends on them: confirm the reservation-refusal path is genuinely
      unreachable-to-bypass from `routes_models.go` (i.e., there is no code
      path that calls `LocalExecutor.Start` without a prior successful
      `CommandRecordRunningProfile` Apply) — this is exactly the class of
      "looks wired but isn't" defect T054/the real `Join`/`Leave` gap this
      whole feature exists to close, so the review's specific job is
      confirming THIS layer does not repeat it.

**Checkpoint**: `internal/raft`/`internal/cluster` unit tests (excluding
anything in `test/integration/`) all pass; a real multi-process manual
check (matching T051's own "manually validated by hand first" discipline)
confirms `GET /v1/cluster/nodes`-adjacent state genuinely shows populated,
fresh `Resources` after a real 2-process bootstrap+join. **Get human
approval before starting User Story 1.**

---

## Phase 3: User Story 1 — Start a model without knowing which node has room (Priority: P1) MVP

**Goal**: A start request with no node named lands on a real node that
genuinely has capacity, or is refused with the exact shortfall.
**Independent Test**: quickstart.md Scenarios 1 and 2, on a real 3-node
cluster.

### Tests for User Story 1

- [x] T012 [P] [TDD] [US1] Contract test for the extended
      `POST /v1/tenants/:id/models/:model/start` (no `node` field) in
      `internal/api/routes_models_test.go`: real HTTP request, real
      single-process `LocalExecutor` under `LLMCTL_DRY_RUN=1` — asserts
      the response names a node and that node's dry-run env file exists
      (extending T072-FU4's own established real-subprocess test pattern,
      never a mock). Confirmed failing (route does not yet accept an
      absent `node` field) before implementation.
- [x] T013 [P] [TDD] [US1] Real multi-process integration test in
      `test/integration/cluster_placement_test.go`:
      `TestClusterPlacement_StartWithoutNode_LandsOnNodeWithCapacity`
      (quickstart.md Scenario 1 — 3 real bootstrapped+joined processes,
      `LLMCTL_FAKE_HW` fixtures so only one node has room, real HTTP
      request with no `node` field, assert the response names that exact
      node and that node's own real `bin/llmctl status` under dry-run
      shows the profile). Confirmed failing before implementation.
- [x] T014 [P] [TDD] [US1] Real multi-process integration test:
      `TestClusterPlacement_NoNodeHasCapacity_RefusedWithExactShortfall`
      (quickstart.md Scenario 2 — every node's fixture capacity is smaller
      than the request; assert `insufficient_capacity` with a `considered`
      entry per node showing its real shortfall numbers; assert NO node's
      real status shows the profile started).

### Implementation for User Story 1

- [x] T015 [US1] Add a `Placer` abstraction call site in
      `internal/api/routes_models.go`'s start handler: when the request
      body's `node` field is absent, call `cluster.Place(candidates,
      req)` against the CURRENT `raft.Node.State().Nodes` (converted to
      `[]cluster.Node`), where `candidates` excludes nodes already at
      capacity for THIS tenant's affinity restrictions if configured
      (spec.md FR-011). On refusal, respond `insufficient_capacity` with
      `considered` populated from `Place()`'s own refusal detail (extend
      `Place()`'s error, or capture the same candidate list it evaluated,
      whichever requires the smaller, most honest change to
      `placement.go` — prefer NOT modifying `placement.go`'s tested logic
      per plan.md's Constraints; expose the considered-set from the
      caller's own already-available `candidates` slice instead).
- [x] T016 [US1] On a successful `Place()` result, submit
      `CommandRecordRunningProfile` (T010) for the chosen node BEFORE
      dispatching the actual start. If the reservation is refused (lost
      the race per T010's concurrency guarantee), retry `Place()` once
      against a freshly-read `State()` (excluding the now-known-full
      node) before giving up with `insufficient_capacity`.
- [x] T017 [US1] Implement cross-node forwarding: add a new function to
      `internal/api/client.go` (contracts/cluster-model-api.md's
      forwarding client), structurally parallel to `RequestJoin` (same
      `http3.Transport` + mTLS pattern, same narrow-and-explicit retry
      discipline for the specific "target briefly unreachable" case per
      spec.md's Edge Cases — NOT a generic unbounded retry). When the
      chosen node is NOT the node that received the original HTTP
      request, forward the start to it via this function; on forwarding
      failure, submit `CommandClearRunningProfile` to release the
      reservation made in T016 (compensating action — a failed dispatch
      must never leave a "phantom" reservation blocking future placement)
      and either retry against a different node or fail with
      `placement_delivery_failed` (spec.md FR-010) — never silently
      report success.
- [x] T018 [US1] [SUBAGENT] Record a `PlacementDecision` audit entry
      (data-model.md) via `internal/audit/log.go`'s existing mechanism for
      every automatic placement outcome (success or refusal), including
      every considered node's capacity at decision time and a
      human-readable reason.
- [x] T019 [US1] Preserve the explicit-`node` path byte-identically:
      confirm (via the ALREADY-PASSING T072-FU4 tests, re-run unmodified)
      that a request naming a specific `node` never enters the `Place()`
      path at all.

**Execution notes**: T012-T014 can be dispatched in parallel (different
files, no shared state). T015-T018 are sequential (each depends on the
prior existing).

**Checkpoint**: User Story 1 fully functional and testable in isolation —
the MVP. **Get human approval before starting User Story 2.**

---

## Phase 4: User Story 2 — See where things are running and stop/query them without hunting node-by-node (Priority: P2)

**Goal**: Name-only status/stop resolves to the real hosting node(s); a
cluster-wide status view lists every running profile.
**Independent Test**: quickstart.md Scenario 3.

### Tests for User Story 2

- [x] T020 [P] [TDD] [US2] Real multi-process integration test:
      `TestClusterPlacement_NameOnlyStatusAndStop_ResolveToRealNode`
      (quickstart.md Scenario 3) in `cluster_placement_test.go`. Confirmed
      failing before implementation.
- [x] T021 [P] [TDD] [US2] Real multi-process integration test:
      `TestClusterPlacement_SameProfileOnMultipleNodes_StopActsOnAll` —
      covers spec.md's Edge Case (a profile name found on more than one
      node must never be silently limited to one). Confirmed failing
      before implementation.
- [x] T022 [P] [TDD] [US2] Test for the extended `GET /v1/cluster/status`
      in `internal/api/routes_cluster_test.go`: asserts the
      `running_profiles` field reflects `ClusterState.RunningProfiles`
      accurately. Confirmed failing before implementation.

### Implementation for User Story 2

- [x] T023 [US2] Extend `routes_models.go`'s status/stop handlers: when
      `node` is absent, read `ClusterState.RunningProfiles` for every
      entry matching `(Profile, TenantID)`; for status, forward a query
      to (or aggregate cached state from) every matching `NodeID` via the
      T017 forwarding function and return one entry per node; for stop,
      forward a stop to EVERY matching `NodeID` (never just the first),
      and on each real success submit `CommandClearRunningProfile` for
      that entry.
- [x] T024 [US2] Extend `routes_cluster.go`'s `GET /v1/cluster/status`
      handler to include `running_profiles` from `node.State().RunningProfiles`
      alongside the existing `is_leader`/`state` fields.
- [x] T025 [US2] [REVIEW] Authorization-parity review specifically for
      T023's name-only resolution path — confirm every forwarded
      status/stop call still passes through the SAME
      `authorizeTenantOwnership`/`CheckRBAC`/`CheckTenantBoundary` chain
      T072-FU4/FU5 established, per plan.md's Review Gates row citing the
      T072-FU5 cross-tenant finding as the exact defect class to guard
      against here.

**Checkpoint**: User Stories 1 AND 2 both work independently on a real
multi-node cluster. **Get human approval before starting User Story 3.**

---

## Phase 5: User Story 3 — Placement decisions are auditable and safe under concurrent requests (Priority: P3)

**Goal**: Prove, under real concurrency, that two placements never
double-book a node, and that every decision is reconstructable after the
fact.
**Independent Test**: quickstart.md Scenarios 4 and 5.

**Note**: The correctness mechanism itself (the `Apply`-time re-validation
in `CommandRecordRunningProfile`, T010) was already built and unit-tested
in Phase 2, deliberately — this phase's job is proving it holds under
REAL concurrent HTTP load on a REAL multi-node cluster, and proving the
audit trail (T018) is genuinely queryable, not merely that the mechanism
exists in isolation.

- [ ] T026 [TDD] [US3] Real multi-process integration test:
      `TestClusterPlacement_ConcurrentStarts_NeverDoubleBookANode`
      (quickstart.md Scenario 4 — two goroutines fire real concurrent
      HTTP start requests for two profiles that only jointly fit the
      cluster if placed on different nodes; assert both succeed on their
      correct respective nodes, using real fixtures via
      `LLMCTL_FAKE_HW`). Confirmed failing (or flaky/racy, which counts as
      failing) before T009-T010 exist, and deterministically passing
      after — run at least 10 iterations (matching Constitution
      §11.4.50's deterministic-consistency discipline for a
      concurrency-sensitive test) to rule out a lucky single pass.
- [ ] T027 [TDD] [US3] Real integration test:
      `TestClusterPlacement_DecisionIsReconstructableAfterTheFact`
      (quickstart.md Scenario 5 — after a real placement, retrieve the
      `PlacementDecision` audit record via `internal/audit/log.go`'s
      existing read path and assert every field data-model.md specifies
      is present and matches the real decision that was made).
- [ ] T028 [US3] [REVIEW] Final review of the whole feature's concurrency
      story: re-read `CommandRecordRunningProfile`'s `Apply` alongside
      `CommandAcquireLock`'s (T010's own stated mirroring) side by side,
      confirming no divergence was introduced that would reintroduce the
      TOCTOU hazard this phase exists to close.

**Checkpoint**: All three user stories independently verified. **Get human
approval before Polish.**

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, full-suite verification, and folding this
feature into the project's existing follow-up-tracking convention.

- [ ] T029 [P] Add a new section to `docs/cluster-architecture.md`
      (matching T041/T057's established real-`mmdc`-rendered-Mermaid,
      explicit ✅ IMPLEMENTED/📋 PLANNED-labeling discipline) documenting:
      the node-registry-population fix, the resource-heartbeat mechanism,
      the reservation-based placement flow (with a real sequence diagram
      for the reserve → forward → execute → confirm path, including the
      compensating-clear-on-forwarding-failure branch), and the
      cluster-wide running-profile index.
- [ ] T030 [P] Append this feature to `specs/001-llmctl-completion/tasks.md`'s
      "Follow-up Work" section as `T072-FU6` (or the next free FU number
      at execution time), matching the T072-FU1..FU5 entry format
      (evidence, file:line citations, TDD RED/GREEN confirmations, honest
      scope-boundary disclosures) — this feature's own `specs/002-*`
      directory is retained for its detailed design record, but the
      project's single canonical follow-up ledger stays in sync per this
      project's own established documentation discipline.
- [ ] T031 Update `specs/001-llmctl-completion/progress.yml` with a
      matching entry.
- [ ] T032 Full-suite verification: `go vet ./...`, `gofmt -l .`, `go test
      ./...` (every package including `test/integration/`) clean, zero
      regressions to any pre-existing test (T001's baseline is the
      comparison point).
- [ ] T033 [REVIEW] Independent code review of the complete feature
      (Constitution §11.4.125/§11.4.142) before this is considered done —
      not a substitute for the per-phase review gates above, the final
      whole-feature pass.
- [ ] T034 Update `docs/CONTINUATION.md` with this feature's completion
      state, per Constitution §12.10.

**Execution notes**: T029-T031 can run in parallel with T032 (docs vs.
test verification touch disjoint files).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories.
  This is the phase where the actual, previously-nonexistent "cluster has
  a live, fresh, race-safe node+capacity registry" capability is built;
  every user story assumes it already exists.
- **User Story 1 (Phase 3)**: Depends on Foundational. This is the MVP.
- **User Story 2 (Phase 4)**: Depends on Foundational AND on User Story
  1's forwarding function (T017) — NOT independent of US1 in this
  feature, unlike the general template's assumption that stories are
  usually independent (the forwarding client is shared infrastructure
  both stories need; US2 does not duplicate it).
- **User Story 3 (Phase 5)**: Depends on Foundational's T009-T010
  (mechanism already built there) and exercises it under real concurrency
  — can start as soon as Phase 2 is done, in parallel with Phase 3/4's
  own work if subagent capacity allows, since T026-T028 do not modify
  `routes_models.go` themselves.
- **Polish (Phase 6)**: Depends on all three user stories being complete.

### Parallel Opportunities

- T002 (setup) has no dependencies.
- Within Phase 2: T007-T008 (resource freshness) and T009-T010
  (reservation) touch different new code (health.go's ticker vs. fsm.go's
  new commands) and can be developed as two parallel subagent streams,
  though both land in `fsm.go` for their `CommandType` additions — the
  actual file-edit ordering must serialize on `fsm.go` itself even if the
  design/test-writing work happens in parallel.
- Within Phase 3: T012-T014 (tests) are parallel-safe.
- Phase 5 (US3) can proceed in parallel with Phase 3/4 once Phase 2 is
  done, per the Phase Dependencies note above.

---

## Superpowers Execution

### Execution Discipline by Marker

Identical to this project's established convention (see
`specs/001-llmctl-completion/tasks.md`'s own "Superpowers Execution"
section): `[TDD]` follows RED-GREEN-REFACTOR with a real, captured RED
confirmation before implementation; `[SUBAGENT]` dispatches to a
self-contained subagent per Constitution §11.4.20/§11.4.70; `[REVIEW]`
pauses for human/independent review before the next task proceeds; `[P]`
tasks within the same phase run in parallel.

### Checkpoint Protocol

At every phase boundary: summarize what was completed, run the applicable
real tests (never a subset that skips the new concurrency/race tests),
report results, and wait for explicit approval before continuing — no
skipped checkpoints, matching this project's established discipline for
Phase 9-11's own checkpoints in `specs/001-llmctl-completion/tasks.md`.

---

## Notes

- This feature's TDD discipline is NOT optional per this project's
  Constitution Principle III (Test-First with Anti-Bluff Gates,
  NON-NEGOTIABLE) — every `[TDD]` marker above reflects that mandate, not
  merely the template's own "tests are optional" default.
- Every new gate this feature might introduce (none is currently planned —
  see plan.md's Constitution Check row III) would require a paired §1.1
  mutation before being trusted, per this project's Constitution.
- Commit after each task or logical group, matching the T072-FU1..FU5
  session's own established per-unit commit discipline.
