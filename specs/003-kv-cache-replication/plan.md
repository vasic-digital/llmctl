# Implementation Plan: Cross-Node KV-Cache Replication via Real File Transfer

**Branch**: `003-kv-cache-replication` (developed directly on `main`, same
pattern as `002-cluster-model-scheduler` and the T072-FU1..FU5 chain) |
**Date**: 2026-09-15 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/003-kv-cache-replication/spec.md`

## Summary

Close two related, disclosed gaps: (1) T062's finding that no daemon-side
mechanism automatically forwards a primary node's WAL appends/checkpoints
to replicas (today only a test harness manually fans out to all 3 nodes),
and (2) T060's finding that the real `llama-server` engine's genuine
`--slot-save-path` + `/slots/:id_slot?action=save|restore` HTTP mechanism
is never wired anywhere. (1) is the correctness-bearing fix (User Story 1,
P1); (2) is a strictly-optional, non-blocking performance layer on top
(User Story 2, P2) per spec.md FR-008/FR-009.

**Investigation-grounded technical approach** (verified by reading
`internal/replication/{wal,checkpoint}.go`, `internal/replication/registry.go`,
and the vendored `llama.cpp` server source before writing this plan):

1. **Granularity correction**: `replication.Store` (and its `WAL`) is
   scoped ONE PER TENANT, not per conversation — `WALEntry` carries no
   conversation identifier. "Forwarding a conversation's state" in this
   feature's design means forwarding a tenant's `Store` content, matching
   the storage layer's real existing granularity (spec.md's Assumptions
   documents this correction explicitly).
2. **No existing "who is primary for this tenant's replicated stream"
   concept exists.** `internal/cluster`'s `Place()`/`ReplicaState` (from
   002's own investigation) model MODEL-instance placement
   (`ReplicaState{Model, TargetCount, LiveNodeIDs}`), not per-tenant
   replicated-storage primary/replica roles. This feature introduces that
   concept fresh — a new, small piece of Raft-replicated state (reusing
   the SAME `ClusterState`/FSM mechanism 002 already extends, per the
   "no second replication mechanism" constraint both features share).
3. **The forwarding transport reuses `internal/api/client.go`'s
   established HTTP/3+mTLS pattern** (`RequestJoin`, and 002's own new
   forwarding function if 002 lands first — this feature's forwarding
   client is either the SAME function generalized, or a sibling built the
   identical way; the exact code-sharing decision is made at
   implementation time based on which feature actually lands first, but
   the pattern itself is fixed and non-negotiable per both features'
   FR-012/FR-015 "no second transport" constraints).
4. **The engine cache-file transfer (User Story 2) reuses the same
   channel** for moving the real `--slot-save-path` output file between
   nodes — no new bulk-transfer mechanism, per spec.md FR-012.
5. **`--slot-save-path` wiring is new, additive `bin/llmctl`/`lib/*.sh`
   work**: confirmed (by grepping every `lib/*.sh` file) that no existing
   code passes this flag to `llama-server` today. This feature adds it as
   an opt-in launch parameter for GGUF profiles, plus the actual HTTP
   calls to the engine's own `/slots/:id_slot?action=save|restore`
   endpoint from `internal/executor` (the control-plane component that
   already owns starting/stopping the engine subprocess) — never
   reimplementing engine-internal logic, exactly matching this project's
   existing control-plane/data-plane split principle.

## Technical Context

**Language/Version**: Go (`llmctld/internal/*`) for the daemon-side
forwarding/role-assignment/file-transfer logic; Bash (`bin/llmctl`,
`lib/*.sh`) for the `--slot-save-path` launch-flag wiring, matching each
language's existing ownership boundary in this project (Go = control
plane orchestration, Bash = the single-node engine-launch mechanism).
**Primary Dependencies**: `github.com/hashicorp/raft` and
`github.com/quic-go/quic-go/http3` (both already vendored, reused
unmodified); the real vendored `llama.cpp` `llama-server` binary's own
already-built `--slot-save-path`/`/slots/*` capability (not a dependency
this project adds — it already exists in the pinned submodule; this
feature is the first caller). No new third-party dependency.
**Storage**: The existing per-tenant `bbolt`-backed `replication.Store`
(WAL + checkpoint) is the correctness-bearing state this feature forwards,
unmodified in format. The new primary/replica role assignment is a new,
small field on the existing Raft-replicated `cluster.ClusterState` (or an
equally-replicated sibling structure, decided at implementation time
against whichever shape 002's own `ClusterState` extension has landed as,
to avoid two independently-evolving copies of "cluster-replicated state
shape"). The real engine cache file is a plain file on the node's local
disk (wherever `--slot-save-path` points), transferred (not
Raft-replicated — it is large binary engine output, not small
consensus-worthy state) via the existing HTTP/3+mTLS channel.
**Testing**: Real multi-process integration tests under
`llmctld/test/integration/`, extending `failover_state_test.go`'s own
established pattern (real 3-node cluster, real HTTP/3+mTLS calls, no
mocked transport) — this feature's own tests specifically REMOVE
`failover_state_test.go`'s disclosed manual-fan-out workaround and assert
the daemon does it automatically instead, which is the direct, mechanical
proof this feature's User Story 1 is real. Engine-level tests
(User Story 2) require a real `llama-server` process actually booted with
`--slot-save-path` — reusing `LLMCTL_FAKE_HW`-independent real download/
smoke-test fixtures this project's existing `tests/` suite already has for
GGUF profiles, never a fake engine response.
**Target Platform**: Linux + macOS `llmctld` cluster nodes, matching the
existing supported set; `--slot-save-path` wiring is exercised on
whichever platform(s) the project's existing GGUF smoke-test fixtures
already run on.
**Project Type**: Backend daemon extension (Go) + CLI/engine-launch
extension (Bash) — not a new project type.
**Performance Goals**: Forwarding latency for an append/checkpoint should
not add human-perceptible delay to the primary's own response path
(SC-003 makes this a hard constraint: the engine-cache-file transfer,
which CAN be large and slow, MUST NOT be on this critical path at all).
SC-004's "measurably reduces time-to-first-response" is a real, must-be-
actually-measured claim, not an assumed one — the task list requires a
real before/after timing capture on a long-enough conversation fixture,
never an unverified percentage (matching this project's existing
Constitution §11.4.6 discipline, and the same honest-SC-017-non-fabrication
precedent T057 already set for a structurally similar unmeasured-benchmark
situation).
**Constraints**: MUST NOT introduce a second replicated-state or transport
mechanism (spec.md FR-012, mirrors 002's FR-015); MUST NOT change
`replication.Store`'s existing WAL/checkpoint binary format (every
existing `internal/replication` test, T059-T064, MUST keep passing
unmodified); MUST NOT make correctness recovery (User Story 1) depend on
the engine-cache-file layer succeeding (FR-008/FR-009 — a hard ordering
constraint, not a preference); MUST preserve every existing
`failover_state_test.go` assertion's INTENT even though its own manual
fan-out calls are what this feature makes redundant (the test is updated,
not deleted, to assert the NEW automatic behavior produces the same
correct outcome the manual calls used to prove).

## Constitution Check

*GATE: Must pass before proceeding. Re-check after design phase.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Deterministic Validation & Verification | PASS | Every new behavior (automatic forwarding, role reassignment on failover, real engine cache save/restore, real file transfer) is proven via real captured multi-process test output — extending, not replacing, `failover_state_test.go`'s own already-established real-evidence bar. |
| II. CLI-First Interface & Text I/O | PASS | `--slot-save-path` wiring extends `bin/llmctl`'s existing text-in/out engine-launch mechanism (no new CLI surface shape); the daemon-side forwarding/role logic extends the existing JSON HTTP API. |
| III. Test-First with Anti-Bluff Gates (NON-NEGOTIABLE) | PASS (gate applies at execution time) | Every new FSM/role-assignment command, the forwarding loop, and the engine save/restore wiring each get a RED-first test, matching T059-T064's own established TDD evidence pattern for this exact package. |
| IV. Integration Testing & Real Environment Execution | PASS | Multi-process forwarding and real-engine cache save/restore are both inherently real-process/real-engine concerns; no mocking at the harness level, matching T062's own real-engine discipline. |
| V. Anti-Bluff Covenant | PASS | SC-004's timing claim will be a REAL captured measurement or explicitly reported as not yet measured — never an assumed percentage, matching T057's own honest-unmeasured-SC precedent in this exact area of the codebase. |
| VI. Absolute Codebase & Data Safety | PASS | No destructive operation introduced; the new role-assignment state is additive to whichever `ClusterState` shape exists at implementation time. |
| VII. Host-Session Safety | PASS | Forwarding reuses existing connections/cadence rather than adding new unbounded loops; the real engine cache-file transfer is explicitly kept off the user-facing critical path (FR-009) so it cannot itself become a host-load hazard on the recovery path. |
| VIII. Submodule Governance | PASS | The vendored `llama.cpp` submodule's existing `--slot-save-path`/`/slots/*` capability is consumed as-is (confirmed already present in the pinned tag by T060's own investigation) — this feature does not modify the submodule. |
| IX. Documentation Up to Nano-Details | PASS (gate applies at execution time) | `docs/cluster-architecture.md`'s persistence section (already flagged 📋 for exactly this gap by T060/T062's own honest markers) gets updated to ✅ IMPLEMENTED with a real sequence diagram, following the established discipline. |
| X. Changelog Discipline & Multi-Format Export | PASS (gate applies at execution time) | Same T072-FU-chain documentation pattern as 002. |

## Project Structure

### Documentation (this feature)

```text
specs/003-kv-cache-replication/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── checklists/requirements.md
```

### Source Code (repository root)

```text
llmctld/
├── internal/
│   ├── cluster/
│   │   └── state.go            # MODIFY: new replication-role-assignment
│   │                              type (primary/replica per tenant),
│   │                              additive to whichever ClusterState
│   │                              shape exists (coordinate with 002 if
│   │                              landed concurrently)
│   ├── raft/fsm.go              # MODIFY: new commands for assigning/
│   │                              reassigning the forwarding role
│   ├── replication/
│   │   ├── forwarder.go         # NEW: the daemon-side loop that watches
│   │   │                          its own Store for new appends/
│   │   │                          checkpoints and forwards them to every
│   │   │                          current replica for its tenant
│   │   ├── lag.go               # NEW: replication-lag tracking/reporting
│   │   │                          (User Story 3)
│   │   └── enginecache.go       # NEW: real engine cache save/restore +
│   │                              transfer orchestration (User Story 2)
│   ├── executor/local.go        # MODIFY: optional --slot-save-path
│   │                              threading when starting a GGUF profile;
│   │                              new calls to the engine's real
│   │                              /slots/:id_slot?action=save|restore
│   │                              endpoint
│   └── api/
│       ├── client.go             # MODIFY or reuse 002's forwarding
│       │                           function: send an append/checkpoint/
│       │                           cache-file to a specific peer node
│       └── routes_replication.go # MODIFY: new replication-health
│                                    (lag) read endpoint (User Story 3)
├── lib/
│   ├── scheduler.sh              # MODIFY: pass --slot-save-path when
│   │                                launching a GGUF profile IF this
│   │                                feature is enabled for that profile
│   └── engine.sh                 # possibly MODIFY: engine-launch flag
│                                    plumbing, exact location decided at
│                                    implementation time after reading
│                                    the real current launch-flag
│                                    assembly code path
└── test/integration/
    └── failover_state_test.go    # MODIFY: remove the manual fan-out
                                     calls, assert automatic forwarding
                                     produces the same durable outcome
                                     the manual calls used to prove
docs/
└── cluster-architecture.md       # MODIFY: persistence section flip from
                                     📋 to ✅ for the parts this feature
                                     genuinely implements
```

**Structure Decision**: Direct-on-`main` development, same rationale as
002 (each unit is independently small, backward-compatible, and
individually reviewable). This feature's Go-side work and 002's are both
extensions of the same `internal/cluster`/`internal/raft`/`internal/api`
packages — if both are executed in the same working session, the
`ClusterState`/FSM extensions from whichever lands first MUST be read
fresh (not assumed from this planning document) before the second
feature's implementation begins, to avoid two independently-designed,
divergent extensions of the same replicated-state structure.

## Execution Strategy

### TDD Requirements

- [ ] `internal/raft/fsm.go` new role-assignment commands: strict
      RED-GREEN, matching the existing command-addition pattern.
- [ ] `internal/replication/forwarder.go`: strict RED-GREEN — the
      load-bearing test is a real multi-process assertion that killing a
      primary WITHOUT any test-side manual forwarding call still produces
      a fully-caught-up new primary, which is the literal negation of
      `failover_state_test.go`'s own currently-disclosed gap.
- [ ] `internal/replication/enginecache.go` + `executor/local.go`'s
      `--slot-save-path` wiring: strict RED-GREEN against a REAL booted
      `llama-server` process (per Constitution §11.4.27, no fakes beyond
      unit tests) — the real save/restore HTTP round-trip must be
      observed, not assumed from reading the engine's source alone.

### Parallel Execution Opportunities

- [ ] The role-assignment FSM layer and the engine-cache save/restore
      layer (`enginecache.go`) have no shared files and can be developed
      as independent subagent-driven streams; the forwarding loop
      (`forwarder.go`) depends on the role-assignment layer landing
      first.
- [ ] The replication-lag reporting (User Story 3) can proceed in parallel
      with the engine-cache layer (User Story 2) once forwarding (User
      Story 1) exists, since both read from forwarding's own state
      without modifying it.

### Human Checkpoints

1. After the role-assignment + forwarding loop lands — verify, on a real
   3-node cluster, that `failover_state_test.go`'s scenario now passes
   WITHOUT its own manual fan-out calls.
2. After the engine cache save/restore + transfer layer lands — verify a
   real measured time-to-first-response improvement on a real long-enough
   conversation fixture (SC-004), or an honest "not yet measured, here is
   why" disclosure matching T057's own precedent if a suitable real
   fixture genuinely cannot be constructed in this environment.
3. After replication-lag reporting lands — verify against a real
   deliberately-slowed replica.
4. Before folding into `specs/001-llmctl-completion`'s Follow-up Work
   section — full `go vet`/`gofmt`/`go test ./...` clean, zero
   regressions, independent review.

### Review Gates

- [ ] The role-assignment FSM commands: review for the exact same
      determinism/race-safety bar `fsm.go`'s own doc comment already
      documents having been violated once (Phase 11's T073 concurrent-map
      bug) — a new command touching shared state is exactly the class of
      change that historically introduced that defect.
- [ ] The forwarding loop's exactly-one-primary invariant (spec.md
      FR-011): review specifically for the reassignment-race edge case
      spec.md's Edge Cases section names.
- [ ] The `--slot-save-path` engine-launch wiring: review for host safety
      (Constitution §11.4.133/§12) — an engine flag that changes what the
      engine writes to disk is exactly the class of change that mandate
      exists for.

## Complexity Tracking

*No unjustified Constitution violations — table intentionally empty.*
