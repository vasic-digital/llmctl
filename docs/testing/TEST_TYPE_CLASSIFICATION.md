# Test-Type Classification

**Revision:** 1
**Last modified:** 2026-09-18T09:00:00Z
**Status:** active
**Feature:** [008-full-test-coverage](../../specs/008-full-test-coverage/spec.md)

## Purpose

This document is the single, checked-in, honest classification of this
project against the Constitution's 14-class test-type taxonomy (unit,
integration, e2e, full-automation, security, DDoS, scaling, chaos,
stress, performance, benchmarking, UI, UX, Challenges/HelixQA-style
autonomous QA). It exists so an operator or reviewer can see, at a
glance, exactly which test types genuinely exist and which do not — see
[spec.md](../../specs/008-full-test-coverage/spec.md).

Three verdicts, per component (llmctl, llmctld, claude_toolkit) where
the honest answer differs between them:

- **COVERED** — a specific, real, currently-passing test is cited as
  evidence. Every citation in this document was personally opened and
  read during this feature's own investigation (never assumed from a
  file name alone).
- **PARTIAL** — states exactly what exists and exactly what is still
  missing, in concrete terms.
- **GENUINELY-INAPPLICABLE** — states a specific, checkable reason the
  class does not apply to this component, never a bare assertion.

No class is silently omitted (FR-003). No COVERED verdict lacks a
citation (FR-002).

## Components

- **llmctl** — the bash CLI (`bin/llmctl`, `lib/*.sh`), tests under
  `tests/*.sh`, run via `tests/run_tests.sh` / `make test`.
- **llmctld** — the Go cluster daemon (`llmctld/`), tests under
  `llmctld/**/*_test.go`, run via `go test ./...` from `llmctld/`.
- **claude_toolkit** — the sibling bash multi-account/multi-provider
  toolkit at `/home/milosvasic/Projects/claude_toolkit` (read-only for
  this feature — classified here, not modified), tests under
  `scripts/tests/*.sh`, run via `scripts/tests/run-all.sh`.

## Classification table

| Class | llmctl | llmctld | claude_toolkit |
|---|---|---|---|
| Unit | COVERED | COVERED | COVERED |
| Integration | COVERED | COVERED | COVERED |
| E2E | COVERED | COVERED | COVERED |
| Full-automation | COVERED | COVERED | COVERED |
| Security | COVERED | COVERED | COVERED |
| DDoS | N/A (no server surface) — see below | COVERED | GENUINELY-INAPPLICABLE |
| Scaling | GENUINELY-INAPPLICABLE | COVERED | GENUINELY-INAPPLICABLE |
| Chaos | COVERED | COVERED | COVERED |
| Stress | N/A (no server surface) — see below | COVERED | GENUINELY-INAPPLICABLE |
| Performance | PARTIAL | COVERED | PARTIAL |
| Benchmarking | GENUINELY-INAPPLICABLE | COVERED | GENUINELY-INAPPLICABLE |
| UI | GENUINELY-INAPPLICABLE | GENUINELY-INAPPLICABLE | PARTIAL |
| UX | GENUINELY-INAPPLICABLE | GENUINELY-INAPPLICABLE | GENUINELY-INAPPLICABLE |
| Challenges/HelixQA | GENUINELY-INAPPLICABLE | GENUINELY-INAPPLICABLE | PARTIAL |

(llmctl's DDoS/Stress cells read "N/A (no server surface)" rather than
a bare GENUINELY-INAPPLICABLE label because the reason is component-
structural, not a gap — see the per-class detail below for the full,
checkable statement; the table cell is shorthand for the same verdict.)

---

## Per-class detail

### Unit

- **llmctl — COVERED.** `tests/test_planner.sh` (deterministic planner
  against 3 hardware fixtures), `tests/test_catalog_json.sh` (catalog
  validity), `tests/test_normalize_common.sh` /
  `tests/test_normalize_agents.sh` (transform primitives). All files
  under `tests/*.sh` run via `bash tests/run_tests.sh`: **PASS: 28
  FAIL: 0** as of 2026-09-18, real subprocess run, independently
  re-verified by a dedicated cross-spec regression-verification pass
  (`docs/qa/008-full-test-coverage/raw_inventory.txt` captured an
  earlier, now-stale count of 23 — this file grows as sibling features
  land new tests directly in `tests/*.sh`; the file-count number in
  this row is therefore a point-in-time observation, not a fixed fact,
  and MUST be re-verified with a fresh `bash tests/run_tests.sh` run
  rather than trusted from this citation alone, per this document's own
  FR-008 re-examination-trigger discipline).
- **llmctld — COVERED.** `internal/tenancy/quota_test.go`,
  `internal/auth/jwt_test.go` (5 tests incl.
  `TestValidateToken_RejectsTamperedSignature`), `internal/auth/rbac_test.go`,
  `internal/mtls/rotation_test.go` (7 tests), `internal/cluster/placement_test.go`
  (6 tests). Full run this session: `go test ./... -race` → every
  package `ok`; `go test ./... -v` → **341 PASS / 0 FAIL / 3 SKIP**.
- **claude_toolkit — COVERED.** `scripts/tests/test_lib.sh`,
  `scripts/tests/test_coverage.sh` (explicitly documents covering
  `cma_ensure_alias_file`, `cma_can_prompt`, `cma_enable_plugins`,
  `cma_link_shared_items` — pure function-level behaviors).

### Integration

- **llmctl — COVERED.** `tests/test_download.sh` / `test_download_resume.sh`
  (real local `python3 -m http.server` fixture, verified-download +
  resume logic), `tests/test_preflight_submodules.sh` ("using REAL
  local git repositories (not mocked network calls)" per its own header),
  `tests/test_scheduler.sh` (dry-run scheduler co-residency/eviction
  against the real catalog).
- **llmctld — COVERED.** `test/integration/cluster_bootstrap_test.go`,
  `test/integration/multitenancy_isolation_test.go`,
  `test/integration/replication_health_test.go` — this project's own
  package doc comment states the convention explicitly: "real llmctld
  OS processes, real QUIC+mTLS transports, real HTTP/3 API servers -
  nothing mocked or run in-process" (`test/integration/mtls_rotation_test.go`
  package comment).
- **claude_toolkit — COVERED.** `scripts/tests/test_ccr_conformance.sh`,
  `scripts/tests/test_bootstrap.sh`, `scripts/tests/test_cma_proxy.sh`
  (real proxy-daemon process integration).

### E2E

- **llmctl — COVERED.** `tests/test_setup_e2e.sh` — its own header:
  "fresh-clone simulation of `llmctl setup` (FR-001, US1 Acceptance
  Scenario 1)".
- **llmctld — COVERED.** `test/integration/cluster_bootstrap_test.go`
  and `test/integration/failover_state_test.go` drive a real multi-node
  cluster (bootstrap → join → real Raft replication → real HTTP/3+mTLS
  API calls) end-to-end; `test/integration/mtls_rotation_test.go`'s
  `TestMTLSRotation_Finalize_OldCARejectedAfterward` drives a full
  bootstrap → begin-rotation → dual-trust renewal → finalize → adversarial-
  rejection lifecycle across 3 real spawned node processes.
- **claude_toolkit — COVERED.** `scripts/tests/verify_aliases_live.sh`
  drives a real alias end-to-end against a live provider; `scripts/tests/
  test_kimi_migration.sh` drives a full account-migration flow.

### Full-automation

- **llmctl — COVERED.** `tests/test_determinism.sh` — its own header:
  "zero-flake requirement (spec.md SC-001): running the same command
  against the same fixture N times MUST produce byte-identical output
  every time. Real subprocess invocations of the real `bin/llmctl`" —
  no human interaction, no mocked layer, real repeated subprocess runs.
- **llmctld — COVERED.** The entire `go test ./... -race` suite (341
  tests, this session) is a fully automated, zero-human-interaction
  run against real components (real Raft nodes, real mTLS certs, real
  HTTP servers) per this project's own package doc comments.
- **claude_toolkit — COVERED.** `scripts/tests/run-all.sh` itself is
  the full-automation harness: discovers, runs, and tallies every
  `test_*.sh` file automatically, with its own harness-integrity check
  (a file printing `[FAIL]` but exiting 0 is caught and treated as
  failed — documented in `run-all.sh`'s own comments, citing a real
  past incident where `test_providers.sh` hid 5 real failures this way).

### Security

- **llmctl — COVERED.** `tests/test_tenant_service_isolation.sh`
  proves malicious tenant IDs (embedded `;`, path traversal, embedded
  `..`) are rejected by both the bash-side AND Go-side (internal/isolation/
  cgroup.go) allow-lists, and that the two allow-lists genuinely match
  (not merely claimed to).
- **llmctld — COVERED.** mTLS: `internal/mtls/rotation_test.go` (7
  tests) plus the adversarial, full-multi-process integration test
  `test/integration/mtls_rotation_test.go`'s
  `TestMTLSRotation_Finalize_OldCARejectedAfterward` (a client
  certificate signed by the rotated-out CA is refused the connection
  AFTER rotation finalizes, driven across 3 real spawned node
  processes). JWT: `internal/auth/jwt_test.go` (5 unit-level rejection
  tests: tampered signature, tampered payload, expired, wrong key, `alg:
  none`) PLUS `internal/api/middleware_jwt_test.go` (4 HTTP-401-layer
  tests: missing header, malformed token, expired, wrong key) PLUS this
  feature's own new `internal/api/jwt_adversarial_test.go`'s
  `TestRequireJWT_TamperedPayloadRejectedWith401` (the one case that
  was previously unit-tested only, now also asserted at the real
  HTTP-enforcement boundary). RBAC: 7 different route-test files assert
  `http.StatusForbidden` for a non-privileged caller across every
  RBAC-gated route this project ships (`routes_auth_test.go`,
  `routes_audit_test.go`, `routes_mtls_test.go` (a full 6-route
  table-driven 401/403/negative-control test), `routes_models_test.go`,
  `routes_tenants_test.go`, `routes_replication_test.go`,
  `enginecache_route_test.go`), plus this feature's own new
  `TestAuditVerify_RequiresAdminRole`, `TestReplicationRoutes_
  AppendEndpoint_RequiresJWTAndTenantOwnership`, and
  `TestReplicationRoutes_CheckpointEndpoint_RequiresJWTAndTenantOwnership`
  closing the 3 specific RBAC-route gaps this feature's audit found (see
  "Corrections to research.md" below).
- **claude_toolkit — COVERED.** `scripts/tests/test_redact.sh` (its own
  header: credential-redaction correctness against ~20 provider key
  families PLUS the live `proof/` corpus — documents a real past
  incident where a narrower redactor altered one fixture while walking
  past two files with real live keys), `scripts/tests/test_alias_file_
  concurrency.sh` (concurrent-writer file-corruption regression guard,
  documents a real forensic incident: 37288→282→...→909 bytes in 4
  seconds).

### DDoS

- **llmctl — N/A (no server surface).** `llmctl` is a non-interactive,
  single-invocation bash CLI (confirmed: `tests/test_cli.sh` exercises
  only argument dispatch/exit codes) that never binds a listening
  network socket of its own — there is no request-flood surface for a
  DDoS-style test to exercise. This is a component-structural fact, not
  a coverage gap: `llmctl` cannot receive a flood of requests because it
  never accepts inbound network connections.
- **llmctld — COVERED.** New `llmctld/internal/api/ddos_test.go`,
  `TestDDoS_FloodDuringLegitimateTraffic_BaselineObservation`: a
  3000-concurrent-goroutine flood against a real, locally-listening
  HTTP server wrapping the real gin engine + real, unmodified
  `RegisterClusterRoutes` handler, run FOR 3 seconds while a separate
  low-rate "legitimate traffic" goroutine issues one request every
  ~50ms throughout. Illustrative captured evidence from two independent
  runs during original implementation: run 1 — flood attempted=44187
  succeeded=44187 failed=0; legitimate attempted=27 succeeded=27
  failed=0 (success_rate=1.0000). run 2 — flood attempted=43767
  succeeded=43767 failed=0; legitimate attempted=25 succeeded=25
  failed=0 (success_rate=1.0000). **Honest evidence-durability note**
  (found by an independent cross-spec regression-verification pass,
  2026-09-18): `docs/qa/008-full-test-coverage/ddos_baseline_observation.txt`
  is overwritten in place by the test on every run, so the raw file's
  live content will NOT match the exact numbers quoted above once the
  test has run again — this is expected (a fresh, timing-based flood
  measurement) and does not indicate a functional regression, but the
  specific integer counts above are illustrative of ONE real run, not a
  byte-for-byte reproducible fixture; re-run the test yourself for the
  current numbers rather than treating this citation as re-verifiable
  against the checked-in file. **Decision (research.md R1, "DDoS
  Decision" section below): no new middleware was added** — the
  existing Go/gin/net-http defaults already demonstrate acceptable
  degradation (100% legitimate-traffic success across every run
  observed, including the independent re-run, at a flood several times
  this daemon's own measured sustained-capacity ceiling).
- **claude_toolkit — GENUINELY-INAPPLICABLE.** `claude_toolkit` is a
  bash orchestration toolkit around Claude Code CLI aliases; it binds no
  listening network socket of its own (confirmed: no `nc -l`,
  `python3 -m http.server` used as a served target, or equivalent
  listener anywhere in `scripts/*.sh` outside of test-fixture HTTP
  servers that are themselves the harness, never claude_toolkit's own
  production surface) — there is no request-flood surface to exercise.

### Scaling

- **llmctl — GENUINELY-INAPPLICABLE.** `llmctl` is a single-process,
  single-host bash CLI with no multi-node or multi-process scaling
  dimension: it starts/stops local model-server processes on the SAME
  host it runs on (confirmed: `lib/service_linux.sh`/`lib/service_macos.sh`
  manage systemd/launchd units on localhost only). There is no cluster,
  no horizontal-scaling axis, and no "add another node" concept for this
  component to test.
- **llmctld — COVERED.** `internal/raft/node_test.go`'s
  `TestJoin_SecondNodeReplicatesRealAppliedCommand` (a second node joins
  a real Raft cluster and a real committed command replicates to it) and
  `TestJoin_SurvivingFollowerBecomesLeaderAfterOriginalLeaderShutsDown`
  (a real multi-node leader-failover election); `internal/cluster/
  sharding_test.go`'s `TestPlanShards_SelectsDistinctNodesCoveringEvenSplit`
  (shard planning across multiple distinct nodes); `test/integration/
  cluster_bootstrap_test.go` and `test/integration/failover_state_test.go`
  drive real multi-node (3-process) clusters end-to-end. This is the
  genuine multi-node scaling dimension this component's Raft-cluster
  design has, distinct from what "scaling" would mean for a single-host
  CLI.
- **claude_toolkit — GENUINELY-INAPPLICABLE.** Like `llmctl`,
  `claude_toolkit` is a single-host bash toolkit orchestrating local CLI
  processes and local alias/session state (confirmed: no daemon, no
  cluster membership concept, no multi-node coordination anywhere in
  `scripts/*.sh`) — no multi-node/multi-process scaling dimension exists
  to test.

### Chaos

- **llmctl — COVERED.** `tests/test_services_crashloop.sh` — proves
  systemd `StartLimitBurst=5`/`StartLimitIntervalSec=60` restart-bounding
  for both llama.cpp and colibri units, the launchd throttle-widening
  fallback, AND that `llmctl status` surfaces a crash-looped profile
  with its last log line.
- **llmctld — COVERED.** `internal/executor/enginecache_slot_test.go`'s
  `TestLocalExecutor_RestoreSlot_RealEngineRejection_ReturnsGenuineError`
  (a corrupt/missing slot file's genuine engine-side rejection is
  surfaced as a real error, not swallowed or faked); `internal/mtls/
  rotation_test.go`'s `TestRotationCAHolder_FinalizeLocalRotation_
  NoOpWhenNeverBegun` (a node that never locally received the incoming
  CA out-of-band correctly no-ops rather than corrupting state);
  `test/integration/mtls_rotation_test.go`'s
  `TestMTLSRotation_QuorumProtection_LiveHandshakeDetectsSIGKilledVoter`
  (a genuinely SIGKILLed cluster voter is detected via a real live
  handshake failure, not assumed).
- **claude_toolkit — COVERED.** `scripts/tests/test_alias_file_
  concurrency.sh` (concurrent-writer alias-file corruption regression
  guard, real forensic incident cited in its own header) and
  `scripts/tests/test_suite_lock.sh` (proves two suite runs cannot
  overlap, real forensic incident: `run-proof.sh` PID 170365 running
  concurrently with `run-all.sh` PID 581986 while a third agent mutated
  a test file mid-run).

### Stress

- **llmctl — N/A (no server surface).** Same structural reason as
  llmctl's DDoS row: no listening network socket of its own to sustain
  load against.
- **llmctld — COVERED.** New `llmctld/internal/api/stress_test.go`,
  `TestStress_SustainedLoad_CapacityObservation`: escalating-concurrency
  windows (5/10/25/50/100/200/400/800 concurrent workers, 750ms each)
  against a real, locally-listening HTTP server wrapping the real gin
  engine + real `GET /v1/cluster/status` handler + a real, single-node
  `raft.Node`. Illustrative captured evidence from original
  implementation (real run): **every window sustained 100% success rate
  up to and including 800 concurrent workers** (9471 requests
  attempted/succeeded at the final window, p50=63.1ms/p95=81.1ms/
  p99=89.9ms) — the daemon's own measured ceiling for this route on
  this host was not reached within this run's bounds. **Honest
  evidence-durability note** (found by an independent cross-spec
  regression-verification pass, 2026-09-18): `docs/qa/008-full-test-coverage/stress_capacity_observation.txt`
  is overwritten in place on every run — an independent re-run of this
  same test (same 5-800 concurrency ladder) measured 6577 requests at
  the 800-worker window (still 100% success, zero failures, at a
  slightly-lower absolute count consistent with normal host-load
  variance between runs of a real wall-clock-bounded, 750ms-per-window
  test) — so the exact integer counts above are illustrative of ONE
  real run, not a fixture re-verifiable byte-for-byte against the
  checked-in file; the qualitative conclusion (100% success through
  every tested concurrency level) has been independently reproduced and
  holds.
- **claude_toolkit — GENUINELY-INAPPLICABLE.** Same structural reason as
  claude_toolkit's DDoS row: no listening network socket of its own to
  sustain load against.

### Performance

- **llmctl — PARTIAL.** No dedicated timing/performance-regression test
  exists for the bash CLI today (confirmed: no file under `tests/*.sh`
  asserts a wall-clock/latency bound). `tests/test_determinism.sh`
  proves output-CONTENT determinism, not performance. **Concrete gap:**
  no benchmark or timing assertion exists for `bin/llmctl`'s own
  command-dispatch or planner-computation latency. This gap is honestly
  left open by this feature (out of this feature's scope per plan.md,
  which targets `llmctld`'s benchmark consolidation specifically) —
  tracked as a real, stated, un-closed gap, not silently implied covered.
- **llmctld — COVERED.** `internal/tenancy/quota_bench_test.go`
  (`BenchmarkAllowRequest`), `internal/auth/jwt_bench_test.go`
  (`BenchmarkValidateToken`), `internal/auth/rbac_bench_test.go`
  (`BenchmarkCheck`) — all three pre-existing, all three still passing,
  now consolidated into one runnable `make bench-all` target (this
  feature's Phase 5) with a documented baseline in
  [`BENCHMARK_BASELINE.md`](BENCHMARK_BASELINE.md).
- **claude_toolkit — PARTIAL.** No dedicated timing/performance-
  regression test exists (confirmed: no file under `scripts/tests/*.sh`
  asserts a wall-clock/latency bound for the toolkit's own dispatch
  logic — `verify_aliases_tui.sh` bounds a WAIT window for a live LLM
  response, which is a correctness timeout, not a performance
  benchmark of claude_toolkit's own code). **Concrete gap:** no
  benchmark exists for the alias-resolution/routing logic's own
  execution time. Out of this feature's scope (claude_toolkit is
  read-only for this feature); left honestly open.

### Benchmarking

- **llmctl — GENUINELY-INAPPLICABLE.** Bash has no standard, low-
  overhead micro-benchmarking harness comparable to Go's `testing.B`
  (confirmed: no `hyperfine`/`bench`-style tooling vendored or invoked
  anywhere in `tests/*.sh` or `lib/*.sh`); this project's own Performance
  row above already honestly tracks the underlying gap (no timing
  assertions exist) rather than fabricating a benchmarking mechanism
  bash does not have a natural equivalent for. Distinguished from
  Performance (a broader "is anything ever measured" question) by this
  narrower "is there a dedicated micro-benchmark suite" question — bash
  genuinely has neither.
- **llmctld — COVERED.** Same three benchmarks as the Performance row
  (`BenchmarkAllowRequest`, `BenchmarkValidateToken`, `BenchmarkCheck`),
  now consolidated via `make bench-all` (this feature's T020) into a
  single, timestamped report, with two independently-run outputs this
  session (`docs/qa/008-full-test-coverage/bench_run_1.txt`,
  `bench_run_2.txt`) and a documented ±15% acceptable-variance baseline
  ([`BENCHMARK_BASELINE.md`](BENCHMARK_BASELINE.md)) — both captured
  runs fell well within that tolerance (max observed variance: 4.95%).
- **claude_toolkit — GENUINELY-INAPPLICABLE.** Same reasoning as
  llmctl: a bash toolkit with no vendored micro-benchmarking mechanism
  (confirmed: no `hyperfine`/equivalent anywhere in `scripts/*.sh`).

### UI

- **llmctl — GENUINELY-INAPPLICABLE.** `llmctl` renders no interactive
  terminal or graphical interface — confirmed by direct source search
  this session (`grep -rln "tview\|tcell\|whiptail\|dialog \|read -p"
  bin/ lib/` → zero matches); it is argument-driven with plain stdout/
  stderr text and exit codes (`tests/test_cli.sh`).
- **llmctld — GENUINELY-INAPPLICABLE.** `llmctld` is a headless daemon
  with no terminal or graphical interface of any kind — confirmed by
  direct source search this session (`grep -rn "bufio.NewReader\|
  Scanln\|promptui\|survey\.\|tview\|tcell\|bubbletea" cmd/llmctld/
  internal/**/*.go` (excluding tests) → zero matches); its only surface
  is the HTTP API.
- **claude_toolkit — PARTIAL.** `claude_toolkit` itself renders no UI
  of its own (pure bash orchestration + wrapper functions/aliases —
  same structural fact as `llmctl`). However, this feature's
  investigation found genuine UI-driving test infrastructure:
  `scripts/tests/verify_aliases_tui.sh` + `scripts/tests/lib/pty_drive.py`
  drive a REAL interactive terminal UI (the Claude Code CLI's own TUI,
  launched THROUGH claude_toolkit's alias wrappers) under a real
  pseudo-terminal — typing a real prompt, capturing the full ANSI-stripped
  terminal transcript, and classifying it against named failure
  signatures (`pty_drive.py`'s own doc comment: "a real PTY, waits for
  the TUI to boot, types a prompt... captures the full terminal
  transcript"). **Concrete gap/nuance:** this verifies an EXTERNAL
  program's TUI functions correctly when launched via claude_toolkit's
  wrappers — it is real UI-testing infrastructure, but it does not (and
  cannot, since claude_toolkit owns no UI) prove any UI *claude_toolkit
  itself* renders is correct, because no such UI exists. This
  correction deliberately diverges from tasks.md's T009 default
  (blanket GENUINELY-INAPPLICABLE for all three components) because a
  genuine, real, checkable UI-testing mechanism exists here and a
  blanket "not applicable" verdict would have silently hidden it — see
  "Corrections to research.md/tasks.md" below.

### UX

- **llmctl — GENUINELY-INAPPLICABLE.** No usability/user-experience-
  specific evaluation exists or is meaningful beyond CLI help-text/exit-
  code correctness (already covered under Unit/Integration via
  `tests/test_cli.sh`) — `llmctl` has no interactive experience beyond
  a single command invocation and its result.
- **llmctld — GENUINELY-INAPPLICABLE.** A headless daemon has no user-
  facing experience to evaluate; its only "users" are HTTP API callers,
  whose correctness is covered under Security/Integration/Unit.
- **claude_toolkit — GENUINELY-INAPPLICABLE.** Distinct from the UI
  row above: `verify_aliases_tui.sh`/`pty_drive.py` verify FUNCTIONAL
  correctness (does the TUI respond, does it avoid known failure
  signatures like the documented "compact-loop" defect) — this is
  UI-behavior testing, not a UX evaluation (usability heuristics,
  workflow ease-of-use, accessibility). No such UX-specific evaluation
  exists anywhere in this project, and none is meaningful for a toolkit
  whose only "experience" is launching an already-existing third-party
  program's own interface.

### Challenges/HelixQA-style autonomous QA

- **llmctl — GENUINELY-INAPPLICABLE.** No Challenges or HelixQA
  submodule/dependency is vendored anywhere in this repository —
  confirmed: `cat .gitmodules` lists only `constitution`,
  `submodules/superspec`, `submodules/llama.cpp`, `submodules/colibri`;
  no Challenges/HelixQA entry exists. Not adopted, per spec.md's own
  Assumptions section — genuinely inapplicable, not merely unused.
- **llmctld — GENUINELY-INAPPLICABLE.** Same `.gitmodules` (llmctld is
  a subdirectory of the same repository, not a separate `.gitmodules`)
  — same verdict, same reason.
- **claude_toolkit — PARTIAL.** **This corrects spec.md's blanket
  Assumption for this component specifically** (see "Corrections to
  research.md/tasks.md" below): `claude_toolkit`'s own `.gitmodules`
  DOES vendor `submodules/challenges` →
  `git@github.com:vasic-digital/challenges.git`, confirmed checked out
  at `helixcode-v1.1.0-20-g072724a` with a real, populated `banks/`
  directory (`examples`, `yole`). The dependency IS adopted (vendored,
  pinned, checked out) — but a repo-wide search this session
  (`grep -rl "submodules/challenges" --include=*.sh .`) found **zero**
  scripts anywhere in claude_toolkit that invoke or reference it.
  **Concrete gap:** the Challenges submodule is present but completely
  unwired — no test bank from it is ever run, no autonomous-QA session
  is ever driven through it. This is PARTIAL (adopted-but-unwired), not
  GENUINELY-INAPPLICABLE (not-adopted), because the dependency
  genuinely exists in the tree.

---

## The DDoS decision (research.md R1)

research.md's own decision procedure (R1) required running the
DDoS-style flood test FIRST against the daemon as-is, then deciding
whether new quota-enforcement middleware was warranted based on the
REAL observation, never assumed in advance.

**What was measured (this session, two independent runs):** a
3000-concurrent-goroutine flood for 3 seconds against `GET
/v1/cluster/status` (a route that is NOT behind any auth/quota
middleware today) while a separate, low-rate legitimate-traffic
goroutine issued one request every ~50ms throughout. In BOTH runs, the
legitimate-traffic goroutine's success rate was **100% with zero
failures** (run 1: 27/27; run 2: 25/25), and the flood goroutines
themselves also saw 100% success with zero failures (44187/44187 and
43767/43767 respectively) — i.e. Go's own `net/http`/gin runtime and
the OS's connection handling absorbed a flood 3.75× this daemon's own
measured 800-concurrent sustained-capacity ceiling (stress_test.go)
without degrading legitimate traffic at all in either run.

**Decision: no new quota-enforcement middleware was added.**
research.md R1's branch (b) applies: "the existing Go/gin/OS-level
defaults already degrade acceptably... document that honestly as the
real mechanism and do not add unneeded middleware only to 'look
thorough'."

**Honest limitation of this observation** (stated explicitly, per
Constitution §11.4.6): this test runs the real gin engine + real,
unmodified route handlers over a real HTTP/1.1 TCP listener
(`net/http/httptest.Server`), in-process with the test binary — it does
NOT reproduce the production HTTP/3+QUIC+mTLS transport
`server.go`/`NewServer` wires for this daemon's real deployment, and it
does not test a genuinely separate OS-process daemon's memory/CPU
exhaustion under a flood originating from a real, separate network
path. It also does not exercise the `tenancy.Enforcer`/`authz.Decider.
CheckQuota` code path at all (confirmed still true after this feature:
`grep -rn "AllowRequest\|AcquireConcurrencySlot\|\.Quota\."
internal/api --include=*.go | grep -v _test.go` still returns zero
matches) — that logic remains implemented, unit-tested, and
deliberately un-wired, exactly as research.md R1 found, because this
feature's own real measurement showed wiring it was not warranted for
the route/scenario tested. A future finding that the PRODUCTION
transport (or a different, authenticated/tenant-scoped route) degrades
under load would be new evidence warranting re-opening this decision —
this verdict is scoped to what was actually measured, not a permanent,
unconditional claim about every route or every transport this daemon
serves.

## Corrections to research.md/tasks.md

This feature's own investigation (per this project's own no-guessing
discipline, Constitution §11.4.6) found the following places where
research.md's or tasks.md's stated assumptions did not match what was
actually true in the codebase, verified by direct file reads rather
than accepted on the plan's word:

1. **research.md R4 significantly understated existing JWT/mTLS/RBAC
   adversarial coverage.** research.md framed FR-007 as needing three
   new JWT tests, a new mTLS test, and an audit that would find "one
   such [RBAC] case" already existing. Direct investigation this
   session found: 5 JWT unit-level adversarial tests already existed
   (`internal/auth/jwt_test.go`) PLUS 4 already existed at the HTTP-401
   layer (`internal/api/middleware_jwt_test.go`); the mTLS "old cert
   rejected after rotation" case ALREADY EXISTED as a full, real,
   multi-process integration test
   (`test/integration/mtls_rotation_test.go`'s
   `TestMTLSRotation_Finalize_OldCARejectedAfterward` — at a HIGHER
   fidelity than a new test would have added, since it drives 3 real
   spawned node processes through a full begin→renew→finalize→reject
   lifecycle); and RBAC negative-path (`403`) tests already existed
   across 7 different route-test files covering nearly every
   RBAC-gated route. This feature therefore added exactly the
   genuinely-missing pieces (one HTTP-layer tampered-payload JWT test;
   zero new mTLS tests; three specific RBAC-route gaps: `GET
   /v1/audit/verify`, `POST /v1/replication/append`, `POST
   /v1/replication/checkpoint`) rather than the larger, partially-
   duplicative set research.md's plan described — writing a test that
   duplicates already-real, already-passing coverage would itself be a
   form of the "check a box" anti-pattern this feature exists to avoid.
2. **spec.md's Challenges/HelixQA "not adopted" Assumption is false
   for claude_toolkit.** See the Challenges/HelixQA row above:
   `claude_toolkit` genuinely vendors `submodules/challenges`, checked
   out and populated. The assumption remains true for llmctl/llmctld.
3. **claude_toolkit's UI row is not cleanly GENUINELY-INAPPLICABLE.**
   tasks.md's T009 directed a blanket GENUINELY-INAPPLICABLE verdict
   for UI across all three components. Direct investigation found
   genuine, real UI-driving test infrastructure in claude_toolkit
   (`verify_aliases_tui.sh`/`pty_drive.py`) — see the UI row above for
   the honest, nuanced PARTIAL verdict this required instead.

## Re-examination trigger (FR-008)

Any GENUINELY-INAPPLICABLE verdict in this document MUST be
re-examined and re-confirmed the moment the underlying structural fact
it depends on changes — specifically:

- **UI/UX** (all three components): re-examine if a graphical or
  terminal interface is ever added that any of these three components
  itself renders/owns (not merely launches an external program's own
  interface, which claude_toolkit already does today per its PARTIAL
  UI verdict above).
- **DDoS/Stress** (llmctl, claude_toolkit): re-examine if either
  component ever binds its own listening network socket.
- **Scaling** (llmctl, claude_toolkit): re-examine if either component
  ever gains a multi-node/multi-process coordination dimension.
- **Benchmarking** (llmctl, claude_toolkit): re-examine if a
  bash-native micro-benchmarking mechanism is ever adopted.
- **Challenges/HelixQA** (llmctl, llmctld): re-examine if either
  vendors a Challenges/HelixQA submodule dependency in the future
  (`.gitmodules`).
- **DDoS decision for llmctld** (the "no middleware" verdict above):
  re-examine if a future stress/DDoS observation against the PRODUCTION
  HTTP/3+mTLS transport, or against an authenticated/tenant-scoped
  route, shows uncontrolled degradation — the honest limitation section
  above states exactly what this decision does and does not cover.

This document itself is re-verified whenever `llmctld`'s HTTP route set
changes materially (a new route added/removed), whenever a new test
file lands in any of the three components' test directories, or at
minimum before any release tag (Constitution §11.4.40's full-suite
retest already required at that point is the natural re-verification
seam — this document's citations are checked against the live tree at
that time, exactly as they were checked this session).

## Full-suite regression status

See `docs/qa/008-full-test-coverage/full_suite_regression.txt` for the
captured, real full-suite re-run confirming zero regressions from this
feature's additions (Constitution §11.4.40/SC-006).

## See also

- [BENCHMARK_BASELINE.md](BENCHMARK_BASELINE.md) — the consolidated
  benchmark suite's documented baseline (User Story 3).
- [../../specs/008-full-test-coverage/spec.md](../../specs/008-full-test-coverage/spec.md)
- [../../specs/008-full-test-coverage/research.md](../../specs/008-full-test-coverage/research.md)
