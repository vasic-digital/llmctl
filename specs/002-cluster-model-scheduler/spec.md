# Feature Specification: Cluster-Wide Model-Placement Scheduling

**Feature Branch**: `002-cluster-model-scheduler`

**Created**: 2026-09-15

**Status**: Draft

**Input**: User description: "Cluster-wide model-placement scheduling: llmctld nodes today only dispatch model start/stop/status to the specific node targeted by the API caller (T072-FU4's disclosed boundary - no cross-node request forwarding, no automatic node selection). This feature adds a cluster-aware scheduler that, given a model-start request without a specific node pinned, selects which node in the cluster should run it based on each node's advertised capacity/budget (RAM/VRAM per the existing local scheduler budget model), forwards the start/stop/status request to that node over the existing cluster HTTP API, and reports back a unified view. Must build on existing internal/replication (WAL/state), internal/api routes, internal/auth RBAC, internal/isolation tenant scoping, and the existing cluster bootstrap/join mechanism in cmd/llmctld - no reinventing what already exists."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a model without knowing which node has room (Priority: P1)

An operator (or an automated caller acting on an operator's behalf) wants a
model profile running somewhere in the cluster. They do not want to manually
check every node's remaining memory/VRAM budget and guess which one has
room — they want to ask the cluster once and have it pick a node that can
actually run the model, honoring the same budget-refusal guarantee llmctl
already gives on a single node.

**Why this priority**: This is the entire reason the feature exists — it is
the disclosed gap called out when the single-node model-lifecycle API
shipped. Without it, cluster mode still requires an operator to manually
target a node, which defeats the purpose of running a cluster at all.

**Independent Test**: Can be fully tested by joining two or more nodes into a
cluster, submitting a start request that does not name a node, and
confirming the model ends up running on a node that had sufficient budget —
delivering value on its own even before stop/status are cluster-aware.

**Acceptance Scenarios**:

1. **Given** a cluster of 3 nodes where only node B currently has enough free
   RAM+VRAM for the requested profile, **When** an operator submits a start
   request naming the profile but no node, **Then** the model starts on node
   B and the response identifies node B as the node that accepted the work.
2. **Given** a cluster where every node's advertised remaining budget is
   smaller than the requested profile's footprint, **When** an operator
   submits a start request with no node named, **Then** the request is
   refused with the same exact-numbers budget-refusal message the
   single-node scheduler already gives, listing the shortfall against every
   considered node rather than silently picking one anyway.
3. **Given** an operator submits a start request that DOES name a specific
   node, **When** that node has room, **Then** the request is dispatched to
   that exact node exactly as it is today, with no cluster-wide placement
   decision involved.

---

### User Story 2 - See where things are running and stop/query them without hunting node-by-node (Priority: P2)

An operator who does not remember (or was never told) which node a given
profile landed on wants to check its status or stop it by name alone, and
wants one combined view of what is running across the whole cluster rather
than having to query every node in turn.

**Why this priority**: Placement without visibility is only half the
feature — an operator who used User Story 1 to start something needs an
equally simple way to find and manage it afterward, and a cluster operator
generally wants a single-pane view of the fleet.

**Independent Test**: Can be fully tested by starting a profile via User
Story 1 on an unspecified node, then issuing a status query and a stop
request by profile name alone (no node named) and confirming both correctly
resolve to the node actually running it, plus a cluster-wide status query
that lists every profile running on every node in one response.

**Acceptance Scenarios**:

1. **Given** a profile is running on node B (placed automatically or
   explicitly), **When** an operator queries status for that profile by name
   without naming a node, **Then** the response reports the real state from
   node B, identifying which node it came from.
2. **Given** a profile is running on node B, **When** an operator sends a
   stop request for that profile by name without naming a node, **Then** the
   stop is delivered to node B and the response confirms which node was
   stopped.
3. **Given** a cluster of multiple nodes each running different profiles,
   **When** an operator requests the cluster-wide status view, **Then** the
   response lists every currently-running profile together with the node it
   is running on, in one call.

---

### User Story 3 - Placement decisions are auditable and safe under concurrent requests (Priority: P3)

A cluster operator wants confidence that two simultaneous start requests for
different profiles cannot both be placed on the same node in a way that
double-books its budget, and wants every placement decision to be traceable
after the fact (which node was chosen, why, and what the considered
alternatives were).

**Why this priority**: Placement correctness under concurrency and
after-the-fact auditability are what make the feature trustworthy enough to
run unattended; without them, User Stories 1 and 2 could silently
overcommit a node or leave an operator unable to explain a placement
decision during an incident.

**Independent Test**: Can be fully tested by firing multiple concurrent
start requests that only fit on the cluster if placed on different nodes,
confirming none are double-booked onto a node that lacks room, and by
confirming each placement decision is recorded with enough detail to
reconstruct why that node was chosen.

**Acceptance Scenarios**:

1. **Given** two start requests are submitted at nearly the same time, each
   for a profile that only one specific node in the cluster has room for,
   **When** both are processed, **Then** both succeed and land on their
   respective correct nodes, with no window in which both could have been
   placed on the same over-budget node.
2. **Given** a placement decision has been made, **When** an operator later
   inspects the record of that decision, **Then** they can see which node
   was chosen, what each considered node's advertised budget was at
   decision time, and why the chosen node was selected over the others.

---

### Edge Cases

- What happens when a node that was considered eligible for placement goes
  offline or stops advertising its budget between the placement decision and
  the moment the start request is actually delivered to it? The system must
  detect the delivery failure and either retry placement against a
  different eligible node or fail the request with a clear, distinguishable
  reason (not the generic budget-refusal message, since this is a
  different failure class) — never silently report success.
- What happens when a profile with the same name is already running on more
  than one node (e.g., started explicitly on two nodes before this feature
  existed, or during a migration/incident)? A profile-name-only status or
  stop request must not silently act on only one of them and hide the
  other — it must report every node running that name.
- What happens when the cluster's membership changes (a node joins or
  leaves) while a placement decision is being made? The decision must use a
  single consistent snapshot of cluster membership and per-node budget, and
  must never place work on a node it did not consider eligible.
- What happens when every node in the cluster is temporarily unreachable at
  the moment a start request arrives? The request is refused with a clear
  "cluster unreachable" reason, distinguishable from a budget refusal.
- What happens when a tenant-scoped start request is submitted and the
  tenant is restricted (see FR-011) to a subset of nodes that all lack
  room? The refusal must state that the shortfall was evaluated only against
  that tenant's eligible nodes, not the whole cluster, so the operator is
  not misled into thinking cluster-wide capacity was exhausted.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST accept a model-start request that identifies a
  profile but does not identify a specific node, and MUST select an
  eligible node on the caller's behalf rather than requiring the caller to
  name one.
- **FR-002**: The system MUST continue to accept a model-start request that
  explicitly names a specific node, and MUST dispatch to exactly that node
  without invoking cluster-wide placement — the existing single-node
  behavior is preserved unchanged for callers who already pin a node.
- **FR-003**: When selecting a node automatically, the system MUST only
  consider nodes whose currently-advertised remaining capacity (the same
  RAM/VRAM budget accounting the single-node scheduler already uses) is
  sufficient for the requested profile's footprint.
- **FR-004**: When no node in the eligible set has sufficient remaining
  capacity, the system MUST refuse the request and MUST report, for every
  node it considered, the exact shortfall (requested vs. available),
  matching the specificity of the existing single-node budget-refusal
  message rather than a generic error.
- **FR-005**: The system MUST prevent two concurrently-processed placement
  decisions from both selecting the same node for work that would jointly
  exceed that node's remaining capacity — placement and the corresponding
  capacity reservation MUST be atomic with respect to each other.
- **FR-006**: The system MUST accept a status query for a profile by name
  alone (no node specified) and MUST return the real, current status from
  the node(s) actually running that profile, identifying which node each
  result came from.
- **FR-007**: The system MUST accept a stop request for a profile by name
  alone (no node specified) and MUST deliver the stop to the node(s)
  actually running that profile, reporting which node(s) were stopped.
- **FR-008**: If a profile name is found running on more than one node at
  the moment of a name-only status or stop request, the system MUST report
  or act on every node running it — never silently limit the result to one.
- **FR-009**: The system MUST provide a cluster-wide status view that lists,
  in a single response, every profile currently running across every node
  in the cluster together with the node each is running on.
- **FR-010**: If a node becomes unreachable after being selected for
  placement but before the start request is confirmed delivered and
  accepted by that node, the system MUST detect the failure and either
  retry placement against a different currently-eligible node or fail the
  request with a reason distinguishable from a budget refusal — it MUST
  NOT report the request as started when it was not.
- **FR-011**: Cluster-wide placement, status, and stop operations MUST
  respect the same tenant-scoping and authorization rules the existing
  single-node model-lifecycle API already enforces — a caller MUST NOT be
  able to discover, start, stop, or query a profile on behalf of a tenant it
  is not authorized for, and (per the resolved scope in FR-012) a tenant's
  eligible node set for automatic placement MUST be limited according to
  that tenant's configured node affinity/restriction, when one exists.
- **FR-012**: When multiple eligible nodes all have sufficient remaining
  capacity for a placement decision, the system MUST select among them
  using a best-fit strategy: the node that would be left with the least
  proportional slack across every tracked capacity dimension (RAM, VRAM,
  CPU, network) after the new profile lands is chosen, minimizing
  fragmentation of the cluster's remaining capacity. (This strategy is
  already implemented and tested in the codebase's existing bin-packing
  selection logic; this feature reuses it as-is rather than replacing it
  with a different strategy such as load-spreading.)
- **FR-013**: The system MUST NOT change where an already-running profile is
  placed once it has been started — placement is decided once, at start
  time, from a fresh evaluation of cluster state at that moment; there is
  no persistent "pinned" placement cache consulted for future decisions,
  and no automatic rebalancing or migration of already-running profiles.
- **FR-014**: Every automatic placement decision MUST be recorded with
  enough detail to reconstruct, after the fact: which node was chosen, the
  advertised remaining capacity of every node considered at decision time,
  and the reason the chosen node was selected over the alternatives.
- **FR-015**: The system MUST use the cluster's existing node-to-node
  communication and cluster-membership mechanisms to discover eligible
  nodes and forward requests — it MUST NOT introduce a second, parallel
  cluster-membership or transport mechanism alongside the one the cluster
  already uses for bootstrap/join.

### Key Entities *(include if feature involves data)*

- **Placement Decision**: A single automatic node-selection outcome for one
  start request. Represents which profile was requested, which node was
  chosen, the snapshot of every considered node's advertised remaining
  capacity at decision time, and the reason the winning node was chosen.
  Immutable once recorded.
- **Node Capacity Snapshot**: A point-in-time view of one node's advertised
  remaining RAM/VRAM budget, used as an input to a placement decision.
  Reused from the existing single-node scheduler's budget accounting; not a
  new capacity-tracking mechanism.
- **Cluster-Wide Running-Profile Index**: The aggregate view, across every
  node, of which profiles are currently running and on which node(s) — the
  data that answers a name-only status/stop request and the cluster-wide
  status view.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can start a model profile on a multi-node cluster
  without specifying which node, and the profile ends up running on a node
  that genuinely had sufficient capacity, in 100% of cases where at least
  one eligible node had room.
- **SC-002**: When no node in the cluster has sufficient capacity for a
  requested profile, the operator receives a refusal that names the exact
  shortfall for every considered node, with zero cases of the request being
  silently accepted onto an over-budget node.
- **SC-003**: An operator can query or stop a running profile by name alone,
  without knowing in advance which node it landed on, and receive a correct
  result identifying the actual node, in 100% of cases where the profile is
  genuinely running somewhere in the cluster.
- **SC-004**: Under concurrent start requests that only jointly fit the
  cluster if placed on different nodes, zero requests are placed in a way
  that double-books a single node's capacity.
- **SC-005**: Every automatic placement decision can be reconstructed after
  the fact — which node was chosen and why — without needing to
  re-interrogate live node state, in 100% of cases.

## Assumptions

- The existing single-node scheduler's RAM/VRAM budget-accounting model
  (the same one that already produces exact-numbers refusals on one node)
  is reused as-is for evaluating a node's eligibility; this feature does not
  redefine or replace that accounting.
- The existing cluster bootstrap/join mechanism already gives every node in
  the cluster a way to discover its peers and communicate with them over an
  authenticated channel; this feature reuses that channel rather than
  introducing a new one (per FR-015).
- The existing replication/state layer already gives the cluster a way to
  keep a shared, eventually-consistent view of state across nodes; the
  cluster-wide running-profile index and the placement-decision record are
  built on that existing layer rather than a new independent store.
- The existing authorization/tenant-scoping rules already enforced on the
  single-node model-lifecycle API are the correct rules to enforce
  identically here; this feature does not introduce new permission
  concepts, only extends the existing ones to cluster-wide operations.
- "Automatic placement" only applies to a request that does not name a
  node. A caller that already knows exactly which node it wants (the
  existing behavior) is never second-guessed or overridden by the
  scheduler.
- Rebalancing or migrating an already-running profile to a different node
  after the fact is explicitly out of scope for this feature (see FR-013);
  it may be considered as a separate, later feature.
- Node capacity advertising is reused from whatever mechanism the cluster
  already uses to know a peer node is alive and to learn its resource
  state; this feature does not invent a new heartbeat/health-check
  protocol.
- **Investigation finding (confirmed by reading the real source, not
  assumed)**: the node-selection (bin-packing) engine itself, a health
  monitor that can detect a node going unhealthy and trigger
  re-placement, and a multi-shard placement planner for oversized profiles
  already exist in the codebase, are already tested, and are already
  documented as reusable-as-is. What does NOT yet exist anywhere in the
  running system is (a) any real node ever actually registering itself
  and its resource capacity into the cluster's shared, replicated node
  registry — today that registry is populated only inside unit tests, and
  a real running cluster's registry is always empty — and (b) any record
  of which node is currently running which profile. Both of those are
  genuinely new work this feature must build, not merely wire together;
  the node-selection/health/sharding engine is the one part of this
  feature that is already done.
