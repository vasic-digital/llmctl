# API Reference

**Revision:** 1
**Last modified:** 2026-09-15T00:00:00Z

llmctl does not implement its own inference API — it launches and manages
real `llama-server` (llama.cpp) and `coli serve` (colibri) processes, and
**those processes** serve the HTTP API documented in §1 below. §2 documents
`llmctld`'s planned HTTP/3 API, which — stated honestly up front — **does
not exist yet** (verified via `find llmctld -name '*.go'`: no `internal/api/`
package, no HTTP route registration of any kind, anywhere in this
repository as of this session).

## 1. Model-serving API (llama.cpp / colibri) — ✅ real, in production use today

Every profile started via `llmctl start <profile>` binds to
`127.0.0.1:<fixed-port>` (never an external interface — see
`docs/architecture.md`'s port map) and serves:

### `GET /health`

Returns HTTP 200 once the model is loaded and ready to serve requests.
Used by `lib/download.sh`'s post-download smoke test (polls this endpoint
for up to `LLMCTL_SMOKE_TIMEOUT` seconds before declaring the download
verified) and by `docs/quickstart.md`'s manual release-gating procedure.

```bash
curl -fsS http://127.0.0.1:8080/health
```

### `POST /v1/chat/completions` — OpenAI-compatible chat completions

The primary inference endpoint every CLI agent in `docs/integrations.md`
targets. Request/response shape follows the OpenAI Chat Completions API.
The exact deterministic-smoke-test request this project's own download
verification sends (`lib/download.sh`, `_dl_smoke_test_gguf`):

```bash
curl -fsS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role": "user", "content": "Reply with exactly: OK"}],
    "max_tokens": 8,
    "temperature": 0
  }'
```

Expected: a JSON response whose `choices[0].message.content` contains `OK`
— this is the exact anti-bluff check (Constitution §11.4/§11.4.5) that
gates whether a downloaded model is accepted as verified, not merely that
the HTTP request succeeded.

**Determinism (spec.md FR-012/SC-008):** setting `LLMCTL_SEED=<value>`
before `llmctl start <profile>` (a llama.cpp profile) appends `--seed
<value> --temp 0` to the server's own launch arguments (see
`lib/scheduler.sh`'s `sched_build_launch`), making every request against
that running server instance deterministic at the sampling layer — the
request body's own `"temperature"` field is still honored per-request by
llama-server, but the server-level `--temp 0` establishes a deterministic
default even for a client that omits it.

### `GET /v1/models`

Lists the currently-loaded model. llama.cpp's server accepts (and reports
back) any model identifier string, so `"model": "local"` works as a
client-side placeholder in practice — the actual served model is whatever
`llmctl start <profile>` loaded, not selected per-request.

```bash
curl -fsS http://127.0.0.1:8080/v1/models
```

### `POST /v1/messages` — native Anthropic API (colibri only)

Colibri profiles (`colibri-glm` port 8090, `colibri-qwen36` port 8091)
additionally serve a native Anthropic-compatible `/v1/messages` endpoint,
letting Claude Code point `ANTHROPIC_BASE_URL` directly at a colibri
profile with no OpenAI→Anthropic proxy needed (see `docs/integrations.md`'s
"Claude Code" section, US4 Acceptance Scenario 3). llama.cpp profiles do
NOT serve this endpoint — an OpenAI→Anthropic shim is required for those
(also documented in `docs/integrations.md`).

## 2. `llmctld` cluster HTTP/3 API — 📋 PLANNED, not yet implemented

**Honest boundary (Constitution §11.4.6):** this section exists to satisfy
Phase 7's documentation-completeness goal (spec.md FR-008/SC-011: "API
reference... for all... routes") by giving future implementers a concrete
target, grounded in spec.md's own functional requirements — it is **not** a
description of code that exists. `bin/llmctl`'s `cluster status` subcommand
issues a real HTTP request (`cluster::request GET /v1/cluster/status`) when
a daemon IS reachable, but since llmctld exposes no HTTP routes today, that
request currently has nothing real to reach. See
`docs/cluster-architecture.md`'s honest implementation-status boundary for
the full picture (§1–4 there cross-reference the exact Go source files that
do and do not exist).

Per spec.md FR-039/FR-040/FR-041 and the Key Entities section, the daemon
will use Gin Gonic + HTTP/3 (QUIC) + Brotli compression, with node-to-node
traffic authenticated via mutual TLS (the CA/cert-issuance primitive for
this already exists, see `internal/mtls`) and client-facing traffic
authenticated via JWT bearer tokens (not yet implemented at all). Planned
route surface, inferred from the CLI subcommands `bin/llmctl` already
stubs out plus the spec's Key Entities (Cluster State, KV Cache State, WAL
Entry, Tenant, User/Team/API-Key):

| Method | Route (planned) | Purpose (planned) | Phase |
|---|---|---|---|
| GET | `/v1/cluster/status` | Cluster health, leader, membership, term | 9 (US7) |
| POST | `/v1/cluster/join` | Join a node to the cluster | 9 (US7) |
| POST | `/v1/cluster/leave` | Remove a node from the cluster | 9 (US7) |
| GET | `/v1/kvcache/:session/checkpoint` | Latest KV-cache checkpoint for a session | 10 (US8) |
| POST | `/v1/kvcache/:session/wal` | Append a WAL entry (internal, replication) | 10 (US8) |
| POST | `/v1/tenants` | Create a tenant | 11 (US9) |
| GET | `/v1/tenants` | List tenants | 11 (US9) |
| PUT | `/v1/tenants/:name/quota` | Set a tenant's resource quota | 11 (US9) |
| POST | `/v1/apikeys` | Create an API key (scoped, JWT-backed) | 11 (US9) |
| POST | `/v1/apikeys/:id/rotate` | Rotate an API key | 11 (US9) |

None of these routes are registered anywhere in this repository as of this
session. This table is a design target derived from the spec, not a claim
of shipped behavior — see `docs/CONTINUATION.md` for the live phase-by-phase
implementation status.

**Honest disclosure (added 2026-09-15, T072-FU4)**: the table above is a
Phase-1-era planning target and is now STALE relative to what Phases 9-12
actually shipped (the real cluster/replication/tenant/auth/audit/model
route surface is materially different and more detailed than what's
listed above — see `internal/api/routes_*.go` for the authoritative,
tested implementation). A full refresh of this section to match the real
shipped surface is a legitimate but separate documentation task, not
undertaken here; the one addition below documents ONLY the new routes
this task itself added, so this table's drift is not made worse by this
change.

### Model-lifecycle dispatch routes (T072-FU4, real, shipped)

Added directly to `internal/api/routes_models.go`, gated by RBAC actions
`model:start`/`model:stop`/`model:view` (defined since T066) plus tenant
ownership + tenant-visibility checks (mirroring the pre-existing
`/v1/tenants/:id/models/:model/visible` route's own gating):

| Method | Route | Purpose |
|---|---|---|
| POST | `/v1/tenants/:id/models/:model/start` | Start `:model` (a registered/shared bin/llmctl catalog profile) for tenant `:id`, dispatched to THIS node's real `bin/llmctl start` subprocess with `LLMCTL_TENANT_ID=:id` |
| POST | `/v1/tenants/:id/models/:model/stop` | Stop `:model` for tenant `:id` on this node |
| GET | `/v1/tenants/:id/models/:model/status` | Real `bin/llmctl status` output, filtered to `:model`'s row |

Scope boundary: dispatch is THIS NODE ONLY — no cluster-wide scheduler or
cross-node request-forwarding exists anywhere in this codebase yet
(the same disclosed per-node boundary T073/T075 already established for
the tenancy/auth stack).
