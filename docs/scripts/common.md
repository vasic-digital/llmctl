## Overview

`lib/common.sh` is the foundational library every other `lib/*.sh` file and
`bin/llmctl` sources first. It establishes `LLMCTL_ROOT`, the full set of
XDG-aware state/config/data/runtime directories, the color/logging helpers
(`log`/`info`/`warn`/`err`/`die`/`bold`), small guard helpers
(`need_cmd`/`have_cmd`/`ensure_dir`/`ensure_state_dirs`), two thin
`python3`-backed JSON query wrappers (`json_query`/`json_stdin`), and two
integer-arithmetic helpers (`mib`/`ceil_div`). It exists so every other
library gets one consistent source of truth for "where does llmctl keep its
files" and "how do I print/fail" instead of each file reinventing its own
logging and path conventions.

## Prerequisites

* Must be sourced, not executed directly — it defines functions and exported
  variables and has no dispatch logic of its own.
* `python3` on `PATH` for `json_query`/`json_stdin` — guarded by
  `need_cmd python3 "install python3 via your package manager"`, which
  `die`s with an install hint if missing.
* Reads (with sane defaults) `HOME`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
  `XDG_STATE_HOME`, and (best-effort) `XDG_RUNTIME_DIR`.
* Honors pre-set overrides for every derived directory
  (`LLMCTL_CONFIG_DIR`, `LLMCTL_DATA_DIR`, `LLMCTL_STATE_DIR`,
  `LLMCTL_RUNTIME_DIR`, `LLMCTL_MODELS_DIR`, `LLMCTL_LOG_DIR`,
  `LLMCTL_VERIFY_DIR`, `LLMCTL_SERVICES_DIR`) and the catalog path
  (`LLMCTL_CATALOG`), each via `"${VAR:-default}"` — this is how tests
  redirect all of llmctl's state into a throwaway sandbox directory.
* Honors `LLMCTL_DRY_RUN` (default `0`) and `NO_COLOR` as opt-in environment
  switches; color output is further gated on `[[ -t 1 ]]` (stdout is a tty).
* Honors `LLMCTL_BIND_HOST` (default `0.0.0.0` — LAN-accessible, per
  explicit operator mandate) as the global default engine bind address;
  consumed by `lib/catalog.sh`'s `catalog_bind_host()`, which
  `lib/scheduler.sh`'s `sched_build_launch` resolves its `--host` flag
  through for both engine paths. **Security trade-off, disclosed here and
  in README.md "Safety guarantees":** llama-server's/colibri's
  OpenAI-compatible APIs have no built-in authentication, so a `0.0.0.0`
  bind is reachable — with zero auth — by any device that can reach the
  host's LAN interface. Set `LLMCTL_BIND_HOST=127.0.0.1` to revert every
  profile to localhost-only, or `LLMCTL_BIND_HOST_<PROFILE>` (see
  `catalog.sh`) to revert just one.

## Usage examples

```sh
# sourced from bin/llmctl or a test harness, never run standalone:
source "${LLMCTL_ROOT}/lib/common.sh"

log  "starting something"          # blue "[llmctl] " prefix
info "all good"                    # green text
warn "heads up"                    # yellow "WARN:" prefix, to stderr
err  "something broke"             # red "ERROR:" prefix, to stderr
die  "fatal, exiting now"          # err + exit 1

need_cmd curl "brew install curl"  # dies with an install hint if absent
have_cmd nvidia-smi && echo "has nvidia-smi"

ensure_dir "/tmp/some/nested/dir"
ensure_state_dirs                  # mkdir -p every LLMCTL_*_DIR at once

# JSON helpers (python3-backed; expression sees the parsed doc as `d`)
json_query models/catalog.json 'sorted(d["profiles"].keys())'
echo '{"a": 1}' | json_stdin 'd["a"]'

mib 1073741824       # -> 1024
ceil_div 100 8        # -> 13

# redirect all state into a sandbox (typical test pattern)
export LLMCTL_STATE_DIR=/tmp/llmctl-test/state
export LLMCTL_DATA_DIR=/tmp/llmctl-test/data
```

## Edge cases

* **`LLMCTL_ROOT` is only computed if not already set** (`if [[ -z
  "${LLMCTL_ROOT:-}" ]]`): when sourced from `bin/llmctl`, `LLMCTL_ROOT` is
  already exported by the caller and this block is skipped entirely; when
  `common.sh` is sourced directly (e.g. by a test helper), it derives its own
  root by walking one directory up from its own `${BASH_SOURCE[0]}` location.
* **`LLMCTL_RUNTIME_DIR` falls back when `XDG_RUNTIME_DIR` is unusable**:
  it only uses `XDG_RUNTIME_DIR` when the variable is both non-empty AND the
  directory actually exists (`-d`); otherwise it falls back to
  `${LLMCTL_STATE_DIR}/run` — the documented reason is macOS and containers,
  which commonly lack a usable `XDG_RUNTIME_DIR`.
* **Colors are disabled in two independent conditions**: not a tty
  (`! -t 1`, e.g. piped output or a log file) OR `NO_COLOR` is set to any
  non-empty value — either condition alone is enough to blank every
  `LLMCTL_C_*` variable to the empty string, so `printf`-based colorized
  helpers degrade to plain text with zero escape codes.
* **`json_query`/`json_stdin` propagate real failures, not silent nulls**:
  a JSON parse error exits `2` with a message on stderr naming the file; an
  expression that raises an exception (bad key, wrong type) exits `3`; the
  parsed-but-falsy-boolean case (`False`) returns exit code `1` with no
  stdout, so callers can use these as real predicates in `if json_query ...;
  then` without needing to grep output.
* **`json_query`/`json_stdin` result-type dispatch**: a Python `bool` prints
  `"True"`/`"False"` and sets the exit code to match; `None` prints nothing
  and exits `0`; a `list`/`tuple` prints one item per line; anything else is
  printed via a single `print(result)` call — callers rely on this exact
  shape (e.g. `catalog_profiles()` in `lib/catalog.sh` expects one profile
  name per line from a `list` result).
* **`need_cmd`'s hint is optional** (`"${2:+ Install hint: $2}"` uses bash
  parameter expansion, not a plain concatenation) — calling `need_cmd curl`
  with no second argument omits the "Install hint:" clause entirely rather
  than printing an empty hint.
* **`ensure_dir` is a one-line `mkdir -p` wrapper** — it is idempotent by
  construction (no error if the directory already exists) and creates every
  missing parent.

## Internal behaviour

1. **Root resolution**: conditionally compute and `export LLMCTL_ROOT` (see
   Edge cases above).
2. **XDG directory derivation**: set `XDG_CONFIG_HOME`/`XDG_DATA_HOME`/
   `XDG_STATE_HOME` defaults via `:=` parameter expansion (only assigns if
   unset), then derive and export every `LLMCTL_*_DIR` and `LLMCTL_CATALOG`
   from those (or from a pre-set override).
3. **Dry-run flag**: default `LLMCTL_DRY_RUN` to `0` if unset (read by
   `lib/download.sh`, `lib/engine.sh`, and `lib/scheduler.sh` to skip real
   side effects).
3b. **Bind-host default**: default `LLMCTL_BIND_HOST` to `0.0.0.0` if unset
    (read by `lib/catalog.sh`'s `catalog_bind_host()`, never directly by
    `lib/scheduler.sh` — see catalog.md's per-profile override mechanism).
4. **Color setup**: a single `if [[ -t 1 && -z "${NO_COLOR:-}" ]]` branch
   sets five ANSI escape-code variables plus a reset code, or blanks all of
   them in the `else` branch.
5. **Logging functions**: five one-line `printf`-based functions
   (`log`/`info`/`warn`/`err`) plus `die` (calls `err` then `exit 1`) and
   `bold` (wraps text in the bold escape code) — every function is a thin
   `printf` wrapper, no state, no side effects beyond stdout/stderr writes
   and (for `die`) process exit.
6. **Guard helpers**: `need_cmd` (die on missing command, optional hint),
   `have_cmd` (silent boolean check via `command -v`), `ensure_dir`
   (`mkdir -p`), `ensure_state_dirs` (calls `ensure_dir` for every
   `LLMCTL_*_DIR` except `LLMCTL_CONFIG_DIR` and `LLMCTL_DATA_DIR` — it
   creates state, runtime, log, verify, and services dirs, plus the models
   dir).
7. **JSON helpers**: `json_query` (file-path + Python expression, invoked via
   `python3 - "$file" "$@" <<'PYEOF' ... PYEOF` so the script body is a fixed
   heredoc and the file path/expression are passed as `sys.argv`) and
   `json_stdin` (Python expression only, reads the JSON document from stdin,
   invoked via `python3 -c '<script>' "$1"` since there is no file argument
   to also feed via a heredoc's stdin).
8. **Arithmetic helpers**: `mib` (bytes -> whole MiB via integer division)
   and `ceil_div` (ceiling integer division via the `(a + b - 1) / b` idiom)
   — both single-line `echo $(( ... ))` functions.

## Related scripts

* Sourced directly by `bin/llmctl` and by every other `lib/*.sh` file in this
  project (`os_detect.sh`, `hardware.sh`, `catalog.sh`, `download.sh`,
  `engine.sh`, `scheduler.sh`, `doctor.sh`, `cluster.sh`,
  `service_linux.sh`, `service_macos.sh`) — it is the one library with no
  dependency on anything else in `lib/`.
* `tests/helpers.sh` sources it (directly or transitively) to give every
  `tests/test_*.sh` file the same `log`/`die`/`assert_*` vocabulary and
  sandboxed `LLMCTL_*_DIR` environment.
* `tests/test_syntax.sh` parses it with `bash -n` as a basic parseability
  gate; no dedicated `test_common.sh` exists — its behavior is exercised
  indirectly through every other test file that relies on its logging/JSON
  helpers.

## Last verified date

2026-09-22
