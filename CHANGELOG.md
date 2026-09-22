# Changelog

All notable changes to llmctl are documented here. Entries below `## v3.0.0`
are the full conventional-commits history since `v2.0.0`, generated
deterministically by `scripts/release/create_release.sh`'s
`release_generate_changelog` function (same function used for the actual
GitHub/GitLab release notes, so this file and the published release notes
never drift).

## v3.0.0 (2026-09-22)

### Highlights

- **New distributed cluster subsystem (`llmctld`)**: Raft-based multi-node
  clustering, auto-placement scheduling, cross-node KV-cache replication with
  warm-restore, mTLS certificate issuance/rotation with zero-downtime
  renewal and live revocation, and full multi-tenancy (per-tenant quotas,
  RBAC, cgroup isolation, encryption at rest). This is the largest addition
  since `v2.0.0` — see the `### Features` section below for the complete,
  chronological build-out (features `002-cluster-model-scheduler`,
  `003-kv-cache-replication`, `004-mtls-cert-rotation`).
- **Reboot-survival fix**: `bin/llmctl status` (and the scheduler's own
  RAM/VRAM overcommit-safety accounting) previously went blind after a host
  reboot, because its sole source of truth was an ephemeral tmpfs marker
  file systemd never repopulates on its own. It now reconciles against real
  `systemctl --user` state and self-heals the missing record.
- **One-command install/bootstrap script** (`scripts/install.sh`): chains
  `setup` → `models download` → `install` → `enable` → a real
  `loginctl`-lingering check → `status`, closing the gap between "the
  systemd/lingering machinery already works" and "there's a single command
  a new user can run." Also fixed a real, independently-discovered bug: the
  on-disk systemd unit *template* can go missing while systemd still has
  units loaded from a prior install, silently breaking any future `enable`
  until `install` is re-run — the new script always re-runs `install`
  first.
- **LAN-accessible by default**: `llama-server`/`colibri serve` previously
  bound to `127.0.0.1` unconditionally, making every profile unreachable
  from any other device on the local network even though the service itself
  was healthy. The bind host is now `LLMCTL_BIND_HOST` (default `0.0.0.0`),
  overridable globally or per-profile (`LLMCTL_BIND_HOST_<PROFILE>`) to lock
  a profile back to loopback-only. **Security note**: llama-server's
  OpenAI-compatible API has no built-in authentication — binding it to
  `0.0.0.0` means any device on the local network can use it with no auth.
  Scope your network/firewall accordingly if that's not acceptable for your
  environment. `colibri` profiles keep their own independent fail-closed
  guard and require `COLI_ALLOW_INSECURE_BIND=1` to bind non-loopback.
- **Full test-type coverage classification** (`008-full-test-coverage`):
  honest classification of the project against the 14-class test taxonomy
  (unit/integration/e2e/full-automation/security/DDoS/scaling/chaos/stress/
  performance/benchmarking/UI/UX/Challenges), closing every real,
  applicable gap with genuine, non-mocked tests.
- **CUDA GPU inference** (`005-cuda-gpu-inference`): real GPU offload
  verified with a live throughput ratio and VRAM delta against actual
  hardware.

### Full conventional-commits history since v2.0.0

## Changelog since v2.0.0

### Features
- one-command install/bootstrap script for systemd --user persistence
- wire cluster join/leave, apikey create/rotate, tenant create/list/quota (T006-T011, T016-T020)
- add GET /v1/tenants and GET+PUT /v1/tenants/:id/quota routes (T012-T015)
- add Registry.List + Enforcer.GetLimits accessors (T002-T005)
- wire cluster.Monitor's resource heartbeat + health-driven replication-role failover (T072-FU6/FU7)
- Phase 6 (Polish) — architecture docs, full verification, review (T026/T028/T029)
- Phase 5 (User Story 3) coordinated CA rotation without outage
- Phase 5 (User Story 3) replication-lag visibility (T018-T020)
- Phase 5 (US3) concurrency-safety + audit-reconstructability integration tests (T026-T028)
- real engine cache warm-restore (User Story 2, T012-T017)
- Phase 4 (US2) name-only status/stop + cluster-wide running_profiles (T020-T025)
- Feature 004 Phase 4 (User Story 2) - zero-downtime mTLS cert renewal (T014-T017)
- T013/T014 real multi-process cluster-placement tests + fix two genuine races found by them
- implement US1 auto-placement start dispatch T015 T016 T017 T018 T019
- populate cluster.Node.APIAddr via Join/RegisterSelf (T017 prereq)
- add Node-level RecordRunningProfile/ClearRunningProfile T016 T017
- add per-profile resource-footprint lookup for placement T012-T019
- complete Feature 004 Phase 3 (User Story 1) - cert revocation with real-cluster verification (T007-T013)
- wire Forwarder + node-registration into the real join/bootstrap/HTTP path (003-kv-cache-replication T008 wiring)
- add resource-freshness heartbeat to health.Monitor T008
- make Join/Leave genuinely reach the FSM with real resources T004 T005 T006
- add raft.Node replication-role Apply wrappers + Forwarder (003-kv-cache-replication T008/T009 part 1)
- wire health-detected unhealthy primary to replication-role reassignment (003-kv-cache-replication T004)
- add CommandAssignReplicationRole/CommandReassignReplicationRole FSM commands (003-kv-cache-replication T003 part 2)
- implement TrustStore for live cert revocation/rotation (T003)
- add RunningProfile index and reservation-safe FSM commands T007 T009 T010
- add per-tenant ReplicationRole to ClusterState (003-kv-cache-replication T003 part 1)
- wire LocalExecutor into a live model-lifecycle dispatch API (T072-FU4)
- wire per-tenant encryption at rest into StoreRegistry (T072-FU3)
- wire TenantStateDir into internal/replication's Store (T072-FU2)
- wire per-tenant cgroup isolation into service-spawn path (T072-FU1)
- complete Phases 9-11 (distributed cluster, state persistence/recovery, auth/tenancy) with security fixes

### Fixes
- engine bind host hardcoded to 127.0.0.1, defeating LAN accessibility
- sched_running() never reconciled state after a reboot wiped *.run
- small profile's --parallel 2 silently halved its usable context
- bin/llmctl PATH-symlink resolution (needed for claude_toolkit's llmctl provider detection)
- bin/llmctl breaks when invoked through a PATH symlink
- propagate the LD_LIBRARY_PATH SONAME fix to the Go engine-cache test harness + close a real lint finding
- code-review remediation (C1 CRITICAL + I1-I7) + per-profile port override
- real-hardware anti-bluff bugs found while booting every fitting catalog profile as a genuine running service
- reissue forward-client mTLS identity on renew (T072-FU9 follow-up)
- forward the X-Tenant-ID header on cross-node replication forwards (003-kv-cache-replication T011)
- close a real cross-tenant data-access gap found by independent review (T072-FU5)

### Documentation
- capture 007 closure evidence + CONTINUATION.md §10q (claude_toolkit test fixes)
- add SpecKit spec/plan/research/tasks for features 005-007
- fix stale/non-reproducible citations found by regression-verification
- T028 update with the completed third claude_toolkit attempt (20/74 files, 491 PASS/0 FAIL, bounded timeout)
- T003-T012/T028/T029 honest 14-class classification document + regression evidence + README linking
- add spec/plan/research/tasks for the honest test-type classification feature
- update llmctl.md for real cluster/tenant/apikey commands (T021)
- record honest FAIL verdict for larger-context Superpowers-TUI challenge
- record T072-FU10 closure — genuinely zero disclosed open items remain across 002/003/004
- record T072-FU9 closure — zero disclosed open items remain across 002/003/004
- consolidate 002/003/004 Phase 6 follow-up work into shared 001-llmctl-completion tracking
- honestly update §3 KV-cache replication status for 003 Phases 1-5 (T021)
- document 002-cluster-model-scheduler node-registry, resource-heartbeat, reservation flow, running-profile index (T029)
- correct stale ClientAuth doc comments after T018's RequireAnyClientCert fix
- check off T001-T011 - Phase 1/2/3 complete (003-kv-cache-replication)
- check off T003/T007/T009/T010 as verified complete
- add kv-cache-replication spec set + T001/T002 scaffolding
- add commit-fully integration documentation

### Other
- evidence: refresh CUDA throughput/VRAM proof from this session's live run
- evidence: capture fresh re-run outputs from independent verification pass
- build+docs(llmctld): T020-T023 consolidated bench-all target + documented baseline
- security fix: PUT /v1/tenants/:id/quota must require tenant:manage, not self-ownership (post-review fix, T014/T015)
- docs+fix: resolve the 3 remaining audit gaps + retract a false-negative test claim
- Merge follow-up: reissue forward-client mTLS identity on renew (closes the last disclosed gap from T072-FU9)
- Merge follow-up: wire cluster.Monitor's resource heartbeat + health-driven replication-role failover (closes T072-FU6/FU7's disclosed gaps)
- Merge 004 follow-up: FR-010 live per-voter trust confirmation (closes T072-FU8's disclosed gap)
- WIP: T072-FU8 live-trust-confirmation follow-up (fix + tests, pre-RED-verification)
- Merge 004-mtls-cert-rotation Phase 6 (Polish): architecture docs + full verification + independent review
- Merge 003-kv-cache-replication Phase 6 (Polish): architecture docs + full verification + independent review
- Merge 002-cluster-model-scheduler Phase 6 (Polish): architecture docs + full verification + independent review
- Merge 004-mtls-cert-rotation Phase 5 (User Story 3): coordinated CA rotation without an outage
- Merge 003-kv-cache-replication Phase 5 (User Story 3): replication lag visibility
- Merge 002-cluster-model-scheduler Phase 5 (User Story 3): concurrency-safety + audit-reconstructability
- Merge 004-mtls-cert-rotation Phase 4 (User Story 2): zero-downtime certificate renewal
- Merge 003-kv-cache-replication Phase 4 (User Story 2): real engine cache warm-restore
- Merge 002-cluster-model-scheduler Phase 4 (User Story 2): name-only status/stop + cluster-wide running_profiles
- Merge feature 004-mtls-cert-rotation (Phase 1-3, User Story 1 MVP)
- Merge feature 003-kv-cache-replication (Phase 1-3, User Story 1 MVP)
- Merge feature 002-cluster-model-scheduler (Phase 1-3, User Story 1 MVP)
