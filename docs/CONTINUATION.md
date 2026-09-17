# CONTINUATION

**Revision:** 18
**Last modified:** 2026-09-17T14:20:20Z

Per Constitution §12.10: this file reflects the live state of work on the
`001-llmctl-completion` feature so any agent can resume exactly where the
previous session left off by reading this single file. Updated at every
phase checkpoint (Constitution §11.4.131/§12.10 — a stale copy of this file
is itself a violation).

## 1. What this is

llmctl is a bash-based local LLM orchestration tool (hardware probe → model
catalog matching → download+verify → multi-model co-residency scheduling →
systemd/launchd service management), plus an opt-in Go cluster daemon
(`llmctld/`, early scaffolding). Full feature spec, plan, and phased task
breakdown live under `specs/001-llmctl-completion/`:

- `specs/001-llmctl-completion/spec.md` — the spec (functional requirements,
  success criteria, clarifications, user stories).
- `specs/001-llmctl-completion/tasks.md` — 89 tasks across 12 phases, being
  executed via the `/speckit.superspec.execute` workflow with mandatory
  human-approval checkpoints between every phase.
- `specs/001-llmctl-completion/progress.yml` — structured per-phase
  completion evidence (machine-readable companion to tasks.md's inline
  checkbox notes).

## 2. Current phase / immediate next action

**ALL 12 PHASES OF THE `001-llmctl-completion` FEATURE ARE COMPLETE. All
five of its disclosed follow-up items (T072-FU1..FU5, per-tenant isolation,
model-lifecycle dispatch, and an independent security review) are closed —
see §10a-10e. Three entirely new spec-kit features, each disclosed as
follow-up boundaries from the original plan, have SINCE been fully designed
(spec/plan/research/data-model/tasks) and fully implemented (all 6 phases
each — Setup, Foundational, User Story 1 MVP, User Story 2, User Story 3,
Polish) and merged to `main` this session (2026-09-16): `002-cluster-model-
scheduler` (T072-FU6, §10f), `003-kv-cache-replication` (T072-FU7, §10g),
and `004-mtls-cert-rotation` (T072-FU8, §10h).**

All three features were planned and implemented via parallel subagent
dispatch in isolated git worktrees per phase (Constitution §11.4.58/§11.4.70/
§11.4.176/§11.4.230), with every agent's build/test/review claims
INDEPENDENTLY RE-VERIFIED by the conductor before merging (never trusted at
face value — one dispatch's self-reported test-output block did not match
this repository's real package layout and was caught by this re-verification
discipline, though the underlying code/doc changes it made were confirmed
genuinely correct by an independent run). Every phase's merge is a real
2-parent `git merge --no-ff` commit; two real merge conflicts (both in
`docs/cluster-architecture.md`, where multiple features' Phase 6 branches
touched adjacent section boundaries) were resolved by hand, preserving every
feature's real content, never by discarding one side.

**Both items disclosed as open above were CLOSED later the same session
(2026-09-16) — see §10i.** `internal/cluster/health.go`'s `Monitor` is now
genuinely wired into `cmd/llmctld/main.go` (both subcommands), closing the
resource-freshness heartbeat AND the crash-triggered replication-role
failover gap together (the same root cause); 004's FR-010 quorum-protection
check now performs a real live per-voter mTLS handshake confirmation instead
of approximating from Raft voter configuration. Both closures were
independently re-verified by the conductor (build/vet/gofmt/full-suite-under-
`-race`/bash-suite/submodule-drift) before merging, and each dispatch found
and fixed at least one further genuinely separate real defect along the way
(never invented scope) — full detail in §10i. That same closure work
honestly surfaced ONE brand-new real defect (the forward-client mTLS
identity's own certificate never being reissued across a completed CA
rotation, a genuine availability/self-lockout risk) — that too was found,
root-caused, fixed, RED/GREEN-proven, and independently re-verified by the
conductor the same session — see §10j.

**Zero disclosed open items remain — full stop — across 002-cluster-model-
scheduler, 003-kv-cache-replication, or 004-mtls-cert-rotation.** There is
no next phase and no follow-up item currently queued. The immediate next
action for a resuming session is: **present the current project state to
the operator** (this file, plus `specs/001-llmctl-completion/tasks.md` and
`progress.yml`, plus each of `specs/002-cluster-model-scheduler/`,
`specs/003-kv-cache-replication/`, `specs/004-mtls-cert-rotation/`'s own
tasks.md, are the complete record) and await further instruction — e.g.
start a new feature, or actually cut a real release (see the standing
constraint below).

**Important standing constraint carried forward:** `scripts/release/create_release.sh`
in NON-dry-run mode creates a real, public, irreversible GitHub+GitLab
release. It has NEVER been run in that mode this session (only
`--dry-run`, most recently as Phase 12's T082 rehearsal — `v2.1.0`, zero
network-mutating `gh`/`glab` calls made). It MUST NOT be run for real
without explicit, separate operator instruction to actually cut a release.

## 3. Phase-by-phase state — ALL PHASES COMPLETE

| Phase | Story | Status |
|---|---|---|
| 1 | Setup (Shared Infrastructure) | approved |
| 2 | Foundational (Blocking Prerequisites) | approved |
| 3 | US1 — Complete Feature Implementation & Integration | approved |
| 4 | US2 — Deterministic Test Suite with Rock-Solid Evidence | approved |
| 5 | US4 — Live System Testing with Real Models & CLI Agents | approved |
| 6 | US6 — Constitution Compliance Verification | approved |
| 7 | US3 — Exhaustive Documentation Suite | approved |
| 8 | US5 — Release Automation with GitHub/GitLab CLIs | approved |
| 9 | US7 — Distributed Multi-Host Model Orchestration | approved |
| 10 | US8 — Model State Persistence & Recovery | approved |
| 11 | US9 — Built-in Authentication, Authorization & Multi-Tenancy | **complete (T065–T075, 11/11)** |
| 12 | Polish & Cross-Cutting Concerns | **complete (T076–T083, 8/8)** |

Full per-task evidence for every completed phase is in
`specs/001-llmctl-completion/tasks.md` (inline, per-task) and
`specs/001-llmctl-completion/progress.yml` (structured).

## 4. Live-state anchors

- **Git HEAD**: `f7cf4e5` — this entire feature's Phases 9-11 work (plus
  everything accumulated in the working tree through Phase 8) was committed
  and pushed to all 6 configured upstreams (codeberg, gitflic, github,
  gitlab, gitverse, upstream) via `commit_fully`, verified on every remote.
  Phase 12's own polish work (lint fixes, evidence archive, doc updates)
  lands in a follow-up commit at the very end of this session (see the
  operator's instruction in §2).
- **Test suite**: `bash tests/run_tests.sh` → **21/21 test files pass, 0
  failures** (first zero-failure run of this project was reached in Phase
  4; still 0 failures as of Phase 12 — Phase 12 added no new bash test
  files, only Go work + doc/evidence updates).
- **Go suite**: `go test ./... -race` inside `llmctld/` (fresh, `go clean
  -testcache` first) → **all tests pass across all 12 packages, zero data
  races** (api, audit, auth, authz, cluster, executor, isolation, mtls,
  raft, replication, tenancy, test/integration). This module is verified
  race-clean end-to-end (Phase 11's T073 — the first genuine concurrent
  HTTP load this codebase ever drove — surfaced and fixed THREE real,
  previously-undiscovered data races present since earlier phases; see §9
  below) AND lint-clean (`golangci-lint run --max-issues-per-linter=0
  --max-same-issues=0 ./...` → **0 issues**, Phase 12's T077 fixed 76
  genuine `errcheck`/`staticcheck` findings; see §10 below). `go build
  ./...`, `go vet ./...`, and `gofmt -l .` all clean.
- **Constitution verification harness**: `bash
  constitution/scripts/validation/run_verification.sh` → 17/17 submodules
  verified, 0 failures (re-confirmed fresh at Phase 12's T078).
- **Constitution inheritance test**: `bash
  tests/test_constitution_inheritance.sh` → all 10 invariants pass (T033).

## 5. Phase 6 findings (T032–T036)

- **T032/T033**: clean — 17/17 verification submodules pass; all 10
  constitution-inheritance invariants pass. No fixes needed.
- **T034** (§9 data-safety audit): exhaustive search across `lib/`,
  `tests/`, `bin/llmctl`, and `llmctld/`'s Go source found **zero**
  destructive git operations (no `git reset --hard`, no force-push, no
  submodule deinit) anywhere outside of scripts' own session-isolated
  `mktemp -d` temp directories. §9's backup-before-destroy requirement has
  no applicable call site in this codebase — a clean audit result, not a
  gap.
- **T035** (§12.6 RAM-ceiling audit) — **real finding, operator-resolved**:
  FR-015 literally requires both a "60% RAM ceiling" AND OS-level
  MemoryHigh/MemoryMax protection; the prior implementation
  (`MemoryMax = total_RAM - 4GiB`) satisfied only the second half — for any
  host above ~10GiB total RAM this exceeds 60%. Escalated to the operator
  (this is a real product-scoping decision, not a mechanical bug, given
  llmctl's core purpose of serving large local models). **Operator
  decision (2026-09-15): remove artificial caps entirely — served models
  get maximal performance/resources.** Implemented: `MemoryMax` = the full
  probed total system RAM (no subtraction, no percentage), `MemoryHigh` =
  the same value (no soft-throttle zone below the max). The directives
  themselves stay present (still contains a runaway profile to a clean
  cgroup-level OOM-kill of just that service rather than an uncontrolled
  whole-host kernel OOM event) — only the artificial reduction below
  hardware capacity was removed. `lib/service_linux.sh` changed;
  `lib/service_macos.sh` already had no equivalent cap (launchd has no
  clean cgroup-memory-limit analog) so nothing to change there.
  `tests/test_services.sh` updated via TDD RED→GREEN. **Explicitly NOT
  touched**: `lib/catalog.sh`'s scheduler admission-control budget
  (`ram_avail - 4096`) — a distinct, load-bearing multi-profile
  overcommit-protection feature (prevents system-wide swap-thrashing when
  several profiles run co-resident), out of this finding's scope and not
  part of the operator's question.
- **T035a**: already fully satisfied — verified (not assumed) that all 4
  submodules (`constitution`, `submodules/superspec`,
  `submodules/llama.cpp`, `submodules/colibri`) carry a real
  `## INHERITED FROM Helix Constitution` heading (or, for `constitution`
  itself, correctly have none — it IS the source of truth per §11.4.35),
  committed as part of the exact pinned commit each submodule points to
  (cross-checked against `git submodule status`'s recorded SHAs), zero
  uncommitted drift. This had already been done in an earlier session
  (commit `941c185`).
- **T036**: this file — created for the first time (did not previously
  exist).

## 6. Phase 7 findings (T037–T043)

- **T037–T039** (tutorial/FAQ/user-manual, dispatched to 3 parallel
  subagents): all three independently verified `llmctld`'s real Go-file
  listing and/or `bin/llmctl`'s real case statement BEFORE writing, and all
  three explicitly label the `cluster`/`tenant`/`apikey` CLI stubs as
  hard-failing "not yet implemented" — none presents a future-phase feature
  as working today.
- **T040** (architecture.md diagrams) — found real, pre-existing doc drift:
  the file still said `vendor/` (fixed in Phase 3), the old
  `StartLimitIntervalSec=0` (fixed in Phase 2), the old `ThrottleInterval=5`
  (fixed in Phase 2), and the old 90%-headroom memory formula (fixed in
  Phase 6). Corrected all of it, then added 5 Mermaid diagrams, each
  genuinely rendered to a real SVG via `mmdc` (mermaid-cli) — not merely
  assumed syntactically valid.
- **T041** (cluster-architecture.md, new doc) — every diagram element is
  explicitly labeled ✅ IMPLEMENTED (grounded in real code + passing tests)
  or 📋 PLANNED (spec-derived design intent, zero code exists) — the Raft
  FSM's node-membership logic and the mTLS CA/cert-issuance primitive are
  real; multi-node consensus, JWT auth, and all of KV-cache/WAL/checkpoint
  are not. All 4 diagrams genuinely rendered via `mmdc`.
- **T042** (doc-link completeness) — README.md now has an 18-row
  Documentation table (every doc under `docs/` plus the spec/tasks files),
  every link target verified to actually exist. `docs/integrations.md` got
  a cross-reference block to the 4 new sibling docs.
- **T043** (api-reference.md, new doc) — confirmed `internal/api/routes_*.go`
  does NOT exist before writing anything; documents the REAL llama.cpp/
  colibri HTTP surface (grounded in `lib/download.sh`'s real smoke-test
  payload) and the planned `llmctld` cluster API as two clearly separated,
  honestly-labeled sections.

## 7. Phase 9 findings (T049–T058)

Full per-task evidence is in `specs/001-llmctl-completion/tasks.md`
(inline) and `progress.yml` (structured); this section highlights what a
resuming session most needs to know.

- **T049/T050** (transport + node lifecycle): a real QUIC+mTLS
  `hraft.StreamLayer` (`internal/raft/transport.go`) and a real
  `Bootstrap()`/`New()`/`Join()`/`Leave()`/`LeaderCh()` node wrapper
  (`node.go`). Two real bugs found and fixed via genuine TLS-handshake and
  election testing (not assumed): a missing-SAN mTLS verification failure
  (fixed via `VerifyPeerCertificateAgainstCA`, CA-chain verification
  instead of hostname matching), and — far more consequential — see T051
  below.
- **T052/T052a/T053/T055/T057** (placement, replication, health,
  partition, sharding hints): all real, TDD-tested LIBRARY code in
  `internal/cluster/` (`placement.go`, `health.go`, `partition.go`,
  `sharding.go`). **Honest boundary, explicitly documented in-source and
  in tasks.md, not silently implied otherwise: none of this is yet wired
  into a running scheduling/reconciliation loop inside `cmd/llmctld`** —
  it is real, correct, tested code with no live caller yet. Cross-node
  tensor-parallel EXECUTION (as opposed to placement hints) is honestly
  marked 📋 OPEN in `docs/cluster-architecture.md` §5 — no multi-GPU
  hardware exists in this sandbox to build or validate it against, and
  SC-017's throughput benchmark was never run (no fabricated numbers).
- **T056/T056a** (executor + distributed lock): `internal/executor/local.go`
  shells out to the REAL `bin/llmctl` (confirmed `LLMCTL_DRY_RUN` is a
  real pre-existing bash feature, not invented). `internal/raft/lock.go`
  is a real Raft-backed distributed lock (FSM-applied linearized log
  entries), proven to genuinely block a second `Acquire` until release or
  TTL expiry over a real bootstrapped Raft instance.
- **T058** (HTTP/3 cluster API): `internal/api/` — real `gin-gonic/gin` +
  `quic-go/quic-go/http3` server serving `POST /v1/cluster/join` /
  `/leave` / `GET /v1/cluster/nodes` / `/status`, mTLS-enforced. 5/5 tests
  drive a REAL HTTP/3 client over a REAL QUIC connection against a REAL
  `*raft.Node` — never a direct handler call. One disclosed TDD-ordering
  deviation: the three implementation files were authored before their
  test file this round (time pressure); compensated for by moving the
  implementation out of the package afterward and re-confirming genuine
  RED before restoring it — disclosed rather than silently claimed
  RED-first.
- **T051/T054 (the capstone — real 3-process integration tests) — two
  genuine, previously-invisible bugs found and fixed, exactly the value
  real integration testing exists for:**
  1. `RequestJoin` failed on a real 409 immediately after a fresh
     bootstrap, because a freshly-bootstrapped single-node cluster does
     not elect itself leader instantly (hashicorp/raft's own randomized
     ~1–2s heartbeat/election timeout). Fixed with a bounded (10s) retry
     on 409 specifically.
  2. **A much deeper bug**: `Join(peerAddr)` (from T050) used `peerAddr`
     as BOTH the joining peer's `hraft.ServerID` and its network address,
     but each node's real `raft.Config.LocalID` is its human `-node-id`
     (e.g. `"node-b"`) — the ID mismatch meant hashicorp/raft's own
     internal "do I have a vote in the stable configuration?" check
     ALWAYS failed for a joined follower, so **it could never start an
     election**. This was invisible in every prior test (which only
     checked membership-list visibility, never actual election
     eligibility) until the real 3-process failover test genuinely killed
     the leader and every survivor logged
     `"not part of stable configuration, aborting election"` forever.
     Root-caused by reading the real hashicorp/raft v1.7.3 source (never
     guessed). Fixed by changing `Join`'s signature to
     `Join(peerID, peerAddr string)`, cascaded through
     `routes_cluster.go`, `RequestJoin`, `cmd/llmctld/main.go`, and every
     test call site. A **permanent regression guard** was added at the
     cheap package level
     (`internal/raft/node_test.go`'s
     `TestJoin_SurvivingFollowerBecomesLeaderAfterOriginalLeaderShutsDown`)
     so this defect class is caught by `go test ./internal/raft/...`
     alone, not only the slow OS-process integration suite.
  - `cmd/llmctld/main.go` gained real `cluster bootstrap`/`cluster join`
    subcommands as a result (not separately named as its own task, but
    required supporting infrastructure — there was previously no way to
    run `llmctld` in cluster mode as a real process at all). Manually
    validated end-to-end by hand (real binary, real background processes)
    before writing the automated test.
  - T054 is honestly scope-narrowed: it proves real Raft-layer failover
    (a killed leader → a new real leader elected among survivors within
    30s, observed ~9.6s), NOT model-rescheduling — no workload-placement
    loop is wired into the running binary yet, documented as an explicit
    gap rather than fabricated.

## 8. Phase 10 findings (T059–T064)

Full per-task evidence is in `specs/001-llmctl-completion/tasks.md`
(inline) and `progress.yml` (structured); this section highlights what a
resuming session most needs to know.

- **T059/T060/T063/T064** (WAL, checkpoint, edge cases, encryption —
  `internal/replication/`): a real `go.etcd.io/bbolt`-backed WAL
  (`wal.go`) and periodic checkpoint store (`checkpoint.go`), each with a
  genuine TDD RED (`go vet` `undefined:` errors) confirmed before
  implementation. T063 forced a REAL checkpoint-persistence failure
  (closing the underlying bbolt DB directly) to prove the WAL survives a
  failed checkpoint attempt and a retry incorporates the full delta; the
  WAL-too-large mechanism (`CheckpointConfig.MaxWALSizeBytes`) is
  deliberately opt-in/configurable since spec.md names no specific byte
  threshold (Constitution §11.4.6 no-guessing). T064 added a new
  `internal/tenancy` package (`DeriveKey` via HMAC-SHA256) and
  AES-256-GCM encryption at rest (`crypto.go`), proven not just by a
  wrong-key-fails-to-decrypt test but by a raw byte-level scan of the
  on-disk bbolt file showing no plaintext token IDs leak at the storage
  layer — the actual filesystem-compromise threat model Clarification 20
  names. All existing plaintext `OpenWAL`/`OpenStore` behavior is
  unchanged (verified via `TestOpenWAL_UnencryptedStillWorks`).
- **T060's honest scope boundary** (documented in-source and restated
  here, not silently implied otherwise): `KVState{Tokens, Positions
  []int32}` models the REPLAYABLE TOKEN SEQUENCE fed into a model, not
  raw engine-internal attention-weight bytes — llmctld's control-plane/
  data-plane split means the real inference engine (llama.cpp/colibri)
  always runs as a separate OS process reached only via HTTP. A dedicated
  investigation (a forked research agent reading the real vendored
  `submodules/llama.cpp` source, pinned `3f152073`/~b10969) found
  `llama-server` DOES expose a real `/slots/:id_slot?action=save|restore`
  HTTP endpoint, but it writes to the SERVER's own local disk (requires
  `--slot-save-path`) — genuine cross-node replication would need
  additional out-of-band file transfer, a concrete, documented future
  integration point (`docs/cluster-architecture.md` §3) rather than a
  vague "not possible" claim.
- **T061** (`internal/replication/lora.go`): unlike `KVState`, a LoRA
  adapter IS a real ordinary file (GGUF) on disk before ever being loaded
  into an engine, so this is fully real with no abstraction gap —
  `ReplicateAdapter` reads the source once and fans out to every sink
  (`AdapterSink func(name string, data []byte) error`), proven
  byte-for-byte AND via an independent sha256 comparison.
- **T062 (the capstone — a real 3-node KV-cache failover integration
  test) — dispatched to a subagent, independently re-verified by the
  assistant with a genuinely fresh, non-cached test run.** The subagent
  found the HTTP replication-route layer did not yet exist and built it
  as necessary supporting work: `internal/api/routes_replication.go`
  (`POST /v1/replication/append`, `POST /v1/replication/checkpoint`,
  `GET /v1/replication/state`, all backed by a real `*replication.Store`)
  + a `Router()` accessor added to `internal/api/server.go` (additive,
  non-breaking) + `cmd/llmctld/main.go` extended with a `-state-dir` flag
  and wiring both `cluster bootstrap` and `cluster join` to open a real
  `replication.Store` and register those routes before serving. The
  assistant independently read all three of these files in full and
  confirmed the wiring is correct and the pre-existing `READY` line/CLI
  flag behavior is unchanged.
  - `test/integration/failover_state_test.go`'s
    `TestFailoverState_KVCacheSurvivesPrimaryKill` reuses the
    `testCluster` harness from T054's `cluster_bootstrap_test.go`
    verbatim: bootstraps + joins 3 real `llmctld` processes; replicates +
    checkpoints 5000 simulated tokens (batched 500/HTTP-request) to all 3
    real nodes via real HTTP/3+mTLS calls; verifies durability on EVERY
    node BEFORE sending a real `SIGKILL` to the current Raft leader;
    dynamically resolves the newly elected leader among survivors; and
    asserts EXACT 5000/5000 token equality (stronger than SC-019's ≤5%
    tolerance, justified because durability was pre-verified for every
    node including the one about to be killed) and recovery ≤30s.
  - **Honest scope boundary, disclosed in the test's own doc comment**:
    no automatic daemon-side mechanism yet forwards a primary's live WAL
    appends/checkpoints to replicas as they happen — the test's own calls
    against all three node addresses play that forwarding role directly,
    mirroring T054's own disclosed scope-narrowing. This proves the REAL
    `replication.Store` + REAL HTTP routes genuinely reconstruct state
    correctly under a real process kill and real Raft re-election,
    without claiming a cross-node replication daemon exists.
  - **Real measured evidence** (assistant's own fresh, `go clean
    -testcache`-first run, matching the subagent's two independent
    runs): primary resolved as `node-a`; 5000 tokens replicated +
    checkpointed to all 3 real nodes in 757.243923ms; durability verified
    pre-kill on all 3; `node-b` elected new primary 2.071362688s after
    killing `node-a`; new primary reports 5000/5000 tokens (0.00% loss)
    with recovery taking 2.080684284s; test PASSed in 11.32s.
- **Two honest, well-documented scope boundaries remain open for future
  work** (both left as concrete future-work items rather than fabricated
  completions): (1) genuine llama.cpp/colibri real-engine-state
  integration via `--slot-save-path` + out-of-band file transfer
  (T060's boundary), and (2) an automatic daemon-side mechanism that
  forwards a primary's live replication traffic to followers without a
  test driving it externally (T062's boundary).

## 9. Phase 11 findings (T065–T075)

Full per-task evidence is in `specs/001-llmctl-completion/tasks.md`
(inline) and `progress.yml` (structured); this section highlights what a
resuming session most needs to know.

- **T065–T070** (`internal/auth`: JWT/RBAC/API keys/OIDC; `internal/tenancy`:
  tenant CRUD + namespace isolation/sharing + quotas): all real, TDD-tested
  library code, each with a genuine RED confirmed via `go vet` before
  implementation. JWT is HS256-pinned against the algorithm-confusion
  attack class (`jwt.WithValidMethods`, proven by a hand-crafted `alg:none`
  rejection test); API keys are `crypto/rand`-generated, SHA-256-hashed at
  rest, never stored in plaintext; RBAC fails closed on any
  unknown/unregistered role; tenant model-sharing is scoped to exactly one
  recipient by construction (no data shape can accidentally mean "shared
  with everyone"); quota's rate limiter takes `now time.Time` explicitly
  (never `time.Now()` internally) so its own test drives the 5-minute
  OIDC fallback window and the token-bucket deterministically, without
  real sleeping.
- **T071** (audit-log wiring): a new `internal/authz` package (`Decider`)
  composes the independent auth/tenancy/audit packages, wrapping every
  decision function with an `audit.Log.Append` call — both ALLOW and DENY
  outcomes are logged on every path, proven by a test driving all decision
  classes through one shared `Decider` and asserting an exact entry count
  plus a clean hash-chain verification.
- **T072** (`internal/isolation/cgroup.go`): a real, independently-tested
  `WrapCommand`/`TenantStateDir` library (per-tenant `systemd-run --scope`
  wrapping + verified-0700 state directories) — **honest scope boundary,
  still open**: NOT wired into `internal/executor/local.go` or
  `cmd/llmctld`'s process spawn. This remains real, disclosed follow-up
  work, not silently claimed done.
- **T073** (the capstone — real 3-tenant, 1000-concurrent-request isolation
  test) — dispatched to a subagent, independently re-verified. Required
  supporting infrastructure: a `-bootstrap-admin` CLI flag on
  `cluster bootstrap` (seeds one admin API key at startup, the minimal
  mechanism to solve the real API-key/JWT bootstrap chicken-and-egg
  problem without mocking). **This task's own genuinely-real concurrent
  HTTP load surfaced TWO real, previously-undiscovered data races**,
  present since earlier phases and invisible until real concurrency +
  `-race` exposed them: (1) `internal/audit/log.go`'s `Log.Append` (and
  every sibling method) had ZERO synchronization despite `Decider` calling
  it on every authZ/authN decision; (2) found independently by the
  assistant's own follow-up full-module `-race` verification pass:
  `internal/raft/fsm.go`'s `ClusterFSM.State()` doc comment CLAIMED
  safety "without racing further Apply calls" that the code never actually
  implemented — a real production exposure via `GET /v1/cluster/status`
  and `lock.go`'s `Locks()`, present since Phase 9. Both fixed with a
  `sync.Mutex` via strict RED (a real reproduced `DATA RACE`, and for the
  raft case an actual `fatal error: concurrent map writes` CRASH) →
  GREEN. **The whole `llmctld` module is now verified race-clean
  end-to-end for the first time this session.** Result: zero cross-tenant
  leakage across all 1000 concurrent requests, zero exceptions.
- **T074/T074a** (HTTP routes + benchmarks): `routes_auth.go`,
  `routes_tenants.go`, `routes_audit.go`, `middleware_jwt.go` — every JWT
  validation at the HTTP layer routes through the audited `Decider` too,
  not just direct Go calls. `cmd/llmctld/main.go` now requires
  `LLMCTLD_JWT_SIGNING_KEY` to be set (fails fast, no invented fallback
  key). Benchmarks confirm SC-021's latency ceilings are cleared by orders
  of magnitude (JWT validate p99 43.5µs vs a 5ms ceiling; RBAC check p99
  160ns vs 5ms; quota check p99 110ns vs 1ms).
- **T075 (security review) — found and fixed 4 genuine, exploitable
  security defects**, the most valuable finding of this phase: (1) a
  **CRITICAL full RBAC bypass** — `POST /v1/auth/apikeys` and its
  rotate/revoke siblings were gated by `RequireJWT` ALONE with no RBAC
  check, letting ANY authenticated caller (even the lowest-privileged
  role) mint itself a brand-new admin-scoped API key and exchange it for
  a fully admin-privileged JWT; (2) a cross-tenant model-enumeration
  oracle on the `/visible` endpoint (missing the same ownership check its
  sibling routes already had — notably, T073's own 1000-request test
  never caught this because it always queried using the caller's OWN
  tenant ID); (3) an audit-log coverage gap (`POST /v1/auth/token`
  bypassed the audited `Decider` entirely); (4) an OIDC fallback-cache
  bug that could silently extend a token's validity past its own `exp`
  claim during a provider outage. All four were reproduced live against
  the pre-fix code, then fixed via strict RED→GREEN TDD, independently
  re-verified by the assistant by test name. This is exactly the kind of
  finding the mandatory independent-review gate (Constitution §11.4.125/
  §11.4.142/§11.4.209) exists to catch before a phase is allowed to close.

## 10. Phase 12 findings (T076–T083) — the final phase

Full per-task evidence is in `specs/001-llmctl-completion/tasks.md`
(inline) and `progress.yml` (structured); this section highlights what a
resuming session most needs to know.

- **T076/T077** (`make validate`, `make llmctld-build/test/lint`): two
  honest environment gaps were found and handled differently. `shellcheck`
  is not installed on this build host and cannot be installed without
  interactive `sudo` (attempted, refused) — the Makefile's own `lint`
  target already handles this gracefully with an explicit skip message,
  matching this project's established never-hard-fail-on-an-optional-tool
  pattern (T004). `golangci-lint`, by contrast, installs via `go install`
  with no `sudo` needed, so it WAS installed to get a genuine result. That
  real run found **76 genuine lint findings** (75 `errcheck` unchecked
  error returns + 1 `staticcheck` deprecated-field usage) hiding behind
  golangci-lint's default per-run issue cap — three successive
  `--max-issues-per-linter=0 --max-same-issues=0` runs were needed to see
  the complete list. ALL 76 were fixed: two genuine production-code
  instances (`wal.go`/`checkpoint.go`/`node.go`'s error-path cleanup calls,
  explicitly ignored via `_ = ...Close()` with a comment explaining the
  original error is what the caller needs) and ~70 mechanical test-file
  `defer x.Close()`/`defer x.Shutdown()` → `defer func() { _ = x.Close() }()`
  conversions, plus one deprecated hashicorp/raft field
  (`AppendEntriesRequest.Leader` → the modern `RPCHeader.Addr`, confirmed
  via reading the real v1.7.3 library source). Final: **0 lint issues**,
  zero regressions.
- **T078/T079**: clean re-runs, no new findings — the constitution
  verification harness + meta-test mutation gate both pass exactly as at
  every prior phase, and the combined bash+Go test suite (archived at
  `docs/qa/phase12-final-validation/`) shows zero regressions across the
  whole 12-phase feature, including a fresh re-confirmation of T073's
  1000-concurrent-request zero-cross-tenant-leakage result.
- **T080** (doc cross-reference audit): found and closed one real orphan —
  `docs/qa/phase12-final-validation/README.md` (T079's own newly-created
  evidence directory) had no README pointer; added a Documentation-table
  row for it. Every other doc (19 links, 17 top-level `docs/*.md` files)
  was already correctly reachable.
- **T081**: this file, updated to its final Revision 7.
- **T082** (release rehearsal): `create_release.sh --dry-run v2.1.0`
  genuinely ran every check (SemVer validation, submodule preflight,
  changelog generation from real commit history, archive build, GitHub+
  GitLab publish) with **zero network-mutating `gh`/`glab` calls** —
  confirmed still never run in real/publishing mode this session.
- **T083** (final Constitution compliance sign-off, SC-010): re-ran every
  US6 audit (T032-T036) against the complete, finished 12-phase tree.
  **Zero new violations found.** The one pre-existing honest gap —
  `internal/isolation/cgroup.go`'s `WrapCommand`/`TenantStateDir` (T072)
  still has no production call site wiring it into `cmd/llmctld/main.go`
  or `internal/executor/local.go` — was re-confirmed unchanged via a fresh
  grep, exactly as T072's own evidence entry already disclosed. This is
  the ONE remaining open, honestly-tracked follow-up item across the
  entire feature: per-tenant cgroup isolation exists as a real, tested
  library but is not yet wired into the live daemon's process-spawn path.

**Every other honestly-disclosed scope boundary from Phases 9-11 remains
exactly as documented in §7/§8/§9 above** — none has silently changed
status during Phase 12's polish work. The feature is complete: all 89
tasks across 12 phases done, zero blocking findings, one disclosed
non-blocking follow-up item (cgroup wiring) which was subsequently closed —
see §10a immediately below.

## 10a. Follow-up: T072-FU1 — per-tenant cgroup isolation wiring (closed 2026-09-15)

This closes the ONE remaining open item §10 named above. Full evidence is
in `specs/001-llmctl-completion/tasks.md`'s "Follow-up Work" section and
`progress.yml`'s `follow_up_work` key; this is the resumption-relevant
summary.

- **Root-cause investigation performed before any code was written**
  (Constitution §11.4.102): the obvious-looking plan — wrap
  `internal/executor.LocalExecutor`'s `exec.Command` call in
  `internal/isolation.WrapCommand`'s `systemd-run --user --scope
  --slice=...` prefix — was read through `lib/service_linux.sh` in full and
  confirmed to be a **bluff fix**. `bin/llmctl start <profile>` invokes
  `systemctl --user start llmctl-<engine>@<profile>.service`, a real
  systemd template unit whose actual long-running model-server process is
  spawned and owned by systemd's own user-manager, independent of the
  short-lived `bin/llmctl` CLI invocation that exits in milliseconds.
  Wrapping that short-lived invocation in `systemd-run` would isolate
  nothing of the real process — cgroup placement for a
  `systemctl --user start`-launched unit resolves from the UNIT's own
  `Slice=` property, never from the calling process. The correct
  mechanism, identified before implementing: a per-instance systemd
  **drop-in file** (`<unit>.service.d/tenant-slice.conf`,
  `[Service]\nSlice=llmctl-tenant-<id>.slice`).
- **Bash side** (`lib/service_linux.sh`): added `_svc_validate_tenant_id`
  (mirrors the Go-side `internal/isolation/cgroup.go` tenant-ID allow-list
  so both languages diverge as little as possible), `_svc_instance_key`
  (`<tenant>--<profile>` when `LLMCTL_TENANT_ID` is set, else the bare
  profile name — byte-identical to prior behavior when untenanted), and
  `_svc_ensure_tenant_slice_dropin` (idempotent drop-in write +
  `daemon-reload`, routed through the existing dry-run gate).
  `svc_write_env`/`_svc_unit_for`/`svc_enable`/`svc_disable`/`svc_start`/
  `svc_restart`/`svc_logs` all route through the tenant-aware key;
  `svc_enable` AND `svc_start` (not just the first-install path) both
  independently ensure the drop-in exists. New
  `tests/test_tenant_service_isolation.sh`: 15/15 assertions, TDD RED
  confirmed first. Full bash suite: **22/22 PASS** (was 21 — new file
  auto-discovered, zero regressions).
- **Go side** (`internal/executor/local.go`): `Config` gained `TenantID`;
  `run()` now sets `LLMCTL_TENANT_ID` in the real subprocess environment
  when non-empty (untenanted behavior unchanged). New test
  `TestLocalExecutor_Start_WithTenantID_WritesTenantScopedEnvFile` is a
  genuine real-subprocess proof with no mock anywhere: it never sets
  `LLMCTL_TENANT_ID` on the test process itself, so the only way it can
  reach the subprocess is via `LocalExecutor.run()`'s own injection, and it
  asserts on the real tenant-qualified env file the real bash mechanism
  either did or didn't write. TDD RED confirmed first (compile-time, then
  behavioral), GREEN after wiring. **Independent finding, confirmed via a
  fresh grep audit before writing Go code**: `internal/executor.LocalExecutor`
  was, and after this task still is, not constructed anywhere in
  `cmd/llmctld` or any other package — it remains dead code from the
  daemon's runtime perspective, exactly as T073's own evidence entry
  already disclosed. Wiring it into a live HTTP/scheduler dispatch path in
  `cmd/llmctld` is separate, larger scope not claimed done here.
- **Full verification** (fresh, `go clean -testcache` first): `gofmt -l .`
  clean, `go vet ./...` clean, `go build ./...` clean,
  `go test ./... -race` (all 12 packages) zero regressions/zero races,
  `bash tests/run_tests.sh` **22/22 PASS**.
- **Honest scope boundary, now closed — see §10b below**: `internal/isolation.TenantStateDir`
  (Clarification 18's per-tenant KV-cache/WAL directory half) has since
  been wired into a real model-data path decision (`T072-FU2`,
  2026-09-15). Kept here unedited as the accurate historical record of
  what was true at the time §10a was written.

## 10b. Follow-up: T072-FU2 — TenantStateDir wired into a real model-data path decision (closed 2026-09-15)

Closes §10a's remaining open item. Full evidence is in
`specs/001-llmctl-completion/tasks.md`'s "Follow-up Work" section and
`progress.yml`'s `follow_up_work` key; this is the resumption-relevant
summary.

- **Root-cause investigation performed before any code was written**
  (Constitution §11.4.102): dispatched a subagent to determine, with
  file:line citations, what "KV cache/WAL storage" (Clarification 18/
  FR-049, Clarification 20/FR-051) actually refers to in THIS codebase,
  rather than assuming it meant llama.cpp's own attention-KV-cache.
  Findings: `lib/*.sh` has no KV-cache/WAL notion at all; `llama-server`
  DOES have a real, currently-unwired disk-backed session mechanism
  (`--slot-save-path`) but this project's own `internal/replication/
  wal.go` doc comment already disclosed that as a separate, investigated,
  deliberately-out-of-scope question; `internal/tenancy/key.go`'s own
  PRE-EXISTING doc comment already identified `internal/replication`'s
  bbolt-backed `Store` (the WAL/checkpoint pair) as the real thing
  Clarification 18/20 mean by "KV cache checkpoints and WAL entries...
  persist actual conversation content"; and `LLMCTL_MODELS_DIR` is
  confirmed (via grep) to be written only by the download path — a
  shared, read-only-thereafter resource, exactly as §10a's disclosed
  assumption held.
- **The real wiring decision**: `internal/replication.Store` was, before
  this task, opened exactly ONCE per node (`cmd/llmctld/main.go`'s two
  `replication.OpenStore(stateDir, ...)` call sites), shared across every
  tenant that node might ever serve — a real Clarification-18 violation
  waiting to happen. New `internal/replication/registry.go`:
  `StoreRegistry` lazily opens/caches one `*Store` PER TENANT, routing
  every non-empty tenant ID through `internal/isolation.TenantStateDir`
  (the SAME allow-list + verified-0700 mechanism T072/T072-FU1 already
  established); `Get("")` opens `baseDir` directly, byte-identical to the
  pre-existing single-store-per-node behavior. 6/6 new
  `registry_test.go` tests, TDD RED (`undefined: NewStoreRegistry`) then
  GREEN.
- **HTTP layer**: `internal/api/routes_replication.go`'s
  `RegisterReplicationRoutes` now takes a `*replication.StoreRegistry`;
  a request's optional `X-Tenant-ID` header resolves which tenant's
  `Store` it operates against (absent → the empty/default tenant). New
  real-HTTP/3+mTLS test proves two callers distinguished only by that
  header never see each other's appended tokens. The pre-existing
  round-trip test was updated to construct a `StoreRegistry` (a genuine
  compile-time RED from the signature change, fixed) and, sending no
  header, now doubles as regression coverage for the untenanted default
  path. `cmd/llmctld/main.go`'s two wiring sites (bootstrap/join) updated
  symmetrically.
- **Disclosed behavior-change note**: `StoreRegistry.Get` opens each
  tenant's Store LAZILY (on first request) rather than eagerly at node
  startup, so a per-tenant Store-open failure now surfaces on that
  tenant's first `/v1/replication/*` request instead of at startup —
  `stateDir`'s own creation is still verified eagerly exactly as before,
  and no existing test depended on the old eager-open-at-startup
  behavior (confirmed via grep before making the change).
- **Full verification** (fresh, `go clean -testcache` first): `gofmt -l .`
  clean, `go vet ./...` clean, `go build ./...` clean,
  `go test ./... -race` (all 12 packages) zero regressions/zero races —
  explicitly re-confirmed by name: both new/updated replication tests
  PASS, `TestClusterFailover_KillingLeaderElectsNewRealLeaderAmongSurvivors`
  PASS, `TestFailoverState_KVCacheSurvivesPrimaryKill` PASS (the real
  3-node failover test, exercising the untenanted default path,
  unchanged). `bash tests/run_tests.sh` **22/22 PASS** (unaffected — this
  task touches Go only).
- **Honest scope boundary, now closed — see §10c below**:
  `StoreRegistry.Get` always opened a PLAINTEXT `Store`, never
  `OpenEncryptedStore`. Kept here unedited as the accurate historical
  record of what was true when §10b was written; closed by `T072-FU3`
  (2026-09-15).

## 10c. Follow-up: T072-FU3 — per-tenant encryption at rest wired (closed 2026-09-15)

Closes §10b's remaining open item — Clarification 20/FR-051.

- New `NewEncryptedStoreRegistry(baseDir, cfg, masterSecret)` mirrors the
  pre-existing `OpenStore`/`OpenEncryptedStore` naming pair: a non-empty
  tenant ID's `Store` opens via `OpenEncryptedStore` under a key
  `internal/tenancy.DeriveKey` derives specifically for THAT tenant from
  `masterSecret` — two tenants sharing one master secret never share a
  readable key. The empty (`""`) tenant ID is deliberately EXEMPT from
  encryption under either constructor (it represents "no tenant", the
  single-node/no-tenancy default path) — T072-FU2's own established
  invariant (`Get("")` byte-identical to a bare `OpenStore` call) holds
  unconditionally, so a deployment that never opts into multi-tenancy
  observes zero behavior change. `NewStoreRegistry` (the plain
  constructor) is completely unaffected.
- 3 new tests, TDD RED (`undefined: NewEncryptedStoreRegistry`) then
  GREEN: a genuine-ciphertext proof (re-opening the same on-disk
  directory afterward via a bare, keyless `OpenStore` fails to `Restore`
  — AES-GCM's auth-tag check fails closed); per-tenant-derived-key
  independence proven at the registry WIRING layer (not merely at
  `DeriveKey`'s own unit-test layer) — tenant-b's derived key cannot
  decrypt tenant-a's real on-disk directory; the plain registry's
  default path reconfirmed unaffected.
- `cmd/llmctld/main.go`: new env var `LLMCTLD_TENANT_ENCRYPTION_KEY` —
  deliberately OPTIONAL (unlike the required JWT signing key), following
  this project's zero-means-unset convention, since encryption at rest
  is opt-in hardening rather than a security-critical fail-fast
  requirement. A new `newStoreRegistry` helper resolves
  `NewEncryptedStoreRegistry` vs `NewStoreRegistry` in ONE place both
  `runClusterBootstrap`/`runClusterJoinReal` use, so the two subcommands
  cannot drift apart on it. `.env.example` documents the new var.
- **Full verification** (fresh, `go clean -testcache` first): `gofmt`/
  `go vet`/`go build` clean, `go test ./... -race` (all 12 packages) zero
  regressions/zero races. `bash tests/run_tests.sh` **22/22 PASS**
  (unaffected — Go-only change).
- **Result: both Clarification 18 (per-tenant directory) and
  Clarification 20 (per-tenant encryption at rest) for
  `internal/replication`'s KV-cache/WAL state are now closed.** No
  further honest scope boundary remains on this thread of follow-up
  work. The one still-open item across the whole feature was
  `internal/executor.LocalExecutor` itself not being constructed
  anywhere in `cmd/llmctld`'s live HTTP/scheduler dispatch path (§10a) —
  now closed too, see §10d immediately below.

## 10d. Follow-up: T072-FU4 — LocalExecutor wired into a live model-lifecycle dispatch path (closed 2026-09-15)

This closes the LAST disclosed gap across the whole feature. Unlike
T072-FU1/FU2/FU3 (all backward-compatible wiring of an already-built
mechanism into its OWN pre-existing call site), this one required
inventing a genuinely NEW HTTP API surface — classified **architectural**
per the brainstorming discipline, and presented to the operator via
`AskUserQuestion` before any code was written; the operator chose
"Design it now".

- **Investigation before designing**: confirmed `internal/auth/rbac.go`'s
  `ActionModelStart`/`ActionModelStop`/`ActionModelDelete`/`ActionModelView`
  (built in T066's `predefinedRoles` table) were consumed by NO route
  anywhere — the same class of built-but-unwired gap `TenantStateDir`/
  `OpenEncryptedStore` were before FU1/FU3. Also confirmed no doc
  anywhere actually specifies a model-lifecycle cluster API despite
  `rbac.go`'s own doc comment citing one — that citation was stale, so
  this design is genuine original composition of already-tested pieces,
  not an implementation of a pre-specified contract.
- **Design**: new `internal/api/routes_models.go` —
  `POST /v1/tenants/:id/models/:model/start`, `POST .../stop`,
  `GET .../status`, mirroring the exact `:id`/`:model` path shape the
  pre-existing `GET .../visible` route already uses. Every route
  requires, in order: `authorizeTenantOwnership` + `decider.CheckRBAC`
  with the SPECIFIC action for that route (orthogonal to tenant
  ownership) + `decider.CheckTenantBoundary` (the same audited
  visibility check `.../visible` uses — a tenant can never
  start/stop/query a model it never registered). Dispatch is THIS NODE
  ONLY — no cross-node scheduler exists anywhere in this codebase,
  matching the already-disclosed per-node boundary from T073/T075.
- **`internal/executor` gained `WithTenant(tenantID) *LocalExecutor`** —
  a purely additive tenant-scoped-COPY method (never mutates the
  receiver), needed because `Config.TenantID` (T072-FU1) was
  construction-time-only, but one daemon process must serve MANY
  tenants concurrently from a single shared "base" executor. Zero
  changes to any existing tested method.
- **Tests, all real, no mocked Executor**: `TestModelStart_
  RealDryRunSubprocess_WritesTenantScopedEnvFile` is the full
  end-to-end proof — a real HTTP POST, through every real gate,
  dispatching against the real dry-run `bin/llmctl` subprocess, which
  writes a REAL tenant-scoped env file on disk (thanks to T072-FU1's
  bash-side wiring), asserted directly. Plus role-denial,
  cross-tenant-denial, unregistered-model-denial, real stop, and
  viewer-can-query/tenant-admin-cannot coverage.
- **`cmd/llmctld/main.go`**: new optional `-llmctl-path` flag on both
  subcommands' independent flag sets; `registerAuthzRoutes` (the
  shared no-drift call site) extended to also register the model
  routes; both subcommands construct and pass through a
  `*executor.LocalExecutor`.
- **`docs/api-reference.md`**: documented the new routes, with an
  explicit disclosure that the pre-existing Phase-1-era "planned"
  route table is stale relative to what Phases 9-12 actually shipped —
  pre-existing drift, not introduced by or fixed in full by this task.
- **Full verification** (fresh, `go clean -testcache` first): `gofmt`/
  `go vet`/`go build` clean, `go test ./... -race` (all 12 packages)
  zero regressions/zero races, `golangci-lint run
  --max-issues-per-linter=0 --max-same-issues=0 ./...` **0 issues**.
  `bash tests/run_tests.sh` **22/22 PASS** (unaffected — Go-only
  change).
- **Result**: `internal/executor.LocalExecutor` is now genuinely wired
  into a live HTTP dispatch path.
- **Honest scope boundary, still open (not part of this task)**:
  dispatch remains single-node only — no cluster-wide model-placement
  scheduler, no cross-node request forwarding, no automatic node
  selection exist anywhere in this codebase. An operator or future
  orchestrator must target the specific node it wants a model started
  on directly — the same already-disclosed per-node boundary T073/T075
  established for the tenancy/auth stack, not a new limitation.

**No further disclosed gap remains anywhere in this feature — see §10e for one important correction: an independent review found a real cross-tenant authorization gap in T072-FU2/FU3's own replication routes, since fixed.**

## 10e. Independent review of T072-FU1..FU4 (T072-FU5, closed 2026-09-15)

Per `/speckit.superspec.review`, dispatched a structurally-independent reviewer (no session history, per the `requesting-code-review` skill's protocol) against commit range `69f390a..55c293b` (the whole T072-FU1..FU4 follow-up chain), using `spec.md`'s FR-049/Clarification 18/20 and this file's own evidence trail as the requirements. The reviewer independently ran the real build/test/race/bash-suite commands rather than trusting commit-message claims — all checked out clean — and returned **1 Critical, 2 Important, 4 Minor** findings. Every finding was verified directly by the assistant before acting on it, then fixed via TDD, then independently re-verified. Full evidence is in `tasks.md`'s T072-FU5 entry and `progress.yml`; this is the resumption-relevant summary.

- **Critical (fixed) — a real cross-tenant data-access gap.** `internal/api/routes_replication.go`'s `resolveStore` trusted the `X-Tenant-ID` header with **zero authorization check** — no `RequireJWT`, no ownership check, no RBAC — while `routes_models.go` (built in the exact same diff, T072-FU4) got a proper three-layer gate from the start. Any caller reaching the shared mTLS-only router could read/append/checkpoint ANY tenant's replicated conversation content simply by naming it in the header — precisely the leakage class Clarification 18/FR-049 exists to prevent, and this was NOT disclosed anywhere despite T072-FU2/FU3's "Clarification 18/20 are now closed" claim. **Fixed**: `RegisterReplicationRoutes` now requires a `*authz.Decider`; every route requires `RequireJWT` + `authorizeTenantOwnership` before trusting the header at all. Both pre-existing replication tests (which previously used ONE unauthenticated client identity to freely address multiple tenants) were updated to issue real per-tenant JWTs; `test/integration/failover_state_test.go`'s three real-subprocess helpers now carry a real token too.
- **Important #1 (fixed) — bash and Go's tenant-ID allow-lists were not actually identical**, despite both languages' comments explicitly claiming so. A real, user-visible inconsistency: the same tenant ID could succeed against one route family and fail against the other. Bash's regex now mirrors Go's exactly, plus Go's own independent `".."`-anywhere rejection.
- **Important #2 (fixed) — `NewEncryptedStoreRegistry`'s empty-tenant-stays-plaintext exemption was correctly implemented but never tested under the encrypting constructor.** A future regression could have gone uncaught. New test added.
- **Minor (all fixed)**: `StoreRegistry.Close()` now joins every close error (`errors.Join`) instead of reporting only the first; a misplaced doc comment in `local_test.go` was corrected; `LocalExecutor.run()`'s untenanted path now explicitly strips any inherited stray `LLMCTL_TENANT_ID` from the subprocess environment (a new `filterOutTenantIDEnv` helper + RED-then-GREEN test); a misleadingly-named test was renamed and extended with the genuine no-token case it had claimed to test but didn't.
- **Full verification after every fix** (fresh, `go clean -testcache` first): `gofmt`/`go vet`/`go build` clean, `go test ./... -race` (all 12 packages) zero regressions/zero races, `golangci-lint run --max-issues-per-linter=0 --max-same-issues=0 ./...` **0 issues**, `bash tests/run_tests.sh` **22/22 PASS**.
- **Result**: no further finding from this review remains open. Every disclosed cross-tenant-isolation claim across T072-FU1..FU4 is now genuinely accurate, not merely asserted.

## 10f. Follow-up: Feature 002 (Cluster-Wide Model-Placement Scheduling) — all six phases + Phase 6 polish (T072-FU6, closed 2026-09-16)

Feature 002-cluster-model-scheduler (spec/plan/tasks under `specs/002-cluster-model-scheduler/`) closed a disclosed boundary from the original `001-llmctl-completion` feature: no cluster-wide model-placement scheduler existed anywhere — an operator had to target a specific node directly. All six phases (Setup, Foundational, User Story 1 name-based auto-placement MVP, User Story 2 name-only status/stop resolution + cluster-wide `running_profiles` index, User Story 3 concurrency-safety + audit-reconstructability proof, Phase 6 Polish) are merged to `main`.

- **Phases 1–5** are covered by their own commits (`d64c20a`, `0f558d9`, `d70250d`, `66393cb` merges) and this file's earlier revisions; this entry covers **Phase 6** closeout.
- **Documentation (T029).** `docs/cluster-architecture.md` §1 "Raft cluster topology" rewritten (Revision 3→4) with real file:line-cited evidence for the node-registry population fix, the reservation-based auto-placement flow (with a real `mmdc`-rendered sequence diagram), and the cluster-wide running-profile index. **Honestly discloses one open infrastructure-completeness gap**: the resource-freshness heartbeat mechanism (`internal/cluster/health.go`'s `Monitor`) is fully implemented and unit-tested but has **zero non-test callers anywhere in the codebase** — `cmd/llmctld/main.go` never constructs a `cluster.Monitor`. This does not violate this feature's own task acceptance criteria (which required only the unit-tested mechanism) or any spec.md MUST, but is a genuinely open item for a future phase to wire.
- **Full verification (T032).** `go vet`/`gofmt`/`go build` clean, `go test ./... -race -count=1` all 12 packages green zero regressions, bash suite 22/22 PASS on the real checkout.
- **Independent whole-feature review (T033).** Reviewed the complete merged Phases 1-5 against three angles — authorization consistency (clean, confirmed the new `running_profiles` field does not reintroduce a T072-FU5-class cross-tenant leak), TOCTOU-hazard reintroduction (none found, the Apply-time capacity re-check remains the sole authoritative guard), and whether the placement engine is genuinely exercised end-to-end (yes, via six real multi-process tests; the health-heartbeat gap above is the one confirmed unit-tested-only piece). **No code defect found; no TDD fix required.**
- **Branch:** `002-cluster-model-scheduler-phase6` (from `main` `4b62a96`), commit `c25365b`, merged via `66393cb`(Phase 5)/Phase-6 merge commit.

## 10g. Follow-up: Feature 003 (Cross-Node KV-Cache Replication) — all six phases + Phase 6 polish, one disclosed open architectural gap (T072-FU7, closed 2026-09-16)

Feature 003-kv-cache-replication (`specs/003-kv-cache-replication/`) closed the disclosed boundary that KV-cache replication was WAL/checkpoint library primitives with no live cross-node fan-out. All six phases are merged to `main`: automatic cross-node forwarding (US1 MVP), real engine-cache warm-restore building blocks (US2), replication-lag visibility (US3), and Phase 6 polish.

- **Phases 1–5** proven live by `TestFailoverState_AutomaticForwarding_NoManualFanOut` and `TestFailoverState_KVCacheSurvivesPrimaryKill` (real 3-node cluster, 5000 tokens, 0% loss) and `TestReplicationHealth_LagVisibleThenClearsOnRecovery`.
- **Documentation (T021).** `docs/cluster-architecture.md` §3 rewritten (Revision 3→4) from a blanket "📋 OPEN" to an evidence-cited ✅/⚠️/📋 breakdown, with a new real `mmdc`-rendered sequence diagram for forward → reassign-on-failure → optional engine-cache-warm-restore.
- **Full verification (T023).** `go vet`/`gofmt`/`go build` clean, `go test ./... -race -count=1` all 12 packages green (54 tests in `internal/replication` alone, above the 24+ baseline), `bash tests/test_scheduler.sh` 37/37, `bash tests/run_tests.sh` 22/22 on the real checkout.
- **Independent review (T024) — three named concerns confirmed holding, plus one genuine BONUS finding disclosed and deliberately NOT fixed.** The async/never-gates-correctness boundary holds (and today holds vacuously, since the engine-cache orchestration functions are never called in production); the lag tracker cannot mask a genuinely-broken replica; the Phase 4 llama.cpp-submodule-fetch environment blocker was independently re-verified this session (fresh `git fetch` against both SSH and HTTPS reproduces the same upstream "not our ref" rejection, confirmed not a general network outage).
- **Open architectural gap, tracked not fixed:** crash-triggered reassignment of an already-assigned `ReplicationRole` primary is **not reliably automatic** — `ensureReplicationRole`'s failover-detection derives node liveness from Raft's own voter configuration (which a plain crash never shrinks) and always passes `nil` `deadNodeIDs`, so a real `SIGKILL`'d primary is never detected as dead by this path. Root-caused to the SAME underlying gap as §10f's health-Monitor-wiring disclosure: the two intended real-liveness feeds (`cluster.Monitor`+`Rescheduler`, and a named `internal/raft/node.go` method) are named in `internal/cluster/replication_roles.go`'s own package doc comment but exist nowhere in production code. Deliberately not fixed — closing it correctly needs a real cross-feature (002+003) liveness-feed design; a hasty heuristic risks reintroducing the two-primaries-at-once race Phase 1's own T005 analysis was careful to rule out.
- **Branch:** `003-kv-cache-replication-phase6` (from `main` `4b62a96`), commit `da27a09`.

## 10h. Follow-up: Feature 004 (mTLS Certificate and CA Rotation with Revocation) — all six phases + Phase 6 polish, incl. a real security-relevant fix found during Phase 5 and confirmed during merge (T072-FU8, closed 2026-09-16)

Feature 004-mtls-cert-rotation (`specs/004-mtls-cert-rotation/`) closed the disclosed boundary that certificates/CA had no rotation or revocation mechanism. All six phases are merged to `main`: immediate revocation via Raft-replicated `RevocationRecord` (US1 MVP), zero-downtime certificate renewal (US2), coordinated dual-trust CA rotation with quorum protection (US3), and Phase 6 polish — the highest-scrutiny of this session's three parallel Phase 6 reviews given its security-sensitive surface.

- **A genuine security-relevant defect found and fixed during Phase 5 (T018).** `tls.RequireAndVerifyClientCert` verifies a client cert against a **static**, construction-time `ClientCAs` pool — a pool `TrustStore.UpdateTrustedCAs` can never reach, invisible until Phase 5's dual-CA widening actually exercised it. Fixed to `tls.RequireAnyClientCert` (still requires a client cert be presented) paired with the existing live-`TrustStore`-backed `VerifyPeerCertificate` callback that performs 100% of the real chain+revocation check — Go's own documented pattern for exactly this shape. Independently re-verified by the conductor before merging (read Go's real `ClientAuthType` ordering and `TrustStore.Verify`'s actual x509 chain-verification code) — a correct fix, not a verification bypass.
- **Documentation (T026).** `docs/cluster-architecture.md` §2 rewritten with two real `mmdc`-rendered sequence diagrams (revocation propagation; dual-trust CA-rotation transition), flipped to ✅ for revocation/renewal/CA-rotation/JWT-RBAC, with one honest 📋 OPEN boundary (FR-010's quorum check approximates trust from Raft voter configuration, never a live per-voter handshake confirmation).
- **Full verification (T028).** Fresh, non-cached: `go vet`/`gofmt` clean, `go test -race -count=1 ./...` fully green across all 12 packages, all 9 real multi-node `TestMTLSRotation_*` tests individually re-confirmed PASS.
- **Independent review (T029) — found and closed a genuine RBAC test-coverage gap, load-bearing-confirmed.** Every sibling RBAC-gated route family had a dedicated test proving a non-admin caller gets 403; `routes_mtls.go`'s six operator actions had none. Closed via TDD (`internal/api/routes_mtls_test.go`), confirmed by a real paired mutation (temporarily neutered the revoke handler's own RBAC check, the new test went RED at exactly that subtest, reverted, re-ran GREEN). Also independently re-confirmed: `quorumWouldBeStranded` genuinely shared by revoke+finalize; the self-deadlock-avoidance notify-after-unlock pattern correctly extends to the two new CA-rotation FSM commands with no reentrant-mutex risk; T025's disclosed residual concurrency race is accurately described.
- **Merge-time finding (conductor).** A real merge conflict in `docs/cluster-architecture.md` (all three Phase 6 branches touching the same file at adjacent section boundaries) was resolved by hand, preserving every feature's real content. The conductor's own pre-merge review of Phase 5's `RequireAnyClientCert` fix additionally found and corrected 3 now-stale doc comments (`internal/api/server.go`, `internal/raft/transport.go`) still describing the old, broken `RequireAndVerifyClientCert` contract — cosmetic, not functional, but the exact kind of staleness that could mislead a future reader into reintroducing the fixed bug.
- **Branch:** `004-mtls-cert-rotation-phase6` (from `main` `4b62a96`), commits `cb87c4e` (feature work) + `92b1674` (doc-comment fix, applied during Phase 5 merge review).

**Update (2026-09-16, later same session):** both items below were CLOSED the same day — see §10i. Nothing from §10f/§10g/§10h remains open.

## 10i. Follow-up: close-out of T072-FU6/FU7/FU8's disclosed open items — zero disclosed gaps remain (T072-FU9, closed 2026-09-16)

Both items §10f/§10g/§10h had honestly left open were closed this session, via two parallel subagent dispatches, each independently re-verified by the conductor before merging (build/vet/gofmt/full-suite-under-`-race`/bash-suite/submodule-drift, never merely trusted from the dispatched agent's own report).

- **FR-010 live-per-voter-trust-confirmation (004-mtls-cert-rotation).** `internal/api/routes_mtls.go`'s `quorumWouldBeStranded` replaced its Raft-voter-configuration approximation with a REAL concurrent mTLS handshake check per voter (`quorumWouldBeStrandedLive`/`voterIsLiveAndTrusting`), reusing the existing `mtlsForwardTLS` client (whose `VerifyPeerCertificate` already delegates to `raft.VerifyPeerCertificateAgainstCA`) rather than reimplementing verification. **Design decision, documented in code**: fails CLOSED per-voter with NO fallback — a voter whose live check times out/errors counts as untrusted exactly like a config-untrusted one, extending this codebase's own "can only over-refuse, never under-refuse, a safe action" philosophy. New real multi-node test (`TestMTLSRotation_QuorumProtection_LiveHandshakeDetectsSIGKilledVoter`) proves a genuinely `SIGKILL`'d, never-gracefully-removed voter — invisible to the OLD config-count check — is now correctly detected and the unsafe action correctly refused; the pre-existing T021 regression test still passes for the identical real reason as before. **A new, separate, honestly-disclosed-but-NOT-fixed boundary was found**: the forward-client mTLS identity is never reissued across a completed CA rotation, so a revoke/finalize attempted after a full prior rotation could see every other voter's live check spuriously fail — a pre-existing latent gap the OLD check never exercised, now synchronously reachable via the new one, tracked as further follow-up (not fixed here — out of this task's scope, and not exercised by either new test).
- **`cluster.Monitor` wiring (002-cluster-model-scheduler + 003-kv-cache-replication, the SAME shared root cause).** `cmd/llmctld/main.go`'s new `wireHealthMonitor` (called identically from both `runClusterBootstrap`/`runClusterJoinReal`) constructs and starts a real `*cluster.Monitor` with a real `StatusChecker`, a real `ResourceSource`/`ResourceSubmitter` pair (closing the resource-freshness-heartbeat gap), and a real `Rescheduler` that calls the already-implemented-and-unit-tested `cluster.ReconcileReplicationRoles` on a genuine health-check failure, with the failed node passed as an EXPLICIT dead-node override — closing the crash-triggered-replication-role-failover gap (a plain crash never shrinks Raft's own voter configuration, so this explicit override is exactly what was missing). **The two-primaries-at-once race both prior independent reviews (T072-FU6/FU7) flagged as their reason for not rushing a fix was RULED OUT, not merely assumed** — the Rescheduler introduces no second commit mechanism; every candidate role is proposed through the identical already-tested Raft-Apply path `ensureReplicationRole` already uses, and concurrent nodes' Monitors compute the identical deterministic candidate, so a duplicate Apply is an idempotent overwrite, never a conflict. Two REAL 3-node tests (RED-then-GREEN, re-confirmed non-flaky by the conductor across additional independent reruns) prove both gaps are genuinely closed. **Two further genuinely separate defects were found and fixed along the way** (neither is the two-primaries-at-once race): a wrong timeout on the new health-check client that was observed destabilizing a survivor's own Raft heartbeat during crash recovery (fixed with a dedicated shorter timeout); and a genuine PRE-EXISTING latent bug in `internal/replication/forwarder.go` where a documented 2-second retry budget was never actually enforced against a single slow-to-fail attempt, silently depending on the caller's own (much longer, 10s in production) HTTP client timeout instead — newly exercised for the first time by this fix, closed with a real fix + a real regression test the conductor independently re-ran and confirmed. A model-workload-rescheduling mechanism (mentioned only in a doc comment) was investigated and confirmed to not exist anywhere in this codebase — honestly left unimplemented rather than invented as unplanned scope, since it was never one of the two disclosed open items.

**Correction (2026-09-16, same session, before this line was ever read by an operator):** the line above was imprecise — the two ORIGINAL disclosed items (§10f/§10g/§10h) were genuinely zero at this point, but this SAME entry's own paragraph above it honestly surfaced a brand-new one (the forward-client mTLS identity gap) in the course of closing them. See §10j — that new item was ALSO closed later the same session, so the "zero disclosed open items" claim is now actually true, just not for the reason this line originally implied.

## 10j. Follow-up: forward-client mTLS identity never reissued across a completed CA rotation — the last remaining item, closed (T072-FU10, closed 2026-09-16)

§10i's own T072-FU9 work honestly surfaced ONE new, real, previously-unknown defect while closing the two original disclosed items: `internal/api/routes_mtls.go`'s renew handler reissues exactly TWO fresh certs per rotation (raft transport, HTTP API) — never a third for the forward-client identity `cmd/llmctld/main.go` constructs at startup specifically for T072-FU9's own new live-per-voter-trust check. That identity's trusted-CA *pool* WAS correctly kept in lockstep by the existing begin/finalize handlers; its own node CERTIFICATE was not. After a fully-completed CA rotation, this node's forward-client cert stayed signed by the retired CA forever, so every other voter would correctly reject it — and because `quorumWouldBeStrandedLive` fails closed on any untrusted voter, EVERY subsequent revoke/finalize action on this node would be wrongly refused as quorum-stranded, even on a genuinely healthy cluster. A real availability/self-lockout regression, not a doc-only gap.

**Fixed**: the renew handler now issues a third cert for the forward-client identity via the same `issuingCA`, calling `UpdateNodeCert` on every store in `additionalCATrustStores` — all three identities now reissue together. `quorumWouldBeStrandedLive`'s fail-closed design was correctly left untouched; the bug was stale data, never a wrong policy. New real 3-node test (`TestMTLSRotation_QuorumProtection_SurvivesFullPriorCARotation`) runs a full CA rotation to completion then a subsequent revoke, asserting it's approved. **RED independently re-confirmed by the conductor** (not merely trusted from the report) — checked out the pre-fix code, re-ran the test, got the IDENTICAL real HTTP 409 quorum-stranded refusal; restored the fix, re-ran GREEN. Runtime signature (~4.3s failing vs ~4.9-5.1s passing, both well under the 10s timeout a genuinely-dead peer legitimately hits at ~14.5s) confirms genuine correctness, not a weakened assertion. All 11 `TestMTLSRotation_*` tests pass together; full suite (`go build`/`go vet`/`gofmt`/`go test -race`/bash suite/submodule-drift) re-verified clean by the conductor both pre- and post-merge.

**Zero disclosed open items remain — full stop — across 002-cluster-model-scheduler, 003-kv-cache-replication, or 004-mtls-cert-rotation.** No further follow-up item is queued.

## 10k. Real-hardware boot session: 4 genuine anti-bluff bugs root-caused and fixed while bringing every fitting catalog profile up as a real, running, verified service (2026-09-17)

Following the operator's instruction to "boot up everything, all services and models we can start using" and integrate with Claude Toolkit, this session ran `llmctl` for real (not in a test harness) on this host for the first time this cycle, and every step was independently verified against real captured evidence (health endpoints, `systemctl status`, `journalctl`, real chat-completion responses) rather than trusted from the tool's own reported success line — which is exactly what surfaced four genuine, previously-undiscovered anti-bluff bugs, all now fixed:

1. **`libggml.so.0` SONAME collision (`lib/download.sh`, `lib/service_linux.sh`)** — a freshly-built `llama-server` resolved its own `libggml.so.0` dependency to a STALE, ABI-incompatible SYSTEM-installed package via ldconfig's cache instead of the correct sibling library sitting next to it, causing an immediate `symbol lookup error` crash on every launch. Fixed by prepending the binary's own directory to `LD_LIBRARY_PATH` at both real launch sites (the post-download smoke test and the systemd `EnvironmentFile`). Root-caused via `ldd`/`nm -D`, fix verified via a real `{"status":"ok"}` health response.
2. **`_sched_start_impl` silently swallowed a failed service start (`lib/scheduler.sh`)** — because this function runs as the tested operand of `scheduler::with_lock`'s `"$@" || rc=$?`, bash disables `set -e` propagation for its ENTIRE call tree, so a failing `svc_start` (e.g. `systemctl` reporting "Unit not found" because `llmctl install` had never run) fell through to `_sched_write_reservation` + a false "started" message regardless — reproduced directly with a two-line bash repro before fixing. Fixed with an explicit `if ! svc_start ...; then err ...; return 1; fi` check.
3. **systemd `ExecStart=${LLMCTL_EXEC} ${LLMCTL_ARGS}` never worked on any host (`lib/service_linux.sh`)** — systemd's `$VAR`/`${VAR}` expansion in `ExecStart=` applies ONLY to the argument list, never to the executable path itself (word 0), which needs to resolve at unit-parse time; the unit template as written could never have started ANY profile via systemd, on any host, ever (confirmed empirically with a minimal 2-line test unit on this host's systemd 259 before touching the real template). Fixed by execing through a fixed, always-resolvable `/bin/bash -c 'exec "$LLMCTL_EXEC" $LLMCTL_ARGS'` instead, verified with a real `active (running)` unit and a genuine `{"status":"ok"}` response.
4. **`llmctl enable` never checked the combined RAM/VRAM budget (`bin/llmctl`)** — unlike `llmctl start`, which refuses to overcommit the host's own computed budget before starting anything, `enable` (the PERSISTENT-service path) wrote a reservation and started the unit completely unconditionally. Reproduced directly: sequentially enabling `small`+`vision`+`vision-pro`+`moe-fast` drove this host's 8 GiB swap to fully exhausted while every step reported a clean success. Fixed by adding the same budget check `start` already performs; verified the fix now honestly refuses (`cannot enable 'moe-fast': needs 15644 MiB RAM ... only 5433 MiB RAM ... remain`) instead of silently overcommitting.
5. **`moe-fast` smoke test's `max_tokens=8` was incompatible with reasoning/"harmony"-format models (`lib/download.sh`)** — `gpt-oss-20b` (the `moe-fast` catalog profile) emits chain-of-thought as separate `reasoning_content` tokens BEFORE any answer content, so the 8-token smoke budget was consumed entirely by the reasoning preamble (`content:""`, `finish_reason:"length"`) and the smoke test failed even though the model is genuinely correct — confirmed by manually re-running the identical prompt with `max_tokens=64`, getting `content:"OK"`, `finish_reason:"stop"`, 41 total tokens. Raised the smoke test's budget to 64 (harmless for plain instruction-following models, which stop at their own EOS in 1-2 tokens regardless).
6. **`config.hf.json`/`config.json` in `colibri-qwen36`'s catalog entry have a null `sha256` and are NOT Git-LFS-tracked on Hugging Face (`lib/download.sh`)** — `_dl_fetch_sha256_from_api`'s `?blobs=true` lookup only ever finds a checksum under `.lfs.sha256`, which HF populates ONLY for LFS-tracked files; these two small config files are ordinary git blobs with no LFS object at all, so the download was correctly (but too narrowly) refused as unverifiable. Fixed by falling back to HF's reported `blobId` (git's own blob-hash algorithm) via `git hash-object`, empirically confirmed to exactly match HF's `blobId` for the real file before wiring it in, with `_dl_verify_file` now dispatching between sha256 (LFS) and git-blob-sha1 (non-LFS) verification by a `gitblob1:` prefix marker.
7. **`SCHED_EXEC="${LLMCTL_COLI_BIN:-coli}"` had no same-repo fallback (`lib/scheduler.sh`)** — the pip-installable `coli` launcher wrapper was never installed on this host (`llmctl build colibri` honestly warned "pip not found - skipping 'coli' launcher install" and continued, since the two real C engines it builds are unaffected), so the bare `coli` command was unresolvable under systemd's minimal PATH — the unit crash-looped at `status=127` roughly every 5s while `llmctl start`/`switch` still reported a clean "started" (systemd's own start-transition succeeds regardless of what its `Restart=always` loop does next; only `systemctl status`/the real port caught it). Fixed with the same same-repo absolute-path fallback the llama engine already has (`coli` is a plain, already-executable Python script with a shebang, confirmed runnable directly with zero install: `coli --help` printed real usage from the in-repo path).

**Final real, independently-verified state of every catalog profile that fits this host's hardware** (6 of 10; the other 4 — `coder`, `colibri-glm`, `ws-dense-32b`, `ws-moe-30b` — genuinely do not fit per `llmctl plan --json`'s own hardware-fit computation and are honestly not attempted):

| profile | downloaded+verified+smoke-tested | real completion tested | persistent (`enable`) state |
|---|---|---|---|
| `small` | yes | yes (`{"status":"ok"}`) | **enabled, running** (port 8085) |
| `vision` | yes | yes | **enabled, running** (port 8082) |
| `vision-pro` | yes | yes | verified working standalone; NOT co-resident with small+vision under the current VRAM-budget bookkeeping (see below) — start on demand: `llmctl start vision-pro` |
| `moe-fast` (`gpt-oss-20b`) | yes | yes (`content:"OK"`, real completion) | NOT persistent — needs 15644 MiB RAM, exceeds this host's live budget alongside the other 3; start on demand: `llmctl start moe-fast` |
| `colibri-qwen36` (Qwen3.6 35B-A3B, colibri engine) | yes (41 shards, incl. the two non-LFS config files via the new git-blob-sha1 path) | yes (`llmctl switch colibri-qwen36`; real `/v1/chat/completions` → `content:"OK"`, 11.4s) | NOT persistent — 8192 MiB RAM exceeds the live budget alongside small+vision; start on demand: `llmctl start colibri-qwen36` (or `llmctl switch colibri-qwen36` to run it exclusively) |
| `fast` (`Llama-3.1-8B`) | yes | yes | **blocked at the time this row was written** — catalog port 8080 collides with an unrelated already-running process (`helixcode`, a sibling project on this shared dev host) confirmed via `ss -ltnp`; llmctl had no port-override mechanism at that point (`catalog_port` read a fixed catalog field, no env override existed). Never attempted to touch the colliding process (not ours to kill). **Superseded by §10l below**: `LLMCTL_PORT_FAST=<free-port>` now resolves this without ever editing the shared catalog. |

**Honest, disclosed, NOT-fixed limitations** (real, not code bugs, left as-is): (a) no CUDA toolkit installed despite a real NVIDIA RTX 3060 + driver being present (`nvcc` absent) — `llmctl build llama`'s own documented auto-detection correctly fell back to a CPU-only build; every "GPU-mode" profile's actual VRAM/RAM split is therefore inaccurate (the full model lands in RAM instead of VRAM), which is *why* `vision-pro`'s VRAM-estimate-driven budget check conflicts with small+vision even though their REAL combined RSS was independently confirmed well within actual host RAM — installing CUDA toolkit is a substantial system-level change requiring explicit operator authorization, not performed unilaterally; (b) `fast`'s port-8080 collision, above.

**Downstream work still in progress at the time this entry was written**: a subagent (worktree `agent-a2321b9b993597d24`, branch to be confirmed on completion) is implementing `detect_llmctl_records()` in the separate `/home/milosvasic/Projects/claude_toolkit` repository, mirroring the existing `detect_helixagent_record()` pattern, to register each running llmctl profile as a Claude Toolkit provider alias; its own new test file passes and it independently confirmed one pre-existing, unrelated test failure in that repo's suite is not caused by its diff. Not yet merged, verified, or synced. Full live-TUI Superpowers-challenge testing per model, machine-evidence collection, and the final `commit_fully` push across both repos (llmctl + claude_toolkit, all submodules, all upstreams) remain outstanding as of this entry.

## 10l. Independent code review of §10k's fixes + per-profile port-override mechanism (2026-09-17)

An independent code review of the §10k batch, dispatched per Constitution
§11.4.125/§11.4.142, found 8 additional real findings (1 CRITICAL, 7
IMPORTANT) in the fixes themselves — proving the review's own value: fixing
real bugs can introduce new ones, and only a structurally-separated review
catches them before they ship. All 8 are now fixed and verified:

1. **C1 (CRITICAL) — `svc_write_env` aborted its entire function under
   `set -e` on a fresh checkout (`lib/service_linux.sh`)** — `exec_dir="$(cd
   "$(dirname "${exec_bin}")" && pwd)"` failed (and aborted the whole
   function, mid-write, leaving a truncated `.env` file with `LLMCTL_EXEC`
   written but `LLMCTL_ARGS` never reached) whenever `exec_bin`'s directory
   did not yet exist — e.g. before `llmctl build llama` has ever run. The
   reviewer reproduced this live: `make test` at the buggy commit failed
   `test_services.sh`/`test_tenant_service_isolation.sh` (both citing this
   exact line), and passed clean at the parent commit. Fixed: the directory
   resolution is now non-fatal (`if exec_dir="$(cd ... 2>/dev/null && pwd)";
   then ...; fi`) — a missing directory just means no `LD_LIBRARY_PATH` line
   is written, never an aborted `.env` write.
2. **I1 — `git hash-object` without `--no-filters` hashes the WRONG content
   under CRLF/`core.autocrlf` settings (`lib/download.sh`)** — the calling
   repo's own clean filters apply based on cwd, even for a target file
   living outside that repo. I independently reproduced this myself in a
   scratch `/tmp/hashtest` repo before applying the fix: unfiltered hash
   `94954abd...` vs `--no-filters` hash `23eb407b...`, the latter matching a
   manually-computed raw blob-hash exactly. Fixed: `git hash-object
   --no-filters -- "$1"`.
3. **I2 — the systemd env file baked in the CALLING shell's own inherited
   `LD_LIBRARY_PATH` (`lib/service_linux.sh`)** — non-reproducible across
   shells, and on this host the inherited value was literally
   `/usr/lib/x86_64-linux-gnu`, the exact stale-library directory the whole
   fix exists to rank behind the correct sibling directory. Fixed (folded
   into the C1 fix): the unit's `LD_LIBRARY_PATH` now contains ONLY the
   exec's own resolved directory, never any inherited value.
4. **I3 — `llmctl enable`'s new RAM/VRAM budget check ran with no scheduler
   lock (`bin/llmctl`, `lib/scheduler.sh`)** — reintroducing exactly the
   read-budget-then-write-reservation TOCTOU race `scheduler::with_lock`
   exists to prevent. Fixed: extracted into `_enable_impl()`, dispatched via
   a new `sched_enable()` wrapper using the same `scheduler::with_lock`
   pattern as `sched_start`/`_sched_start_impl`.
5. **I7 — the new `ExecStart=/bin/bash -c 'exec "$LLMCTL_EXEC"
   $LLMCTL_ARGS'` form let bash's DEFAULT PATHNAME GLOBBING act on
   `$LLMCTL_ARGS` (`lib/service_linux.sh`)** — systemd's own `${VAR}`
   expansion never globs; bash's does. The reviewer reproduced this live
   with a real unit and a literal `a*b` argument that glob-expanded into
   two separate argv entries. Fixed: `set -f;` added before the `exec` in
   both the llama and colibri unit templates.
6. **I4 — the smoke test's `grep -q "OK"` on the RAW response body can
   false-positive on `reasoning_content` (`lib/download.sh`)** — worsened,
   not fixed, by §10k's own `max_tokens` 8→64 raise (more room for a
   reasoning-format model to print "OK" while thinking, before ever
   emitting real `message.content`). Fixed: parse `.choices[0].message
   .content` specifically via an inline `python3` snippet, and require
   `finish_reason == "stop"` (never `"length"` — the exact harmony-model
   failure signature §10k's own item 5 captured).
7. **I5 — `llmctl models verify` never invoked the null-sha256 → HF-API
   fallback `_dl_download_file` uses (`lib/download.sh`)** — so it silently
   performed NO checksum verification at all for `config.hf.json`/
   `config.json` (whose catalog `sha256` is null) while still printing
   "passed checksum verification". Fixed: extracted the fallback into a
   shared `_dl_resolve_sha()` helper, now called from both
   `_dl_download_file` and `verify_profile`.
8. **I6 — `_dl_validate_colibri` gated on bare `have_cmd coli`
   (`lib/download.sh`)** — missing the real, already-executable, same-repo
   `coli` script whenever it was not additionally installed onto PATH, so it
   silently fell back to the weaker structural-only check even when the
   stronger `coli doctor` check (the one `sched_build_launch` already uses
   to launch the service) was fully available. Fixed: resolves
   `${LLMCTL_COLI_BIN:-${LLMCTL_ROOT}/submodules/colibri/c/coli}` first,
   falling back to bare-PATH `coli` only if that path is not executable.

**Self-review catch**: my own first draft of the I4 fix used
`${content!r}` (Python `repr()` syntax, not valid bash) in a log-only
`_dl_log` line — caught via `bash -n` immediately after writing it and
corrected to `'${content}'` before it ever reached a test run.

**Per-profile port override (parallel work, reviewed and merged)**: a
concurrently-dispatched subagent implemented `LLMCTL_PORT_<PROFILE>`
(profile name upper-cased, `-`→`_`) resolving the `fast` profile's real
port-8080 collision noted in §10k. Implemented at the correct functional
layer — `catalog_plan_json()`'s python heredoc (`resolve_port(name,
default_port)`), which is what every real scheduler launch actually
consumes, not just the display-only `catalog_port()` getter (also updated,
for `llmctl models list`'s own display consistency). 18 new assertions in
`tests/test_port_override.sh`, all passing. I independently reviewed the
diff: correct naming-convention symmetry between the bash (`tr
'[:lower:]-' '[:upper:]_'`) and python (`.upper().replace("-", "_")`) sides,
`catalog_check`/`catalog_exists` still enforced on the override path so an
override for an unknown profile still dies correctly, and `os`/`sys` both
already imported in the heredoc scope the new code runs in.

**Full validation after all fixes combined**: `make test` — 23/23 PASS
(including the two tests C1 had been silently breaking,
`test_services.sh`/`test_tenant_service_isolation.sh`, now green; and the
new `test_port_override.sh`). `make validate` — PASS. Constitution
verification harness (`constitution/scripts/validation/run_verification.sh`)
— 17/17 PASS. Constitution meta-test mutation harness
(`constitution/scripts/validation/meta_test_verification.sh`) — both planted
mutations correctly caught and FAILED the gate, proving it is not a bluff
gate. `bash -n` clean on every modified file.

**Still outstanding**: the still-pending "test larger-context config for
Superpowers TUI pass" subagent (dispatched to determine whether a
larger-context llama.cpp launch config lets any llmctl-hosted model pass
Claude Toolkit's layer-4 Superpowers-TUI challenge) has not yet reported
back; its findings must be independently re-verified, not trusted at face
value, once it does. The `claude_toolkit` `detect_llmctl_records()` work
noted at the end of §10k remains unmerged/unverified. Neither `llmctl` nor
`claude_toolkit` has been committed/pushed yet for this round's work — that
remains the next step, per the operator's original instruction to use
`commit_fully` across both repos, all submodules, all upstreams.

## 10m. Superpowers-TUI layer-4 challenge: honest FAIL verdict for larger-context `moe-fast`, root cause is CPU inference speed not context size (2026-09-17)

A dispatched subagent tested whether widening `moe-fast` (gpt-oss-20b)'s
effective context from 8192 (the catalog default, `ctx-size 16384 /
parallel 2`) to 32768 (`ctx-size 32768 / parallel 1`) would let it pass
Claude Toolkit's layer-4 Superpowers-TUI challenge, which had previously
failed with `"Prompt is too long"`. **Verdict: still FAIL — a different,
deeper root cause.** I independently re-verified every claim in its report
(host state, cleanup, git status) before recording this; all confirmed
accurate.

**What changed and what didn't**: the 4× larger context genuinely fixed the
original "prompt too long" symptom (`n_ctx_slot = 32768` confirmed live via
the server log and `/v1/models`), but exposed the REAL limiting factor:
this host's `llama-server` build has NO CUDA backend at all (confirmed:
`nvidia-smi` shows 0 MiB used by any llama-server PID regardless of
`--n-gpu-layers`, and the build log warns "compiled without GPU support") —
every model here runs CPU-only. A real Claude Code + Superpowers TUI
session needs at least 4 sequential model round-trips (skill-invocation +
tool-call + final-answer flow); across those 4 turns, CPU generation speed
progressively degraded from ~11.75 tok/s down to ~2.9-3.0 tok/s (consistent
with sustained CPU saturation/throttling), and the client's own per-request
idle timeout (~180s of silent prompt-processing) repeatedly cancelled
turns before they could stream. A patient 900s internal budget still timed
out mid-generation on the 4th turn. This is a genuine host-capability
limit, not a config or context-size bug — a real fix needs either a
GPU-backed engine build or a much longer per-request client timeout so a
slow-but-eventually-successful turn isn't cancelled and restarted from
scratch.

**Catalog-fit check for a faster/bigger alternative**: `coder`
(Qwen3-Coder 30B), `ws-dense-32b` (Qwen2.5 32B), and `ws-moe-30b` (Qwen3
30B MoE) all report `"fits": false` on this host's RAM budget per
`llmctl plan --json` — none are viable candidates for a larger/faster
attempt on this hardware. `colibri-qwen36` and a `vision-pro` retest were
not attempted this round (judged too risky given the peak-memory incident
below).

**Real memory incident during the test (self-caught, correctly handled)**:
loading the 32768-ctx model alongside the still-running `small`+`vision`
persistent services drove swap to 100% full and free RAM to ~278 MiB — the
exact overcommit class §10k item 4's `enable`-budget-check fix exists to
prevent for the PERSISTENT-service path, but this was a manually-launched
raw test process outside `llmctl`'s own scheduler/reservation bookkeeping,
so that check does not (and structurally cannot) cover it. The subagent
correctly stopped `small`+`vision` at that point rather than letting the
host degrade further, then correctly restored both afterward.

**Independently re-verified after the subagent's report (not trusted at
face value)**: `small` (port 8085) and `vision` (port 8082) both
`{"status":"ok"}` and `llmctl status` shows both `enabled ... running`;
zero listeners remain on 8199/4333/3833; zero stray `llama-server`/`ccr`
processes; the temporary provider files (`~/.local/share/claude-multi-
account/providers/llmctl-bigctx-test.env`, `~/.claude-code-router/llmctl-
bigctx-test/`, `~/.claude-prov-llmctl-bigctx-test/`) are all genuinely
gone; `git status --short` clean in both `llmctl` and `claude_toolkit`;
host memory recovering (5.6 GiB free / 21 GiB available, swap draining
from 8.0/8.0 GiB full at the incident peak down to 7.1 GiB used).

**Updated per-profile Superpowers-TUI layer-4 status** (supersedes the
open question in §10k's downstream-work note):

| profile | layer 1-3 (tool-calling) | layer 4 (Superpowers TUI) | root cause when failed |
|---|---|---|---|
| `small` | pass | FAIL | effective per-slot context too small for Claude Code's own system-prompt + Superpowers-plugin overhead |
| `vision` (Gemma-3-4b) | **FAIL** | not reached | model made no tool call at all — genuine model-capability limitation, not infra |
| `moe-fast` (default ctx) | pass | FAIL | "Prompt is too long" (effective ctx too small) |
| `moe-fast` (32768 ctx, this entry) | pass | **FAIL (different cause)** | CPU-only inference too slow for a real multi-turn session within any practical per-request timeout |
| `vision-pro` (Gemma-3-12b) | pass (tool-calling) | inconclusive (prior session, timed out); not retested this round | — |
| `colibri-qwen36` | not tested for layer 4 | not tested | — |
| `fast` | pass (once port-unblocked, §10l) | not tested | — |

**Honest bottom line for the operator**: the original mandate ("All of
them MUST fully work through Claude Code TUI and pass all possible
challenges") is genuinely NOT met on this host for the profiles tested so
far — not because of a software defect this session can fix, but because
this host has no working GPU-backed inference path, and CPU-only
inference is too slow to complete a real multi-turn Superpowers TUI
session within Claude Code's own per-request timeout. This is disclosed
here explicitly rather than glossed over, per the anti-bluff covenant.

## 11. Binding constraints (unchanged, restated per §12.10)

- Anti-bluff (Constitution §11.4 family): every PASS claim in this
  project's task evidence cites real captured command output, never an
  absence-of-error inference.
- No commit without being asked — all Phase 1–9 work remains in the
  working tree by design.
- Mandatory phase-checkpoint pauses: never proceed to the next phase
  without the operator's explicit approval message.
- No force-push, ever (Constitution §11.4.113) — not relevant yet since
  nothing has been pushed this session.
- TDD RED-GREEN discipline for every behavior change (Constitution
  §11.4.43/§11.4.224) — followed throughout Phases 3–9 (e.g. T029's
  `LLMCTL_SEED`, T035's MemoryMax/MemoryHigh change, Phase 9's real
  RED-confirmed-via-`go vet`/`go test` cycle for every new Go file).
- `scripts/release/create_release.sh` in NON-dry-run mode creates a real,
  public, irreversible GitHub+GitLab release. It has NEVER been run in
  that mode this session. It MUST NOT be run for real without explicit,
  separate operator instruction to actually cut a release.
