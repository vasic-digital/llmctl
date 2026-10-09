## Overview

`lib/decide.sh` is the **thin bash front end** of llmctl's typed-decision
commands (`llmctl decide ...`). The decision logic itself lives in the Go
binary `llmctl-decide` (`cmd/llmctl-decide`, `internal/client`,
`internal/server`, `internal/gateway`): the HTTPS client (`ask`, `batch`,
`models`), the gateway (`serve`), key management (`key`) and certificate
management (`cert`). This file only

* **locates** that binary (`decide_bin`),
* **delegates** `ask`, `batch`, `models`, `serve`, `key`, `cert` and the other
  Go subcommands to it, passing every argument through unchanged and returning
  its exit code unchanged,
* keeps the two reports that need the shell libraries: `decide capacity` (the
  planner's `decision_instances`, the same numbers as `llmctl plan --json`)
  and `decide status`,
* keeps the **interactive wizard** (`decide_interactive`), a thin prompter over
  `decide ask`.

What it deliberately does **not** do any more (candidate defects D-02, D-03,
D-05, D-11, D-29, N-01): it never reads or forwards the access key (the Go
client resolves it: environment, then `.env`, FR-058), never puts the state on a
command line (use `--state-file` or `--stdin`; there is no argument-length
limit), has no backend host/port override, no fake-model switch, no second
credential variable, and no switch that disables certificate verification
(trust is the CA file only, FR-068).

The Python gateway of the candidate (`lib/decide_gateway.py`) and the five shell/Python
smoke helpers that used it (options derivation, prompt building, logprob query, response
shaping and the options-part re-serialiser) are **retired** (historical: they were an
uncommitted candidate, archived with a git-history note under
`specs/009-jev-decision-models/evidence/python-gateway-retired/`). The post-download decision smoke of
`lib/download.sh` now runs `llmctl-decide smoke` (the production Go driver) through `decide_bin`.

## Prerequisites

* Sources `lib/common.sh` and `lib/catalog.sh` from its own directory
  (`_decide_dir`). `lib/decide.sh` is sourced by `bin/llmctl` at startup.
* The `llmctl-decide` binary. It is looked up in this order: `LLMCTL_DECIDE_BIN`
  (must be usable, never silently replaced), else
  `${LLMCTL_DECIDE_BUILD_OUT:-$LLMCTL_ROOT/build/llmctl-decide}`. When that file
  is absent and `go` is installed, `llmctl build decide` is run once
  automatically; when Go is missing the error names exactly what to run
  (`llmctl build decide`, or copy a prebuilt binary / set `LLMCTL_DECIDE_BIN`).
  The failure exit code is 1 (never 3, which means "refused by admission").
* `python3` — only for the `capacity`/`status` JSON renderers, the wizard's
  criteria builder.
* Bash >= 3.2 (the wizard deliberately avoids `read -i`, `read -p` and `mapfile`).

## Environment variables

Read by this file:

| Variable | Default | Effect |
|---|---|---|
| `LLMCTL_DECIDE_BIN` | unset | path of the `llmctl-decide` binary; if set it must be an executable file |
| `LLMCTL_DECIDE_BUILD_OUT` | `$LLMCTL_ROOT/build/llmctl-decide` | where `llmctl build decide` writes, and where the default lookup reads |
| `LLMCTL_DECIDE_NO_INTERACTIVE` | `0` | `1` makes the wizard always exit 2 (CI safety) |
| `LLMCTL_DECIDE_PROFILE` | unset | the wizard's profile when `--profile` is not given (the client sends no profile otherwise; the gateway then uses its default) |
| `LLMCTL_DRY_RUN` | `0` | `decide serve` prints the delegation line and starts nothing |

Read by the Go binary (documented in `docs/decision-models.md` and
`contracts/env-vars.md`): `LLMCTL_API_KEY`, `LLMCTL_ENV_FILE`, `LLMCTL_HOME`,
`LLMCTL_CACERT`, `LLMCTL_ENDPOINT`, `LLMCTL_DECIDE_PORT`, `LLMCTL_DECIDE_TIMEOUT` (the client waits this many
seconds plus a 5 s grace per attempt; default 30 s; `--timeout SEC` overrides),
`LLMCTL_DECIDE_MAX_OPTIONS`, `LLMCTL_DECIDE_MAX_STATE_CHARS`,
`LLMCTL_DECIDE_MAX_QUESTIONS`, `LLMCTL_DECIDE_TRUNCATE` (a malformed numeric value
is exit 2 with the variable's name, never a traceback).

## Exit codes

`decide ask|batch|models` return the client's code unchanged: `0` ok, `1`
backend/readout failure (including a timeout), `2` usage error, `4` access-key
problem (absent, blank, malformed, or rejected by the gateway), `5`
certificate/TLS problem (unknown authority, name mismatch, expired, unreadable
CA file), `6` gateway not ready or unreachable, `10` answer withheld because
confidence is below `--min-confidence` (the JSON is still printed, with
`"abstained": true`). `capacity`/`status`/wizard errors use 2 (usage) or 1.

## Usage examples

```sh
# via the CLI (see docs/user-manual.md for the full chapter):
bin/llmctl decide ask --type noul --state "Arithmetic facts." \
    --instructions "Is 2+2=4?"
bin/llmctl decide ask --type choice --state-file ticket.txt --json \
    --instructions "Which team handles invoices?" \
    --criteria '{"billing":"handles invoices","legal":"contracts"}'
cat build.log | bin/llmctl decide ask --type noul --stdin --instructions "Any errors?"
bin/llmctl decide ask --type noul --state s --instructions q --dry-run   # nothing is sent
bin/llmctl decide ask --question-file q.json --state-file s.txt --explain # prompt + letter map on stderr
bin/llmctl decide batch --in requests.ndjson --out answers.ndjson
bin/llmctl decide models
bin/llmctl decide capacity          # parallel-instance capacity report
bin/llmctl decide status --json     # {profiles, gateway, registry}
bin/llmctl decide interactive       # wizard (TTY only)
bin/llmctl decide serve --status    # delegated generically to llmctl-decide serve
bin/llmctl decide key path          # key and cert are delegated too
bin/llmctl decide cert show
bin/llmctl decide smoke --url http://127.0.0.1:8093 --protocol letter-logit --expect-choice billing
                                    # one deterministic question against ONE engine (what download runs)

# function level (as used by lib/download.sh's _dl_smoke_test_decision):
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/decide.sh"
"$(decide_bin)" smoke --url http://127.0.0.1:8093 --protocol letter-logit --options 2 --json
```

## Edge cases

* **Arguments are not parsed here.** `decide_ask` forwards every flag to the Go
  client (unknown flags are exit 2 from the client). The one exception is
  `--interactive`, the wizard's sanctioned activation path: it is removed from
  the arguments and the remaining flags become the wizard's flag equivalents.
* **The state never touches a command line.** The wizard sends the state to the
  client on `--stdin`; the shell-level test scans every process command line
  during a slow request and finds neither the key nor the state.
* **`decide capacity` and `decide status` are strict.** Any argument other than
  one optional `--json` is exit 2 (a typo like `--jsno` is no longer ignored).
* **`decide status`** reports the scheduler view of every decision profile, then
  the gateway (`llmctl-decide serve --status`, verified process identity) and the
  registry (`llmctl-decide discover`). When the binary is not built these parts
  are reported as unavailable, never as an error. With `--json` the output is
  `{"profiles": [...], "gateway": {"available", "running", "detail"}, "registry": ...}`.
* **The wizard's prompts go to stderr with `printf`**, not `read -p` (bash prints a
  `read -p` prompt only when stdin is a terminal), so they are visible with piped
  stdin too, and only the final single-line JSON lands on stdout. **End of input
  at any prompt is exit 2 with a message** (`end of input while waiting for: ...`);
  the calling shell is never terminated silently. The multi-line state and
  criteria loops treat end of input as their terminator. The confirmation prompt
  counts as a prompt: a scripted run must supply its line.
* **Non-TTY stdin without `--interactive`** is exit 2 (`interactive mode requires a
  TTY`); `LLMCTL_DECIDE_NO_INTERACTIVE=1` is exit 2 even with the flag (it wins).
  Bare `llmctl decide` opens the wizard only when both stdin and stdout are
  terminals.
* **A wizard run that the client answers with exit 10** still prints the JSON and
  returns 10; any other non-zero client code is returned without output.
* **`decide serve`** is a generic pass-through to `llmctl-decide serve` (start,
  `--foreground`, `--status`, `--stop`, `--bind`, `--port`); process identity
  checks for `--stop` live in the Go code, not here. `LLMCTL_DRY_RUN=1` prints
  `DRY-RUN: <binary> serve <args>` and starts nothing.
* **Auto-build** happens only for real work (`ask`, `batch`, `serve`, ...), never
  for `status`.

## Internal behaviour

1. **Binary lookup**: `_decide_bin_path` (where it should be), `_decide_bin_quiet`
   (exists? no building, no messages — used by `status`), `decide_bin` (usable
   path, building once if allowed, otherwise an actionable error and return 1).
2. **Delegation**: `_decide_exec <subcommand> [args...]` runs the binary and
   returns its exit status unchanged; `decide_ask`, `decide_batch`,
   `decide_models`, `decide_key`, `decide_cert`, `decide_serve` and
   `decide_passthrough` are one-liners over it. `cmd_decide` dispatches; every
   other Go subcommand (the single list `_DECIDE_FORWARDED`: scale, calibrate,
   probe-order, schema, completions, registry, port, discover, smoke, mcp,
   vantage) is forwarded verbatim. `tests/test_decide_cli.sh` compares that
   list with the commands the binary registers (fake binary recording argv).
3. **Reports**: `decide_capacity` renders the planner's `decision_instances`
   subtree (single source of truth for the budgets); `decide_status` combines the
   scheduler rows with the Go binary's gateway and registry output.
4. **Wizard**: `_decide_read` (prompt to stderr, one line, returns 1 at end of
   input), `_decide_eof` (the single diagnostic), `decide_interactive` (seven
   steps; the final step invokes the client with the state on stdin).
5. **Profile helpers**: `_decide_profile_downloaded` (engine-aware on-disk check: a
   non-empty `.gguf` for llama profiles, a non-empty `model.onnx` top-level or under `onnx/`
   for onnx profiles) and `_decide_downloaded_profiles` feed the wizard's profile list.
   `decide smoke` is a generic delegation too: the smoke driver is
   `internal/gateway/smoke.go` (exit 0 valid typed answer, 1 backend failure, 2 usage, 6 unreachable).

## calibrate, probe-order, completions (OD-23)

`llmctl decide calibrate --profile P --labels F [--method temperature|platt|isotonic] [--catalog C] [--state-dir D] [--model-sha H] [--template-hash H] [--unbound] [--dry-run] [--json]`

Label file: CSV with header; required `p_pred` (probability the answer gave to its own prediction, 0..1) and either `correct` (0/1/true/false) or both `expected` and `predicted`; optional `id`, `type`, `well_formed`, `variant` (only `orig` rows count), `options`. The JSON written by `scripts/golden/run_golden.py` is accepted too. The report gives accuracy with a Wilson 95% interval, the majority/chance baseline, ECE/MCE/Brier (same definitions as `scripts/golden/stats.py`) and, after the fit, in-sample and 5-fold held-out numbers. Below 200 labels it prints "insufficient for ECE", writes nothing and exits 0; isotonic needs 1000. The profile goes to `$STATE/decide/calibration/<profile>.json` (0600, atomic), bound to the model sha256 (catalog) and template hash (`--template-hash` or catalog `decision.template_hash`); an unresolvable binding exits 2 unless `--unbound` (then `<profile>.unbound.json`). Exit codes: 0 report, 1 write failure, 2 usage/invalid labels/unresolved binding.

`llmctl decide probe-order --questions F [--profile P] [--permute K] [--state-file F] [--json]` asks every choice question in K cyclic option orders (0 = full cycle, one call per option of the largest question) and prints the answer-flip rate and per-position share; exit codes as `ask`; "nothing to probe" is 2.

`llmctl decide completions {bash|zsh}` prints a completion script generated from the registered commands and flags; any other shell is exit 2. `eval "$(llmctl decide completions bash)"` or `source <(llmctl decide completions zsh)`.

Details and limits: `specs/009-jev-decision-models/contracts/cli.md`.

## scale (OD-23)

`llmctl decide scale <profile> <N>` - start or stop instances of **one decision profile** until exactly `N` run. It is implemented in the shell scheduler (`sched_decision_scale` in `lib/scheduler.sh`; `decide_scale` in `lib/decide.sh` is a one-line call), not in the Go binary; `_DECIDE_FORWARDED` lists it only so the command table matches.

* Instance keys: `<profile>`, `<profile>.2`, `<profile>.3`, ... Each has its own service env file, reservation record, registry row, port hold and internal key file. The primary keeps its documented port; every further instance gets a registry-allocated port (`portreg_allocate_dynamic`, base port + 1000 x (ordinal - 1) as the starting hint).
* Scale **up** is admission-bounded by the same predicate `llmctl start` uses and is all-or-nothing: if instance K does not fit, nothing is started and the command exits **3** with the numbers (`cannot scale 'P' to N: instance K (P.K) needs A MiB RAM + B MiB VRAM, but only C MiB RAM + D MiB VRAM remain (M more instance(s) would fit; R running; nothing was started)`).
  A runtime failure (no usable port, unit refused to start, engine never answered its health path within `LLMCTL_READY_TIMEOUT`, default 60 s) rolls back every instance started in this call (exit 1). `SCHED_SCALE_BESTEFFORT=1`, set by the restore after a failed `llmctl switch`, keeps what did start and exits 1 with the list of what could not.
* Scale **down** stops the highest-numbered instances first and withdraws their registry rows. `N` equal to the current count prints `already N instance(s) running; nothing to do` (exit 0). `N = 0` stops them all.
* More than one instance needs the registry allocator (`llmctl build decide`); without it a real run is refused before anything is reserved (exit 1, message names the build command).
* `LLMCTL_DECIDE_MODE=deterministic` (default) serves a profile from its primary and overflows to the next instance only when the primary is saturated (byte-identity per instance); `throughput` spreads least-loaded and marks every response `x-llmctl-decide-mode: throughput`. Any other value is refused (exit 1).
* Exit codes: 0 done / nothing to do, 1 unknown or non-decision profile, runtime failure, 2 usage (missing profile or `N`, `N` not a non-negative integer), 3 refused by admission.

Argument errors, run against the real `bin/llmctl` with scratch state directories:

```
$ llmctl decide scale                      ERROR: usage: llmctl decide scale <profile> <N>                                  (rc 2)
$ llmctl decide scale decide-nli x         ERROR: decide scale: N must be a non-negative integer, got 'x'                    (rc 2)
$ llmctl decide scale nosuch 2             ERROR: unknown profile: nosuch (see: llmctl models list)                         (rc 1)
$ llmctl decide scale fast 2               ERROR: 'fast' is not a decision profile (decide scale only scales decision profiles)  (rc 1)
```

Dry run (`LLMCTL_DRY_RUN=1`, scratch `XDG_*` directories, nothing started):

```
$ LLMCTL_DRY_RUN=1 llmctl decide scale decide-nli 2
[llmctl] wrote <state>/services/decide-nli.env
[dry-run] systemctl --user start llmctl-onnx@decide-nli.service
started decide-nli (mode=cpu, port=8096, reserved 3006 MiB RAM + 0 MiB VRAM)
[llmctl] wrote <state>/services/decide-nli.2.env
[dry-run] systemctl --user start llmctl-onnx@decide-nli.2.service
started decide-nli.2 (mode=cpu, port=9096, reserved 3006 MiB RAM + 0 MiB VRAM)
decide-nli: scaled up to 2 instance(s) (2 started)
decide mode: deterministic - requests are served by the primary instance and overflow to the next instance only when it is saturated (byte-identity per instance)
```

Tests: `tests/test_decide_scale.sh` (fixture backend: admission refusals, rollback on start failure, port-hold release, best-effort restore, registry-allocator requirement; last run: `RESULT: PASS`). **UNCONFIRMED:** a real (non dry-run) start of a second engine instance was not run in this pass (task T135 records "real-engine start unverified").

## Persistent gateway: `serve --enable` and the CPU-adaptive timeout

* `llmctl decide serve --enable [--now]` installs and enables the gateway as a boot-time user service (systemd user unit on Linux, launchd agent on macOS) and `--disable` stops, disables and removes it. It is idempotent, refuses while an installed engine unit is stale (`llmctl install`), and under `LLMCTL_DRY_RUN=1` writes no unit. A re-enable over a changed unit does `systemctl --user try-restart`. Tests: `tests/test_decide_serve_enable.sh` (stubbed `systemctl`; macOS is dry-run only). Operator guide: `docs/persistent-services.md`.
* `decide_serve` sources `lib/decide_timeout.sh` and, when `LLMCTL_DECIDE_TIMEOUT` is not set and a CPU-placed llama decision instance is running or enabled, exports `LLMCTL_DECIDE_TIMEOUT=120` (source `cpu-adaptive`); an explicit value always wins, and the gateway banner prints the effective value and its source. Details: `docs/scripts/decide_timeout.md`; test: `tests/test_decide_timeout_adapt.sh`.
## Related scripts

* Sources `lib/common.sh` and `lib/catalog.sh`; `capacity`/`status` use
  `catalog_plan_json`, `catalog_profiles`, `catalog_capability`, `catalog_port` and
  `sched_is_running`/`sched_is_enabled` from `lib/scheduler.sh`.
* Called by `bin/llmctl`'s `decide` command branch (`cmd_decide`), and `lib/download.sh`'s
  `_dl_smoke_test_decision` calls `decide_bin` to run `llmctl-decide smoke`.
* The binary is built by `lib/engine.sh` (`engine_build_decide`, `llmctl build decide`).
* Exercised by `tests/test_decide.sh` (the smoke path through the real binary against a Go fake engine, delegation with a recording
  stand-in binary, the wizard, capacity/status) and `tests/test_decide_cli.sh` (the
  real Go client against a real TLS gateway, exit codes, 5 MB state, no secret on
  any command line). The Go logic has its own tests: `internal/client`,
  `cmd/llmctl-decide/cmd_ask_test.go`.

## Last verified date

2026-10-07
