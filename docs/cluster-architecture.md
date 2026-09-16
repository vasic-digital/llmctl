# Cluster Architecture (`llmctld`)

**Revision:** 4
**Last modified:** 2026-09-16T00:00:00Z

`llmctld` is an **opt-in** Go daemon (Gin Gonic, HTTP/3/QUIC, Brotli
compression) that will provide distributed multi-host scheduler
coordination, Raft consensus, KV-cache replication, JWT/RBAC auth, and
tamper-evident audit logging (spec.md FR-039/FR-040/FR-041, Clarification
9/10/11). **Single-host `bin/llmctl` bash CLI is completely unmodified and
never depends on `llmctld`** — the daemon is only consulted when cluster
mode is explicitly enabled (`llmctl cluster ...`), and `cluster::require_daemon`
hard-fails with an explicit error rather than silently falling back to
single-host scheduling when no daemon is reachable (Clarification 12).

## Honest implementation-status boundary (Constitution §11.4.6 — read this first)

This document diagrams BOTH what exists today AND what spec.md designs for
later phases. **Every diagram below is explicitly labeled** with one of two
states, and neither is presented as the other:

- **✅ IMPLEMENTED** — real Go code exists under `llmctld/internal/`, with
  passing tests, as of this session (verified via `find llmctld -name
  '*.go'`, which currently returns only: `cmd/llmctld/main.go` (a version-only
  stub), `internal/cluster/{state,state_test}.go`, `internal/raft/{fsm,fsm_test,testhelpers_test}.go`,
  `internal/mtls/{certs,certs_test}.go`, `internal/audit/{log,log_test}.go`).
- **📋 PLANNED (not yet implemented)** — described by spec.md's functional
  requirements and data model, but no Go code implements it yet. There is
  currently **no `internal/api/` package, no HTTP route of any kind, no
  JWT/RBAC code, no KV-cache/WAL/checkpoint code, and no tenant/quota code**
  in this repository. These diagrams show the DESIGNED shape so implementers
  in later phases (9, 10, 11) have a target — they are not a claim that any
  of this runs today.

## 1. Raft cluster topology — ✅ IMPLEMENTED (node membership) / 📋 PLANNED (scheduling coordination)

What's real today: `internal/raft.ClusterFSM` wraps `hashicorp/raft`
(Clarification 10 — no external etcd/consul) and implements the `Apply`
half of the FSM interface for exactly two command types,
`CommandJoinNode`/`CommandLeaveNode` (a closed set — an unrecognized command
type is rejected, never silently ignored). `Apply` is proven deterministic:
replaying the same log sequence into a fresh FSM always produces
byte-identical state (`TestApply_DeterministicGivenSameLogSequence`), which
is the correctness property every node's independent log replay depends on.
Snapshot/Restore round-trip correctly (proven by test). What's planned:
actual multi-node leader election, log replication over the network, and
scheduler-state coordination (which models run where) — `internal/raft`
today only exercises the FSM logic itself, in-process, against
`hashicorp/raft`'s library types; there is no running multi-node cluster.

```mermaid
flowchart TB
    subgraph "✅ Implemented: ClusterFSM (in-process, per-node)"
        LOG["Raft log entry<br/>Command{Type, Node, NodeID}"] --> APPLY["ClusterFSM.Apply<br/>(deterministic, closed command set)"]
        APPLY --> STATE["cluster.ClusterState<br/>{Nodes: map[ID]Node}"]
        STATE --> SNAP["Snapshot / Restore<br/>(round-trip proven by test)"]
    end
    subgraph "📋 Planned: multi-node consensus (Phase 9, US7)"
        N1["llmctld node 1<br/>(leader)"] -.Raft heartbeat.-> N2["llmctld node 2<br/>(follower)"]
        N1 -.Raft heartbeat.-> N3["llmctld node 3<br/>(follower)"]
        N2 -.replicated log.-> APPLY
        N3 -.replicated log.-> APPLY
    end
```

## 2. Node-to-node mTLS + client JWT auth flow — ✅ IMPLEMENTED (mTLS primitive, wired transport, JWT/RBAC, revocation, zero-downtime renewal, coordinated CA rotation) / 📋 OPEN (per-voter live-handshake trust confirmation for the FR-010 quorum check — see honest scope note below)

What's real today (Feature 004, Phases 1–5, full task list:
`specs/004-mtls-cert-rotation/tasks.md`): `internal/mtls.CA` is a
self-signed internal certificate authority (ECDSA P-256) that issues
per-node leaf certificates (`IssueNodeCert`); `internal/mtls.TrustStore` is
the live, mutex-protected verification data source both node-to-node Raft
transport (`internal/raft/transport.go`) and the HTTP/3 API server
(`internal/api/server.go`) read from on **every real TLS handshake** via
`GetCertificate`/`GetClientCertificate`/`VerifyPeerCertificate` — no static
`tls.Config` anywhere, so a revocation/renewal/CA-rotation update takes
effect for the very next connection attempt with zero process restart.
Client-facing auth is genuinely wired: every operator-facing route in
`internal/api/routes_mtls.go` (revoke, renew, rotate/begin,
rotate/status, rotate/finalize) is gated by `RequireJWT` +
`authz.Decider.CheckRBAC(..., auth.ActionMTLSManage, "mtls")`
(admin-only — `internal/auth/rbac.go`), reusing the SAME JWT/RBAC
mechanism `routes_tenants.go`/`routes_models.go` already established — this
is proven by a dedicated unit test
(`internal/api/routes_mtls_test.go`,
`TestMTLSRoutes_RequireAdminMTLSManageRole`) added during this feature's
own Phase 6 code review (T029) to close a coverage gap: every OTHER
RBAC-gated route family already had such a test, this one did not. The one
internal, peer-to-peer route (`POST /v1/cluster/mtls/rotate/transition`,
used only by the leader-forwarding fallback below) deliberately carries NO
JWT/RBAC gate — mirroring `routes_cluster.go`'s `join`/`leave` peer routes,
authenticated by the real mTLS handshake alone
(`TestMTLSRoutes_RotateTransition_IsPeerOnlyNotJWTGated`).

Certificate **revocation** (User Story 1, MVP) is a Raft-replicated,
cluster-wide fact: `CommandRevokeCertificate` is applied through the SAME
`hashicorp/raft` log every other command uses, and an event-handler
mechanism (`ClusterFSM.onRevocationApplied`, fired only AFTER `f.mu` is
released — a genuine self-deadlock was found and fixed here during Phase 3,
see `fsm.go`'s own doc comment) pushes the full current revoked-serial set
into every node's own `TrustStore.UpdateRevoked` — on EVERY node, including
one that was unreachable during the original `Apply` and only learns of it
via a Raft snapshot `Restore` on reconnect (T009). Revocation is
independent of cluster-membership eviction (T013/FR-012): a revoked node's
Raft-voter/membership entry is untouched.

**Zero-downtime renewal** (User Story 2) is answered entirely locally — no
Raft write at all, since there is nothing for the rest of the cluster to
durably agree on: `POST /v1/cluster/mtls/renew` issues two fresh certs from
the existing, unmodified `ca.IssueNodeCert` and swaps them into that node's
own two `TrustStore`s via `UpdateNodeCert`. Because `GetCertificate`/
`GetClientCertificate` are re-invoked fresh on every NEW handshake only, an
already-established `*tls.Conn`/HTTP-3 stream is structurally never torn
down by a renewal — proven empirically, not merely by code inspection, by
`TestMTLSRotation_LiveRenewal_ExistingConnectionSurvives` (a held
connection's `httptrace` reports `Reused=true` and an unchanged local
address across a real renewal).

**Coordinated CA rotation** (User Story 3) replaces the cluster's root of
trust without ever dropping below quorum, via dual trust
(`internal/mtls.RotationCAHolder`): `CommandBeginCARotation` /
`CommandFinalizeCARotation` durably record only a SHA-256 **fingerprint
hash** of each CA through Raft (never the certificate or key material — see
`data-model.md`'s `CARotationEvent` security note); the incoming CA's real
material is loaded per-node, out-of-band, via that node's own
`POST /rotate/begin` call — mirroring how `-ca-cert`/`-ca-key` are already
distributed at bootstrap. The SAME `onRevocationApplied` notify mechanism
T011 built for revocation is reused, forward-compatibly, for
`"finalized"` convergence (T023) — one handler mechanism, not two.
`quorumWouldBeStranded` (FR-010) is written once and shared by BOTH the
revoke action and the finalize action, refusing either one if it would
leave fewer than a strict majority of voters trusted. A genuine
find-and-fix concurrency defect from this feature's own T025 review is
disclosed here rather than smoothed over: a non-leader node's local
dual-trust activation on `begin` was not itself gated on Raft confirmation,
so two concurrent `begin` calls naming DIFFERENT incoming CAs could
locally diverge before Raft's own total ordering resolved which one wins;
this is narrowed (a pre-check against the currently-replicated
`CARotation` refuses an obviously-conflicting request on every node) but
NOT eliminated — a truly-simultaneous pair of requests, both reading
`node.State()` before either's Raft entry replicates, is resolved only by
Raft's own log ordering once replication catches up, per Constitution
§11.4.6's honest-boundary discipline.

**📋 OPEN (honest scope, disclosed rather than silently narrowed):**
`quorumWouldBeStranded`'s "which voters are currently trusted" input is
approximated from Raft voter configuration + the replicated
revocation/transition record, never from a live per-voter mTLS handshake —
a voter whose certificate was revoked and has SINCE been re-issued under a
different serial is not distinguished from a genuinely still-revoked
voter. This is conservative (it can only ever OVER-refuse a safe action,
never UNDER-refuse an unsafe one, per §11.4.101's reversible-safe-default
discipline) and is disclosed in `routes_mtls.go`'s own doc comments; a live
per-voter confirmation mechanism is not part of this feature's scope.

```mermaid
sequenceDiagram
    participant Op as Operator<br/>(admin JWT, mtls:manage)
    participant NA as Node A (Raft leader)
    participant Log as Raft log<br/>(hashicorp/raft, replicated)
    participant NB as Node B (follower)
    participant NC as Node C<br/>(previously partitioned/unreachable)

    Note over Op,NA: T012 - POST /v1/cluster/mtls/revoke
    Op->>NA: revoke(serial_number, node_id, reason)
    NA->>NA: RequireJWT + CheckRBAC(mtls:manage)
    NA->>NA: quorumWouldBeStranded? (FR-010, shared w/ finalize)
    NA->>Log: Apply(CommandRevokeCertificate)

    Note over Log,NC: single-threaded FSM.Apply, ClusterState.Revocations[serial]=rec
    Log-->>NA: committed + replicated
    Log-->>NB: committed + replicated

    Note over NA,NB: T011 - notify AFTER f.mu released (self-deadlock fix)
    NA->>NA: onRevocationApplied() -> TrustStore.UpdateRevoked (raft+api stores)
    NB->>NB: onRevocationApplied() -> TrustStore.UpdateRevoked (raft+api stores)

    Note over NC: T009 - NC was unreachable during the Apply above
    NC-->>Log: rejoins, catches up via Raft Snapshot Restore
    NC->>NC: Restore() ALSO fires onRevocationApplied (same handler, no polling)
    NC->>NC: TrustStore.UpdateRevoked - now current before NC serves any traffic

    Note over NA,NC: Every node's TrustStore.Verify now rejects the revoked serial<br/>cluster-wide, zero restart, independent of membership eviction (T013/FR-012)
```

```mermaid
sequenceDiagram
    participant Op as Operator<br/>(admin JWT, mtls:manage)
    participant NA as Node A (Raft leader)
    participant Log as Raft log<br/>(replicated ClusterState.CARotation)
    participant NB as Node B (follower)

    Note over Op,NA: T024 - POST /v1/cluster/mtls/rotate/begin (out-of-band CA material, per node)
    Op->>NA: begin(incoming_ca_cert_pem, incoming_ca_key_pem)
    NA->>NA: RequireJWT + CheckRBAC(mtls:manage)
    NA->>NA: T025 pre-check vs currently-replicated CARotation (narrows, does not eliminate, the concurrent-begin race)
    NA->>Log: Apply(CommandBeginCARotation) [leader-only write]
    Log-->>NB: replicated: CARotation{Status: in_progress, fingerprints}
    NA->>NA: rotationHolder.BeginLocalRotation(incomingCA) [outgoingCA kept]
    NA->>NA: TrustStore.UpdateTrustedCAs([outgoing, incoming]) - dual trust ACTIVE on Node A

    Note over Op,NB: Operator separately distributes the SAME incoming CA to Node B (out-of-band, mirrors -ca-cert/-ca-key bootstrap distribution)
    Op->>NB: begin(incoming_ca_cert_pem, incoming_ca_key_pem)
    NB->>NB: RequireJWT + CheckRBAC(mtls:manage)
    NB->>NB: not leader -> skips Raft Apply, cross-checks matching fingerprints already replicated
    NB->>NB: rotationHolder.BeginLocalRotation(incomingCA)
    NB->>NB: TrustStore.UpdateTrustedCAs([outgoing, incoming]) - dual trust ACTIVE on Node B

    Note over NA,NB: T016/Phase 5 - renewals during the transition issue under the INCOMING CA
    NB->>NB: POST /v1/cluster/mtls/renew -> IssueNodeCert via rotationHolder.IssuingCA() (= incoming)
    NB->>Log: RecordCARotationTransition(node-b) [forwarded to leader if NB is a follower, T020]
    Log-->>NA: CARotation.TransitionedNodeIDs += node-b

    Note over Op,NA: T024 - POST /v1/cluster/mtls/rotate/finalize (leader-only, FR-010 quorum-protection)
    Op->>NA: finalize()
    NA->>NA: RequireJWT + CheckRBAC(mtls:manage)
    NA->>NA: quorumWouldBeStranded(voters, not-yet-transitioned)? refuse (409) if so
    NA->>Log: Apply(CommandFinalizeCARotation) -> CARotation.Status = finalized
    Log-->>NB: replicated: CARotation.Status = finalized

    Note over NA,NB: T023 - onRevocationApplied fires on EVERY node (forward-compatible reuse of T011's mechanism)
    NA->>NA: rotationHolder.FinalizeLocalRotation() -> TrustStore.UpdateTrustedCAs([incoming]) - outgoing CA dropped
    NB->>NB: rotationHolder.FinalizeLocalRotation() -> TrustStore.UpdateTrustedCAs([incoming]) - outgoing CA dropped
```

Both diagrams above are real `mmdc`-rendered Mermaid sequence diagrams
(verified via `mmdc -i <file>.mmd -o <file>.svg`, exit 0, non-degenerate
SVG output cross-checked for the real function/type names each diagram
cites — Constitution §11.4.107(10)/§11.4.170) — not merely hand-typed
prose that looks plausible.

## 3. KV-cache WAL/checkpoint replication sequence — ✅ IMPLEMENTED (WAL + checkpoint + LoRA replication library) / 📋 OPEN (real engine-state integration + automatic daemon-side fan-out)

Per spec.md Clarification 7 / FR-026/FR-027/FR-028: KV cache replicates
**asynchronously** via a write-ahead log, with periodic checkpoints (every
N tokens, default 1000, or every T seconds, default 30s). On failover, the
new primary restores from the latest checkpoint and replays the WAL from
that point (target: ≤5% token loss, ≤30s recovery). LoRA adapters
replicate synchronously on creation and are captured as part of each
checkpoint.

**Honest scope boundary (Constitution §11.4.223 provenance markers).**
`internal/replication` (`wal.go`/`checkpoint.go`/`lora.go`) is real, TDD-tested
library code implementing the WAL + checkpoint + LoRA-adapter-replication
mechanics against a `KVState{Tokens, Positions []int32}` abstraction — the
REPLAYABLE TOKEN SEQUENCE, not raw engine-internal attention-weight bytes.
This is a deliberate, documented choice, not an oversight: llmctld's
control-plane/data-plane split means the real inference engine
(`llama.cpp`/`colibri`) always runs as a separate OS process, reached only
via its OpenAI-compatible HTTP API — never something llmctld can
memory-snapshot directly.

**A real, concrete future integration point exists and was found by
reading the actual vendored source** (`submodules/llama.cpp`, pinned at
`3f152073` / ~b10969): `llama-server` exposes a real HTTP endpoint,
`GET /slots` + `POST /slots/:id_slot?action=save|restore` (registered in
`tools/server/server.cpp:285-286`; handled by `handle_slots_save`/
`handle_slots_restore` in `server-context.cpp:5288-5320`+, dispatching
real `SERVER_TASK_TYPE_SLOT_SAVE`/`_RESTORE` tasks from a JSON body
`{"filename": "..."}`). The underlying C API also genuinely exists
(`llama_state_get_data`/`llama_state_set_data`/`llama_state_seq_save_file`/
`llama_state_seq_load_file`, declared in `include/llama.h:814-898`), but
those are C symbols in `libllama`, reachable only from a process linked
against it (i.e. `llama-server` itself) — not from a separate Go process
without cgo, which this project's architecture deliberately avoids.
**The real constraint**: the HTTP slot-save/restore endpoint writes its
artifact to `llama-server`'s OWN local disk (`--slot-save-path` must be
set at server startup) — the HTTP response returns only metadata (slot
id, filename, token counts), never the raw state bytes. Wiring this in
for genuine cross-node replication would require llmctld to (a) start
`llama-server` with `--slot-save-path` (an `internal/executor` extension),
(b) call the real save/restore HTTP endpoint, AND (c) transfer the
resulting local file to another node's disk out-of-band (rsync-class
mechanism) — real, buildable, but additional scope beyond what T059-T064
asked for. `submodules/colibri` (pinned `7a14d837` / v1.11.0+3) has no
comparable generic mechanism — only a narrow, Kimi-K3-specific,
single-process, single-host recurrent-state checkpoint feature
(`COLI_K3_CKPT`), not a cross-node replication primitive.

**Also 📋 OPEN**: automatic daemon-side fan-out (a running `llmctld`
process automatically forwarding its own WAL entries/checkpoints to
replica nodes as tokens are generated) is not wired into `cmd/llmctld`'s
`main.go` — `internal/replication`'s `Store`/`WAL` are correct, tested
library primitives with no live caller in the running binary yet, the
same honest-gap pattern already established for Phase 9's
`internal/cluster/health.go`/`placement.go`.

```mermaid
sequenceDiagram
    participant Client as CLI agent
    participant Primary as 📋 primary replica
    participant WAL as ✅ WAL (internal/replication, per-tenant dir)
    participant Replica as 📋 secondary replica

    Client->>Primary: token generated
    Primary->>WAL: ✅ Append(WALEntry{Seq, TokenID, Position})
    Primary-->>Replica: 📋 async replicate WAL entry (daemon-side fan-out not yet wired)
    Note over Primary,WAL: ✅ every N=1000 tokens OR T=30s (CheckpointConfig.ShouldCheckpoint)
    Primary->>Primary: ✅ Store.Checkpoint(seq, KVState) - LoRA via ReplicateAdapter
    Primary->>WAL: ✅ Truncate(uptoSeq) - bounded further by WAL.Size()/ShouldForceCheckpoint

    Note over Primary,Replica: failover scenario
    Primary--xReplica: primary fails
    Replica->>Replica: ✅ Store.Restore() - latest checkpoint
    Replica->>WAL: ✅ replay WAL entries since that checkpoint (deterministic fold)
    Replica->>Client: resume serving (target: <=5% token loss, <=30s recovery)
```

## 4. Control-plane / data-plane split (bash `llmctl` + Go `llmctld`) — ✅ IMPLEMENTED (the split + the hard-fail contract) / 📋 PLANNED (the data-plane operations themselves)

What's real today: the ARCHITECTURAL SPLIT itself is implemented and
tested. `bin/llmctl` (bash, single-host) is the CONTROL surface an operator
types commands into; when cluster mode is invoked (`llmctl cluster
join|leave|status`, `llmctl tenant ...`, `llmctl apikey ...`),
`cluster::require_daemon` checks for a reachable `llmctld` and hard-fails
with an explicit, actionable error (naming the daemon and how to restart
it) if none is reachable — proven live: with no daemon running,
`cluster::require_daemon` exits 1 with that exact message, and
`llmctl cluster status` hard-fails identically (both proven by direct
tests in Phase 2, T005/T006). This is the "never silently fall back to
single-host scheduling" guarantee from Clarification 12. `llmctl cluster
status` DOES make a real HTTP request (`cluster::request GET
/v1/cluster/status`) when a daemon IS reachable — but since `llmctld`
exposes no HTTP routes yet (no `internal/api/` package exists), that
request currently has nothing real to reach; `llmctl cluster join`/`leave`
and every `tenant`/`apikey` subcommand are real CLI stubs that immediately
`die` with `"llmctld reachable but '<command>' is not yet implemented
(Phase N, USx)"`.

```mermaid
flowchart TB
    subgraph "Control plane (bash, single-host, ✅ unmodified by any cluster work)"
        CLI["bin/llmctl<br/>setup / hw / plan / models / start / stop /<br/>switch / auto / status / logs / enable / disable"]
    end
    subgraph "Cluster surface (bash CLI stubs, ✅ implemented hard-fail contract)"
        CCLUSTER["llmctl cluster join/leave/status"]
        CTENANT["llmctl tenant create/list/quota"]
        CAPIKEY["llmctl apikey create/rotate"]
    end
    CCLUSTER --> REQUIRE{"cluster::require_daemon<br/>✅ implemented"}
    CTENANT --> REQUIRE
    CAPIKEY --> REQUIRE
    REQUIRE -->|"daemon unreachable"| HARDFAIL["✅ hard-fail: explicit error<br/>naming the daemon + how to restart it<br/>(NEVER silent single-host fallback)"]
    REQUIRE -->|"daemon reachable"| DATAPLANE

    subgraph "Data plane (Go daemon llmctld, 📋 mostly planned)"
        DATAPLANE{"HTTP/3 request"}
        DATAPLANE -->|"GET /v1/cluster/status"| NOROUTE["📋 no internal/api/ package yet<br/>- nothing real to reach"]
        DATAPLANE -->|"join/leave/tenant/apikey ops"| STUB["✅ CLI-side stub:<br/>die 'not yet implemented (Phase N, USx)'"]
        DATAPLANE -.->|"planned"| RAFTFSM["ClusterFSM<br/>(✅ the FSM itself exists,<br/>📋 not yet wired to an HTTP route)"]
    end
```

## 5. Tensor/model-parallelism sharding contract — ✅ IMPLEMENTED (placement hints) / 📋 OPEN (cross-node execution)

FR-022 requires tensor/model parallelism across nodes for models exceeding
a single node's VRAM; FR-024 requires model sharding across nodes for
models exceeding single-node capacity. This section documents the real,
honest split between what T057 implements and what it deliberately does
not, per Constitution §11.4.223 provenance-marker discipline.

```mermaid
flowchart TD
    subgraph "✅ Implemented: internal/cluster.PlanShards (placement-hint layer)"
        REQ["PlacementRequest<br/>(total RAM/VRAM/CPU/network<br/>a model needs)"] --> DIVIDE["Divide RAM/VRAM/CPU<br/>evenly by shardCount<br/>(ceiling division)"]
        DIVIDE --> PERSHARD["per-shard PlacementRequest<br/>(network NOT divided -<br/>each shard needs full<br/>inter-shard bandwidth)"]
        PERSHARD --> LOOP{"shardCount<br/>iterations"}
        LOOP -->|"Place() best-fit,<br/>excluding already-chosen"| PICK["choose 1 distinct<br/>healthy candidate node"]
        PICK --> LOOP
        LOOP -->|"all shards placed"| PLAN["ShardPlan{ShardNodes: [...]}"]
        LOOP -->|"any round refused<br/>(no capacity left)"| REFUSE["error - refuse,<br/>NEVER a partial/<br/>fabricated plan"]
    end

    subgraph "📋 OPEN: cross-node tensor-parallel execution (deferred past this round)"
        PLAN -.->|"not yet built"| SPLIT["Split model layers/tensors<br/>across ShardNodes' real<br/>llama.cpp/colibri engine<br/>processes"]
        SPLIT -.->|"not yet built"| COORD["Coordinate inference across<br/>shards (activation passing,<br/>KV-cache sharding, collective<br/>ops between nodes)"]
        COORD -.->|"not yet built"| BENCH["SC-017 benchmark:<br/>sharded throughput vs.<br/>single-node baseline,<br/>target within 15%"]
    end
```

**✅ IMPLEMENTED — `internal/cluster.PlanShards(candidates, req, shardCount)`**:
selects `shardCount` distinct healthy candidate nodes, each sized for an
even `1/shardCount` fraction of the model's RAM/VRAM/CPU requirement
(network bandwidth is deliberately NOT divided — every shard still needs
the model's full inter-shard bandwidth, since shards talk to each other,
not merely to one external caller). It reuses `Place()`'s own best-fit
selection repeatedly, excluding already-chosen nodes each round, so no
node is ever double-booked for two shards of the same model. It refuses
outright — never returning a partial or fabricated plan — when fewer than
`shardCount` candidates have sufficient per-shard capacity. Proven by
`internal/cluster/sharding_test.go`'s 3 tests (even-split distinct-node
selection, refusal on insufficient capacity, refusal on an invalid
`shardCount < 2`).

**📋 OPEN — cross-node tensor-parallel execution, deliberately deferred**:
`PlanShards` answers *which nodes could jointly host a sharded model*. It
does **not** implement the actual runtime mechanics of tensor/model
parallelism: splitting a model's layers or tensors across multiple nodes'
real `llama.cpp`/`colibri` engine processes, and coordinating inference
across them (activation/KV-cache exchange, collective communication
between shards, failure handling mid-inference). None of that exists in
this codebase. Building it requires real multi-GPU, multi-node hardware to
develop and validate against — hardware that does not exist in this
development sandbox — so it is honestly marked OPEN rather than claimed
done or silently skipped (Constitution §11.4.223).

**SC-017 benchmark status: UNCONFIRMED, not fabricated.** SC-017 asks for
sharded throughput within 15% of a single-node baseline. Measuring that
requires the OPEN execution layer above to exist and actually run —
without it, there is no real throughput to measure. No benchmark numbers
are recorded here because none were genuinely run; asserting a specific
percentage without ever having executed the workload would itself be
exactly the anti-bluff violation Constitution §11.4/§11.4.6 forbid. This
gap is tracked as future work under Phase 9's remaining scope, not
silently implied to be satisfied.

## Where this is going (roadmap pointer, not a claim of current state)

Per `specs/001-llmctl-completion/tasks.md`'s phase ordering: Phase 9 (US7)
builds the actual multi-node Raft coordination and scheduler distribution;
Phase 10 (US8) builds KV-cache WAL/checkpoint persistence and recovery;
Phase 11 (US9) builds JWT/RBAC auth, tenants, quotas, and API keys — none of
which this document claims is done. See `docs/CONTINUATION.md` for the
live phase-by-phase status table.
