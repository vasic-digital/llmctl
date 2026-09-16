---
description: "Task list for Cross-Node KV-Cache Replication via Real File Transfer"
---

# Tasks: Cross-Node KV-Cache Replication via Real File Transfer

**Input**: Design documents from `specs/003-kv-cache-replication/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

## Task Format

`[ID] [markers] [Story] Description` — markers identical to
`specs/002-cluster-model-scheduler/tasks.md`'s convention (`[P]`/`[TDD]`/
`[REVIEW]`/`[SUBAGENT]`).

---

## Phase 1: Setup

- [x] T001 Confirm baseline: `go vet ./...`, `gofmt -l .`, `go test ./...`
      clean before this feature's first commit (if 002 has already landed
      on `main`, this baseline includes 002's changes — read the real
      current `ClusterState`/FSM shape before designing this feature's own
      extension, never assume plan.md's description is still exactly
      current).
- [x] T002 [P] Create the empty test scaffolding for the new
      replication-forwarding assertions in
      `test/integration/failover_state_test.go` (a new test function
      alongside the existing one, not a rewrite yet).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Establish the per-tenant primary/replica role-assignment
state — nothing in User Stories 1-3 is meaningful without knowing which
node is authoritative for forwarding.

- [x] T003 [TDD] Add `ReplicationRole` (data-model.md) to
      `internal/cluster/state.go` (or wherever 002's own `ClusterState`
      extension actually landed — read it fresh first, per T001) and new
      FSM commands `CommandAssignReplicationRole`/
      `CommandReassignReplicationRole` to `internal/raft/fsm.go`, with the
      SAME atomic-replace, no-momentary-dual-primary guarantee
      `CommandJoinNode` already has for its own map. RED first in
      `fsm_test.go`: `TestApply_AssignReplicationRole_ExactlyOnePrimary`,
      `TestApply_ReassignReplicationRole_ReplacesAtomically`. Extend the
      existing determinism replay test to cover these commands.
- [x] T004 [TDD] Wire `internal/cluster/health.go`'s existing unhealthy-node
      detection to trigger `CommandReassignReplicationRole` when the
      CURRENT primary for some tenant is the node detected unhealthy —
      reusing the SAME detection signal `Monitor` already has (per
      research.md Decision 2, no second detector). If 002's own placement
      decision already chose a new host for that tenant's model instance,
      prefer that node as the new primary (research.md Decision 2's
      "natural default" — read 002's actual `Reconcile`/`Place` call
      shape fresh before wiring this, if 002 has landed). RED first:
      `TestMonitor_UnhealthyPrimary_TriggersReassignment` in
      `health_test.go`.
- [x] T005 [REVIEW] Review T003-T004 together for the exact race condition
      spec.md's Edge Cases names (reassignment in flight while forwarding
      is happening) before any forwarding code depends on this layer.

**Checkpoint**: Real multi-process check confirms a tenant's role
assignment exists after real cluster bootstrap and correctly reassigns
after a real primary kill. **Get human approval before starting User
Story 1.**

---

## Phase 3: User Story 1 — Automatic cross-node forwarding (Priority: P1) MVP

**Goal**: Every append/checkpoint on the primary reaches every replica
automatically; a killed primary's replacement already has the state.
**Independent Test**: quickstart.md Scenario 1.

### Tests for User Story 1

- [x] T006 [P] [TDD] [US1] Real multi-process test:
      `TestFailoverState_AutomaticForwarding_NoManualFanOut` — the direct
      replacement/extension of `failover_state_test.go`'s existing
      scenario, this time WITHOUT the test calling every node's HTTP
      routes itself; only real client calls against the primary, then a
      real kill, then a real assertion the new primary already has
      everything. Confirmed failing (times out / shows missing data)
      against the current, un-forwarded daemon before implementation.
- [x] T007 [P] [TDD] [US1] Real test:
      `TestFailoverState_AppendLostBeforeForwarding_IsReportedNotHidden`
      (spec.md Edge Case / FR-005) — kill the primary in the exact
      instant after an append lands only locally; assert the gap is
      reported, never silently presented as complete.

### Implementation for User Story 1

- [x] T008 [US1] Implement `internal/replication/forwarder.go`: on every
      real append/checkpoint the primary's own `replication.Store`
      receives, forward it to every current replica per the
      `ReplicationRole` (T003) via the existing HTTP/3+mTLS client
      pattern (reuse 002's forwarding function if it exists at
      implementation time, or build the sibling the same way).
- [x] T009 [US1] Bounded retry + non-blocking behavior for an unreachable
      replica (spec.md FR-004): forwarding to one replica's failure MUST
      NOT block the primary's own response to its caller.
- [x] T010 [US1] Update `failover_state_test.go`'s original test to remove
      its own manual fan-out calls, keeping its other assertions intact —
      this is the literal, mechanical proof this feature's User Story 1
      is real (per plan.md's TDD Requirements).
- [x] T011 [US1] [REVIEW] Tenant-scoping review (spec.md FR-013) — confirm
      forwarding never crosses a tenant boundary, citing the T072-FU5
      cross-tenant finding as the exact defect class to guard against.

**Checkpoint**: User Story 1 fully functional — the MVP. **Get human
approval before starting User Story 2.**

---

## Phase 4: User Story 2 — Real engine cache warm-restore (Priority: P2)

**Goal**: When available and intact, a real engine cache file speeds up
recovery without ever being a correctness dependency.
**Independent Test**: quickstart.md Scenario 3.

### Tests for User Story 2

- [ ] T012 [P] [TDD] [US2] Real test against a real booted `llama-server`
      with `--slot-save-path` enabled: confirm a real save actually
      produces a real file (not merely that the HTTP call returned 200 —
      open and inspect the file, per this project's own established
      "verify the artifact, not just the API response" discipline).
- [ ] T013 [P] [TDD] [US2] Real test:
      `TestEngineCache_MissingOrCorruptFile_FallsBackCorrectly` (FR-008) —
      delete/corrupt the file, confirm recovery still succeeds via the
      token-sequence path, and confirm the outcome is reported as
      "fell back", never silently reported as either pure success or
      pure failure.
- [ ] T014 [TDD] [US2] Real timing test comparing time-to-first-response
      with vs. without a real, intact engine cache file present on the
      new primary (SC-004) — a genuine measurement, captured and recorded
      in the test's own evidence output; if this environment genuinely
      cannot host a long-enough real conversation to make the difference
      measurable, this MUST be disclosed honestly (matching T057's own
      SC-017 precedent) rather than a fabricated number.

### Implementation for User Story 2

- [ ] T015 [US2] Wire an opt-in `--slot-save-path` launch parameter for
      GGUF profiles in `lib/scheduler.sh`/`lib/engine.sh` (exact file
      confirmed by reading the real current launch-flag assembly code
      before editing — never assumed from this plan alone).
- [ ] T016 [US2] Implement `internal/executor/local.go` calls to the real
      engine's `/slots/:id_slot?action=save` (on checkpoint) and
      `?action=restore` (on warm-start), and `internal/replication/enginecache.go`
      for tracking `EngineCacheFile` (data-model.md) + orchestrating its
      transfer to a new primary via the existing HTTP/3+mTLS channel —
      strictly asynchronous, never gating User Story 1's own recovery
      path (research.md Decision 4).
- [ ] T017 [US2] [REVIEW] Host-safety review of the `--slot-save-path`
      wiring (Constitution §11.4.133) — an engine flag that changes what
      gets written to disk, on which node, is exactly this mandate's
      concern.

**Checkpoint**: User Stories 1 AND 2 both verified independently. **Get
human approval before starting User Story 3.**

---

## Phase 5: User Story 3 — Replication health visibility (Priority: P3)

**Goal**: An operator can see real, accurate lag per tenant/replica.
**Independent Test**: quickstart.md Scenario 4.

- [ ] T018 [TDD] [US3] Implement `internal/replication/lag.go`
      (`ReplicationLagRecord`, data-model.md), updated from real
      forwarding-acknowledgment traffic (T008). RED first:
      `TestLag_ZeroWhenCaughtUp`, `TestLag_ReflectsRealGapWhenBehind`.
- [ ] T019 [US3] Add the read endpoint to `internal/api/routes_replication.go`
      exposing per-tenant lag.
- [ ] T020 [TDD] [US3] Real multi-process test: quickstart.md Scenario 2 +
      Scenario 4 combined (block a replica, assert real non-zero lag,
      restore, assert lag returns to zero).

**Checkpoint**: All three user stories independently verified. **Get
human approval before Polish.**

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T021 [P] Update `docs/cluster-architecture.md`'s persistence section
      from 📋 to ✅ for the parts genuinely implemented here, with a real
      `mmdc`-rendered sequence diagram for the forward → reassign-on-
      failure → (optional) engine-cache-warm-restore flow.
- [ ] T022 [P] Append this feature to `specs/001-llmctl-completion/tasks.md`'s
      Follow-up Work section (next free `T072-FU<N>`) and update
      `progress.yml`, matching the established format.
- [ ] T023 Full-suite verification: `go vet ./...`, `gofmt -l .`,
      `go test ./...` clean, zero regressions (T059-T064's existing 24+
      `internal/replication` tests, T062's own updated test, and every
      Phase 9-11 test all still pass).
- [ ] T024 [REVIEW] Independent code review of the complete feature
      (Constitution §11.4.125/§11.4.142).
- [ ] T025 Update `docs/CONTINUATION.md`.

---

## Dependencies & Execution Order

- **Foundational (Phase 2)** blocks all user stories — the role-assignment
  state everything else reads.
- **User Story 1 (Phase 3)** is the MVP and blocks User Story 2's transfer
  mechanism reuse (T016 reuses T008's forwarding channel) but NOT its
  engine-launch wiring (T015 has no dependency on Phase 3 and could be
  developed in parallel).
- **User Story 3 (Phase 5)** depends only on Phase 3 (forwarding must
  exist to have lag data) — independent of User Story 2, can proceed in
  parallel with it.

## Notes

- If `specs/002-cluster-model-scheduler` has already landed on `main` by
  the time this feature is implemented, T001 and T003's own instructions
  to "read the real current shape first" are load-bearing, not
  boilerplate — this plan was written before knowing which feature would
  execute first, and explicitly does not assume its own `ClusterState`
  sketch is still accurate at that point.
- TDD is NON-NEGOTIABLE per this project's Constitution Principle III,
  matching `specs/002-cluster-model-scheduler/tasks.md`'s own Notes
  section.
