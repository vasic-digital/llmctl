# Phase 0 Research: Cross-Node KV-Cache Replication via Real File Transfer

No `[NEEDS CLARIFICATION]` markers remain. Decisions below were resolved by
reading the real source before writing the plan.

## Decision 1: The replicated-state granularity is per-tenant, not per-conversation

**Decision**: Design forwarding, role-assignment, and lag-tracking around
one `replication.Store` per tenant — the real, existing unit — rather than
inventing a new per-conversation identifier the storage layer does not
have.

**Rationale**: `WALEntry{Seq, TokenID, Position}` (`wal.go`) carries no
conversation ID; `StoreRegistry.Get(tenantID)` (`registry.go`) is the only
existing key. Introducing a finer unit than the storage layer already has
would require redesigning `internal/replication`'s schema, which is
explicitly out of this feature's scope (plan.md Constraints: MUST NOT
change the existing WAL/checkpoint binary format).

**Alternatives considered**: Adding a conversation ID to `WALEntry` was
considered and rejected — it would be a breaking schema change to a
package with 24+ already-passing tests (T059-T064) for a capability
(per-conversation isolation within one tenant) the spec does not actually
require; if a tenant needs multiple genuinely independent conversations,
that is a pre-existing, separately-scoped storage-layer limitation.

## Decision 2: A new, small piece of Raft-replicated state for primary/replica role assignment

**Decision**: Add a per-tenant "who is currently the forwarding primary,
who are the current replicas" record to the cluster's existing
Raft-replicated state, applied via new FSM commands, exactly as
002-cluster-model-scheduler's own new state (node registry, running-profile
index) is added.

**Rationale**: No existing structure models this. `cluster.ReplicaState`
(from `internal/cluster/placement.go`, T052a) models MODEL-instance
replica counts (`{Model, TargetCount, LiveNodeIDs}`), a different concern
(how many copies of a MODEL are running) from "which node currently owns
forwarding this TENANT's replicated stream." Reusing the Raft FSM
mechanism (rather than inventing a second consensus/replication channel)
is required by spec.md FR-012 and is the same reasoning
002's research.md Decision 2 already established for this codebase.

**Alternatives considered**: Deriving "primary" implicitly from whichever
node currently hosts the tenant's model instance (reusing `Place()`'s
placement decision from 002, if that feature has landed) was considered.
Rejected as the SOLE mechanism, because a tenant's replicated stream can
outlive any single model-hosting decision (the whole point of surviving a
model-instance failover is that the STREAM continues even though the model
instance moved) — but NOTED as the natural DEFAULT initial assignment
(when a new primary must be chosen after a failure, prefer the node the
model instance actually failed over to, if 002's placement decision
already picked one) rather than a fully independent selection process,
avoiding two uncoordinated node-selection mechanisms disagreeing with each
other.

## Decision 3: Engine cache save/restore is real, exists, and is unwired — confirmed, not assumed

**Decision**: Wire `--slot-save-path` + the engine's own
`/slots/:id_slot?action=save|restore` HTTP endpoint as this feature's User
Story 2 mechanism, exactly as T060's own investigation already found it.

**Rationale**: T060's investigation (a forked research agent reading the
real vendored `submodules/llama.cpp` source, pinned tag) found the real
capability at `tools/server/server.cpp:285-286`/`server-context.cpp:5288-5320`+.
Re-confirmed for this feature: no `lib/*.sh` file passes `--slot-save-path`
today. This is genuinely new wiring, not a re-verification of already-done
work.

**Alternatives considered**: Building a custom llmctld-side KV-cache
snapshot mechanism (reading the engine process's memory directly) was
considered and rejected — it would violate the project's own documented
control-plane/data-plane split (`wal.go`'s own doc comment: "the inference
engine is always a separate OS process reached only via its OpenAI-
compatible HTTP API... never something llmctld can memory-snapshot
directly"), and the engine already exposes a purpose-built HTTP mechanism
for exactly this.

## Decision 4: Engine-cache warm-restore is strictly non-blocking for correctness

**Decision**: The real engine cache file's availability/transfer/restore
NEVER gates when a failed-over conversation becomes available to its user
(spec.md FR-009); it is an asynchronous upgrade path.

**Rationale**: The engine cache file can be arbitrarily large (a real
binary snapshot of engine memory) while the abstract token-sequence
checkpoint (already proven fast in T062's real measurement: 5000 tokens
replicated+checkpointed to 3 nodes in 757ms) is not. Making user-visible
recovery wait on the larger, slower artifact would make the OPTIMIZATION
(User Story 2) actively worse for the user than not having it, which
would contradict the entire reason User Story 2 exists.

**Alternatives considered**: Synchronous engine-cache-file-first recovery
(restore from the real file when present, only fall back to token-replay
when it's missing) was considered and rejected precisely because it makes
recovery latency depend on file-transfer time in the common case — the
opposite of what SC-003 requires.
