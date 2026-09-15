# CONTINUATION

**Revision:** 6
**Last modified:** 2026-09-15T00:00:00Z

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

**Phase 11 (User Story 9 — Built-in Authentication, Authorization &
Multi-Tenancy) is complete, pending checkpoint approval; Phases 1–10 are
approved.** All 11 Phase 11 tasks (T065–T075, including T074a) are done.
The operator has directed the agent to proceed autonomously through every
remaining phase (Phase 11 → Phase 12) without pausing for per-phase
approval, committing and pushing via `commit_fully` along the way — this
supersedes the default mandatory-checkpoint-pause rule for the remainder
of this run. The immediate next action is: **start Phase 12 (Polish &
Cross-Cutting Concerns)**, the final phase.

**Important standing constraint carried forward:** `scripts/release/create_release.sh`
in NON-dry-run mode creates a real, public, irreversible GitHub+GitLab
release. It has NEVER been run in that mode this session (only
`--dry-run`, and only against real fake-PATH-injected `gh`/`glab` binaries
in tests). It MUST NOT be run for real without explicit, separate operator
instruction to actually cut a release — completing Phase 8 is not that
instruction.

## 3. Phase-by-phase state

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
| 11 | US9 — Built-in Authentication, Authorization & Multi-Tenancy | **complete, pending checkpoint approval (T065–T075, 11/11)** |
| 12 | Polish & Cross-Cutting Concerns | in progress |

Full per-task evidence for every completed phase is in
`specs/001-llmctl-completion/tasks.md` (inline, per-task) and
`specs/001-llmctl-completion/progress.yml` (structured).

## 4. Live-state anchors

- **Git HEAD**: working tree only — nothing from this feature's work has
  been committed yet (by design; the operator has not asked for a commit).
  `git status` shows extensive modified/untracked files under `lib/`,
  `tests/`, `docs/`, plus the `vendor/` removal from Phase 3.
- **Test suite**: `bash tests/run_tests.sh` → **21/21 test files pass, 0
  failures** (first zero-failure run of this project was reached in Phase
  4; still 0 failures as of Phase 11 — Phase 11 added no new bash test
  files, only Go work).
- **Go suite**: `go test ./... -race` inside `llmctld/` (fresh, `go clean
  -testcache` first) → **all tests pass across all 12 packages, zero data
  races** (api, audit, auth, authz, cluster, executor, isolation, mtls,
  raft, replication, tenancy, test/integration — `auth`, `authz`, and
  `isolation` are new in Phase 11: JWT/RBAC/API-key/OIDC, the audited
  authZ/authN decision layer, and per-tenant systemd-scope wrapping;
  `api`/`cmd/llmctld`/`test/integration` grew — new `/v1/auth/*`,
  `/v1/tenants/*`, `/v1/audit/*` HTTP routes and a real 3-tenant
  1000-concurrent-request isolation test). **This module is now verified
  race-clean end-to-end for the first time this session** — Phase 11's
  work (the first genuine concurrent HTTP load this codebase ever drove)
  surfaced and fixed THREE real, previously-undiscovered data races (two
  in `internal/audit/log.go` + `internal/raft/fsm.go`, both present since
  earlier phases; see §8 below). `go build ./...`, `go vet ./...`, and
  `gofmt -l .` all clean.
- **Constitution verification harness**: `bash
  constitution/scripts/validation/run_verification.sh` → 17/17 submodules
  verified, 0 failures (T032).
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

## 10. Binding constraints (unchanged, restated per §12.10)

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
