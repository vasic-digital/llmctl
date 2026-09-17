## Overview

`docs/integrations/install_pi.sh` installs and verifies **pi**
(`@earendil-works/pi-coding-agent` on npm, binary `pi`; homepage
https://pi.dev, source https://github.com/earendil-works/pi) for use
against a running llmctl profile. It implements FR-011 of
`specs/001-llmctl-completion/spec.md` (T023): pi must be installable via
its documented curl setup mechanism and testable against a running llmctl
server. This script performs the *automated* half of that requirement
(install-if-absent, then capture real verification evidence);
`docs/integrations.md` documents the manual half (the
`~/.pi/agent/models.json` + `~/.pi/agent/settings.json` wiring needed to
point pi at an llmctl profile). The script's own header notes explicitly
that "pi" here is **not** any Raspberry Pi tool or math-constant CLI of the
same name — identity is confirmed against the `~/.pi/agent/` config-file
layout, which matches `docs/integrations.md`'s "pi" section byte-for-byte
in path and shape.

## Prerequisites

* `bash` (`set -euo pipefail`).
* `curl` — required to run pi's official install script; if `pi` is not
  already on `PATH` and `curl` is also absent, the script fails immediately
  with no install attempt.
* `sh` (POSIX shell) — the installer script itself (`install.sh`) is piped
  into `sh`, not `bash`.
* `tput` is optional (only used to detect an interactive terminal for color
  output); its absence just means plain, uncolored `PASS`/`FAIL`/`WARN`
  lines.
* No llmctl `lib/` sourcing and no environment variables are read — only
  `PATH` is consulted implicitly via `command -v` — the script is
  standalone and fetchable/runnable on its own, exactly like pi's own
  install script.
* Network access to `https://pi.dev/install.sh` if pi is not already
  installed.

## Usage examples

Run it directly, with no arguments:

```bash
bash docs/integrations/install_pi.sh
```

Safe to re-run — if `pi` is already on `PATH` the script skips installation
entirely and only re-verifies:

```bash
bash docs/integrations/install_pi.sh
# ... WARN pi already present on PATH (/home/user/.local/bin/pi); skipping install, verifying only.
# ... PASS pi installed and verified. `pi --version` -> 0.85.1
```

There are no flags or arguments this script accepts — the only exposed
"surface" is the `PATH` environment variable it reads implicitly.

## Edge cases

* **`curl` missing when pi is also absent**: `_ipi_fail`s with
  `"curl is required to run pi's official install script but was not
  found on PATH."` and returns 1 before attempting any install.
* **pi already on `PATH`**: emits an `_ipi_warn` naming the existing
  binary path (`$(command -v pi)`) and skips straight to verification —
  the install script is never invoked at all.
* **Install script (`curl -fsSL https://pi.dev/install.sh | sh`) exits
  non-zero**: `_ipi_fail`s with the exact command and a pointer to the
  npm alternative (`npm install -g --ignore-scripts
  @earendil-works/pi-coding-agent`), then returns 1.
* **Install succeeds but `pi` still isn't resolvable on this shell's
  `PATH`**: unlike `install_opencode.sh`, this script has **no** fallback
  check for a known install location — it goes straight to the
  post-install verification check. If `pi` is still absent, `_ipi_fail`s
  with an explicit instruction to open a new shell or install manually
  (`npm install -g --ignore-scripts @earendil-works/pi-coding-agent`),
  rather than silently reporting success.
* **`pi --version` itself exits non-zero** after an apparently successful
  install: `_ipi_fail`s and includes the command's actual captured
  combined stdout+stderr (`pi --version 2>&1`) in the failure message —
  never a bare "failed" with no evidence.
* **Non-interactive / non-TTY output**: color codes (`_ipi_c_green` etc.)
  are only set when `[[ -t 1 ]]` is true and `tput colors` reports ≥8
  colors; otherwise they stay empty strings, so `PASS`/`FAIL`/`WARN`
  prefixes degrade gracefully to plain text when piped to a file or CI log.

## Internal behaviour

1. **Color setup** (top of file): probes `[[ -t 1 ]]` and `tput colors` to
   decide whether to populate `_ipi_c_reset`/`_ipi_c_green`/`_ipi_c_red`/
   `_ipi_c_yellow` with ANSI escape sequences, or leave them empty.
2. **Helper functions**: `_ipi_pass` prints a green `PASS` prefix to
   stdout; `_ipi_fail`/`_ipi_warn` print red/yellow `FAIL`/`WARN` prefixes
   to stderr.
3. **`main()`**:
   * If `pi` is **not** on `PATH`: checks for `curl` (fails if absent),
     then runs `curl -fsSL https://pi.dev/install.sh | sh`; on failure,
     fails with a pointer to the npm alternative. No further PATH-fallback
     probing is attempted on success (contrast with `install_opencode.sh`).
   * If `pi` **is** already on `PATH`: emits a `WARN` and skips straight
     to verification.
   * **Post-install/skip check**: re-checks `command -v pi`; if still
     absent, fails with an explicit "open a new shell" instruction.
   * **Verification**: captures `pi --version 2>&1` into `version_output`;
     on non-zero exit, fails with that captured output; on success, emits
     two `PASS` lines — the version string, and the resolved binary path
     (`command -v pi`).
4. `main "$@"` is invoked unconditionally at the bottom of the file (no
   argument parsing — the script takes none).

## Related scripts

* Sibling `install_<agent>.sh` scripts (same install-if-absent-then-verify
  shape): `install_aider.sh`, `install_claude_code.sh`, `install_cline.sh`,
  `install_continue.sh`, `install_crush.sh` (documented separately);
  `install_opencode.sh` (documented in this same batch, and the one sibling
  that *does* perform a known-location PATH fallback check pi's script
  does not).
* `docs/integrations.md` — documents pi's llmctl provider config
  (`~/.pi/agent/models.json` + `~/.pi/agent/settings.json`) and links to
  this script under "Installing pi".
* Not exercised by any `tests/test_*.sh` in `make test` — per
  `docs/integrations.md`, none of the `install_<agent>.sh` scripts are
  invoked automatically by `llmctl setup` or `make test`; installing
  developer tooling onto a host is a deliberate, manual/release-gating
  step.
* Unrelated to `docs/integrations/normalize_pi.sh` — that sibling script
  (documented in this same batch) filters pi's *run output* for
  determinism testing, whereas this script installs the `pi` binary
  itself.

## Last verified date

2026-09-17
