# Phase 1 Data Model: Cluster-Wide Model-Placement Scheduling

All entities below extend the existing, already-replicated
`internal/cluster.ClusterState` (`llmctld/internal/cluster/state.go`).
Fields marked **(existing)** are unchanged; fields marked **(new)** are this
feature's additions.

## `cluster.Node` (existing struct, unchanged fields, freshness semantics extended)

| Field | Type | Status | Notes |
|---|---|---|---|
| `ID` | `string` | existing | Unchanged. |
| `Addr` | `string` | existing | Unchanged. |
| `Health` | `string` (`"healthy"\|"unhealthy"\|"unknown"`) | existing | Unchanged; `Place()` already excludes anything not exactly `"healthy"`. |
| `Resources` | `Resources` | existing struct, **new freshness rule** | Previously written once, at hypothetical join time (never actually reached in production — see research.md Decision 3). This feature makes it genuinely written at real join time AND refreshed on the existing 10s health-check cadence via a new `CommandUpdateResources` command, so `Place()`'s candidates always reflect capacity as of at most one health-check interval ago. |

## `cluster.Resources` (existing struct, unchanged)

No field changes. `RAMAvailMB`/`VRAMAvailMB`/`CPUCores`/`NetworkMbps` are
exactly what `Place()`'s `fits()`/`leftoverScore()` already consume; this
feature's only change is ensuring these values are genuinely populated and
kept fresh (Decision 3), never a schema change.

## `cluster.RunningProfile` (new)

Represents one profile currently running on one node — the entity that
answers "where is X running" for name-only status/stop and the
cluster-wide status view (spec.md's "Cluster-Wide Running-Profile Index").

| Field | Type | Notes |
|---|---|---|
| `Profile` | `string` | The model profile name (matches `bin/llmctl`'s existing profile identifiers). |
| `NodeID` | `string` | Which node is running it — foreign-key-style reference to `cluster.Node.ID`. |
| `TenantID` | `string` | The tenant this instance belongs to (empty string = untenanted, matching the existing T072-FU convention in `internal/executor.LocalExecutor`/`internal/tenancy`). |
| `StartedAt` | `time.Time` | When this instance was recorded as started — carried in the Raft log entry (computed once by the proposer, never read from `time.Now()` inside `Apply`, matching the existing `LockEntry`/`CommandAcquireLock` determinism pattern in `fsm.go`). |
| `Footprint` | `PlacementRequest` (existing struct, reused) | The resource footprint this instance reserved on `NodeID` — required so `Apply` can re-derive "how much of this node's capacity is already spoken for" without consulting anything outside the log (see Concurrency-safety note below). |

**Uniqueness / multiplicity**: `(Profile, TenantID)` may map to MORE THAN ONE
`NodeID` simultaneously (spec.md's Edge Cases explicitly requires this —
"a profile name is already running on more than one node" must be reported,
never silently collapsed to one). The index is therefore modeled as a set
of `RunningProfile` entries, not a single-valued map keyed by profile name.

**State transitions**: `Recorded` (via `CommandRecordRunningProfile`, applied
when a node's real `LocalExecutor.Start` succeeds) → `Cleared` (via
`CommandClearRunningProfile`, applied when a node's real `LocalExecutor.Stop`
succeeds, OR when the health monitor's reconciliation detects the hosting
node has gone unhealthy — reusing `health.go`'s existing failure-detection
signal rather than inventing a second one).

## `PlacementDecision` (new — the audit record for User Story 3)

| Field | Type | Notes |
|---|---|---|
| `Profile` | `string` | What was requested. |
| `ChosenNodeID` | `string` | The winning node. |
| `ConsideredNodes` | `[]NodeCapacitySnapshot` | Every eligible node's advertised capacity AT DECISION TIME (see below) — the input `Place()` actually saw. |
| `Reason` | `string` | Human-readable justification (e.g. "best-fit: lowest leftover score 0.42 among 3 eligible nodes"). |
| `DecidedAt` | `time.Time` | When the decision was made. |

**`NodeCapacitySnapshot`** (new, nested): `{NodeID string, Resources cluster.Resources}`
— a point-in-time copy, never a live reference, so a later inspection of a
`PlacementDecision` reflects exactly what was true when the decision was
made even if the node's real capacity has since changed.

**Persistence**: `PlacementDecision` records are NOT part of the
Raft-replicated `ClusterState` (they are audit/observability data, not
cluster-membership state every node must agree on to make further
decisions) — they are recorded via the existing structured-logging/audit
mechanism this project already has (`internal/audit/log.go`), consistent
with how every other auditable action in this codebase (join, leave, lock
acquire/release) is already recorded, rather than inventing a second
persistence mechanism for this feature alone.

## Concurrency-safety note (FR-005, SC-004): capacity accounting MUST be re-validated inside `Apply`, not trusted from the caller

A client-side `Place()` call against a possibly-stale `State()` snapshot is
only a HINT — two concurrent requests can both read the same snapshot,
both compute "node B fits", and both submit a
`CommandRecordRunningProfile` for node B before either sees the other's
effect, double-booking node B's budget. This is the exact TOCTOU
(time-of-check-to-time-of-use) hazard FR-005 requires closing.

The fix mirrors the existing `CommandAcquireLock` pattern in `fsm.go`
exactly: `CommandAcquireLock`'s `Apply` does not trust the proposer's own
pre-check that the lock was free — it re-validates the CURRENT
(server-side, single-threaded-goroutine, therefore race-free) state at
`Apply` time and refuses (`errLockHeldByAnother`) if a concurrent
`Apply` already changed the answer. `CommandRecordRunningProfile`'s `Apply`
does the identical thing for capacity: it re-derives the target node's
CURRENT available capacity (total minus every ALREADY-recorded
`RunningProfile`'s footprint on that node, computed inside `Apply`, not
carried from the proposer) and refuses the command if the requested
footprint no longer fits — at which point the caller (the HTTP handler
in `routes_models.go`) re-runs `Place()` against the now-current state and
retries once against a different node, rather than ever recording an
over-budget placement. This requires `RunningProfile` to also carry the
footprint it reserved (`RAMMB, VRAMMB, CPUCores, NetworkMbps int64`/`int`,
matching `PlacementRequest`'s existing fields) so `Apply` can compute "how
much of this node's total capacity is already spoken for" without
re-deriving it from anywhere else.

## New `raft.CommandType` values (extends the existing closed set in `fsm.go`)

| Value | Carries | Applied when |
|---|---|---|
| `CommandUpdateResources` | `NodeID string`, `Resources cluster.Resources` | A node's periodic (10s) re-probe of its own real hardware/budget state, submitted to the leader. |
| `CommandRecordRunningProfile` | `Profile, TenantID, NodeID string`, `StartedAt time.Time`, `Footprint PlacementRequest` | Proposed once `Place()` has picked a candidate node, BEFORE the real `LocalExecutor.Start` call is made on that node; `Apply` re-validates the footprint still fits the node's current uncommitted capacity and refuses (mirroring `errLockHeldByAnother`'s pattern) if a concurrent Apply already used it up — see Concurrency-safety note below. Only on a successful `Apply` does the caller proceed to the real `LocalExecutor.Start`. |
| `CommandClearRunningProfile` | `Profile, TenantID, NodeID string` | A node's real `LocalExecutor.Stop` call succeeds, or the health monitor's reconciliation determines the hosting node is no longer healthy. |

`CommandJoinNode`/`CommandLeaveNode` (existing) are unchanged in shape; this
feature makes them genuinely reachable from the real `Join`/`Leave` call
path (research.md Decision 3), which is a change to `node.go`'s control
flow, not to the FSM command schema itself.
