# Phase 0 Research: Cluster-Wide Model-Placement Scheduling

No `[NEEDS CLARIFICATION]` markers remain in the Technical Context — every
open question was resolved by reading the real, existing source before
writing the plan (per this project's investigate-before-fixing discipline).
This document records those decisions.

## Decision 1: Reuse `Place()`'s best-fit strategy unmodified

**Decision**: Do not design a new placement/scheduling algorithm. Use
`internal/cluster/placement.go`'s existing `Place(candidates, req)` exactly
as it stands.

**Rationale**: Confirmed by reading `placement.go` directly — it already
implements a GPU/CPU/RAM/Network-aware, best-fit bin-packing selection with
an unhealthy-node exclusion rule and a deterministic ascending-ID tie-break,
and it already has 8/8 passing tests (T052/T052a: exact-fit, over-budget
refusal, multi-candidate best-fit, unhealthy-node handling, determinism,
under-replication reconciliation). Re-implementing or replacing this would
violate the user's own explicit instruction ("no reinventing what already
exists") and would discard tested, documented logic for no benefit.

**Alternatives considered**: A load-spreading ("most headroom first")
strategy was the initial default written into the first draft of this
feature's spec, before the existing `placement.go` was found and read. It
was rejected once the real code was discovered, since best-fit is already
implemented, tested, and explicitly justified in-source (minimizing
fragmentation, not spreading load) — switching strategies would be
unmotivated churn against working code.

## Decision 2: Extend the existing Raft FSM command set rather than build a second replication mechanism

**Decision**: The new node-registry-population, resource-heartbeat, and
running-profile-index data all become new `CommandType` values applied
through the existing `internal/raft/fsm.go` `ClusterFSM.Apply` switch,
replicated via the same `hraft.Raft.Apply` log every other cluster-state
mutation already uses.

**Rationale**: `cluster.ClusterState` is already the single source of truth
for replicated cluster state (`Nodes`, `Locks`), already snapshotted/restored
via `hraft.FSMSnapshot`, and already proven race-safe under concurrent
Apply/State() access (a real, previously-found `concurrent map writes` bug
was fixed here in Phase 11's T073, per `fsm.go`'s own doc comment). Building
a second, parallel replication mechanism for the new data would duplicate
that already-solved correctness work and would violate spec.md's FR-015
("MUST NOT introduce a second, parallel cluster-membership or transport
mechanism").

**Alternatives considered**: Using the existing `internal/replication`
package (bbolt-backed WAL/checkpoint, built for KV-cache/LoRA state in
Phase 10/US8) was considered and rejected — that package is explicitly
per-tenant, per-model conversational/adapter state, not cluster-membership
or scheduling state; conflating the two would misuse a mechanism designed
for a different consistency model (eventual, per-tenant) where the cluster
registry needs Raft's strict linearizability (the same reasoning that
already justified keeping locks in the Raft FSM rather than in
`internal/replication`, per T056a's own file-location rationale).

## Decision 3: The node-registry gap is real and is this feature's true starting point

**Decision**: Before any placement/forwarding logic can be exercised against
a real cluster, `raft.Node.Join`/`Leave` must be extended to actually apply
`CommandJoinNode`/`CommandLeaveNode` — today they only touch hashicorp/raft's
own voter configuration (`AddVoter`/`RemoveServer`), never the FSM.

**Rationale**: Confirmed by reading `node.go`'s `Join`/`Leave` functions
directly: neither calls `n.raft.Apply(...)`. `routes_cluster.go`'s
`POST /v1/cluster/join` handler only forwards `peer_id`/`peer_addr` to
`node.Join`, with no `Resources` field anywhere in `joinRequest`. This means
`ClusterState.Nodes` — the exact map `Place()` reads its candidates from —
is populated ONLY inside unit tests that construct it directly; a real
running cluster's registry is always empty today. This is a materially
different (and larger) gap than "the model API doesn't call the placement
engine yet" — it is "the placement engine has never been fed real data from
a running cluster." Confirming this via source-reading (rather than
assuming the existing `/v1/cluster/join` route already did this, since its
name suggests it might) is exactly the kind of check this project's anti-bluff
discipline requires before scoping work.

**Alternatives considered**: A live-probe side-channel independent of Raft
(e.g., each node periodically POSTing its resources to every peer directly,
gossip-style) was considered and rejected in favor of routing resource
updates through the existing Raft leader-applies-log mechanism, since that
keeps exactly ONE source of truth for cluster state (consistent with
Decision 2) rather than introducing a second, weaker-consistency channel
alongside it.

## Decision 4: Cross-node forwarding reuses the existing HTTP/3+mTLS client pattern

**Decision**: A new function in `internal/api/client.go`, structurally
parallel to the existing `RequestJoin`, will forward a model
start/stop/status request to a specific peer node's own
`routes_models.go` endpoint.

**Rationale**: `RequestJoin` already establishes the correct pattern for
node-to-node calls in this codebase: an `http3.Transport` with the caller's
mTLS client config, a JSON request body, and explicit, narrow retry
semantics for one specific expected failure class (there, a 409
"not yet leader"; here, the analogous transient case is a target node that
is mid-failover or briefly unreachable — see spec.md's Edge Cases). Reusing
this pattern is both a Constraints requirement (FR-015: no second transport
mechanism) and simply the correct engineering choice — it is already proven
correct against this project's actual mTLS certificate setup (T049's
documented SAN-verification investigation).

**Alternatives considered**: Routing model-lifecycle forwarding through the
Raft log itself (as an FSM-applied command, like locks) was considered and
rejected — a model start/stop is a real side-effecting operation against a
live `bin/llmctl` subprocess on one specific node, not a piece of replicated
state; forcing it through Raft `Apply` would make every node's FSM
responsible for triggering local subprocess execution as a side effect of
log replication, which is a correctness and blast-radius hazard the
existing design deliberately avoids (the FSM is documented as applying pure
state mutations only).
