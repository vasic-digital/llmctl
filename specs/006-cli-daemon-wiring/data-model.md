# Phase 1 Data Model: bash-CLI to Go-daemon Cluster/Tenant/Apikey Wiring

**Feature**: [spec.md](./spec.md) | **Research**: [research.md](./research.md)

This feature adds no new persistent storage. It extends two existing
in-memory Go types with a read accessor each, and adds no new bash-side
data structures beyond the request/response JSON shapes below.

## Entity: Tenant (existing, `internal/tenancy/tenant.go`)

No field changes. One new accessor:

- `func (r *Registry) List() []*Tenant` — returns every registered tenant
  (order not contractually significant; tests assert set membership, not
  order). Backing field: the existing `r.tenants map[string]*Tenant`
  (already present, already mutex-protected by `r.mu`).

## Entity: Limits (existing, `internal/tenancy/quota.go`)

No field changes (`RequestsPerSecond`, `MaxConcurrentRequests`,
`MaxGPUBytes`, `MaxCPUCores`, `MaxRAMBytes`, `MaxStorageBytes` — all
already defined). One new accessor:

- `func (e *Enforcer) GetLimits(tenantID string) (Limits, bool)` — returns
  the tenant's current `Limits` and whether any were ever set (the zero
  value `Limits{}, false` for a tenant with no configured limits — the
  existing package convention of "zero field = unlimited" extended one
  level to "zero Limits + false = never configured", so a caller can
  distinguish "unlimited on every dimension" from "not found", matching
  this project's own no-guessing discipline).

## Wire shapes (new/extended HTTP surface)

### `GET /v1/tenants` (NEW route)

Response `200`:
```json
{"tenants": [{"id": "tenant-a", "name": "Tenant A"}, {"id": "tenant-b", "name": "Tenant B"}]}
```
Empty registry → `{"tenants": []}` (never a bare `null` or omitted key —
FR-003's "malformed responses" edge case is partly about the CLIENT
tolerating a real daemon's edge-case output, but the SERVER side owns not
manufacturing one in the first place).

### `GET /v1/tenants/:id/quota` (NEW route)

Response `200` (limits configured):
```json
{"requests_per_second": 5.0, "max_concurrent_requests": 10, "max_gpu_bytes": 8589934592, "max_cpu_cores": 4, "max_ram_bytes": 17179869184, "max_storage_bytes": 107374182400}
```
Response `200` (tenant exists, no limits ever set — all-unlimited, per
`Limits`'s zero-value-means-unlimited convention):
```json
{"requests_per_second": 0, "max_concurrent_requests": 0, "max_gpu_bytes": 0, "max_cpu_cores": 0, "max_ram_bytes": 0, "max_storage_bytes": 0}
```
Response `404` (tenant does not exist — resolved against `decider.Tenants.Get`,
NOT `decider.Quota`, since a quota view is meaningless for an unregistered
tenant id):
```json
{"error": "tenant \"ghost\" not found"}
```

### `PUT /v1/tenants/:id/quota` (NEW route, "set" half of `tenant quota <name> [...]`)

Request:
```json
{"requests_per_second": 5.0, "max_concurrent_requests": 10, "max_gpu_bytes": 8589934592, "max_cpu_cores": 4, "max_ram_bytes": 17179869184, "max_storage_bytes": 107374182400}
```
Any omitted field defaults to `0` (unlimited) per Go's JSON-unmarshal
zero-value behavior — matching `Limits`'s own existing convention, no new
"partial update" semantics invented.

Response `200`: echoes the now-current `Limits` (same shape as the GET
`200` above). Response `404`: same shape as GET's 404. Response `403`:
same authorization shape as the existing `POST /v1/tenants` route's 403
(`{"error": "requires a role granting tenant:manage"}`), reusing
`authorizeTenantOwnership` (already defined in `routes_tenants.go`) rather
than inventing a second authorization check.

## Bash-side value: cluster::request_checked's split result (new, `lib/cluster.sh`)

Not a persisted entity — an in-process convention. On return, callers read:
- Function's own exit code: `0` = 2xx response (body printed to stdout, as
  `cluster::request` already does today); `1` = a non-2xx HTTP response
  (body — llmctld's own `{"error": "..."}` — printed to stdout so the
  caller can display the daemon's real error message); any other exit code
  = curl's own transport-failure exit code, unchanged passthrough (`7`
  connection refused, `28` timeout, etc.), so existing `cluster::require_daemon`-style
  reachability handling keeps working unmodified.
