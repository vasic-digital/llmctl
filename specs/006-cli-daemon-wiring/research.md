# Phase 0 Research: bash-CLI to Go-daemon Cluster/Tenant/Apikey Wiring

**Feature**: [spec.md](./spec.md) | **Date**: 2026-09-18

## R1: Do the five non-list/non-quota target routes already exist server-side?

**Decision**: Yes, all five (`POST /v1/cluster/join`, `POST /v1/cluster/leave`, `POST /v1/auth/apikeys`, `POST /v1/auth/apikeys/:id/rotate`, `DELETE /v1/auth/apikeys/:id`) are real, implemented, tested Go routes. This feature's `cluster join/leave` and `apikey create/rotate` user stories are bash-side wiring ONLY — no Go changes.

**Evidence gathered this phase**: confirmed by direct read of `llmctld/internal/api/routes_cluster.go` (lines 113, 175 register `POST /v1/cluster/join` and `POST /v1/cluster/leave`) and `llmctld/internal/api/routes_auth.go` (lines 129, 146, 158 register the three apikey routes), each backed by a real `*auth.Store`/cluster membership implementation with passing Go tests (`routes_auth_test.go`, `routes_mtls_test.go`).

## R2: Do `tenant list` and `tenant quota` have any existing HTTP surface?

**Decision**: No — confirmed zero. This is the feature's real Go-side scope (FR-006/FR-007), landing in the SAME already-open file (`internal/api/routes_tenants.go`) that already wires `POST /v1/tenants`.

**Evidence gathered this phase**:
- `internal/tenancy/tenant.go`'s `Registry` type has `Create`, `Get`, `Delete`, `RegisterModel`, `ShareModel`, `IsVisible`, `ListVisibleModels` — no `List()` method returning all registered tenants. This is a genuine, small Go addition (TDD: a failing `TestRegistry_List` first).
- `internal/tenancy/quota.go`'s `Enforcer` type has `SetLimits`, `AllowRequest`, `AcquireConcurrencySlot`, `CheckResourceBudget` — no getter returning a tenant's current `Limits`. This is a genuine, small Go addition (TDD: a failing `TestEnforcer_GetLimits` first) — `SetLimits` already exists and is what a `PUT`/set-quota route calls.
- `internal/api/routes_tenants.go`'s `RegisterTenantRoutes(r gin.IRoutes, decider *authz.Decider)` already receives `decider.Tenants` (`*tenancy.Registry`) AND `decider.Quota` (`*tenancy.Enforcer`) — confirmed via `internal/authz/decide.go` lines 31-43 (`Decider.Quota *tenancy.Enforcer`, `Decider.Tenants *tenancy.Registry`). Both new routes (`GET /v1/tenants`, `GET /v1/tenants/:id/quota`, `PUT /v1/tenants/:id/quota`) can be added to this SAME function with no new dependency-injection plumbing anywhere else in the daemon.

**Alternatives considered**: A separate new route-registration file (`routes_tenant_quota.go`): rejected — the existing file already owns tenant-scoped routes and already receives both dependencies; splitting would be an arbitrary file-boundary decision with no isolation benefit (writing-plans skill's "files that change together should live together" guidance).

## R3: Does `cluster::request` already distinguish "daemon unreachable" from "daemon returned an error status"?

**Decision**: No, and this is a genuine bash-side gap this feature MUST close (spec's Edge Cases: "auth-vs-unreachable-vs-app-error distinction"). Resolve it with a NEW function, `cluster::request_checked`, rather than changing `cluster::request`'s existing output contract.

**Evidence gathered this phase**:
- `lib/cluster.sh`'s `cluster::request()` (lines 39-49) runs `curl -sS --max-time 5 ...` with NO `-f`/`--fail` and NO `-w '%{http_code}'` — curl's own exit code only reflects TRANSPORT-level failure (connection refused → 7, timeout → 28, TLS error → 35/60, etc.), never an HTTP 4xx/5xx application response (curl exits 0 and prints the error JSON body as if it were a success body).
- The one existing caller, `bin/llmctl`'s `cluster status)` case (line 188), does not need to distinguish this today because a status GET has no meaningful 4xx/5xx path in current usage — but `join` (peer-addr validation can 400), `apikey rotate` (ownership check can 403 per `routes_auth_test.go` line 207), and `tenant quota` (nonexistent tenant can 404) all have real, tested non-2xx paths this feature's new commands must surface distinctly from "the daemon is down".
- **Design decision**: add `cluster::request_checked <method> <path> [body]` to `lib/cluster.sh` that captures the HTTP status code via `curl -w '\n%{http_code}'`, splits the trailing status line from the body (`body="${raw%$'\n'*}"; status="${raw##*$'\n'}"`), and returns three distinguishable outcomes via its own exit code + printed body: exit 0 + 2xx body → success; exit 0 + non-2xx status → prints the body (which is llmctld's own `{"error": "..."}` JSON) and returns 1, letting the caller report the daemon's own error message; a non-zero curl exit (unchanged from today) → still means "unreachable/transport failure", handled identically to today's `cluster::require_daemon` path. This is purely ADDITIVE — `cluster::request` is untouched, so the one existing caller (`cluster status`) has zero behavior change (regression-safety per FR-005/SC-... implicit "no regression" bar every prior feature in this project holds itself to).

**Alternatives considered**: Modifying `cluster::request` in place to always capture and check status: rejected — would silently change behavior (and the printed-body format) for the one existing, already-shipped, already-tested caller, which is exactly the kind of blast-radius risk this project's own Constitution (§11.4.92 Pass 2, regression-blast-radius analysis) requires avoiding when an additive alternative exists.

## R4: What does a malformed/non-JSON daemon response look like to a bash caller, and how should it be handled?

**Decision**: `cluster::request_checked`'s callers (the new `bin/llmctl` cases) MUST validate the response body is parseable JSON before extracting fields from it (using the project's existing `json_query`-style helper pattern already used elsewhere, e.g. `lib/scheduler.sh`'s `json_query "${plan_file}" ...`), and report a distinct "malformed response from llmctld" error rather than a raw parse-tool stack trace or a silently-empty extracted value — this satisfies the spec's edge case "malformed responses" without inventing new JSON-parsing machinery (the project already has one JSON-query convention to reuse).

**Evidence gathered this phase**: `lib/scheduler.sh` and `lib/catalog.sh` both already use a `json_query`-style call into a shared Python-heredoc JSON helper (confirmed present in `lib/common.sh` — the same mechanism already relied on throughout this codebase) — no new parsing dependency needed.
