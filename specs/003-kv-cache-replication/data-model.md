# Phase 1 Data Model: Cross-Node KV-Cache Replication via Real File Transfer

## `ReplicationRole` (new — the per-tenant forwarding-role assignment)

| Field | Type | Notes |
|---|---|---|
| `TenantID` | `string` | The tenant whose replicated stream this assignment concerns (empty-tenant/no-tenancy default is out of scope for cross-node forwarding — a single-node deployment has nothing to forward to). |
| `PrimaryNodeID` | `string` | The one node currently authoritative for forwarding this tenant's `replication.Store` content (spec.md FR-011: exactly one at any time). |
| `ReplicaNodeIDs` | `[]string` | Every node that should be receiving forwarded appends/checkpoints for this tenant. |
| `AssignedAt` | `time.Time` | When this assignment took effect — carried in the log entry, computed once by the proposer (matching the existing `LockEntry`/`CommandAcquireLock` determinism pattern). |

**State transitions**: `Assigned` (initial, or after a reassignment) →
`Reassigned` (when the health monitor detects the current primary is no
longer healthy, following the SAME detection signal `health.go`'s existing
`Monitor` already uses — never a second, independently-invented
unhealthy-node detector). A reassignment is applied via a new FSM command
that atomically replaces the record (matching `CommandJoinNode`'s own
map-replace-in-place pattern) — never two records momentarily coexisting
for the same tenant.

## `ReplicationLagRecord` (new — User Story 3)

| Field | Type | Notes |
|---|---|---|
| `TenantID` | `string` | |
| `ReplicaNodeID` | `string` | |
| `LastConfirmedSeq` | `uint64` | The highest WAL `Seq` (per `wal.go`'s existing field) this replica has confirmed receiving. |
| `PrimarySeq` | `uint64` | The primary's own current highest `Seq`, at the moment this record was last updated. |
| `Lag` | `uint64` (derived) | `PrimarySeq - LastConfirmedSeq`; zero means fully caught up (SC-002/SC-005). |

**Persistence**: Kept in-memory on the primary node (rebuilt from real
forwarding-acknowledgment traffic, not itself Raft-replicated — it is
observability data about replication's progress, not state every node
must agree on, matching 002's own `PlacementDecision`'s audit-not-consensus
persistence choice) and exposed via a new read endpoint (contracts, below).

## `EngineCacheFile` (new — User Story 2)

| Field | Type | Notes |
|---|---|---|
| `TenantID` | `string` | |
| `NodeID` | `string` | Which node currently holds the real file. |
| `Path` | `string` | The real on-disk path (`--slot-save-path`'s output location). |
| `Validity` | `string` (`"intact"\|"stale"\|"unavailable"`) | Whether this file is currently trustworthy to warm-restore from (spec.md's Key Entities — "stale" covers the case where the tenant's replicated stream has advanced past what this file reflects). |
| `SavedAt` | `time.Time` | When the engine last confirmed a successful save to this path. |

**Not Raft-replicated**: this is a large binary artifact reference, not
small consensus state — tracked the same way `ReplicationLagRecord` is
(in-memory, rebuilt from real save/transfer confirmations), per plan.md's
Constraints (no new consensus-worthy state for this layer) and research.md
Decision 4 (never gates correctness).

## Relationship to existing entities

- `ReplicationRole.PrimaryNodeID`/`ReplicaNodeIDs` reference the same node
  identity space as `cluster.Node.ID` (002's/the existing cluster
  registry), but are a DISTINCT record from `cluster.ReplicaState`
  (MODEL-instance replica counts) — see research.md Decision 2 for why
  these are not merged into one structure.
- `ReplicationLagRecord.LastConfirmedSeq`/`PrimarySeq` are the existing
  `WALEntry.Seq` field (`wal.go`) — no new sequence-numbering scheme.
- `EngineCacheFile` is additive to, never a replacement for, the existing
  `KVState{Tokens, Positions}` checkpoint (`checkpoint.go`) — a
  conversation's correctness never depends on `EngineCacheFile` existing
  (research.md Decision 4).
