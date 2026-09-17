## Overview

`lib/cluster.sh` is llmctl's thin HTTP client for the opt-in, separately-built
`llmctld` cluster daemon. Single-host llmctl (the project's default and only
fully-implemented mode) never sources or calls into this file's behavior at
all — it exists purely for the `cluster`, `tenant`, and `apikey` CLI
subcommands, which become thin clients to `llmctld` when cluster mode is
enabled. The file owns the *only* code path in the project that talks to
`llmctld` over the network, and it is deliberately built to hard-fail rather
than silently fall back to single-host scheduling when the daemon is
unreachable: a silent fallback would misrepresent which mode actually served
a given request, which the project's anti-bluff constitution treats as a
release-blocking defect class. As of this writing `llmctld` itself is real
Go scaffolding with the daemon-reachability contract fully implemented and
tested, but with `cluster join`/`cluster leave` not yet implemented behind
that same guard (see `docs/user-manual.md`'s "cluster (PLANNED, not yet
implemented)" section and `docs/cluster-architecture.md` for the current,
honestly-disclosed implementation boundary).

## Prerequisites

* Must be sourced, not executed standalone — it resolves its own directory
  from `${BASH_SOURCE[0]}` and sources `common.sh` from that directory
  before defining anything.
* Functions/variables it consumes from `common.sh`: `die` (used by
  `cluster::require_daemon`'s hard-fail path).
* Requires `curl` on `PATH` — both `cluster::request` (to issue the actual
  HTTP request) and `_cluster_http3_supported` (to probe `curl --version`)
  call it directly; there is no fallback HTTP client.
* Environment variables it reads:
  - `LLMCTL_CLUSTER_ENDPOINT` — the `llmctld` API base URL. Defaults to
    `https://127.0.0.1:9443` via a `:-` parameter-expansion default,
    evaluated once when the file is sourced (see Edge cases).
  - `LLMCTL_CLUSTER_TOKEN` — optional bearer token; when non-empty,
    `cluster::request` adds an `Authorization: Bearer <token>` header.
* Network access: every `cluster::request` call makes a real outbound HTTPS
  (or HTTP/3-over-QUIC, when supported) request to `${LLMCTL_CLUSTER_ENDPOINT}`
  — there is no offline/dry-run mode for this file specifically (unlike
  `lib/scheduler.sh`'s `LLMCTL_DRY_RUN` handling for local process/service
  actions).
* Implicitly depends on a reachable `llmctld` daemon actually running and
  answering `GET /v1/cluster/status` for `cluster::require_daemon` to
  succeed — this is not a build-time or install-time prerequisite of the
  script itself, but every real subcommand built on top of it fails
  immediately without one.

## Usage examples

`lib/cluster.sh` is not meant to be run standalone; it is sourced by
`bin/llmctl`, which gates every `cluster`/`tenant`/`apikey` subcommand behind
`cluster::require_daemon` before dispatching:

```bash
# Query cluster/Raft status - the one subcommand with real behavior today.
llmctl cluster status

# Every subcommand below calls cluster::require_daemon first and hard-fails
# identically if llmctld is unreachable, regardless of the subcommand name.
llmctl cluster join 10.0.0.5:9443    # currently: die "... not yet implemented (Phase 9, US7)"
llmctl cluster leave                 # currently: die "... not yet implemented (Phase 9, US7)"
llmctl tenant create acme
llmctl tenant list
llmctl tenant quota acme --max-ram 32Gi
llmctl apikey create read-only
llmctl apikey rotate key-123
```

Overriding the endpoint and supplying a bearer token:

```bash
LLMCTL_CLUSTER_ENDPOINT=https://cluster.internal:9443 \
LLMCTL_CLUSTER_TOKEN="$(cat ~/.llmctl/token)" \
  llmctl cluster status
```

Directly sourcing the file (as the test suite does for other `lib/*.sh`
modules) to call its functions in isolation:

```bash
source lib/common.sh
source lib/cluster.sh
cluster::require_daemon               # dies immediately if llmctld is down
cluster::request GET /v1/cluster/status
cluster::request POST /v1/cluster/join '{"peer_addr":"10.0.0.5:9443"}'
```

## Edge cases

* **`llmctld` unreachable never falls back to single-host scheduling** —
  `cluster::require_daemon` treats ANY failure of
  `cluster::request GET /v1/cluster/status` (connection refused, timeout,
  TLS handshake failure, DNS failure — anything that makes curl exit
  non-zero, or an HTTP error status that `curl -sS` still exits 0 for, since
  the check only tests exit code, not response body) as "daemon
  unreachable" and calls `die` with a message naming the exact configured
  endpoint and the exact `systemctl --user start llmctld` /
  `launchctl load ...` remediation commands for both supported OSes. There
  is no code path in this file that would let a `cluster`/`tenant`/`apikey`
  command proceed as if it were a local, single-host operation.
* **Callers can distinguish "daemon unreachable" from "daemon returned an
  error status"** — `cluster::request`'s own doc comment states this
  explicitly: it prints the response body on success and returns curl's own
  exit code on failure, so a caller inspecting `$?` after a raw
  `cluster::request` call (outside the `require_daemon` gate, which only
  checks success/failure as a boolean) can tell a network-level failure
  apart from an HTTP-level one, since curl with `-sS` still exits 0 for a
  4xx/5xx HTTP response and only fails (non-zero) on things like connection
  refused, timeout, or a TLS error.
* **The HTTP/3 capability probe is cached exactly once per process** —
  `_CLUSTER_HTTP3_SUPPORTED` starts as an empty string (unknown); the first
  call to `_cluster_http3_supported` runs `curl --version | grep -qiE '(^| )HTTP3( |$)'`
  and memoizes the boolean result (`"1"`/`"0"`) into that global, so a
  script issuing many `cluster::request` calls in one process only pays for
  spawning `curl --version` once, not once per request.
* **`--http3` is opportunistic, never required** — `cluster::request` only
  appends `--http3` to curl's arguments when `_cluster_http3_supported`
  reports true; otherwise it silently falls back to whatever protocol curl
  negotiates by default (HTTP/2), because `llmctld` is documented (via
  `lib/doctor.sh`'s own matching check) to always serve both protocols
  dual-stack specifically so this fallback is safe.
* **`Authorization` header and request body are both conditionally
  appended, never sent empty** — `[[ -n "${LLMCTL_CLUSTER_TOKEN:-}" ]]` guards
  the bearer-token header (an unset or empty token means no `Authorization`
  header at all, not an empty one), and `[[ -n "${body}" ]]` guards `-d`
  (a `GET` request with no third argument to `cluster::request` sends no
  body).
* **5-second request timeout is unconditional and not overridable** —
  `--max-time 5` is hardcoded into `cluster_args`; there is no environment
  variable to change it, so a genuinely slow (but reachable) `llmctld`
  under heavy load would appear as "unreachable" to `cluster::require_daemon`
  after 5 seconds rather than being distinguished from a fully down daemon.
* **Endpoint default is resolved once, at source time, not per-call** —
  `LLMCTL_CLUSTER_ENDPOINT="${LLMCTL_CLUSTER_ENDPOINT:-https://127.0.0.1:9443}"`
  runs as a plain assignment when the file is sourced; exporting or changing
  `LLMCTL_CLUSTER_ENDPOINT` in the environment *after* this file has already
  been sourced in the current shell has no effect on subsequent calls unless
  the variable was already set before sourcing.
* **Every real subcommand in `bin/llmctl` calls `cluster::require_daemon`
  before doing anything else, including subcommands that are themselves not
  yet implemented** — e.g. `llmctl cluster join` still probes the daemon
  first and only reaches its own `die "... not yet implemented (Phase 9,
  US7)"` message if the probe succeeds; an unreachable daemon is reported as
  unreachable even for a subcommand whose real logic doesn't exist yet.

## Internal behaviour

1. **Setup** (top of file): resolves `_cluster_dir` from
   `${BASH_SOURCE[0]}`, sources `common.sh` from it, sets
   `LLMCTL_CLUSTER_ENDPOINT` to its default if unset, and initializes the
   process-local HTTP/3-capability cache `_CLUSTER_HTTP3_SUPPORTED=""`.
2. **`_cluster_http3_supported`** — internal helper. On first call (cache
   empty), runs `curl --version | grep -qiE '(^| )HTTP3( |$)'` and stores
   `"1"` or `"0"` into `_CLUSTER_HTTP3_SUPPORTED`; every call (including the
   first) then returns success/failure by testing whether the cached value
   equals `"1"`.
3. **`cluster::request <method> <path> [json-body]`** — the public,
   lower-level primitive. Builds a `curl_args` array
   (`-sS --max-time 5 -X <method> <endpoint><path> -H 'Content-Type:
   application/json'`), conditionally appends `--http3` (via step 2),
   conditionally appends the `Authorization: Bearer` header (if
   `LLMCTL_CLUSTER_TOKEN` is set), conditionally appends `-d <body>` (if a
   body was passed), and finally execs `curl "${curl_args[@]}"` — the
   response body goes to stdout on success; curl's own exit code propagates
   as the function's exit code on failure.
4. **`cluster::require_daemon`** — the public gate every cluster-mode
   subcommand calls first. Issues `cluster::request GET
   /v1/cluster/status`, discarding its output (`>/dev/null 2>&1`); on
   success, returns `0` immediately. On any failure, calls `die` with a
   multi-line message naming the unreachable endpoint, both OS-specific
   start commands, and the explicit no-silent-fallback guarantee.

## Related scripts

* `bin/llmctl` sources `lib/cluster.sh` directly (`source
  "${LLMCTL_ROOT}/lib/cluster.sh"`) and is the only caller of both public
  functions: `cluster::require_daemon` is called first in the `cluster)`,
  `tenant)`, and `apikey)` case arms of its command dispatcher, and
  `cluster::request` is called directly for the one subcommand with real
  behavior, `cluster status` (`cluster::request GET /v1/cluster/status`).
* Sources `lib/common.sh` for `die` only.
* Its HTTP/3-detection expression (`curl --version | grep -qiE '(^| )HTTP3( |$)'`)
  is duplicated independently in `lib/doctor.sh`'s environment
  self-diagnosis (the check that reports whether "llmctl cluster commands
  will use HTTP/2 against llmctld"); the two files do not share this logic
  through a common function, so a change to the detection expression in one
  needs the same change applied to the other.
* Covered generically (not cluster-specific) by `tests/test_syntax.sh`
  (`bash -n`, shebang, and `set -euo pipefail` checks over every shipped
  script including this one). There is no dedicated
  `tests/test_cluster.sh` in this repository as of this writing;
  `tests/test_tenant_service_isolation.sh` — despite the name overlap with
  the `tenant` CLI subcommand this file gates — exercises a different,
  unrelated concern: per-tenant systemd `Slice=` drop-in isolation inside
  `lib/service_linux.sh`, keyed off `LLMCTL_TENANT_ID`, for the local
  single-host service backend, not this file's HTTP client to `llmctld`.
* `lib/doctor.sh` reports on this file's client-side prerequisites
  informationally (curl's HTTP/3 support, Go toolchain availability to
  build `llmctld` from source) without importing or calling into this file.
* `docs/faq.md`, `docs/user-manual.md`, and `docs/cluster-architecture.md`
  document this file's exact hard-fail behavior and the current, honestly
  disclosed gap between the CLI-side guard (fully implemented here) and the
  `llmctld` daemon it targets (real scaffolding, with `cluster
  join`/`leave` and the `tenant`/`apikey` subcommands' real logic not yet
  implemented as of this writing).

## Last verified date

2026-09-17
