# API Reference

**Revision:** 2
**Last modified:** 2026-10-08T00:00:00Z

llmctl does not implement its own inference API — it launches and manages
real `llama-server` (llama.cpp) and `coli serve` (colibri) processes, and
**those processes** serve the HTTP API documented in §1 below. §2 documents
`llmctld`'s HTTP/3 control-plane API (implemented in `llmctld/internal/api/`).

## 1. Model-serving API (llama.cpp / colibri) — ✅ real, in production use today

Every profile started via `llmctl start <profile>` binds to
`<bind-host>:<port>` (chat engines bind `LLMCTL_BIND_HOST`, default `0.0.0.0`; decision engines are loopback-only — see
`docs/architecture.md`'s port map and [ports](ports.md)) and serves:

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

## 2. `llmctld` cluster HTTP/3 API - implemented (control plane only)

`llmctld` (Gin, HTTP/3 over QUIC) serves the routes below from `llmctld/internal/api/routes_*.go`; that source and its tests are authoritative, this table is a snapshot of the route registrations at 3.1.0.
Node-to-node routes are protected by mutual TLS; every route marked JWT additionally needs a bearer token from `POST /v1/auth/token` with a role that allows the action. **No inference traffic passes through
`llmctld`**: chat requests go to each node's engine (section 1) and typed decisions to the decision gateway. How the CLI reaches these routes (certificates, SANs, the `curl` requirement):
[llmctld-cluster-tls](llmctld-cluster-tls.md); behaviour and its verification status: [faq](faq.md) and [cluster-architecture](cluster-architecture.md).

| Method | Route | Auth | Purpose |
|---|---|---|---|
| GET | `/v1/cluster/status` | mTLS | leader, membership, term, running profiles |
| GET | `/v1/cluster/nodes` | mTLS | registered nodes and their resources |
| POST | `/v1/cluster/join` | mTLS | join a node (`llmctl cluster join`) |
| POST | `/v1/cluster/leave` | mTLS | remove a node (`llmctl cluster leave`) |
| POST | `/v1/cluster/resources/update` | mTLS | refresh a node's resource figures |
| POST | `/v1/auth/token` | none (API key id and secret in the JSON body) | exchange an API key for a short-lived JWT; every attempt is audited |
| POST | `/v1/auth/apikeys` | JWT | create an API key (`llmctl apikey create`) |
| POST | `/v1/auth/apikeys/:id/rotate` | JWT | rotate a key; the old value stops working at once |
| DELETE | `/v1/auth/apikeys/:id` | JWT | revoke a key |
| POST / GET | `/v1/tenants` | JWT | create / list tenants (`llmctl tenant create|list`) |
| GET / PUT | `/v1/tenants/:id/quota` | JWT | read / set a tenant's quota (`llmctl tenant quota`) |
| GET / POST | `/v1/tenants/:id/models` | JWT | list / register a tenant's models |
| POST | `/v1/tenants/:id/models/:model/share` | JWT | share a model with another tenant |
| GET | `/v1/tenants/:id/models/:model/visible` | JWT | is the model visible to the tenant |
| POST | `/v1/tenants/:id/models/:model/start` | JWT | start `:model` for the tenant (runs the real `bin/llmctl start` on a node with room; see cluster-architecture 1c) |
| POST | `/v1/tenants/:id/models/:model/stop` | JWT | stop it |
| GET | `/v1/tenants/:id/models/:model/status` | JWT | status of the model |
| GET | `/v1/audit/entries` | JWT (tenant:manage) | the in-memory audit log |
| GET | `/v1/audit/verify` | JWT (tenant:manage) | verify the audit hash chain |
| POST | `/v1/replication/append` | JWT | append a KV-cache WAL entry |
| POST | `/v1/replication/checkpoint` | JWT | write a checkpoint |
| GET | `/v1/replication/state` | JWT | replication state |
| GET | `/v1/replication/lag` | JWT | replication lag per replica |
| POST | `/v1/replication/enginecache` | JWT | receive an engine-cache file |
| POST | `/v1/cluster/mtls/renew` | JWT | renew this node's certificate |
| POST | `/v1/cluster/mtls/revoke` | JWT | revoke a certificate serial |
| GET | `/v1/cluster/mtls/revocations` | JWT | list revocations |
| POST | `/v1/cluster/mtls/rotate/begin`, `/finalize` | JWT | start / finish a coordinated CA rotation |
| GET | `/v1/cluster/mtls/rotate/status` | JWT | rotation status |
| POST | `/v1/cluster/mtls/rotate/transition` | mTLS (peer only) | peer-to-peer rotation step |

Status of the pieces behind the routes (wired versus library only) is in the [faq](faq.md); the tenant quota route, for instance, stores and shows a quota, but nothing enforces a request rate on inference traffic.
