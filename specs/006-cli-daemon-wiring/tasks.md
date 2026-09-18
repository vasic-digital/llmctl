# Tasks: bash-CLI to Go-daemon Cluster/Tenant/Apikey Wiring

**Input**: Design documents from `/specs/006-cli-daemon-wiring/`
**Prerequisites**: plan.md, research.md, data-model.md, quickstart.md

**Tests are explicitly requested** — TDD is mandatory per this project's own Constitution Principle III.

## Phase 1: Setup

- [ ] T001 Confirm the daemon builds and its full existing test suite passes cleanly before any change: `cd llmctld && go build ./... && go test ./... -race`. Capture the baseline pass count to `docs/qa/006-cli-daemon-wiring/baseline_go_tests.txt`.

## Phase 2: Foundational

- [ ] T002 Write the failing test first: `TestRegistry_List` in `llmctld/internal/tenancy/tenant_test.go` asserting (a) `NewRegistry().List()` returns an empty (non-nil) slice, (b) after two `Create` calls, `List()` returns both, matched by ID regardless of order. Run it — MUST fail (`List` does not exist).

- [ ] T003 Implement `func (r *Registry) List() []*Tenant` in `llmctld/internal/tenancy/tenant.go` (per data-model.md), returning a snapshot slice built while holding `r.mu`. Run T002 — MUST pass.

- [ ] T004 Write the failing test first: `TestEnforcer_GetLimits` in `llmctld/internal/tenancy/quota_test.go` asserting (a) `NewEnforcer().GetLimits("ghost")` returns `Limits{}, false`, (b) after `SetLimits("t1", someLimits)`, `GetLimits("t1")` returns `someLimits, true`. Run it — MUST fail (`GetLimits` does not exist).

- [ ] T005 Implement `func (e *Enforcer) GetLimits(tenantID string) (Limits, bool)` in `llmctld/internal/tenancy/quota.go` (per data-model.md), reading `e.limits[tenantID]` under `e.mu`. Run T004 — MUST pass.

## Phase 3: User Story 1 - cluster join/leave against a real daemon (Priority: P1) 🎯 MVP

**Goal**: `llmctl cluster join <peer-addr>` and `llmctl cluster leave` genuinely call the already-implemented `POST /v1/cluster/join`/`POST /v1/cluster/leave` routes instead of dying.

**Independent Test**: Against two real running `llmctld` instances, `llmctl cluster join <peer-addr>` from one succeeds and is reflected in `llmctl cluster status`; `llmctl cluster leave` removes it.

- [ ] T006 [US1] Write the failing test first: `tests/test_cluster_join_leave.sh` starting two real local `llmctld` instances on different ports, running `bin/llmctl cluster join <peer-addr>` against one, and asserting (a) exit code 0, (b) a subsequent `bin/llmctl cluster status` on the peer reflects the new node. Run it against the current `bin/llmctl` — MUST fail (`die "...not yet implemented..."`).

- [ ] T007 [US1] In `bin/llmctl`, replace the `join)` case's `die "llmctld reachable but 'cluster join' is not yet implemented (Phase 9, US7)"` (line ~186) with a real call: `cluster::request POST /v1/cluster/join "$(json_body peer_addr="$1")"` (or the equivalent existing JSON-body-construction helper already used elsewhere in this file), printing the response body and propagating a non-zero exit on failure per `cluster::request`'s existing exit-code contract.

- [ ] T008 [US1] In `bin/llmctl`, replace the `leave)` case's `die "llmctld reachable but 'cluster leave' is not yet implemented (Phase 9, US7)"` (line ~187) with a real call: `cluster::request POST /v1/cluster/leave`. Run T006 — MUST now pass.

**Checkpoint**: User Story 1 independently complete — cluster join/leave are real.

## Phase 4: User Story 2 - apikey create/rotate against a real daemon (Priority: P1)

**Goal**: `llmctl apikey create <scope>` and `llmctl apikey rotate <key-id>` genuinely call the already-implemented routes.

**Independent Test**: `apikey create` returns a real key id; `apikey rotate` on that id returns a new key value distinct from the original.

- [ ] T009 [US2] [P] Write the failing test first: `tests/test_apikey_lifecycle.sh` against a real running `llmctld`, asserting `bin/llmctl apikey create <scope>` returns a parseable key id, and `bin/llmctl apikey rotate <that-id>` returns a NEW key value different from the first. Run it against current `bin/llmctl` — MUST fail.

- [ ] T010 [US2] In `bin/llmctl`, replace the `create)` case's `die` (line ~208, apikey) with `cluster::request POST /v1/auth/apikeys "$(json_body scope="$1")"`.

- [ ] T011 [US2] In `bin/llmctl`, replace the `rotate)` case's `die` (line ~209, apikey) with `cluster::request POST "/v1/auth/apikeys/$1/rotate"`. Run T009 — MUST now pass.

**Checkpoint**: User Story 2 independently complete — apikey create/rotate are real. (Independent of User Story 1 — no shared state.)

## Phase 5: User Story 3 - tenant create/list/quota, including two new daemon routes (Priority: P2)

**Goal**: `llmctl tenant create/list/quota` are fully real, including the two genuinely-new server routes this feature adds.

**Independent Test**: `tenant create demo` then `tenant list` shows `demo`; `tenant quota demo --max-concurrent-requests 5` then `tenant quota demo` echoes the set value.

- [ ] T012 [US3] Write the failing test first: `TestListTenants` in `llmctld/internal/api/routes_tenants_test.go` — `GET /v1/tenants` with a valid JWT on an empty registry returns `200 {"tenants": []}`; after creating two tenants, returns both. Run it — MUST fail (route does not exist, 404).

- [ ] T013 [US3] Implement `r.GET("/v1/tenants", ...)` in `llmctld/internal/api/routes_tenants.go` per data-model.md's wire shape, using `decider.Tenants.List()` (T003). Run T012 — MUST pass.

- [ ] T014 [US3] Write the failing test first: `TestTenantQuota_ViewAndSet` in `routes_tenants_test.go` — `GET /v1/tenants/:id/quota` on an existing tenant with no limits set returns `200` with all-zero `Limits`; `GET` on a nonexistent tenant returns `404`; `PUT /v1/tenants/:id/quota` with a JSON body sets limits and echoes them back `200`; a subsequent `GET` reflects the set value; a non-owning, non-admin caller gets `403`. Run it — MUST fail (routes do not exist).

- [ ] T015 [US3] Implement `r.GET("/v1/tenants/:id/quota", ...)` and `r.PUT("/v1/tenants/:id/quota", ...)` in `routes_tenants.go` per data-model.md, using `decider.Tenants.Get` (404 check), `authorizeTenantOwnership` (403 check, reusing the existing helper), and `decider.Quota.GetLimits`(T005)/`decider.Quota.SetLimits` (already existing). Run T014 — MUST pass.

- [ ] T016 [US3] [P] Write the failing test first: `tests/test_tenant_list_quota.sh` against a real running `llmctld`, exercising the full bash-CLI round trip: `bin/llmctl tenant create demo`, `bin/llmctl tenant list` (asserts `demo` appears), `bin/llmctl tenant quota demo --max-concurrent-requests 5` (set), `bin/llmctl tenant quota demo` (view, asserts the value echoes). Run it against current `bin/llmctl` — MUST fail (`die`).

- [ ] T017 [US3] Add `cluster::request_checked()` to `lib/cluster.sh` per research.md R3/data-model.md's bash-side wire convention: captures HTTP status via `curl -w '\n%{http_code}'`, splits body from status, returns 0 on 2xx (body on stdout), 1 on non-2xx (body — the daemon's own error JSON — on stdout), passes through curl's own non-zero exit unchanged for transport failures. Do NOT modify the existing `cluster::request` function.

- [ ] T018 [US3] In `bin/llmctl`, replace the `tenant create)` case's `die` with `cluster::request POST /v1/tenants "$(json_body id="$1" name="$1")"`; replace `tenant list)`'s `die` with `cluster::request_checked GET /v1/tenants`; replace `tenant quota)`'s `die` with a dispatch that calls `cluster::request_checked PUT "/v1/tenants/$1/quota" "<body from remaining args>"` when extra args are given (set), or `cluster::request_checked GET "/v1/tenants/$1/quota"` when none are given (view). Run T016 — MUST now pass.

**Checkpoint**: All three user stories independently complete.

## Phase 6: Polish & Cross-Cutting

- [ ] T019 Write the failing test first, then implement: a test proving `cluster::request_checked` correctly distinguishes all three outcomes (unreachable daemon → passthrough curl exit code; reachable + 2xx → exit 0; reachable + non-2xx → exit 1 with the daemon's error body printed) — this is the spec's own Edge Case "auth-vs-unreachable-vs-app-error distinction" made into a permanent regression test, `tests/test_cluster_request_checked.sh`.

- [ ] T020 Verify no regression on the ONE pre-existing caller of the untouched `cluster::request`: re-run `bin/llmctl cluster status` against a real daemon and confirm byte-identical behavior to before this feature (per research.md R3's additive-only design decision).

- [ ] T021 Update `docs/scripts/llmctl.md` (existing §11.4.18 companion doc) to reflect the seven now-real subcommands.

- [ ] T022 Run the full existing bash AND Go test suites (`bash tests/test_all.sh`; `cd llmctld && go test ./... -race`) to confirm zero regressions. Capture summaries to `docs/qa/006-cli-daemon-wiring/full_suite_regression.txt`.

## Dependencies

- Phase 1 (Setup) blocks Phase 2 (Foundational).
- Phase 2 (Foundational: T002-T005, the two new Go accessors) blocks Phase 5 (User Story 3), which is the only story that needs them.
- User Story 1 (Phase 3) and User Story 2 (Phase 4) do NOT depend on Phase 2 and MAY start in parallel with it.
- User Story 3 (Phase 5) additionally depends on T017 (`cluster::request_checked`), which has no dependency on Phases 3-4.
- Phase 6 depends on all prior phases.

## Parallel Example

```
# After Phase 1, these three streams can run in parallel:
Stream A (Phase 2): T002 -> T003 -> T004 -> T005
Stream B (Phase 3): T006 -> T007 -> T008
Stream C (Phase 4): T009 -> T010 -> T011
# Phase 5 (T012-T018) starts once Stream A completes.
```

## Implementation Strategy

**MVP**: Phase 1 + Phase 3 (User Story 1, cluster join/leave) is the
smallest independently-shippable slice — it requires zero Go changes,
only bash wiring against already-implemented routes. User Story 2
(apikey) is equally cheap and can land alongside it. User Story 3 (tenant
list/quota) is the one genuinely new Go surface and is scoped last,
matching its P2 priority.
