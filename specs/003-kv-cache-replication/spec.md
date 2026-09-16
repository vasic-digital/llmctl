# Feature Specification: Cross-Node KV-Cache Replication via Real File Transfer

**Feature Branch**: `003-kv-cache-replication`

**Created**: 2026-09-15

**Status**: Draft

**Input**: User description: "Cross-node KV-cache replication via real file transfer: T060's disclosed boundary. Today internal/replication's WAL/checkpoint tracks a REPLAYABLE TOKEN SEQUENCE per conversation, not the real llama-server engine's actual attention-weight KV cache bytes - confirmed real llama-server exposes a genuine /slots/:id_slot?action=save|restore HTTP endpoint but it requires --slot-save-path and writes to the SERVER's own local disk, never wired anywhere in bin/llmctl/lib/*.sh today. Separately, T062's own disclosed gap: no daemon-side background mechanism yet automatically forwards a primary node's live WAL appends/checkpoints to replica nodes - today only a test harness manually calls all 3 nodes' HTTP replication routes to fan out state; llmctld's cmd/llmctld/main.go has zero automatic replication-forwarding loop. This feature must (1) build the daemon-side auto-forwarding of the existing internal/replication WAL/checkpoint state from whichever node is primary for a given tenant/conversation to every replica, and (2) wire the real llama-server engine's --slot-save-path + save/restore HTTP endpoint so that after a failover the new primary's real inference server process can warm-restore its actual attention-weight KV cache instead of only replaying the abstract token sequence from scratch, including transferring the real slot-cache file to the new primary node when it differs from where the file was written."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A conversation survives its primary node dying, automatically (Priority: P1)

An operator is running a model on a 3+ node cluster. A user's in-progress
conversation is being served by whichever node currently holds the
"primary" role for it. That node crashes or is taken down. Without any
operator intervention, and without the operator having to run a manual
fan-out step, the conversation's state has already been present on the
other nodes before the crash, so the newly-elected primary can pick up
exactly where the conversation left off.

**Why this priority**: This is the literal difference between "the
replication mechanism exists and was proven once in a test that manually
did the forwarding" and "the replication mechanism actually runs, all the
time, as part of the cluster daemon" — without it, failover state recovery
is a demonstrated capability that isn't actually switched on in the
running system.

**Independent Test**: Can be fully tested by starting a conversation on a
3-node cluster, confirming (via each node's own real state) that its
history is already present on every node BEFORE any failure happens (no
test-side manual replication calls needed), then killing the primary and
confirming the new primary already has the state.

**Acceptance Scenarios**:

1. **Given** a conversation is being appended to on its primary node,
   **When** each append happens, **Then** every other node in the cluster
   genuinely receives that same append shortly afterward, without any
   external caller having to individually call each node.
2. **Given** a primary node is periodically checkpointing a conversation,
   **When** a checkpoint happens, **Then** every replica node genuinely
   receives that checkpoint the same way.
3. **Given** the primary node is killed the instant after an append lands
   only on the primary (before the automatic forwarding could complete),
   **When** a new primary is elected, **Then** the system reports how much
   (if any) of that most-recent append is missing, rather than silently
   presenting a truncated conversation as if nothing were lost.

---

### User Story 2 - A resumed conversation starts warm, not cold (Priority: P2)

An operator whose cluster runs a real, long-context conversation cares
about resumption speed, not just resumption correctness: after a failover,
they want the new primary's actual inference engine to pick up from a real
warm cache when one is available, rather than always having to
recompute the entire conversation's attention state from the replayed
token history before it can serve the next response.

**Why this priority**: Once User Story 1 guarantees the conversation's
history is not lost, this story is about how expensively it is recovered.
It is valuable but strictly secondary to not losing data at all, and it
depends on the engine actually being asked to run with the right
configuration.

**Independent Test**: Can be fully tested by having a real inference
engine save its real cache file, killing the node it was running on,
confirming the file is available to whichever node the conversation
resumes on, and measuring that recovery there is faster than recomputing
from the full replayed history.

**Acceptance Scenarios**:

1. **Given** a real inference engine process is configured to save its own
   cache to disk, **When** a checkpoint is taken, **Then** a real save of
   the engine's actual cache happens, not only the abstract replayable
   token-sequence checkpoint from User Story 1.
2. **Given** a failover moves a conversation to a different node than the
   one that produced the real engine cache file, **When** the new primary
   starts serving that conversation, **Then** the real cache file is
   transferred to (or made available at) the new node before the engine
   is asked to warm-restore from it.
3. **Given** the real cache file is unavailable, corrupted, or the
   transfer failed, **When** the new primary needs to serve the
   conversation, **Then** it falls back to recomputing from the
   replayed token-sequence checkpoint (User Story 1's guarantee) rather
   than failing the conversation outright — a real warm-restore is a
   performance optimization, never a correctness dependency.

---

### User Story 3 - An operator can see replication health and lag (Priority: P3)

An operator wants to know, for any given conversation, whether its state
is genuinely caught up across the cluster right now, or how far behind any
replica is — so they can judge how much would be at risk if the primary
failed at this exact moment.

**Why this priority**: Visibility into replication health is what turns
"we believe replication is working" into "we can show it is working, and
by how much margin" — valuable for operating the system with confidence,
but it does not itself change what data survives a failure.

**Independent Test**: Can be fully tested by deliberately slowing down (or
temporarily blocking) forwarding to one replica, then querying the
replication-health view and confirming it reports that replica's real lag.

**Acceptance Scenarios**:

1. **Given** every replica is fully caught up, **When** an operator queries
   replication health for a conversation, **Then** the response shows zero
   lag for every node.
2. **Given** one replica has fallen behind (network slowness, temporary
   unreachability), **When** an operator queries replication health,
   **Then** the response identifies exactly which replica is behind and by
   how much.

---

### Edge Cases

- What happens when the primary role for a conversation changes (a new
  node becomes primary through normal cluster reconciliation, not just
  failure) while forwarding is in flight? The system must never have two
  nodes simultaneously believing they are the authoritative forwarding
  source for the same conversation in a way that could apply the same
  append twice or in conflicting order.
- What happens when a replica is unreachable when a forwarding attempt is
  made? The attempt must be retried (bounded, not indefinitely blocking
  the primary's own ability to keep serving the conversation) and the
  replica's lag must become visible (User Story 3) rather than silently
  dropped.
- What happens when the real engine's cache-save file is very large and
  the failover needs to happen quickly? The system must not make
  correctness (User Story 1) wait on a slow, large-file transfer —
  correctness recovery proceeds from the replayed token sequence
  immediately, and the warm-restore optimization (User Story 2) completes
  independently, potentially after the conversation is already being
  served (a "warm it up in the background, upgrade transparently when
  ready" pattern), never blocking the user-visible recovery.
- What happens if the real engine's cache-save/restore mechanism is
  unavailable for a given model or platform (e.g., the engine binary in
  use does not support it)? The system must fall back to User Story 1's
  guarantee alone and report the warm-restore optimization as
  unavailable for that model, never silently pretending it happened.
- What happens when a node is both a replica for one conversation and the
  primary for another at the same time? Both roles must be handled
  correctly and independently — there is no assumption that a node has
  exactly one role at a time.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST automatically forward every append to a
  conversation's replicated state from its primary node to every replica
  node, without requiring any external caller to individually contact each
  node.
- **FR-002**: The system MUST automatically forward every checkpoint of a
  conversation's replicated state from its primary node to every replica
  node, the same way.
- **FR-003**: Automatic forwarding MUST begin the moment a node becomes
  primary for a conversation and MUST require no manual operator step to
  activate — it is a standing, always-on behavior of the running cluster
  daemon, not a capability that exists only when explicitly invoked.
- **FR-004**: If an append or checkpoint cannot be forwarded to a
  particular replica (the replica is unreachable, or the attempt times
  out), the system MUST retry within a bounded budget and MUST NOT let a
  slow or unreachable replica block the primary from continuing to serve
  the conversation to its user.
- **FR-005**: If the primary node fails before a given append or
  checkpoint was successfully forwarded anywhere, the system MUST make
  the resulting gap detectable (the newly-elected primary's state, and
  any operator-facing report, must reflect exactly what was and was not
  successfully replicated) — it MUST NOT silently present a
  possibly-incomplete conversation as if it were guaranteed complete.
- **FR-006**: The system MUST allow the real underlying inference engine
  to save its own actual cache to disk as a genuine, distinct capability
  from the replayable token-sequence checkpoint (User Story 1) — this
  capability is additive, never a replacement for the token-sequence
  mechanism.
- **FR-007**: When a conversation's primary role moves to a different node
  than the one that produced a real engine cache file, and that real
  file exists and is intact, the system MUST make it available at the new
  node before asking the engine there to warm-restore from it.
- **FR-008**: The real engine cache warm-restore path MUST be strictly
  optional for correctness: if the real cache file is missing, corrupted,
  fails to transfer, or the engine/model in use does not support this
  capability, the system MUST still recover the conversation correctly via
  the replayed token-sequence checkpoint (User Story 1), and MUST report
  the warm-restore attempt's outcome (succeeded / fell back / unsupported)
  rather than silently reporting only success or only failure.
- **FR-009**: The system MUST NOT let the presence or absence of a real
  engine cache file affect how quickly a failed-over conversation becomes
  available to its user — correctness recovery (User Story 1) proceeds
  immediately; the warm-restore optimization (User Story 2) MAY complete
  afterward without delaying user-visible availability.
- **FR-010**: The system MUST provide an operator-facing way to see, for
  any given conversation, whether every replica is currently caught up,
  and if not, which replica is behind and by how much.
- **FR-011**: At any point in time, exactly one node MUST be recognized as
  the authoritative forwarding source for a given conversation's state —
  the system MUST prevent two nodes from simultaneously believing they are
  both the forwarding source for the same conversation in a way that could
  produce duplicate or conflicting appends on a replica.
- **FR-012**: All cross-node forwarding and cache-file transfer described
  by this feature MUST use the cluster's existing authenticated node-to-node
  communication channel — this feature MUST NOT introduce a second,
  parallel transport mechanism for moving this data between nodes.
- **FR-013**: Every automatic-forwarding and cache-transfer operation MUST
  respect the same tenant-scoping and authorization rules the existing
  per-tenant replication API already enforces — a node MUST NOT be able to
  push or pull another tenant's conversation state across a trust boundary
  it is not authorized for.

### Key Entities *(include if feature involves data)*

- **Forwarding Assignment**: The record of which node currently holds the
  authoritative "primary, forward from here" role for a given
  conversation, and which nodes are its current replicas. Changes when the
  cluster's placement/health mechanism reassigns a conversation (e.g.,
  after the previous primary is detected unhealthy).
- **Replication Lag Record**: For a given conversation and replica, how far
  behind that replica's last-confirmed-received state is from the
  primary's current state — the data User Story 3's visibility requirement
  is built from.
- **Engine Cache File**: The real, engine-produced artifact representing
  an inference engine's actual in-memory cache for one conversation,
  saved to disk by the engine itself, distinct from and additional to the
  replayable token-sequence checkpoint. Has a location (which node/path it
  currently resides at) and a validity state (intact / stale / unavailable).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After a primary node is killed with no manual intervention
  and no external test-side forwarding calls, the newly-elected primary's
  conversation state matches what was durably confirmed on the killed
  node before it died, in 100% of cases where forwarding had genuinely
  caught up.
- **SC-002**: An operator can determine, for any conversation, whether
  every replica is currently caught up or exactly how far behind a
  specific replica is, without needing to separately inspect that
  replica's own internal state.
- **SC-003**: A conversation recovered after failover becomes available to
  its user without waiting on the availability, size, or transfer time of
  a real engine cache file — recovery latency is governed only by the
  replayed token-sequence checkpoint path.
- **SC-004**: When a real engine cache file for a conversation is
  available and intact at failover time, resuming that conversation with
  it measurably reduces the engine's own time-to-first-response compared
  to recomputing from the full replayed history, for conversations long
  enough that recomputation is not already near-instant.
- **SC-005**: At no point does the system report a conversation as fully
  and durably replicated when a gap genuinely exists — every reported
  "caught up" state is real, and every real gap is reported.

## Assumptions

- The existing `internal/replication` package's WAL + checkpoint
  abstraction (a replayable token-sequence model, deliberately NOT a raw
  copy of engine-internal memory — a design choice already made and
  documented in the existing codebase) remains the correctness-bearing
  mechanism this feature builds automatic cross-node forwarding for; this
  feature does not redesign that abstraction.
- The real inference engine's own save/restore capability (confirmed to
  exist as a genuine HTTP mechanism in the vendored engine source, gated
  behind an explicit engine configuration flag that is not wired anywhere
  in this project today) is reused as-is; this feature does not modify
  the engine itself, only wires the existing capability in and transfers
  its output file between nodes.
- "Primary" and "replica" roles for a conversation are assigned by the
  cluster's existing placement/health mechanism (the same mechanism that
  already elects which node handles a workload and detects node failure);
  this feature does not invent a second, competing notion of node roles.
- The existing cluster node-to-node authenticated communication channel is
  sufficient for both small state-forwarding messages (appends,
  checkpoints) and larger file transfers (the real engine cache file);
  this feature does not require a separate bulk-transfer mechanism beyond
  what already exists.
- This feature is scoped to a single conversation's KV-cache-adjacent
  state; cluster-wide model-placement scheduling (which node runs a given
  model at all) is a separate, already-tracked concern this feature does
  not redefine.
- A bounded, retried-but-not-indefinite forwarding attempt is the correct
  default for replica unreachability; an operator-configurable retry
  budget, if ever needed, is a refinement left for a future iteration
  rather than blocking this feature's initial scope.
- **Investigation finding (confirmed by reading the real source, not
  assumed)**: the existing replicated-state storage's actual granularity
  is one stream PER TENANT, not per individual conversation — a tenant's
  replicated token sequence has no conversation identifier of its own
  today. Every "conversation" reference in this spec's scenarios refers to
  a tenant's ongoing replicated stream as it exists today; this feature
  does not introduce a finer per-conversation granularity than the
  storage layer already has. A tenant that genuinely runs multiple
  concurrent independent conversations sharing one replicated stream is a
  pre-existing scope boundary of the storage layer itself, not something
  this feature changes or is required to fix.
