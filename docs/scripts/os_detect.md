## Overview

`lib/os_detect.sh` is a small, dependency-light library that answers "what OS
/ CPU architecture / package manager / core count am I running on" for the
rest of llmctl. It exists so every other library (`hardware.sh`,
`engine.sh`, `bin/llmctl`'s `install`/`enable`/`restart`/`logs` dispatch via
`sched_load_backend`) has one normalized, portable source of truth for
OS/arch classification instead of re-parsing `uname` output in multiple
places — llmctl is explicitly a two-OS project (Linux with systemd --user,
macOS with launchd) and this file is where that distinction is made once.

## Prerequisites

* `uname` (`-s` and `-m`) — always available on both target OSes; this is
  the only command `llmctl_os`/`llmctl_arch` depend on directly.
* `have_cmd` (defined in `lib/common.sh`) — used by `llmctl_nproc` and
  `llmctl_pkg_hint`, so `common.sh` must be sourced first (and is, via the
  `# shellcheck source=` hint at the top of this file — though this file
  does not actually `source` it itself; callers are expected to have already
  sourced `common.sh`, as `bin/llmctl` and every other `lib/*.sh` file does).
* On macOS: `sysctl` (for `llmctl_nproc`'s `hw.ncpu` fallback) and (for
  `is_apple_silicon`) nothing beyond `uname -m` returning `arm64`.
* On Linux: `nproc` or `getconf` (for `llmctl_nproc`); neither is a hard
  `need_cmd` dependency — see Edge cases for the final fallback.

## Usage examples

```sh
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"

llmctl_os              # -> linux | macos | unknown (with return 1)
llmctl_arch            # -> x86_64 | arm64 | <raw uname -m output>
llmctl_nproc           # -> a whole-number core count, always
llmctl_pkg_hint        # -> a package-manager-specific install hint string
is_apple_silicon && echo "running on Apple Silicon"

# a typical caller pattern (from lib/engine.sh):
if [[ "$(llmctl_os)" == "macos" ]]; then
  echo "metal"
fi
```

## Edge cases

* **`llmctl_os` on an unrecognized kernel**: the `case` statement's `*)`
  branch echoes `"unknown"` AND `return 1` — callers that only capture
  stdout (`os="$(llmctl_os)"`) get `"unknown"` but must separately check the
  exit code if they want to detect this case as an error rather than a
  valid-but-unsupported OS string; `hw_probe_json` (in `lib/hardware.sh`)
  does exactly this: `os="$(llmctl_os)" || die "unsupported operating
  system: $(uname -s)"`.
* **`llmctl_arch` on an unrecognized machine type**: falls through to a bare
  `uname -m` in the `*)` branch — it does not die or return an error; the
  caller gets whatever the raw kernel-reported architecture string is
  (e.g. `riscv64`, `armv7l`) rather than a normalized token.
* **`llmctl_nproc` has a three-tier fallback**: macOS first tries
  `sysctl -n hw.ncpu` and returns immediately on success
  (`&& return 0`); if that fails (or on Linux), it prefers `nproc` when
  present, then `getconf _NPROCESSORS_ONLN`, and as an absolute last resort
  (neither command found) echoes the literal string `1` rather than failing
  — this function is designed to never die, since a wrong-but-safe core
  count (1) is preferable to blocking every downstream build/probe.
* **`llmctl_pkg_hint` has no fallback branch for macOS-without-brew**: it
  explicitly detects that case and returns an install-Homebrew-first hint
  string rather than a bare "install <pkg>" — this is the one branch that
  differs in shape from the Linux branches (which all print a single
  package-manager command).
* **`llmctl_pkg_hint`'s Linux branch order matters**: it checks
  `apt-get` -> `dnf` -> `pacman` -> `zypper` -> `apk` in that fixed order
  and returns on the first match; a host with multiple package managers
  installed (rare, but possible in some container base images) gets
  whichever one is listed first, not necessarily the "primary" one.
* **`is_apple_silicon` is a compound boolean, not a probe**: it purely
  composes the results of `llmctl_os` and `llmctl_arch` (`== "macos" && ==
  "arm64"`) — it does not itself call any Apple-specific command, so it is
  safe to call on any OS without side effects or errors.

## Internal behaviour

1. **`llmctl_os()`**: `case "$(uname -s)"` mapping `Linux` -> `linux`,
   `Darwin` -> `macos`, anything else -> `unknown` (with a non-zero return).
2. **`llmctl_arch()`**: `case "$(uname -m)"` mapping `x86_64`/`amd64` ->
   `x86_64`, `arm64`/`aarch64` -> `arm64`, anything else -> the raw
   `uname -m` value verbatim.
3. **`llmctl_nproc()`**: branches on `llmctl_os` for the macOS-first
   `sysctl -n hw.ncpu` short-circuit, then falls through a Linux-oriented
   `nproc` -> `getconf` -> literal `1` chain that also serves as the
   final fallback for any OS where the macOS branch did not already return.
4. **`llmctl_pkg_hint()`**: `case "$(llmctl_os)"` with a `macos` branch
   (brew-or-install-brew-first) and a `linux` branch (five-way `have_cmd`
   chain over `apt-get`/`dnf`/`pacman`/`zypper`/`apk`, with a generic
   fallback string if none match).
5. **`is_apple_silicon()`**: a single boolean expression combining
   `llmctl_os` and `llmctl_arch`, used as a condition (`[[ ... ]]`) rather
   than printing anything — callers use it as `if is_apple_silicon; then`.

## Related scripts

* Depends on `lib/common.sh` for `have_cmd` (must be sourced first by the
  caller; `os_detect.sh` does not source it itself despite the
  `# shellcheck source=common.sh` hint at the top of the file being for
  linting purposes, not a runtime `source` statement — the actual `source`
  calls in this repo always load `common.sh` before `os_detect.sh`, e.g. in
  `bin/llmctl` and in `lib/hardware.sh`/`lib/engine.sh`).
* Sourced by `bin/llmctl`, `lib/hardware.sh`, and `lib/engine.sh` (all three
  need OS/arch/core-count detection); also relied on transitively by
  `lib/scheduler.sh`'s `sched_load_backend`, which calls `llmctl_os` to
  decide whether to source `lib/service_linux.sh` or `lib/service_macos.sh`.
* Exercised by `tests/test_hardware_probe.sh` and `tests/test_engine.sh`
  indirectly (both depend on OS/arch detection to select their expected
  fixtures/backends); `tests/test_syntax.sh` parses it with `bash -n`.

## Last verified date

2026-09-17
