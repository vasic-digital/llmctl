## Overview

`docs/integrations/install_opencode.sh` installs and verifies
[opencode](https://opencode.ai/) for use against a running llmctl profile.
It implements FR-011 of `specs/001-llmctl-completion/spec.md` (T022):
opencode must be installable via its documented curl setup mechanism and
testable against a running llmctl server. This script performs the
*automated* half of that requirement (install-if-absent, then capture real
verification evidence); `docs/integrations.md` documents the manual half
(the `~/.config/opencode/opencode.json` custom-provider wiring needed to
point opencode at an llmctl profile).

## Prerequisites

* `bash` (`set -euo pipefail`).
* `curl` — required to run opencode's official install script; if
  `opencode` is not already on `PATH` and `curl` is also absent, the script
  fails immediately with no install attempt.
* `tput` is optional (only used to detect an interactive terminal for color
  output); its absence just means plain, uncolored `PASS`/`FAIL`/`WARN`
  lines.
* No llmctl `lib/` sourcing and no environment variables are read — only
  `PATH` is consulted implicitly via `command -v` — the script is
  standalone and fetchable/runnable on its own, exactly like opencode's own
  install script.
* Network access to `https://opencode.ai/install` if opencode is not
  already installed.

## Usage examples

Run it directly, with no arguments:

```bash
bash docs/integrations/install_opencode.sh
```

Safe to re-run — if `opencode` is already on `PATH` the script skips
installation entirely and only re-verifies:

```bash
bash docs/integrations/install_opencode.sh
# ... WARN opencode already present on PATH (/home/user/.opencode/bin/opencode); skipping install, verifying only.
# ... PASS opencode installed and verified. `opencode --version` -> 1.18.30
```

There are no flags or arguments this script accepts — the only exposed
"surface" is the `PATH` environment variable it reads implicitly.

## Edge cases

* **`curl` missing when opencode is also absent**: `_iop_fail`s with
  `"curl is required to run opencode's official install script but was not
  found on PATH."` and returns 1 before attempting any install.
* **opencode already on `PATH`**: emits an `_iop_warn` naming the existing
  binary path (`$(command -v opencode)`) and skips straight to
  verification — the install script is never invoked at all.
* **Install script (`curl -fsSL https://opencode.ai/install | bash`) exits
  non-zero**: `_iop_fail`s with the exact command and a pointer to
  `https://opencode.ai/docs/` for manual alternatives
  (npm/bun/pnpm/yarn/brew/pacman/paru/choco/scoop/mise/docker), then
  returns 1.
* **Install succeeds but `opencode` still isn't resolvable on this shell's
  `PATH`** (the install script may only update a shell rc file, not this
  already-running process): the script checks the documented default
  location `${HOME}/.opencode/bin/opencode` and, if executable, prepends it
  to `PATH` in-process (`export PATH="${HOME}/.opencode/bin:${PATH}"`)
  rather than blindly assuming that location — it only does this if the
  binary is genuinely found there.
* **Still not found after that fallback**: `_iop_fail`s with an explicit
  instruction to open a new shell or export `PATH` manually
  (`export PATH="$HOME/.opencode/bin:$PATH"`), rather than silently
  reporting success.
* **`opencode --version` itself exits non-zero** after an apparently
  successful install: `_iop_fail`s and includes the command's actual
  captured combined stdout+stderr (`opencode --version 2>&1`) in the
  failure message — never a bare "failed" with no evidence.
* **Non-interactive / non-TTY output**: color codes (`_iop_c_green` etc.)
  are only set when `[[ -t 1 ]]` is true and `tput colors` reports ≥8
  colors; otherwise they stay empty strings, so `PASS`/`FAIL`/`WARN`
  prefixes degrade gracefully to plain text when piped to a file or CI log.

## Internal behaviour

1. **Color setup** (top of file): probes `[[ -t 1 ]]` and `tput colors` to
   decide whether to populate `_iop_c_reset`/`_iop_c_green`/`_iop_c_red`/
   `_iop_c_yellow` with ANSI escape sequences, or leave them empty.
2. **Helper functions**: `_iop_pass` prints a green `PASS` prefix to
   stdout; `_iop_fail`/`_iop_warn` print red/yellow `FAIL`/`WARN` prefixes
   to stderr.
3. **`main()`**:
   * If `opencode` is **not** on `PATH`: checks for `curl` (fails if
     absent), then runs `curl -fsSL https://opencode.ai/install | bash`; on
     failure, fails with a pointer to manual install docs. On success, if
     `opencode` still isn't resolvable, checks
     `${HOME}/.opencode/bin/opencode` and PATH-prepends it if executable.
   * If `opencode` **is** already on `PATH`: emits a `WARN` and skips
     straight to verification.
   * **Post-install/skip check**: re-checks `command -v opencode`; if
     still absent, fails with an explicit "open a new shell" instruction.
   * **Verification**: captures `opencode --version 2>&1` into
     `version_output`; on non-zero exit, fails with that captured output;
     on success, emits two `PASS` lines — the version string, and the
     resolved binary path (`command -v opencode`).
4. `main "$@"` is invoked unconditionally at the bottom of the file (no
   argument parsing — the script takes none).

## Related scripts

* Sibling `install_<agent>.sh` scripts (same install-if-absent-then-verify
  shape): `install_aider.sh`, `install_claude_code.sh`, `install_cline.sh`,
  `install_continue.sh`, `install_crush.sh` (documented separately);
  `install_pi.sh` (documented in this same batch).
* `docs/integrations.md` — documents opencode's llmctl provider config
  (`~/.config/opencode/opencode.json` custom provider) and links to this
  script under "Installing opencode".
* Not exercised by any `tests/test_*.sh` in `make test` — per
  `docs/integrations.md`, none of the `install_<agent>.sh` scripts are
  invoked automatically by `llmctl setup` or `make test`; installing
  developer tooling onto a host is a deliberate, manual/release-gating
  step.
* Unrelated to `docs/integrations/normalize_opencode.sh` — that sibling
  script (documented in this same batch) filters opencode's *run output*
  for determinism testing, whereas this script installs the `opencode`
  binary itself.

## Last verified date

2026-09-17
