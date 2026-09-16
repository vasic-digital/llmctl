# Implementation Plan: Cluster-Wide Model-Placement Scheduling

**Branch**: `002-cluster-model-scheduler` (developed directly on `main`,
matching this project's established pattern for the T072-FU1..FU5 follow-up
chain — see Structure Decision below) | **Date**: 2026-09-15 | **Spec**:
[spec.md](spec.md)
**Input**: Feature specification from `specs/002-cluster-model-scheduler/spec.md`

## Summary

Close T072-FU4's disclosed gap ("an operator or future orchestrator must
target the specific node it wants a model started on directly") by making
model start/stop/status cluster-aware: a request without a pinned node is
placed automatically, forwarded to the chosen node, and a cluster-wide view
answers name-only status/stop queries.

**Investigation-grounded technical approach** (every claim below verified by
reading the real source in `llmctld/internal/{cluster,raft,api}` before
writing this plan, per this project's investigate-before-fixing discipline
— nothing here is guessed):

The bin-packing node-selection engine (`internal/cluster/placement.go`'s
`Place()`, best-fit, GPU/CPU/RAM/Network-aware), the health monitor that
detects an unhealthy node and re-places its under-replicated models
(`internal/cluster/health.go`'s `Monitor.Reconcile`), and the oversized-model
sharding planner (`internal/cluster/sharding.go`'s `PlanShards`) **already
exist, are already TDD-tested (T052/T052a/T053/T057), and are reused as-is**
— this feature does not touch any of their logic.

What this feature actually builds is the missing data plumbing and API
wiring around that engine, confirmed absent by reading the real join/leave
and FSM code paths:

1. **A live node registry that is actually populated.** `cluster.ClusterState.Nodes`
   (the map `Place()` reads its candidate list from) is populated ONLY by
   direct unit-test construction today. The real `POST /v1/cluster/join`
   HTTP route (`routes_cluster.go`) and `raft.Node.Join`/`Leave`
   (`node.go`) only ever touch hashicorp/raft's own voter configuration
   (`AddVoter`/`RemoveServer`) — neither one ever calls
   `raft.Apply(Command{Type: CommandJoinNode, ...})`, the one FSM command
   that actually writes into `ClusterState.Nodes`. In a real running
   cluster today, `ClusterState.Nodes` is always empty. This feature wires
   real join to also submit a real `CommandJoinNode` (extending
   `joinRequest` to carry the joining node's real hardware-probe-derived
   `cluster.Resources`) and real leave to submit `CommandLeaveNode`.
2. **A resource-freshness heartbeat.** `Resources.RAMAvailMB`/`VRAMAvailMB`
   captured once at join time goes stale the moment any model starts or
   stops consuming budget on that node — `Place()` would then place work
   against numbers that no longer reflect reality. This feature adds a
   periodic (existing 10s health-check cadence, `health.go`'s ticker) local
   re-probe + a new `CommandUpdateResources` Raft command each node submits
   to the leader, reusing the SAME hardware-probe JSON (`lib/hardware.sh`'s
   schema, which `cluster.Resources`'s field names were already designed to
   mirror — confirmed via `state.go`'s own doc comment) `bin/llmctl`
   already produces for a single node.
3. **A cluster-wide running-profile index.** Nothing today records "profile
   X is running on node Y" anywhere shared. This feature adds a new,
   equally Raft-replicated map (`ClusterState.RunningProfiles`) written by
   whichever node actually executes a start/stop (via `LocalExecutor`,
   `internal/executor/local.go`) and consulted by the cluster-wide status
   view and by name-only status/stop resolution.
4. **Cross-node request forwarding.** `internal/api/client.go` has exactly
   one existing node-to-node HTTP/3+mTLS client function (`RequestJoin`,
   narrowly built for the join flow). This feature adds a second, symmetric
   client function for forwarding a model start/stop/status request to a
   specific peer's own `/v1/tenants/:id/models/:model/*` route (the
   existing T072-FU4 API surface), reusing the exact same mTLS/HTTP-3
   transport pattern `RequestJoin` already established — not a new
   transport mechanism.
5. **New cluster-facing routes** in `internal/api` (exact route naming
   decided at implementation time to fit the existing `routes_models.go`
   conventions) that: accept a start request with no node pinned, call
   `cluster.Place()` against the CURRENT `ClusterState.Nodes` snapshot,
   forward via (4) to the chosen node, and record the outcome in the new
   running-profile index; accept a name-only status/stop and resolve via
   the running-profile index before forwarding; and expose the existing
   `GET /v1/cluster/status`-style aggregate view extended with running
   profiles.

## Technical Context

**Language/Version**: Go (module `github.com/vasic-digital/llmctl/llmctld`),
matching every existing `llmctld/internal/*` package — this feature adds no
new language to the project.
**Primary Dependencies**: `github.com/hashicorp/raft` (already vendored, FSM
command pattern reused), `github.com/quic-go/quic-go/http3` (already
vendored, node-to-node transport reused), `github.com/gin-gonic/gin`
(already vendored, HTTP routing reused), `go.etcd.io/bbolt` (already
vendored, used by `internal/replication`, NOT newly introduced by this
feature — the running-profile index and node registry both live in the
existing Raft-replicated `ClusterState`, not a new bbolt store). No new
third-party dependency is introduced.
**Storage**: The Raft-replicated in-memory `cluster.ClusterState` (extended
with a new `RunningProfiles` field), persisted via the existing
`hraft.SnapshotStore`/log mechanism `internal/raft` already uses — no new
storage engine.
**Testing**: Go's standard `testing` package + real (non-mocked) multi-process
integration tests under `llmctld/test/integration/`, following the exact
pattern `cluster_bootstrap_test.go`/`failover_state_test.go` already
established (real `go build` binary, real spawned OS processes, real
HTTP/3+mTLS calls, `LLMCTL_DRY_RUN=1` for `LocalExecutor`'s real
`bin/llmctl` subprocess calls) — Constitution §11.4.27 (no fakes beyond
unit tests) applies identically to this feature.
**Target Platform**: Linux + macOS servers running `llmctld` in cluster
mode, matching the project's existing supported platform set — no new
platform requirement.
**Project Type**: Backend daemon extension (Go service, `llmctld`) plus its
existing HTTP API surface — not a new project type.
**Performance Goals**: A placement decision (FR-001..FR-005) completes
without a human-perceptible delay for an operator-driven request (well
under 1s for the `Place()` computation itself, which is a pure in-memory
slice scan over the cluster's node count — realistically dozens of nodes,
not thousands); the resource-heartbeat cadence reuses the existing 10s
health-check interval (`health.go`) rather than inventing a faster or
slower one, so no new performance target is introduced beyond what SC-013
(5s leader election) and SC-015 (10s failure detection / 30s reschedule)
already established for the underlying cluster mechanisms this feature
builds on.
**Constraints**: MUST reuse `Place()`/`Reconcile()`/`PlanShards()` unmodified
(no re-implementation of bin-packing, best-fit tie-breaking, or the
`Node.Health != "healthy"` exclusion rule — FR-012's assumption and the
Investigation-finding note in spec.md make this explicit); MUST NOT
introduce a second cluster-membership or transport mechanism alongside
Raft + the existing HTTP/3+mTLS channel (spec.md FR-015); MUST preserve
byte-identical single-node behavior for a start request that already names
a node (spec.md FR-002 — the existing T072-FU4 `routes_models.go` handlers
for an explicitly-node-scoped request are not touched); MUST NOT change
`cluster.ClusterState`'s existing `Nodes`/`Locks` fields' semantics for
any already-passing T052/T052a/T053/T055/T056a/T057/T058/T072-FU* test —
every extension is additive.

## Constitution Check

*GATE: Must pass before proceeding. Re-check after design phase.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Deterministic Validation & Verification | PASS | Every new behavior (real node-registry population, real resource heartbeat, real cross-node forwarding, real running-profile index) will be proven via real multi-process integration tests reading real captured HTTP responses — no metadata-only or config-only PASS, matching the established `cluster_bootstrap_test.go`/`failover_state_test.go` evidence bar. |
| II. CLI-First Interface & Text I/O | PASS | This feature extends `llmctld`'s existing JSON HTTP API (the `internal/api` package); it introduces no new CLI surface of its own — `bin/llmctl` remains the single-node CLI, untouched. |
| III. Test-First with Anti-Bluff Gates (NON-NEGOTIABLE) | PASS (gate applies at execution time) | Every new FSM command (`CommandUpdateResources`, running-profile-index commands), every new HTTP route, and the new cross-node forwarding client function will each get a RED-first test proven to fail for the right reason before implementation, following T052/T058/T072-FU4's own established TDD evidence pattern in this same codebase. Paired-mutation meta-tests are required for any new gate this feature introduces (Constitution §1.1) — none is currently planned to introduce a new *gate*, only new library/route code covered by ordinary tests; if a gate is added during implementation it MUST carry a paired mutation. |
| IV. Integration Testing & Real Environment Execution | PASS | The multi-node placement, forwarding, and running-profile-index behaviors are inherently multi-process and will be tested exactly as T051/T054/T062 already test multi-process Raft behavior — real spawned `llmctld` binaries, real HTTP/3+mTLS, no mocking at the harness level. |
| V. Anti-Bluff Covenant | PASS | Every new claim ("placement respects live capacity", "forwarding reaches the chosen node", "name-only stop finds the right node") will be backed by a real integration test asserting the real observed outcome, not an assumption — matching T062's disclosed-boundary discipline of stating exactly what is proven versus what remains a gap. |
| VI. Absolute Codebase & Data Safety | PASS | No destructive operation is introduced; `ClusterState` extension is additive (a new field), so `Restore()`'s existing nil-map defensive initialization pattern (`fsm.go`'s `Restore`) is extended the same way for the new field, preserving backward-compatible snapshot restore. |
| VII. Host-Session Safety | PASS | No new unbounded loop or heavy long-running process is introduced; the resource-heartbeat reuses the EXISTING 10s ticker cadence rather than adding a second one, keeping resource usage within the same envelope this cluster daemon already operates in. |
| VIII. Submodule Governance | N/A | This feature touches only `llmctld/internal/*` and `llmctld/cmd/*` in the main repository; no submodule is touched. |
| IX. Documentation Up to Nano-Details | PASS (gate applies at execution time) | `docs/cluster-architecture.md` (already extended twice, T041/T057, with real `mmdc`-rendered Mermaid diagrams and explicit ✅ IMPLEMENTED / 📋 PLANNED labeling) MUST gain a new section for this feature's node-registry-population + resource-heartbeat + running-profile-index + cross-node-forwarding design, following that same established honest-labeling discipline. |
| X. Changelog Discipline & Multi-Format Export | PASS (gate applies at execution time) | Follows the existing per-task documentation discipline this session's T072-FU1..FU5 chain already established (tasks.md entries, progress.yml, CONTINUATION.md). |

## Project Structure

### Documentation (this feature)

```text
specs/002-cluster-model-scheduler/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md           # Phase 0 output (below)
├── data-model.md         # Phase 1 output (below)
├── quickstart.md         # Phase 1 output (below)
├── tasks.md              # Task breakdown (/speckit.superspec.tasks output)
└── checklists/
    └── requirements.md   # Spec quality checklist
```

### Source Code (repository root)

```text
llmctld/
├── internal/
│   ├── cluster/
│   │   ├── state.go          # MODIFY: ClusterState gains RunningProfiles;
│   │   │                       Resources already has the right fields (no change)
│   │   ├── placement.go       # UNCHANGED (reused as-is per Constraints)
│   │   ├── health.go          # MODIFY: wire the resource re-probe into the
│   │   │                       existing 10s Monitor ticker
│   │   ├── sharding.go        # UNCHANGED (reused as-is)
│   │   └── partition.go       # UNCHANGED
│   ├── raft/
│   │   ├── fsm.go             # MODIFY: new CommandUpdateResources,
│   │   │                       CommandRecordRunningProfile,
│   │   │                       CommandClearRunningProfile; CommandJoinNode/
│   │   │                       CommandLeaveNode become genuinely reachable
│   │   │                       (no signature change to the existing ones)
│   │   ├── node.go            # MODIFY: Join/Leave additionally call
│   │   │                       n.raft.Apply with the corresponding command
│   │   │                       (the joining/leaving node's real Resources
│   │   │                       must be threaded through the existing Join
│   │   │                       call chain — signature change, all call
│   │   │                       sites updated)
│   │   └── lock.go            # UNCHANGED
│   ├── api/
│   │   ├── routes_cluster.go  # MODIFY: joinRequest gains Resources; the
│   │   │                       /v1/cluster/status response gains the
│   │   │                       running-profile index view
│   │   ├── client.go          # MODIFY: new RequestForward (or similarly
│   │   │                       named) function alongside RequestJoin,
│   │   │                       reusing the identical HTTP/3+mTLS pattern
│   │   ├── routes_models.go   # MODIFY: start/stop/status handlers gain a
│   │   │                       "no node pinned" path that calls
│   │   │                       cluster.Place, forwards via client.go, and
│   │   │                       records into the running-profile index;
│   │   │                       the existing explicit-node path is
│   │   │                       byte-identical to today
│   │   └── routes_models_test.go, routes_cluster_test.go  # extended
│   └── executor/
│       └── local.go           # UNCHANGED (the local single-node execution
│                                 primitive this feature forwards TO)
├── cmd/llmctld/
│   └── main.go                 # MODIFY: wires the resource-probe source
│                                 (reusing lib/hardware.sh's JSON output,
│                                 exact invocation mechanism decided at
│                                 implementation time) and the health
│                                 Monitor's periodic Reconcile call — T054's
│                                 own disclosed gap ("main.go currently only
│                                 wires cluster-membership + health/lock
│                                 LIBRARIES, never a running reconciliation
│                                 loop") is closed as a byproduct of this
│                                 feature needing the same wiring.
└── test/integration/
    └── cluster_placement_test.go  # NEW: real multi-process test proving
                                     User Stories 1-3's acceptance scenarios
docs/
└── cluster-architecture.md    # MODIFY: new section per Constitution
                                 Check row IX above
```

**Structure Decision**: This feature extends the existing `llmctld` Go
module in place — no new module, no new top-level directory, no new
external dependency. It follows the SAME direct-on-`main`,
commit-per-completed-unit development pattern this session's T072-FU1
through T072-FU5 follow-up chain already used successfully for this exact
codebase (rather than a long-lived feature branch per Constitution
§11.4.195's `feat/<slug>` taxonomy, since — like those five follow-ups —
each unit of work here is independently small, backward-compatible, and
individually reviewable/revertible; a single long branch would defer that
same review discipline rather than improve it). The spec directory
(`specs/002-cluster-model-scheduler/`) is retained for planning/traceability
per this project's SpecKit convention even though implementation lands via
direct commits, matching how `specs/001-llmctl-completion/tasks.md`'s own
"Follow-up Work" section already documents T072-FU1..FU5 the same way.

## Execution Strategy

### TDD Requirements

- [ ] `internal/raft/fsm.go` new commands (`CommandUpdateResources`,
      `CommandRecordRunningProfile`, `CommandClearRunningProfile`): strict
      RED-GREEN — each command's `Apply` behavior (including the
      determinism requirement `TestApply_DeterministicGivenSameLogSequence`
      already enforces for existing commands) must be proven via a real
      `go vet`-confirmed RED before implementation, exactly like every
      existing FSM command in this file.
- [ ] `internal/raft/node.go` Join/Leave resource-threading: strict
      RED-GREEN — this is the exact class of defect (a call path that
      LOOKS wired but never actually reaches the FSM) that T054 already
      found once in this same function; the new test must assert the
      resulting `ClusterState.Nodes` entry is genuinely present after a
      real `Join` call, not merely that `Join` returns no error.
- [ ] `internal/api/client.go`'s new forwarding function: strict RED-GREEN,
      following `RequestJoin`'s own established real-HTTP/3+mTLS test
      pattern (a fake/mocked transport is not acceptable per Constitution
      §11.4.27).
- [ ] `internal/api/routes_models.go`'s no-node-pinned path: strict
      RED-GREEN, extending the existing `routes_models_test.go` real-HTTP
      test pattern from T072-FU4.
- [ ] `llmctld/test/integration/cluster_placement_test.go`: strict RED-GREEN
      at the multi-process level, matching `cluster_bootstrap_test.go`'s
      real-process harness reuse.

### Parallel Execution Opportunities

- [ ] The FSM-command layer (`fsm.go` + `node.go` Join/Leave threading) and
      the new HTTP-client forwarding function (`client.go`) have no shared
      files and can be developed as two independent subagent-driven work
      streams; `routes_models.go`'s wiring depends on BOTH being done
      first, so it is not parallel with either.
- [ ] `docs/cluster-architecture.md`'s new section can be written in
      parallel with any of the above once the design is settled (it
      documents the design, not any specific file's final diff).

### Human Checkpoints

1. After the FSM-command + node-registry-population work lands (the
   foundational data-plumbing layer) — verify a real multi-process test
   shows `ClusterState.Nodes` genuinely populated with live resources
   after a real join, before building anything on top of it.
2. After the resource-heartbeat + running-profile-index work lands —
   verify staleness/consistency behavior against the acceptance scenarios
   in User Story 3 (concurrency safety, auditability).
3. After the cross-node forwarding + `routes_models.go` wiring lands —
   verify User Stories 1 and 2's acceptance scenarios end-to-end on a real
   multi-node cluster.
4. Before this feature is folded into `specs/001-llmctl-completion`'s
   Follow-up Work section (matching the T072-FU1..FU5 documentation
   pattern) — full `go vet`/`gofmt`/`go test ./...` clean, zero
   regressions, independent code review per Constitution §11.4.125/§11.4.142.

### Review Gates

- [ ] The new FSM commands and `ClusterState` extension: review before any
      HTTP-layer code depends on them (a determinism or race-safety defect
      here — matching the exact class of bug `fsm.go`'s own doc comment
      already documents having found once — would silently corrupt cluster
      state across every node).
- [ ] The cross-node forwarding client function: review before
      `routes_models.go` depends on it, specifically for the same mTLS
      peer-verification correctness `transport.go`'s own documented
      SAN/CommonName investigation (T049) already had to get right once.
- [ ] `routes_models.go`'s no-node-pinned path: review for authorization
      parity with the explicit-node path (T072-FU5's independent-review
      finding — a cross-tenant authorization gap in a superficially similar
      "which node handles this" resolution step — is the exact defect
      class this review gate exists to catch again).

## Complexity Tracking

*No unjustified Constitution violations — table intentionally empty.*
