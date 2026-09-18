## Overview

`bin/llmctl` is the single CLI entrypoint for the whole project. It resolves
its own install root, sources every `lib/*.sh` module in a fixed order
(`common.sh`, `os_detect.sh`, `hardware.sh`, `catalog.sh`, `download.sh`,
`engine.sh`, `scheduler.sh`, `doctor.sh`, `cluster.sh`), defines `usage()` and
a handful of small `cmd_*` glue functions, and dispatches `argv[1]` to the
right library function in a `main()` `case` statement. It exists so every
other library stays a pure, sourceable function collection with no top-level
side effects — `bin/llmctl` is the only file that parses `$@` and decides what
the user asked for (hardware probing, model download/verify, engine builds,
service lifecycle, and the opt-in cluster commands).

## Prerequisites

* `bash` with `set -euo pipefail` support (the whole codebase targets bash
  &gt;= 3.2 per the file-header comments, though `bin/llmctl` itself needs
  nothing beyond core POSIX utilities plus what the sourced libs require).
* Every `lib/*.sh` file listed above must exist relative to
  `${LLMCTL_ROOT}/lib/` — `LLMCTL_ROOT` is derived from `${BASH_SOURCE[0]}`'s
  directory (`bin/`) walked up one level, then exported so every sourced
  library and every command it dispatches to can see it.
* Transitively inherits every prerequisite of the nine sourced libraries:
  `python3` (via `common.sh`'s `json_query`/`json_stdin`), `curl` (downloads),
  `cmake`/`make`/a C compiler (`engine.sh`), `flock` (`scheduler.sh`), and the
  OS-specific service backend (`systemd --user` on Linux, `launchd` on
  macOS, loaded lazily by `sched_load_backend`).
* No network access is required by `bin/llmctl` itself; individual
  subcommands (`models download`, `cluster *`) need it.

## Usage examples

```sh
# top-level help / version
bin/llmctl help
bin/llmctl version

# hardware + planning
bin/llmctl hw --json
bin/llmctl plan --json
LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json bin/llmctl plan

# catalog + models
bin/llmctl models list
bin/llmctl models download fast
bin/llmctl models verify fast

# engines
bin/llmctl build all
bin/llmctl build llama

# one-shot setup: doctor -> build both engines -> print the plan
bin/llmctl setup

# runtime (dry-run keeps every service/scheduler side effect as print-only)
LLMCTL_DRY_RUN=1 bin/llmctl start fast coder
bin/llmctl status
bin/llmctl switch fast
bin/llmctl auto chat coder
bin/llmctl logs fast 100

# persistent services
bin/llmctl install
bin/llmctl enable fast
bin/llmctl disable fast
bin/llmctl restart fast

# host-local port override for one profile (never edit the catalog file)
LLMCTL_PORT_FAST=18080 bin/llmctl start fast

# cluster (opt-in; every subcommand hard-fails if llmctld is unreachable)
bin/llmctl cluster status
bin/llmctl cluster join 10.0.0.5:9443
bin/llmctl cluster leave

# tenant/apikey (opt-in; same daemon-reachability guarantee as cluster)
bin/llmctl tenant create demo
bin/llmctl tenant list
bin/llmctl tenant quota demo --max-concurrent-requests 5
bin/llmctl tenant quota demo
bin/llmctl apikey create model-viewer
bin/llmctl apikey rotate <key-id>
```

## Edge cases

* **No subcommand at all**: `cmd="${1:-help}"` — running `bin/llmctl` with no
  arguments prints help rather than erroring, since `help` is the default.
* **Unknown top-level command**: falls into the `*)` branch, calls
  `err "unknown command: ${cmd}"`, prints `usage()` to stderr, and
  `exit 2` — a distinct exit code from the `die`-driven `exit 1` used for
  missing-argument errors elsewhere (verified by `tests/test_cli.sh`).
* **Missing required argument** for `switch`, `models download`,
  `models verify`, `restart`, `enable`, `disable`, `logs`: each checks
  `[[ "$#" -eq 1 ]]` (or `-ge 1` for `logs`) before dispatching and calls
  `die "usage: llmctl <cmd> <arg>"` on `exit 1` with the exact usage string.
* **`models` / `cluster` / `tenant` / `apikey` sub-dispatch**: each reads its
  own sub-command with a default (`${1:-list}`, `${1:-status}`, `${1:-list}`,
  `${1:-}`) and `shift`s only when `$# -gt 0`, so `llmctl models` with zero
  args does not error on an unbound `$1` — it falls through to the default
  sub-command instead.
* **Cluster/tenant/apikey commands are gated by daemon reachability, not
  stubbed** (006-cli-daemon-wiring): `cluster::require_daemon` (from
  `lib/cluster.sh`) is called before the `case` on the sub-command, so an
  unreachable `llmctld` fails loudly, with a clear "llmctld unreachable"
  message, before any of the seven real subcommands below is even
  attempted — single-host mode never silently substitutes for the
  cluster daemon. All seven subcommands (`cluster join/leave`,
  `apikey create/rotate`, `tenant create/list/quota`) now make a real
  HTTP request to `llmctld` and report its genuine response — none of
  them `die`s with "not yet implemented" any more.
  - `cluster join <peer-addr>` sends `{"peer_id": "$(hostname)",
    "peer_addr": "<peer-addr>"}` to `POST /v1/cluster/join` — `peer_id`
    is derived from this host's own hostname since the CLI documents a
    single `<peer-addr>` argument while the daemon's real route requires
    both fields.
  - `apikey create <scope>` sends `{"owner_id": "<scope>", "scopes":
    ["<scope>"]}` to `POST /v1/auth/apikeys` — the given value is used
    as both the key's owner and its sole scope, since the CLI documents
    a single `<scope>` argument while the daemon's real route requires
    an `owner_id`.
  - `tenant quota <name> [--flag value ...]` issues a `GET
    /v1/tenants/<name>/quota` when no flags are given (view), or a `PUT`
    with a JSON body built from whichever of `--requests-per-second`,
    `--max-concurrent-requests`, `--max-gpu-bytes`, `--max-cpu-cores`,
    `--max-ram-bytes`, `--max-storage-bytes` were passed (set) — any
    flag not given defaults to `0` (unlimited) on the daemon side, per
    `tenancy.Limits`'s own zero-means-unlimited convention. **Setting**
    a quota (`PUT`) requires an `LLMCTL_CLUSTER_TOKEN` carrying a role
    granting `tenant:manage` (the same bar as `tenant create`) — a
    tenant cannot raise its own quota merely by owning that tenant
    (post-review security fix: an earlier version of this route allowed
    exactly that self-service escalation). **Viewing** a quota (`GET`)
    still only requires owning the tenant (or `tenant:manage`).
  - `tenant list` and `tenant quota` (both verbs) go through the new
    `cluster::request_checked` (see below), never the original
    `cluster::request`, so a non-2xx daemon response (e.g. a 404 for a
    nonexistent tenant, a 403 for an unauthorized caller) is reported as
    a distinct daemon-side error rather than silently treated the same
    as a successful response.
* **`cluster::request_checked` vs `cluster::request`** (`lib/cluster.sh`,
  006-cli-daemon-wiring): `cluster::request` (unchanged, still the sole
  function `cluster status` and every `POST`-only subcommand above uses)
  prints the response body and its exit code is ALWAYS curl's own raw
  exit code — 0 for any HTTP response received at all, reachable or not,
  regardless of HTTP status. `cluster::request_checked` is an additive
  sibling used ONLY by `tenant list`/`tenant quota`: it captures the real
  HTTP status code and returns three distinguishable outcomes — exit 0
  on a 2xx response (body on stdout), exit 1 on a non-2xx response (the
  daemon's own `{"error": "..."}` body on stdout), or curl's own
  transport-failure exit code unchanged (connection refused, timeout,
  ...) when the daemon is genuinely unreachable — see
  `tests/test_cluster_request_checked.sh` for the real, non-mocked proof
  of all three outcomes.
* **Environment-architecture finding (recorded, not a bug in this doc's
  own commands)**: on a host whose `curl` build has no HTTP/3 support,
  no cluster/tenant/apikey command above can complete a successful round
  trip against a real `llmctld`, because `llmctld`'s cluster API serves
  exclusively over HTTP/3 (QUIC/UDP) with mandatory mTLS — a plain
  TCP-based `curl` request to it fails with "Connection refused",
  identical to the daemon not running at all. Every command above still
  correctly reports the genuine "llmctld unreachable" failure in that
  case; see `docs/qa/006-cli-daemon-wiring/` for the full writeup and how
  to verify HTTP/3 support locally (`curl --version | grep -i HTTP3`).
* **`hw`/`plan` `--json` flag detection**: checked as `"${1:-}" == "--json"`
  (not getopt-style parsing), so `--json` must be the very next token after
  `hw`/`plan`; anything else (including no argument) falls through to the
  human-readable renderer.
* **`enable` routes through the scheduler's own lock** (comment at
  bin/llmctl:158-163): this used to run enable logic directly in `main()`
  with no lock, a TOCTOU race on scheduler's read-budget-then-write-
  reservation sequence; it now calls `sched_enable "$1"`, which is dispatched
  under the same lock `start` already holds.
* **`disable` cleans up runtime state files** after calling `svc_disable`:
  it removes `${LLMCTL_SERVICES_DIR}/$1.enabled` and
  `${LLMCTL_RUNTIME_DIR}/$1.run` unconditionally (`rm -f`, so a
  never-created file is not an error).
* **`build`'s default argument**: `engine_build "${@:-all}"` — with zero
  args, `${@:-all}` expands to the single word `all`; with any args present
  it passes them through unmodified (so `build llama extra-arg` still works
  as `engine_build` itself defines it).

## Internal behaviour

1. **Bootstrap** (top of file): compute `_bin_dir` from `${BASH_SOURCE[0]}`,
   derive and `export LLMCTL_ROOT` as its parent, then `source` all nine
   `lib/*.sh` files by absolute path (each with a `# shellcheck source=`
   hint comment for static analysis).
2. **`usage()`**: a single heredoc (`cat <<'EOF' ... EOF`) printing the full
   command reference shown under "Usage examples" above — this is the exact
   text `help`/`-h`/`--help` prints, and the text `bin/llmctl` (with no args)
   prints via its `help` default.
3. **`cmd_models_list()`**: calls `catalog_check` once, then iterates
   `catalog_profiles()` printing a fixed-width table (profile, port, engine,
   size in GiB rounded up via `(size_mb + 1023) / 1024`, min-tier,
   capability string) — purely a formatting wrapper around `lib/catalog.sh`
   getters.
4. **`cmd_setup()`**: the one-shot onboarding path — logs intent, runs
   `doctor_run` and `die`s with a clear message if it fails, builds both
   engines via `engine_build all`, then pipes a fresh hardware probe through
   the planner twice (`hw_probe_json | catalog_plan_json | catalog_plan_human`)
   to show the resulting plan, and finally prints a one-line "what's next"
   hint.
5. **`main()`**: reads `cmd="${1:-help}"`, shifts past it if present, then
   dispatches on a `case "${cmd}"` with one branch per top-level command
   (`setup`, `doctor`, `hw`/`probe`, `plan`, `models`, `build`, `install`,
   `enable`, `disable`, `start`, `stop`, `restart`, `switch`, `auto`,
   `status`, `logs`, `cluster`, `tenant`, `apikey`, `version`,
   `help`/`-h`/`--help`, and a catch-all `*` for unknown commands). Most
   branches call straight into a `lib/*.sh` function (`sched_start`,
   `sched_stop`, `sched_switch`, `sched_auto`, `sched_status`, `doctor_run`,
   `hw_probe_json`/`hw_probe_human`, `catalog_plan_json`/`catalog_plan_human`,
   `download_profile`, `verify_profile`, `engine_build`); a few
   (`install`, `disable`, `restart`, `logs`) first call `sched_load_backend`
   to source the correct OS service backend before calling into it
   (`svc_install`, `svc_disable`, `svc_restart`, `svc_logs`).
6. **`main "$@"`** at the bottom of the file is the only top-level statement
   executed when the script runs — everything above it is function
   definitions.

## Related scripts

* Sources (in this exact order): `lib/common.sh`, `lib/os_detect.sh`,
  `lib/hardware.sh`, `lib/catalog.sh`, `lib/download.sh`, `lib/engine.sh`,
  `lib/scheduler.sh`, `lib/doctor.sh`, `lib/cluster.sh`.
* `lib/scheduler.sh` and `lib/doctor.sh` are documented at
  `docs/scripts/scheduler.md` and (if present) their own companion docs;
  `lib/service_linux.sh` / `lib/service_macos.sh` are documented at
  `docs/scripts/service_linux.md` / `docs/scripts/service_macos.md` — all
  four are sourced transitively through `lib/scheduler.sh`'s
  `sched_load_backend`, not directly by `bin/llmctl`.
* Exercised end-to-end by `tests/test_cli.sh` (dispatch, help/version,
  exit codes, `hw`/`plan` fixture-backed output) and indirectly by nearly
  every other `tests/test_*.sh` file, since most invoke `${LLMCTL_ROOT}/bin/llmctl`
  as the black-box entrypoint under test (e.g. `tests/test_setup_e2e.sh`,
  `tests/test_scheduler.sh`, `tests/test_services.sh`,
  `tests/test_port_override.sh`).
* `tests/test_syntax.sh` parses `bin/llmctl` (and every `lib/*.sh`) with
  `bash -n` as a basic parseability gate.

## Last verified date

2026-09-17
