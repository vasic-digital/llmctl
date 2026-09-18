# 006-cli-daemon-wiring: HTTP/3-only daemon transport vs curl-based CLI

**Recorded**: 2026-09-18, during implementation of tasks T006/T009/T016/T019.

## Finding

`bin/llmctl`'s cluster/tenant/apikey commands talk to `llmctld` through
`lib/cluster.sh`'s `curl`-based `cluster::request`/`cluster::request_checked`.
`llmctld`'s cluster API server (`llmctld/internal/api/server.go`'s
`NewServer`) serves **exclusively** over HTTP/3 via a UDP-only QUIC
listener with mandatory mTLS (`http3.Server` bound to a `net.PacketConn`,
never a TCP listener).

On a host whose `curl` build has no HTTP/3 support — confirmed on this
session's host, `curl 8.18.0`, whose `--version` Features line lists
`HTTP2` but not `HTTP3` — `lib/cluster.sh`'s own `_cluster_http3_supported()`
correctly detects this and falls back to a plain TCP-based HTTPS request.
That request can **never** reach a UDP-only QUIC listener: it fails with
`Connection refused`, byte-for-byte identical to the failure when no
daemon is running at all.

## Evidence captured

1. Built the real `llmctld` binary (`go build ./cmd/llmctld`).
2. Started a real `cluster bootstrap` node:
   `llmctld cluster bootstrap -node-id n1 -ca-cert ./ca.crt -ca-key ./ca.key
   -raft-bind 127.0.0.1:0 -api-bind 127.0.0.1:19443 -bootstrap-admin
   -llmctl-path <repo>/bin/llmctl`
3. Confirmed it printed a real `READY node_id=n1 raft_addr=... api_addr=127.0.0.1:19443`
   line and a real `BOOTSTRAP_ADMIN_KEY_ID=... BOOTSTRAP_ADMIN_KEY_SECRET=...` pair.
4. `ss -tulpn | grep 19443` showed:
   ```
   udp   UNCONN 0      0                              127.0.0.1:19443      0.0.0.0:*    users:(("llmctld_test_bi",pid=...,fd=7))
   ```
   — a UDP socket only, no TCP socket, on the exact address the daemon
   itself reported as its bound API address.
5. `curl -sS --max-time 3 -v https://127.0.0.1:19443/v1/cluster/status` against
   that real, running, healthy daemon:
   ```
   *   Trying 127.0.0.1:19443...
   * connect to 127.0.0.1 port 19443 from 127.0.0.1 port ... failed: Connection refused
   * Failed to connect to 127.0.0.1 port 19443 after 0 ms: Could not connect to server
   curl: (7) Failed to connect to 127.0.0.1 port 19443 after 0 ms: Could not connect to server
   ```
6. Repeated with the newly-wired `bin/llmctl cluster join`/`tenant create`
   pointed at the same real, running daemon (`LLMCTL_CLUSTER_ENDPOINT`
   set to its real bound address) — both commands hard-failed with the
   project's standard `llmctld unreachable at ...` message via
   `cluster::require_daemon`, identical to pointing the CLI at a port
   with no daemon running at all.

## Impact on this feature's test obligations

`spec.md`'s Independent Test criteria for User Stories 1-3 require
proving a genuine 2xx round trip (a node actually joining and appearing
in a peer's node list, a key actually authenticating, a tenant actually
appearing in a list) against a real running `llmctld`. This is **not
achievable via `curl`-based bash commands in this environment**,
regardless of how the seven subcommands are wired in `bin/llmctl` — the
blocker is the transport protocol mismatch above, which predates and is
independent of this feature's own scope (`spec.md`'s Assumptions section
states only that "request/response shapes will not need to change to be
called from bash", not that the transport itself would be reachable).

This is orthogonal to a second, smaller finding: the real
`POST /v1/cluster/join` route requires `peer_id` (not only `peer_addr`)
and the real `POST /v1/auth/apikeys` route requires `owner_id` (not only
a bare `scope`) — both bridged with a documented, minimal interpretation
in `bin/llmctl` (see its inline comments and the feature's final report),
since fixing this required no protocol capability the daemon lacks, only
a value the CLI's one-argument usage text did not previously collect.

## What was done instead

- Every daemon-unreachable hard-fail path (`FR-008`/`FR-009`/`SC-002`)
  IS proven for real, against BOTH no daemon at all and a genuinely
  running-but-curl-unreachable daemon, for all seven subcommands
  (`tests/test_cluster_join_leave.sh`, `tests/test_apikey_lifecycle.sh`,
  `tests/test_tenant_list_quota.sh`).
- `cluster::request_checked`'s own three-way status-splitting logic IS
  proven for real against a real local HTTP server this host's `curl`
  CAN reach (`tests/test_cluster_request_checked.sh`), which also proves
  the pre-existing `cluster::request` function's contract is unchanged.
- The two brand-new daemon-side routes' actual behavior (`GET
  /v1/tenants`, `GET`/`PUT /v1/tenants/:id/quota`) IS proven for real, at
  the Go/HTTP level (no mocks — `httptest` driving the real `gin.Engine`
  and real `*tenancy.Registry`/`*tenancy.Enforcer`), by
  `TestListTenants`/`TestTenantQuota_ViewAndSet` in
  `llmctld/internal/api/routes_tenants_test.go`.
- The bash-level SUCCESS-path assertions that could not be made are
  explicitly `assert_skip`'d with this exact reason in each test file,
  never silently omitted and never fabricated as passing.

## Recommended follow-up (outside this feature's scope; operator decision)

One of, non-exhaustive:
1. Give `llmctld`'s cluster API a plain HTTP/1.1+TLS (or h2) TCP listener
   alongside its HTTP/3 one, so an ordinary `curl` build can reach it.
2. Have `lib/cluster.sh` shell out to a small Go (or `quic-go`-linked)
   helper binary instead of `curl` when HTTP/3 is required.
3. Document HTTP/3-capable `curl` (built with `--with-nghttp3` +
   `--with-ngtcp2`, or an equivalent) as a hard prerequisite for
   operating `llmctl` in cluster mode, and gate `cluster::require_daemon`
   on that capability with an explicit, actionable error message instead
   of the current generic "unreachable" message when the real cause is
   "this host's curl cannot speak HTTP/3 at all".
