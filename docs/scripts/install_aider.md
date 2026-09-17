## Overview

`docs/integrations/install_aider.sh` installs and verifies [aider](https://aider.chat/)
for use against a running llmctl profile. It implements FR-011 of
`specs/001-llmctl-completion/spec.md` (T026, US4 Acceptance Scenario 2):
aider must be installable via its documented curl setup mechanism and
testable against a running llmctl server. This script performs the
*automated* half of that requirement (install-if-absent, then capture real
verification evidence); `docs/integrations.md` documents the manual half
(the `OPENAI_API_BASE`/`OPENAI_API_KEY` env vars and `.aider.conf.yml`
wiring needed to point aider at an llmctl profile).

## Prerequisites

* `bash` (`set -euo pipefail`).
* `curl` — required to run aider's official install script; if `aider` is
  not already on `PATH` and `curl` is also absent, the script fails
  immediately with no install attempt.
* `tput` is optional (only used to detect an interactive terminal for color
  output); its absence just means plain, uncolored `PASS`/`FAIL`/`WARN`
  lines.
* No llmctl `lib/` sourcing and no environment variables are read (only
  `PATH` is consulted, implicitly, via `command -v`) — the script is
  standalone and fetchable/runnable on its own, exactly like aider's own
  install script.
* Network access to `https://aider.chat/install.sh` if aider is not already
  installed.

## Usage examples

Run it directly, with no arguments:

```bash
bash docs/integrations/install_aider.sh
```

Safe to re-run — if `aider` is already on `PATH` the script skips
installation entirely and only re-verifies:

```bash
bash docs/integrations/install_aider.sh
# ... WARN aider already present on PATH (/home/user/.local/bin/aider); skipping install, verifying only.
# ... PASS aider installed and verified. `aider --version` -> aider 0.86.1
```

There are no flags or arguments this script accepts — the only exposed
"surface" is the `PATH` environment variable it reads implicitly.

## Edge cases

* **`curl` missing when aider is also absent**: `_ia_fail`s with
  `"curl is required to run aider's official install script but was not
  found on PATH."` and returns 1 before attempting any install.
* **aider already on `PATH`**: emits a `_ia_warn` naming the existing
  binary path (`$(command -v aider)`) and skips straight to verification —
  the install script is never invoked at all.
* **Install script (`curl -LsSf https://aider.chat/install.sh | sh`) exits
  non-zero**: `_ia_fail`s with the exact command and a pointer to
  `https://aider.chat/docs/install.html` for manual alternatives
  (`aider-install`/`uv`/`pipx`/`pip`), then returns 1.
* **Install succeeds but `aider` still isn't resolvable on this shell's
  `PATH`** (the install script may only update a shell rc file, not this
  already-running process): the script checks the documented default
  location `${HOME}/.local/bin/aider` and, if executable, prepends it to
  `PATH` in-process (`export PATH="${HOME}/.local/bin:${PATH}"`) rather
  than blindly assuming that location — it only does this if the binary is
  genuinely found there.
* **Still not found after that fallback**: `_ia_fail`s with an explicit
  instruction to open a new shell or export `PATH` manually, rather than
  silently reporting success.
* **`aider --version` itself exits non-zero** after an apparently
  successful install: `_ia_fail`s and includes the command's actual
  captured combined stdout+stderr (`aider --version 2>&1`) in the failure
  message — never a bare "failed" with no evidence.
* **Non-interactive / non-TTY output**: color codes (`_ia_c_green` etc.)
  are only set when `[[ -t 1 ]]` is true and `tput colors` reports ≥8
  colors; otherwise they stay empty strings, so `PASS`/`FAIL`/`WARN`
  prefixes degrade gracefully to plain text when piped to a file or CI log.

## Internal behaviour

1. **Color setup** (top of file): probes `[[ -t 1 ]]` and `tput colors` to
   decide whether to populate `_ia_c_reset`/`_ia_c_green`/`_ia_c_red`/
   `_ia_c_yellow` with ANSI escape sequences, or leave them empty.
2. **Helper functions**: `_ia_pass` prints a green `PASS` prefix to stdout;
   `_ia_fail`/`_ia_warn` print red/yellow `FAIL`/`WARN` prefixes to stderr.
3. **`main()`**:
   * If `aider` is **not** on `PATH`: checks for `curl` (fails if absent),
     then runs `curl -LsSf https://aider.chat/install.sh | sh`; on failure,
     fails with a pointer to manual install docs. On success, if `aider`
     still isn't resolvable, checks `${HOME}/.local/bin/aider` and
     PATH-prepends it if executable.
   * If `aider` **is** already on `PATH`: emits a `WARN` and skips straight
     to verification.
   * **Post-install/skip check**: re-checks `command -v aider`; if still
     absent, fails with an explicit "open a new shell" instruction.
   * **Verification**: captures `aider --version 2>&1` into
     `version_output`; on non-zero exit, fails with that captured output;
     on success, emits two `PASS` lines — the version string, and the
     resolved binary path (`command -v aider`).
4. `main "$@"` is invoked unconditionally at the bottom of the file (no
   argument parsing — the script takes none).

## Related scripts

* Sibling `install_<agent>.sh` scripts (same install-if-absent-then-verify
  shape): `install_claude_code.sh`, `install_cline.sh`,
  `install_continue.sh` (documented in this same batch); `install_crush.sh`
  and `install_opencode.sh`/`install_pi.sh` (documented separately).
* `docs/integrations.md` — documents aider's llmctl provider config
  (`OPENAI_API_BASE`/`OPENAI_API_KEY` env vars or `.aider.conf.yml`) and
  links to this script under "Installing aider".
* Not exercised by any `tests/test_*.sh` in `make test` — per
  `docs/integrations.md`, none of the `install_<agent>.sh` scripts are
  invoked automatically by `llmctl setup` or `make test`; installing
  developer tooling onto a host is a deliberate, manual/release-gating
  step.
* Unrelated to `docs/integrations/normalize_aider.sh` — that sibling script
  (documented by another agent in this batch) filters aider's *run output*
  for determinism testing, whereas this script installs the `aider` binary
  itself.

## Last verified date

2026-09-17
