# Contract: Cluster-Aware Model-Lifecycle + Cluster-Status API

Extends the existing `internal/api` HTTP surface (T072-FU4's
`/v1/tenants/:id/models/:model/{start,stop,status}` and T058's
`/v1/cluster/{join,leave,nodes,status}`). All routes below inherit the
existing `RequireJWT` + `authorizeTenantOwnership` + `CheckRBAC` +
`CheckTenantBoundary` gating chain T072-FU4/FU5 already established for
tenant-scoped model routes — this feature adds no new authorization
concept, only extends the existing chain to the auto-placement and
cross-node-resolution cases (spec.md FR-011).

## `POST /v1/tenants/:id/models/:model/start` (extended, existing route)

**Request body** (new, optional field):
```json
{ "node": "node-b" }
```
- `node` present and non-empty → byte-identical to today's behavior:
  dispatched to exactly that node (spec.md FR-002).
- `node` absent or empty → NEW: cluster.Place() selects a node among the
  tenant's eligible healthy candidates (spec.md FR-001, FR-011, FR-012),
  the request is forwarded to it, and a `RunningProfile` entry is recorded.

**Response** (extended): existing response shape, plus a `node` field
naming which node actually accepted the work (present whether the caller
pinned it or the system chose it), and — on refusal — a `considered` array
naming every eligible node's shortfall (spec.md FR-004).

**Refusal cases** (distinguishable reasons, spec.md FR-004/FR-010):
- `insufficient_capacity`: no eligible node fit; `considered` lists every
  node's shortfall.
- `placement_delivery_failed`: the chosen node became unreachable between
  selection and confirmed dispatch; either retried against a different
  node transparently, or surfaced with this distinct reason — never
  reported as `insufficient_capacity` (a different failure class).
- `cluster_unreachable`: no node in the cluster was reachable at all.

## `POST /v1/tenants/:id/models/:model/stop` (extended, existing route)

Same `node`-optional extension. When `node` is absent, resolves via the
`RunningProfile` index (spec.md FR-007); if more than one node is running
the named profile for this tenant, the stop is delivered to every one of
them and the response lists every node stopped (spec.md FR-008) — never
silently limited to one.

## `GET /v1/tenants/:id/models/:model/status` (extended, existing route)

Same `node`-optional extension for read (spec.md FR-006); multi-node
results are returned as a list, each entry naming its source node
(spec.md FR-008).

## `GET /v1/cluster/status` (extended, existing route, T058)

Response gains a `running_profiles` field: every currently-known
`RunningProfile` entry across the cluster (spec.md FR-009, the cluster-wide
status view), in addition to the existing `is_leader`/`state` fields.

## `POST /v1/cluster/join` (extended, existing route, T058)

**Request body** (new, required field):
```json
{ "peer_id": "node-b", "peer_addr": "10.0.0.2:7000", "resources": { "cpu_cores": 8, "ram_total_mb": 32768, "ram_avail_mb": 25904, "vram_total_mb": 12288, "vram_avail_mb": 10444, "network_mbps": 1000 } }
```
`resources` mirrors `cluster.Resources`'s existing JSON field names exactly
(no new schema — `state.go`'s doc comment already documents these field
names mirroring `lib/hardware.sh`'s own JSON output). This is the payload
that makes `Join` genuinely populate `ClusterState.Nodes` (research.md
Decision 3) — every existing caller of this route (the real
`cmd/llmctld`'s `cluster join` subcommand, and `internal/api.RequestJoin`)
is updated to supply it, sourced from the joining node's own real
`bin/llmctl` hardware-probe JSON output.

## Not part of this feature's contract (explicitly out of scope)

- No new CLI subcommand — `bin/llmctl` is untouched (Constitution Principle
  II: `llmctld` extends the existing HTTP API, not the bash CLI).
- No new authentication/authorization primitive — every route above reuses
  the existing JWT + RBAC + tenant-boundary chain unchanged.
- No rebalancing/migration endpoint for an already-placed profile (spec.md
  FR-013 — explicitly out of scope for this feature).
