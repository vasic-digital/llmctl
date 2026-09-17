## Overview

`lib/doctor.sh` is llmctl's environment self-diagnosis. It defines a single
public entry point, `doctor_run`, that walks the host checking every
precondition the rest of llmctl relies on — required commands, a checksum
tool for verified downloads, submodule initialization, catalog validity,
writable state directories, GPU tooling, the OS service backend, whether the
engines have already been built, and (informationally) the opt-in `llmctld`
cluster daemon's client-side prerequisites (curl HTTP/3 support, a Go
toolchain). Every check prints a `PASS`/`WARN`/`FAIL` line with the concrete
evidence behind it (the resolved binary path, the exact HEAD short-SHA of an
initialized submodule, curl's real `Features:` line, etc.) rather than a bare
verdict, and the function's own exit status is non-zero exactly when at
least one `FAIL` occurred. It exists so `bin/llmctl setup` (and an operator
running `llmctl doctor` directly) gets one deterministic, evidence-backed
answer to "is this host ready to run llmctl" before any build or download is
attempted — the anti-bluff discipline this project's `CLAUDE.md` mandates
applied to the very first step of the workflow.

## Prerequisites

* Must be sourced, not executed standalone — it resolves its own directory
  from `${BASH_SOURCE[0]}` and sources `common.sh` and `os_detect.sh` from
  that same directory before defining anything, so it depends on being
  co-located with them under `lib/`.
* Functions/variables it consumes from `common.sh`: `have_cmd`, `bold`,
  `ensure_state_dirs`, `json_query`, and the color variables
  `LLMCTL_C_GREEN`/`LLMCTL_C_YELLOW`/`LLMCTL_C_RED`/`LLMCTL_C_RESET`; and the
  exported paths `LLMCTL_ROOT`, `LLMCTL_CATALOG`, `LLMCTL_STATE_DIR`.
* Functions it consumes from `os_detect.sh`: `llmctl_os`, `llmctl_arch`,
  `llmctl_pkg_hint`.
* Required host commands it checks for directly: `bash`, `curl`, `git`,
  `python3` (all `required` — a missing one is a `FAIL`); `cmake` and `make`
  are checked as `optional` (needed only to build llama.cpp / colibri
  respectively); a C compiler (`gcc`, `clang`, or `cc` — any one satisfies
  the check) is looked for informationally for the colibri build.
* A sha256 tool: `sha256sum`, `shasum`, or `openssl` — required (`FAIL` if
  none is present, since verified downloads depend on one).
* Reads `${LLMCTL_CATALOG}` (default `models/catalog.json`, from
  `common.sh`) via `json_query` to confirm it parses as JSON and has a
  `profiles` array.
* Calls `ensure_state_dirs` (from `common.sh`) to confirm `${LLMCTL_STATE_DIR}`
  is writable — this is a real side effect: it creates the state, runtime,
  log, verify, services, and models directories if they don't already exist.
* Checks `submodules/llama.cpp/.git` and `submodules/colibri/.git` under
  `${LLMCTL_ROOT}` to determine whether those submodules were initialized
  (`git submodule update --init`), and shells out to `git -C <submodule> rev-parse
  --short HEAD` for evidence when they are.
* GPU tooling checks: `nvidia-smi` (and, if present, shells out to it for a
  GPU name list), `rocm-smi`, or (on macOS/arm64) treats Apple Silicon's
  unified memory as a built-in GPU — all purely informational, never a
  `FAIL`.
* Service backend check depends on `llmctl_os`'s result: on `linux` it
  requires `systemctl` and a working `systemctl --user list-units`; on
  `macos` it requires `launchctl`.
* Checks `${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server` for
  executability to report whether the llama.cpp engine has already been
  built.
* Cluster-daemon prerequisites (`curl --version`'s `Features:` line for
  HTTP/3, and `go version` for the ability to build `llmctld` from source)
  are checked but are always `PASS`/`WARN`, never `FAIL` — cluster mode is
  opt-in and single-host llmctl never depends on either.
* No network access is required by `doctor_run` itself (it never fetches
  anything); it only inspects local commands, files, and the local git
  submodule state.

## Usage examples

`lib/doctor.sh` is sourced by `bin/llmctl`, which exposes `doctor_run` as the
`doctor` subcommand and also runs it as the first step of `setup`:

```bash
# Run the self-diagnosis directly.
llmctl doctor

# `setup` runs doctor first and aborts before building/planning on any FAIL.
llmctl setup
```

Directly sourcing the file (as the test suite's `llmctl setup` invocation
does transitively) to call `doctor_run` in isolation:

```bash
source lib/common.sh
source lib/os_detect.sh
source lib/doctor.sh
doctor_run
echo "exit: $?"     # 0 only if DOCTOR_FAILS stayed 0
```

Deterministic hardware/OS output for tests uses the same fixture mechanism
`hw_probe_json`/`catalog_plan_json` use elsewhere in the project (`doctor_run`
itself calls `llmctl_os`/`llmctl_arch` directly rather than the hardware
fixture, so its OS/arch line always reflects the real host it runs on — see
Edge cases):

```bash
LLMCTL_DRY_RUN=1 llmctl setup   # doctor_run runs for real; build/plan are dry-run
```

## Edge cases

* **Unsupported OS never aborts the whole run** — `llmctl_os` returning
  non-zero (an OS other than `Linux`/`Darwin`) is caught by
  `doctor_run`'s own `|| { ...; os="unknown"; }` handler, which records a
  `FAIL` naming `$(uname -s)` and sets `os="unknown"` so every later
  `case "${os}"` branch (GPU tooling, service backend) simply falls through
  its `*`/default arm instead of crashing the script under `set -euo
  pipefail`.
* **Missing required vs. optional command produces a different severity and a
  different hint** — `_doc_check_cmd`'s `required` branch calls `_doc_fail`
  and, if no explicit hint string was passed, falls back to
  `llmctl_pkg_hint`'s OS-appropriate install command with `<pkg>` substituted
  for the real command name; the `optional` branch calls `_doc_warn` with
  whatever hint string was passed (or none).
* **No sha256 tool at all is a hard `FAIL`**, not a warning — the comment and
  code both treat this as blocking because "downloads cannot be verified"
  without one, unlike the C-compiler or GPU-tooling checks which only warn.
* **Uninitialized submodule is a `WARN`, not a `FAIL`** — a project running
  `llmctl doctor` before ever running `llmctl build` is expected and
  non-fatal; the warning names the exact remediation (`run: llmctl build`).
  The check tests for `submodules/<name>/.git` specifically (a file or a
  directory both satisfy `[[ -e ... ]]`), matching how `git submodule
  update --init` leaves either a `.git` file (submodule) or directory
  (older git) — see `docs/llmctl_plan.md`'s note on the corrected
  `submodules/` path (this was previously, incorrectly, `vendor/`).
* **Invalid or missing catalog is a hard `FAIL`** — `json_query
  "${LLMCTL_CATALOG}" 'len(d["profiles"])'` failing (bad JSON, missing file,
  or a JSON document with no `profiles` key) is caught by the `if ... >/dev/null
  2>&1` guard and reported as `FAIL "catalog invalid or missing: ${LLMCTL_CATALOG}"`
  rather than letting the script exit under `set -e` from the unguarded
  second call inside the `_doc_pass` branch.
* **Unwritable state dir is a hard `FAIL`** — the check requires BOTH
  `ensure_state_dirs` to succeed (directory creation) AND `[[ -w
  "${LLMCTL_STATE_DIR}" ]]` to hold; either failing alone is enough to report
  `FAIL`, so a state dir that exists but lost its write permission after
  creation is still caught.
* **No GPU tooling is informational only** — the fallback branch
  (`_doc_warn "no GPU tooling detected - CPU-only inference"`) never blocks
  `doctor_run` from succeeding; llmctl is explicitly designed to run CPU-only.
* **`macos` with `launchctl` missing is treated as a genuine anomaly** —
  unlike every other optional/informational check, a macOS host with no
  `launchctl` reports `_doc_fail "launchctl missing on macOS?"` (the
  trailing `?` in the message itself signals this is an unexpected,
  should-never-happen condition on real macOS, not a normal missing-tool
  case).
* **`llama-server` not yet built is a `WARN`, not a `FAIL`** — checked via
  `[[ -x ... ]]` on the exact path `sched_build_launch` (in
  `lib/scheduler.sh`) later resolves for the `llama` engine by default; a
  fresh clone that hasn't run `llmctl build llama` yet is expected, so this
  never blocks `doctor_run`'s own success even though `llmctl start` on a
  llama-engine profile would fail later.
* **curl lacking HTTP/3 support is a `WARN` that explains the real fallback**
  — `curl --version | grep -qiE '(^| )HTTP3( |$)'` failing does not treat
  HTTP/3 as required; the warning explicitly states that `llmctld` itself
  always serves both HTTP/2 and HTTP/3, so cluster commands keep working
  over HTTP/2 — this same detection expression is duplicated (independently)
  in `lib/cluster.sh`'s `_cluster_http3_supported`, so a change to one must be
  checked against the other (see Related scripts).
* **No Go toolchain is a `WARN`, explicitly scoped to the opt-in daemon** —
  the warning states single-host llmctl is unaffected; `go` is only needed to
  run `make llmctld-build` (see the `Makefile`'s own guard for the same
  absence, which prints a similar message and skips the target rather than
  failing `make`).
* **The final summary line is always printed, and the function's boolean
  result is the truth source, not the printed text** — `doctor_run` ends
  with `echo "doctor: ${DOCTOR_FAILS} failure(s), ${DOCTOR_WARNS}
  warning(s)"` followed by the bare test `[[ "${DOCTOR_FAILS}" -eq 0 ]]`,
  which is what actually determines the function's (and, transitively,
  `bin/llmctl doctor`'s and `llmctl setup`'s) exit code — a caller must not
  infer success from the summary text alone.

## Internal behaviour

1. **Setup** (top of file): resolves `_doc_dir` from `${BASH_SOURCE[0]}`,
   sources `common.sh` and `os_detect.sh` from it, and initializes the two
   module-level counters `DOCTOR_FAILS=0` and `DOCTOR_WARNS=0`.
2. **Severity helpers** — `_doc_pass` (prints green `PASS <msg>`, no counter
   change), `_doc_warn` (increments `DOCTOR_WARNS`, prints yellow `WARN
   <msg>`), `_doc_fail` (increments `DOCTOR_FAILS`, prints red `FAIL
   <msg>`). Every check function below calls exactly one of these per
   condition it evaluates.
3. **`_doc_check_cmd <cmd> <required|optional> [hint]`** — the shared
   command-existence check every simple tool check in step 4 is built on: on
   `have_cmd` success it reports `PASS` with the resolved path
   (`command -v`); on failure it dispatches to `_doc_fail` (required,
   defaulting the hint to `llmctl_pkg_hint`) or `_doc_warn` (optional, using
   the caller-supplied hint verbatim).
4. **`doctor_run`** — the single public entry point, run top-to-bottom in
   this order: prints the `bold` banner; probes `llmctl_os`/`llmctl_arch`
   (with the unsupported-OS fallback described in Edge cases); calls
   `_doc_check_cmd` for `bash`/`curl`/`git`/`python3` (required) and
   `cmake`/`make` (optional); checks for any C compiler; checks for a sha256
   tool; loops over `submodules/llama.cpp`/`submodules/colibri` checking
   `.git` presence; validates the catalog via `json_query`; checks state-dir
   writability via `ensure_state_dirs`; checks GPU tooling
   (`nvidia-smi`/Apple Silicon/`rocm-smi`/none); dispatches a `case
   "${os}"` for the service backend (`systemctl --user` on `linux`,
   `launchctl` on `macos`); checks whether `llama-server` is already built;
   checks curl's HTTP/3 support and Go toolchain availability for the
   opt-in cluster daemon; finally prints the summary line and returns
   `[[ "${DOCTOR_FAILS}" -eq 0 ]]` as its exit status.

## Related scripts

* `bin/llmctl` sources `lib/doctor.sh` directly (`source
  "${LLMCTL_ROOT}/lib/doctor.sh"`) and calls `doctor_run` from two places:
  the `doctor)` case arm of its command dispatcher, and as the first step of
  `cmd_setup` (`doctor_run || die "doctor reported failures; fix them and
  re-run 'llmctl setup'"`).
* Sources `lib/common.sh` (logging, color variables, `have_cmd`,
  `ensure_state_dirs`, `json_query`, exported `LLMCTL_*` path variables) and
  `lib/os_detect.sh` (`llmctl_os`, `llmctl_arch`, `llmctl_pkg_hint`).
* Its HTTP/3-detection expression (`curl --version | grep -qiE '(^| )HTTP3( |$)'`)
  is duplicated independently in `lib/cluster.sh`'s `_cluster_http3_supported`
  — the two are not shared code, so a change to the detection logic in one
  needs the same change applied to the other.
* Referenced (informationally, not by name) alongside `lib/scheduler.sh`'s
  engine-launch path: the `llama-server` executable path `doctor_run` checks
  is the same default path `sched_build_launch` resolves for the `llama`
  engine.
* Exercised end-to-end by `tests/test_setup_e2e.sh`, which runs the real
  `bin/llmctl setup` entrypoint against a simulated fresh-clone `LLMCTL_ROOT`
  and asserts on several of `doctor_run`'s own `PASS` lines (`"PASS OS:"`,
  the two submodule-initialized lines, `"catalog valid JSON"`).
* Covered generically (not doctor-specific) by `tests/test_syntax.sh`
  (`bash -n`, shebang, and `set -euo pipefail` checks over every shipped
  script including this one). There is no dedicated `tests/test_doctor.sh`
  in this repository as of this writing.
* Sibling diagnostic/support scripts in `lib/`: `lib/hardware.sh` (the real
  hardware probe `doctor_run` does not itself call, but which backs
  `llmctl hw`/`llmctl plan`), `lib/catalog.sh` (owns catalog parsing that
  `json_query` here re-validates a narrower slice of), and `lib/os_detect.sh`
  (the OS/arch/package-manager detection this file depends on directly).

## Last verified date

2026-09-17
