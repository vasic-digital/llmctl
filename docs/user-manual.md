# User Manual

**Revision:** 1
**Last modified:** 2026-09-15T00:00:00Z

Complete command reference for `bin/llmctl`. Every command below is
described from the real source (`bin/llmctl`'s `main()` case statement plus
the `lib/*.sh` functions each branch calls) — nothing here is guessed or
inferred from the `--help` text alone (Constitution §11.4.6). For a guided
first run see `docs/quickstart.md`; for wiring a coding agent against a
running profile see `docs/integrations.md`.

## Conventions used below

- `llmctl` is invoked as `./bin/llmctl <command> [args]` from the repository
  root, or as `llmctl` if the `bin/` directory is on `PATH`.
- All ports, profile names, and defaults below are taken verbatim from
  `models/catalog.json` and cross-checked against `docs/integrations.md`'s
  port table.
- Environment variables that change command behavior are documented once in
  [Environment variables](#environment-variables) at the end of this file
  rather than repeated under every command.
- "Real evidence" callouts cite an actual assertion from the test suite
  (`tests/test_cli.sh`, `tests/test_scheduler.sh`) so the documented output
  shape is provably the real one, not an invented example.

## Command index

| Command | Purpose |
|---|---|
| [`setup`](#setup) | doctor → build engines → hardware plan, in one shot |
| [`doctor`](#doctor) | environment self-diagnosis |
| [`hw`](#hw---json) | probe hardware (human or JSON) |
| [`plan`](#plan---json) | which catalog profiles fit this host |
| [`models list`](#models-list) | list catalog profiles |
| [`models download`](#models-download-profile) | verified model download |
| [`models verify`](#models-verify-profile) | re-verify a downloaded profile's checksums |
| [`build`](#build-allllamacolibri) | build the inference engines from source |
| [`install`](#install) | install/refresh persistent-service unit templates |
| [`enable`](#enable-profile) | enable a profile at login + start it now |
| [`disable`](#disable-profile) | disable autostart + stop |
| [`start`](#start-profile-more) | co-resident start (footprint-checked) |
| [`stop`](#stop-profileall) | stop one, several, or all running profiles |
| [`restart`](#restart-profile) | restart a service |
| [`switch`](#switch-profile) | stop everything, start exactly one profile |
| [`auto`](#auto-capability) | best-fitting set for a capability, with LRU eviction |
| [`status`](#status) | running services, reservations, crash-loop state |
| [`logs`](#logs-profile-lines) | tail a service log |
| [`cluster`](#cluster-planned-not-yet-implemented) | **planned** — cluster join/leave/status |
| [`tenant`](#tenant-planned-not-yet-implemented) | **planned** — tenant namespace management |
| [`apikey`](#apikey-planned-not-yet-implemented) | **planned** — API key issuance/rotation |
| [`version`](#version) | print the llmctl version |
| [`help`](#help) | print usage |

---

## setup

```
llmctl setup
```

Runs the full bring-up sequence in order (`cmd_setup` in `bin/llmctl`):

1. `doctor_run` — aborts with `die "doctor reported failures; fix them and
   re-run 'llmctl setup'"` if any check `FAIL`s.
2. `engine_build all` — builds both `llama.cpp` and `colibri` from the
   pinned `submodules/` git submodules.
3. Prints the hardware plan (`hw_probe_json | catalog_plan_json |
   catalog_plan_human`) — the same output as `llmctl plan`.

Ends with `info "setup complete. Next: llmctl models download <profile>,
then llmctl start <profile>"`.

Takes no arguments. See `docs/quickstart.md` §1 for the expected full
transcript on a fresh clone.

## doctor

```
llmctl doctor
```

Environment self-diagnosis (`doctor_run` in `lib/doctor.sh`). Every check
prints `PASS`, `WARN`, or `FAIL` with real evidence inline — never a bare
claim. Checks performed, in order:

- OS + architecture detection.
- Required commands: `bash`, `curl`, `git`, `python3` (`FAIL` if missing).
- Optional commands: `cmake` (needed for `llmctl build llama`), `make`
  (needed for `llmctl build colibri`), a C compiler (`gcc`/`clang`/`cc`).
- A sha256 tool (`sha256sum`, `shasum`, or `openssl`) — `FAIL` if none, since
  downloads could not be verified.
- Whether `submodules/llama.cpp` and `submodules/colibri` are initialized
  git submodules, printing the short commit hash when they are.
- Catalog validity (`models/catalog.json` parses and has profiles).
- Whether the state directory is writable.
- GPU tooling: `nvidia-smi`, Apple Silicon unified memory, or `rocm-smi`
  (informational only — `WARN`, never `FAIL`, on CPU-only hosts).
- Service backend availability: `systemd --user` session on Linux,
  `launchctl` on macOS.
- Whether `llama-server` has already been built.
- Cluster-mode tooling (informational, never blocking single-host use):
  whether `curl` supports HTTP/3, and whether a Go toolchain is present to
  build the opt-in `llmctld` daemon.

Exit code is non-zero exactly when `DOCTOR_FAILS > 0`; the final line prints
`doctor: <N> failure(s), <N> warning(s)`.

## hw [--json]

```
llmctl hw            # human-readable
llmctl hw --json     # machine-readable
llmctl probe         # alias for hw
```

Probes CPU, RAM, GPU/VRAM, and storage on the host (`hw_probe_human` /
`hw_probe_json` in `lib/hardware.sh`, called directly from `main()`'s
`hw|probe` branch). `--json` prints the same probe as a JSON document
consumed internally by `plan`, `start`, `auto`, and `enable`.

Real evidence (from `tests/test_cli.sh`, against the fixture hardware doc):
human output includes lines such as `AMD Ryzen 7 2700X Eight-Core Processor`
and `NVIDIA GeForce RTX 3060` — i.e. the actual detected CPU model string
and GPU name, not a generic label.

## plan [--json]

```
llmctl plan            # human-readable
llmctl plan --json     # machine-readable
```

Pipes the live hardware probe through the catalog planner
(`hw_probe_json | catalog_plan_json | catalog_plan_human`, or without the
final stage for `--json`). Reports:

- The host's classified tier (`below-minimum`, `baseline`, `workstation`,
  or `datacenter` — see `catalog_classify_tier` in `lib/catalog.sh`).
- RAM/VRAM/storage budgets (available RAM minus 4 GiB headroom; total VRAM
  minus 15% headroom).
- Per-profile verdict: `FITS` (recommended), `GATED` (host tier too low for
  the profile's `min_tier`), or `NO-FIT` (footprint exceeds budget), plus
  mode (`gpu`/`cpu`/`colibri`), RAM/VRAM need, context size, and GPU-layer
  count.
- Co-residency groups: sets of profiles whose combined RAM+VRAM+storage
  footprint fits at the same time, computed by greedy bin-packing in port
  order.

Real evidence (`tests/test_cli.sh`): against the baseline fixture, output
contains `Host tier:   baseline` and `group 1: fast, coder, vision` — the
`fast` (8080), `coder` (8081), and `vision` (8082) profiles co-resident in
one group.

## models list

```
llmctl models list
```

Lists every profile in `models/catalog.json` (`cmd_models_list` in
`bin/llmctl`), one row per profile: `profile`, `port`, `engine`
(`llama`/`colibri`), `size GiB` (rounded up from the sum of the profile's
file sizes), `min-tier`, and `capabilities` (space-separated, e.g. `chat`,
`coder`, `vision`). Current catalog profiles: `fast` (8080), `coder` (8081),
`vision` (8082), `vision-pro` (8083), `moe-fast` (8084), `small` (8085),
`ws-dense-32b` (8086), `ws-moe-30b` (8087), `colibri-glm` (8090),
`colibri-qwen36` (8091).

## models download \<profile\>

```
llmctl models download coder
```

Verified download for one catalog profile (`download_profile` in
`lib/download.sh`). For each file the catalog lists:

1. Skips the download if the file already exists on disk **and** its
   sha256 matches the catalog (or a live-fetched Hugging Face checksum when
   the catalog entry has none).
2. Otherwise downloads via `curl -L --continue-at -` into a `.part` file
   (resumable; falls back to a full re-download from byte 0 if the server
   answers curl exit 33, "no Range support").
3. Verifies size and sha256 **before** the atomic rename to the final path
   — a checksum mismatch never lands at the destination.
4. Runs a post-download validation appropriate to the engine:
   - `llama` (GGUF) profiles: a real smoke test — starts `llama-server`
     against the downloaded model on `127.0.0.1:${LLMCTL_SMOKE_PORT}`
     (default `18090`), waits for `/health`, then sends the deterministic
     prompt `"Reply with exactly: OK"` via `/v1/chat/completions` and
     requires the response to contain `OK`. Skipped with a warning (not a
     failure) if `llama-server` has not been built yet.
   - `colibri` profiles: `coli doctor` if the `coli` launcher is installed,
     else a structural check (at least one non-empty `.safetensors` shard
     plus a `config*.json` file).
5. Appends every command, exit code, and raw output to
   `$LLMCTL_VERIFY_DIR/<profile>.log` as captured evidence.

Example: `llmctl models download fast` downloads Llama 3.1 8B Instruct
Q4_K_M (~4.9 GB, per `models/catalog.json`) and smoke-tests it. Any
mismatch anywhere in this chain is a hard failure (non-zero exit).

## models verify \<profile\>

```
llmctl models verify coder
```

Re-verifies the checksums of an already-downloaded profile
(`verify_profile` in `lib/download.sh`) without re-downloading or
re-running the smoke test. Fails with `die "profile <p> not downloaded (no
<dir>)"` if the profile's model directory does not exist, and fails on the
first file whose size or sha256 no longer matches the catalog.

## build [all|llama|colibri]

```
llmctl build            # both engines (default)
llmctl build llama      # llama.cpp only
llmctl build colibri    # colibri only
```

Builds the inference engines from the pinned `submodules/llama.cpp` and
`submodules/colibri` git submodules (`engine_build` in `lib/engine.sh`),
initializing them first via `git submodule update --init --recursive` if
either is not yet checked out.

- `llama`: configures with `cmake` and builds the `llama-server` target via
  `cmake --build`. Backend is auto-detected (`engine_detect_backend`):
  macOS → Metal (on by default upstream, nothing added); `nvcc` on `PATH`
  or `/usr/local/cuda/bin/nvcc` present → `-DGGML_CUDA=ON`; `rocm-smi` or
  `/opt/rocm` present → `-DGGML_HIP=ON`; otherwise a CPU build with
  `-DGGML_NATIVE=ON` (host-native optimization). Job count comes from
  `llmctl_nproc`. After building it runs `llama-server --version` and dies
  if that fails, so a "successful" build always means a verified-runnable
  binary.
- `colibri`: builds the C engine targets (`colibri`, `qwen36` by default)
  via `make -C submodules/colibri/c <target>`, verifying each resulting
  binary is executable, then optionally `pip install -e submodules/colibri`
  to install the `coli` Python launcher (a clear `warn`, not a failure, if
  `pip`/`pip3` is unavailable).

`LLMCTL_DRY_RUN=1` prints every `cmake`/`make`/`pip` command instead of
running it.

## install

```
llmctl install
```

Installs (or refreshes) the persistent-service backend for this OS
(`svc_install`, dispatched via `sched_load_backend`):

- **Linux**: writes systemd `--user` unit templates
  `llmctl-llama@.service` and `llmctl-colibri@.service` into
  `${LLMCTL_UNIT_DIR:-$XDG_CONFIG_HOME/systemd/user}`. Each instance reads
  its launch parameters from an `EnvironmentFile` written by `enable`/
  `start`. `MemoryHigh`/`MemoryMax` are set to the host's full probed RAM
  (a hard cgroup ceiling at the physical limit, not an artificially reduced
  one — see the comment in `lib/service_linux.sh`), with
  `Restart=always`/`RestartSec=5`/`StartLimitBurst=5` for crash-loop
  bounding. Runs `systemctl --user daemon-reload` and attempts
  `loginctl enable-linger` so services survive logout.
- **macOS**: prepares the LaunchAgents directory
  (`${LLMCTL_PLIST_DIR:-~/Library/LaunchAgents}`); per-profile plists are
  written individually by `enable`/`start`, not by `install`.

## enable \<profile\>

```
llmctl enable coder
```

Writes the profile's launch environment (or plist, on macOS), enables
autostart at login, **and** starts it now (`main()`'s `enable` branch in
`bin/llmctl`): computes a fresh hardware plan, resolves the profile's
mode/port/ctx/ngl/parallel/flash-attn/ram/vram from it, calls
`sched_build_launch`, writes the env file, touches
`$LLMCTL_SERVICES_DIR/<profile>.enabled`, calls `svc_enable` (which starts
the service via `systemctl --user enable && start` or `launchctl
bootstrap`), and records the scheduler reservation so budgeting stays
correct. Prints `enabled and started <profile> (mode=<mode>, port=<port>)`.

An enabled profile is never evicted by `llmctl auto`'s LRU logic.

## disable \<profile\>

```
llmctl disable coder
```

Reverses `enable`: stops and disables the service (`svc_disable`), then
removes the `.enabled` marker and the runtime reservation file
(`$LLMCTL_SERVICES_DIR/<profile>.enabled`, `$LLMCTL_RUNTIME_DIR/<profile>.run`).

## start \<profile\> [more...]

```
llmctl start coder
llmctl start fast small     # co-resident: both together
```

Starts one or more profiles if their **combined** footprint fits the live
RAM/VRAM budgets minus what is already reserved (`sched_start` →
`_sched_start_impl` in `lib/scheduler.sh`, run under an exclusive advisory
lock so concurrent invocations never race). For each requested profile: an
already-running profile is skipped with a log line; an unknown profile
dies with `unknown profile: <p> (see: llmctl models list)`; a profile whose
individual or cumulative footprint would exceed the budget aborts the
*whole* start (nothing partially starts) with an error naming the exact
shortfall, a suggested alternative profile that fits right now (if any),
and a `llmctl switch <profile>` fallback.

On success each profile is launched via `sched_build_launch` +
`svc_write_env` + `svc_start`, and a reservation record is written.

Real evidence (`tests/test_scheduler.sh`): `llmctl start fast small`
prints `started fast (mode=<mode>, port=8080, reserved <N> MiB RAM + <N>
MiB VRAM)` and the equivalent line for `small` (port 8085); a refused start
prints `cannot start 'vision': needs <N> MiB RAM + <N> MiB VRAM, but only
<N> MiB RAM + <N> MiB VRAM remain` followed by `suggested alternative that
fits now: llmctl start <alt>`.

## stop [profile|all]

```
llmctl stop coder     # stop one
llmctl stop           # stop everything (no args = all)
llmctl stop all       # stop everything (explicit)
```

Stops the named profile(s), or every running profile when called with no
arguments or with `all` (`sched_stop` → `_sched_stop_impl`). Removes each
stopped profile's runtime reservation file and prints `stopped <profile>`.
Stopping does not disable autostart — an enabled profile stopped this way
will restart on next login/boot unless also `disable`d.

## restart \<profile\>

```
llmctl restart coder
```

Restarts one running service in place (`svc_restart`: `systemctl --user
restart` on Linux, equivalent to `svc_start`/`kickstart -k` on macOS).
Requires exactly one profile argument.

## switch \<profile\>

```
llmctl switch vision
```

The always-works escape hatch: stops every running profile, then starts
exactly the named one (`sched_switch`: `sched_stop all` followed by
`sched_start <profile>`). Useful when a co-resident `start` would be
refused for lack of budget.

Real evidence (`tests/test_scheduler.sh`): after `llmctl switch moe-fast`,
the only profile reported by `sched_running` is `moe-fast`.

## auto \<capability\> [...]

```
llmctl auto chat
llmctl auto coder vision
```

Resolves each requested capability (`chat`, `coder`, or `vision`) to the
best-ranked catalog profile that is both recommended for this host and
tagged with that capability (`sched_auto` → `_sched_auto_impl` in
`lib/scheduler.sh`), using the fixed ranking in `sched_rank_for_capability`
(e.g. for `chat`: `colibri-glm ws-dense-32b ws-moe-30b coder moe-fast fast
vision-pro vision colibri-qwen36 small`, best first). If the resolved set
does not currently fit the RAM/VRAM budget alongside what is already
running, `auto` evicts the least-recently-started **non-enabled** running
service (LRU) — one at a time, up to 16 attempts — until it fits, printing
`auto: evicting '<profile>' (LRU, not enabled) to make room` for each
eviction. Enabled services and profiles already in the target set are
never evicted; if nothing evictable remains, it fails with `cannot satisfy
'auto <caps>': remaining services are enabled (protected)` and suggests
`llmctl disable <profile>` or `llmctl switch <profile>`.

Real evidence (`tests/test_scheduler.sh`): `llmctl auto vision` prints
`evicting 'fast'` when eviction is required; `llmctl auto coder vision`
prints `capability 'coder' -> profile '<name>'` for each capability
resolved.

## status

```
llmctl status
```

Human-readable table of every running profile (`sched_status`): `profile`,
`port`, `mode`, `RAM MiB`, `VRAM MiB`, `enabled` (yes/no), and `state`.
`state` is `running`, or `failed (crash-loop)` when `svc_is_failed`
reports the service exceeded its restart bound (systemd's
`StartLimitBurst`/`StartLimitIntervalSec`, or the launchd dry-run marker
convention) — in which case the last line of the profile's log is printed
immediately below its row, so a crash-looped service is never shown as
just another healthy row. Prints `no llmctl services running` when nothing
is up.

## logs \<profile\> [lines]

```
llmctl logs coder        # last 100 lines (default)
llmctl logs coder 500    # last 500 lines
```

Tails `$LLMCTL_LOG_DIR/<profile>.log` (`svc_logs`, identical on both
backends). Dies with `no log file yet: <path>` if the profile has never
produced a log. `LLMCTL_DRY_RUN=1` prints the `tail` invocation instead of
running it.

## cluster (PLANNED, not yet implemented)

```
llmctl cluster join <peer-addr>   # planned — not yet implemented
llmctl cluster leave              # planned — not yet implemented
llmctl cluster status             # real: queries a running llmctld daemon
```

**Honest scope.** `cluster` is a real CLI surface today, but it is **not a
functioning multi-node clustering feature**. Reading `bin/llmctl`'s actual
`cluster)` case branch:

- Every `cluster` subcommand first calls `cluster::require_daemon`
  (`lib/cluster.sh`), which hard-fails with a message naming the
  unreachable endpoint and how to start `llmctld` if the daemon does not
  answer its own `GET /v1/cluster/status`. **llmctl never silently falls
  back to single-host scheduling when cluster mode is invoked but the
  daemon is unreachable** — a silent fallback would misrepresent which
  mode actually served the request (this is a deliberate anti-bluff
  property of `cluster::require_daemon`, documented in its own header
  comment).
- `cluster join <peer-addr>`: once the daemon is confirmed reachable, the
  command itself immediately `die`s with the literal message `llmctld
  reachable but 'cluster join' is not yet implemented (Phase 9, US7)`.
- `cluster leave`: same — dies with `llmctld reachable but 'cluster leave'
  is not yet implemented (Phase 9, US7)`.
- `cluster status`: this is the one subcommand with real behavior — once
  the daemon is confirmed reachable, it issues a genuine HTTP request
  (`cluster::request GET /v1/cluster/status`) against
  `${LLMCTL_CLUSTER_ENDPOINT:-https://127.0.0.1:9443}` and prints the raw
  response body. It requires a real running `llmctld` process; there is no
  llmctl-side simulation of cluster state.

Do not treat `cluster join`/`cluster leave` as working features — they are
CLI stubs reserved for Phase 9 (User Story 7) and currently do nothing but
fail with the message above, by design.

## tenant (PLANNED, not yet implemented)

```
llmctl tenant create <name>
llmctl tenant list
llmctl tenant quota <name> [...]
```

**Honest scope: none of these are implemented.** Every `tenant` subcommand
first calls `cluster::require_daemon` (same daemon-reachability hard-fail
as `cluster`, above), and then — even with a reachable daemon —
immediately `die`s:

- `tenant create <name>`: `llmctld reachable but 'tenant create' is not
  yet implemented (Phase 11, US9)`.
- `tenant list`: `llmctld reachable but 'tenant list' is not yet
  implemented (Phase 11, US9)`.
- `tenant quota <name> [...]`: `llmctld reachable but 'tenant quota' is
  not yet implemented (Phase 11, US9)`.

There is no multi-tenancy capability in llmctl today. This surface exists
only as a reserved CLI shape for Phase 11 (User Story 9).

## apikey (PLANNED, not yet implemented)

```
llmctl apikey create <scope>
llmctl apikey rotate <key-id>
```

**Honest scope: none of these are implemented.** Same pattern as `tenant`
— `cluster::require_daemon` runs first, and then each subcommand `die`s
unconditionally:

- `apikey create <scope>`: `llmctld reachable but 'apikey create' is not
  yet implemented (Phase 11, US9)`.
- `apikey rotate <key-id>`: `llmctld reachable but 'apikey rotate' is not
  yet implemented (Phase 11, US9)`.

There is no API-key issuance or rotation capability in llmctl today. This
surface exists only as a reserved CLI shape for Phase 11 (User Story 9).

## version

```
llmctl version
```

Prints `llmctl <version>`, e.g. `llmctl 0.1.0` (the `LLMCTL_VERSION`
constant at the top of `bin/llmctl`). Real evidence (`tests/test_cli.sh`):
the output contains the literal substring `llmctl 0.`.

## help

```
llmctl help
llmctl -h
llmctl --help
llmctl                 # no command = help
```

Prints the full usage text (the `usage()` function in `bin/llmctl`, the
same text `llmctl` prints when invoked with no arguments or an unrecognized
command — an unrecognized command prints `unknown command: <cmd>` to
stderr, then the usage text, then exits 2).

---

## Environment variables

These affect command behavior across multiple commands rather than being
specific to one; each is documented at its point of use in `usage()` and in
the relevant `lib/*.sh` module.

| Variable | Effect |
|---|---|
| `LLMCTL_DRY_RUN=1` | Every OS service action (`systemctl`/`launchctl`/`tail`/`curl` downloads/`cmake`/`make` builds) is printed instead of executed. Env/unit/plist files are still written for real so their content is testable. |
| `LLMCTL_FAKE_HW=<file.json>` | Use a hardware fixture instead of a live probe (testing). |
| `LLMCTL_MODELS_DIR=<dir>` | Override where downloaded model files are stored. |
| `LLMCTL_CLUSTER_ENDPOINT=<url>` | `llmctld` API endpoint for `cluster`/`tenant`/`apikey` commands. Default `https://127.0.0.1:9443`. |
| `LLMCTL_CLUSTER_TOKEN=<jwt>` | Bearer token sent as `Authorization: Bearer <jwt>` on cluster/tenant/apikey HTTP requests. |
| `LLMCTL_SEED=<n>` | Appends `--seed <n> --temp 0` to a `llama` profile's launch arguments (deterministic live-challenge mode). Opt-in only; unset by default so everyday interactive sessions are unaffected. |
| `LLMCTL_SMOKE=0` | Disables the post-download smoke test in `models download` (still logged as an explicit skip, never silently omitted). |
| `LLMCTL_SMOKE_PORT` / `LLMCTL_SMOKE_TIMEOUT` | Port (default `18090`) and timeout in seconds (default `120`) for the post-download GGUF smoke test. |
| `LLMCTL_LLAMA_SERVER` | Override path to the `llama-server` binary (used by `start`/`enable`/`models download`'s smoke test). |
| `LLMCTL_COLI_BIN` | Override the `coli` launcher binary name/path used by `colibri` profile launches. |
| `LLMCTL_UNIT_DIR` (Linux) | Override the systemd `--user` unit directory `install` writes to. |
| `LLMCTL_PLIST_DIR` (macOS) | Override the LaunchAgents directory `install`/`enable` writes to. |
