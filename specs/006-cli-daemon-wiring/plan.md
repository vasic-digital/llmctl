# Implementation Plan: bash-CLI to Go-daemon Cluster/Tenant/Apikey Wiring

**Branch**: `006-cli-daemon-wiring` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/006-cli-daemon-wiring/spec.md`

## Summary

`bin/llmctl`'s `cluster join/leave`, `tenant create/list/quota`, and
`apikey create/rotate` subcommands all currently `die` with "not yet
implemented" despite `llmctld` already implementing five of the seven
underlying operations as real, tested HTTP routes. Direct investigation
(research.md R1) confirms `cluster join/leave` and `apikey create/rotate`
need ONLY bash-side wiring in `bin/llmctl` against the already-working
`cluster::request` client. `tenant list` and `tenant quota`, however,
genuinely have zero backend HTTP surface today (research.md R2) — this
feature adds two small Go accessors (`Registry.List`, `Enforcer.GetLimits`)
and two new routes (`GET /v1/tenants`, `GET`+`PUT /v1/tenants/:id/quota`)
in the same file that already wires tenant routes, then wires all seven
bash subcommands together, plus a new `cluster::request_checked` client
helper (research.md R3) so the bash side can distinguish "daemon
unreachable" from "daemon returned an error" from "daemon returned
malformed JSON" per the spec's edge cases.

## Technical Context

**Language/Version**: Go (llmctld daemon, existing module/version — no
new Go dependency), Bash (bin/llmctl + lib/cluster.sh, existing project
convention)

**Primary Dependencies**: `github.com/gin-gonic/gin` (already a daemon
dependency, used by every existing route file), `curl` (already the sole
HTTP client used by `lib/cluster.sh`, unmodified — no new bash dependency)

**Storage**: In-memory only (existing `tenancy.Registry`/`tenancy.Enforcer`
maps, mutex-protected, already present — no new persistence, no schema
migration)

**Testing**: Go `testing` package + `httptest` (existing pattern in
`routes_tenants_test.go`/`routes_auth_test.go`) for the two new routes and
two new accessors; bash test harness (`tests/test_*.sh`, existing
`LLMCTL_DRY_RUN`-independent live-daemon pattern already used by cluster
tests) for the seven wired subcommands end-to-end against a real, locally
running `llmctld`

**Target Platform**: Any host running both `bin/llmctl` and `llmctld`
(cluster mode is opt-in and already cross-platform per this project's
existing systemd/launchd service dual-support)

**Project Type**: Two-component system (bash CLI `bin/llmctl` as thin
client + Go daemon `llmctld` as server) already established by this
repository — not a new architectural shape

**Performance Goals**: N/A beyond "responds within `cluster::request`'s
existing 5-second `--max-time`" — these are control-plane operations
(cluster membership, tenant/quota admin, API-key issuance), not
inference-path hot code

**Constraints**: Zero behavior change for the one already-shipped caller
of `cluster::request` (`cluster status`) — research.md R3's additive-only
design decision; zero new authorization bypass — the two new routes reuse
the existing `authorizeTenantOwnership`/`ActionTenantManage` RBAC checks
already proven in `routes_tenants_test.go`, never a new, unaudited
authorization path

**Scale/Scope**: Seven CLI subcommands, two new Go routes, two new Go
accessors, one new bash client helper — no new top-level component

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Deterministic V&V)**: SATISFIED — every new/wired command's
  acceptance scenario is a real HTTP round-trip against a real running
  `llmctld`, asserted on real exit codes and real JSON response bodies
  (data-model.md's wire shapes), never a mocked transport.
- **Principle III (Test-First, four-layer)**: Go side — RED test first for
  `Registry.List` (empty registry → `[]`, populated registry → all
  entries) and `Enforcer.GetLimits` (unset tenant → `Limits{}, false`; set
  tenant → the set value, `true`) per TDD, then the route handlers, then
  `routes_tenants_test.go`-style HTTP-level tests for both new routes
  (200/403/404 per data-model.md). Bash side — RED test first proving each
  of the seven subcommands still `die`s with "not yet implemented" (the
  CURRENT state), then implement, then the same test asserts a real
  success/failure round-trip. Meta-test paired mutation: reverting any one
  wired subcommand back to its `die` stub, or removing the new
  `cluster::request_checked` status-splitting logic, MUST make its
  corresponding test FAIL.
- **Principle II (CLI-First)**: SATISFIED — no new interface paradigm; all
  seven operations are already-designed CLI subcommands per `bin/llmctl`'s
  own `usage()` text (lines 74-81), this feature only makes them real.
- No violations requiring Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/006-cli-daemon-wiring/
├── plan.md              # This file
├── research.md          # Phase 0 output (complete)
├── data-model.md         # Phase 1 output (complete)
├── quickstart.md         # Phase 1 output
└── tasks.md              # Phase 2 output (/speckit-tasks)
```

(No `contracts/` directory — the wire shapes are fully specified in
data-model.md above and there is no separate schema-generation tool in
this project's existing convention to target; the Go route handlers and
their `httptest`-based tests ARE the contract, per this project's existing
pattern in `routes_tenants_test.go`.)

### Source Code (repository root)

```text
llmctld/internal/tenancy/
├── tenant.go                 # MODIFY: add Registry.List()
├── tenant_test.go            # MODIFY: add TestRegistry_List (TDD, written first)
├── quota.go                  # MODIFY: add Enforcer.GetLimits()
└── quota_test.go             # MODIFY: add TestEnforcer_GetLimits (TDD, written first)

llmctld/internal/api/
├── routes_tenants.go         # MODIFY: add GET /v1/tenants, GET+PUT /v1/tenants/:id/quota
└── routes_tenants_test.go    # MODIFY: add HTTP-level tests for both new routes (TDD, written first)

lib/
└── cluster.sh                # MODIFY: add cluster::request_checked() (additive; cluster::request untouched)

bin/
└── llmctl                    # MODIFY: replace the seven `die "...not yet implemented..."` lines with real
                               # dispatch through cluster::request (join/leave/apikey create/rotate) or
                               # cluster::request_checked (tenant list/quota, the two genuinely new routes)

tests/
├── test_cluster_join_leave.sh   # NEW: live-daemon round-trip for cluster join/leave
├── test_apikey_lifecycle.sh     # NEW: live-daemon round-trip for apikey create/rotate
└── test_tenant_list_quota.sh    # NEW: live-daemon round-trip for tenant create/list/quota view+set

docs/scripts/
└── llmctl.md                    # MODIFY: existing companion doc's cluster/tenant/apikey section updated
                                  # to reflect real (not "not yet implemented") behavior, per §11.4.18
```

**Structure Decision**: Same two-component layout already established by
this repository (bash CLI + Go daemon) — no new project, no new
directory. Every touched Go file already exists and already owns the
exact responsibility this feature extends (tenant/quota domain logic in
`internal/tenancy/`, tenant-scoped HTTP routes in
`internal/api/routes_tenants.go`); every touched bash file already exists
and already owns the exact responsibility this feature extends (the
cluster HTTP client in `lib/cluster.sh`, the CLI dispatch table in
`bin/llmctl`).

## Complexity Tracking

*No Constitution Check violations — table intentionally omitted.*
