## Overview

`docs/integrations/install_cline.sh` installs and verifies the standalone
Cline CLI for use against a running llmctl profile. It implements FR-011 of
`specs/001-llmctl-completion/spec.md` (T028, US4): Cline must be
installable via its documented setup mechanism and testable against a
running llmctl server. This script performs the *automated* half of that
requirement (install-if-absent, then capture real verification evidence);
`docs/integrations.md` documents the manual half (the `globalState.json`
provider config keys and how to point Cline at llmctl).

The script's own header records a research finding: Cline is no longer an
IDE-extension-only tool. It ships three surfaces from the same
`github.com/cline/cline` monorepo — (1) a genuine standalone CLI installed
via `npm install -g cline` (what this script automates: a real automatable
install plus a real version-flag verification), (2) an IDE extension
(VS Code marketplace id `saoudrizwan.claude-dev`, also distributed for
Cursor/Windsurf/VSCodium/JetBrains) that this script deliberately does
**not** touch and which `docs/integrations.md`'s "## Cline" section already
documents (`globalState.json` provider keys), and (3) an `@cline/sdk` npm
package for embedding Cline in other Node programs, out of scope here.

## Prerequisites

* `bash` (`set -euo pipefail`).
* `npm` (Node.js 20+, 22 recommended per Cline's own docs) — the only
  install mechanism this script automates; if `cline` is absent and `npm`
  is also absent, the script fails immediately with no install attempt.
* No llmctl `lib/` sourcing and no environment variables are read (only
  `PATH` is consulted, implicitly, via `command -v`) — the script is
  standalone and fetchable/runnable on its own, exactly like this
  project's other `install_<agent>.sh` scripts.
* Network access to the npm registry if the Cline CLI is not already
  installed.

## Usage examples

Run it directly, with no arguments:

```bash
bash docs/integrations/install_cline.sh
```

Safe to re-run — if `cline` is already on `PATH` the script skips
installation entirely and only re-verifies:

```bash
bash docs/integrations/install_cline.sh
# ... WARN cline CLI already present on PATH (/home/user/.npm-global/bin/cline); skipping install, verifying only.
# ... PASS Cline CLI installed and verified. `cline --version` -> 2.0.4
```

There are no flags or arguments this script accepts — the only exposed
"surface" is the `PATH` environment variable it reads implicitly.

## Edge cases

* **`npm` missing when `cline` is also absent**: `_ic_fail`s with `"npm is
  required to install the Cline CLI (npm install -g cline) but was not
  found on PATH. See https://docs.cline.bot/cline-cli/installation for
  Node.js setup (Node.js 20+, 22 recommended)."` and returns 1 before
  attempting any install.
* **`cline` already on `PATH`**: emits an `_ic_warn` naming the existing
  binary path (`$(command -v cline)`) and skips straight to verification —
  `npm install` is never invoked at all.
* **`npm install -g cline` exits non-zero**: `_ic_fail`s with the exact
  failing command and a pointer to
  `https://docs.cline.bot/cline-cli/installation` for manual alternatives,
  then returns 1.
* **Install succeeds but `cline` still isn't resolvable on `PATH`**:
  `_ic_fail`s with an explicit instruction to open a new shell (so the
  global npm bin dir is picked up) and re-run the script — unlike the
  curl-based sibling scripts, there is no in-process `PATH`-prepend
  fallback here (npm global installs are expected to already resolve).
* **`cline --version` itself exits non-zero** after an apparently
  successful install: `_ic_fail`s and includes the command's actual
  captured combined stdout+stderr (`cline --version 2>&1`) in the failure
  message — never a bare "failed" with no evidence.
* **The IDE-extension surface is a distinct, unautomated path**: on
  success, the script's final `_ic_warn` explicitly notes that only the
  standalone CLI was installed/verified here — the separate VS
  Code/Cursor/JetBrains extension (marketplace id `saoudrizwan.claude-dev`)
  is a different install path documented (not scripted) in
  `docs/integrations.md`'s "## Cline" section.
* **Non-interactive / non-TTY output**: color codes (`_ic_c_green` etc.)
  are only set when `[[ -t 1 ]]` is true and `tput colors` reports ≥8
  colors; otherwise they stay empty strings, so `PASS`/`FAIL`/`WARN`
  prefixes degrade gracefully to plain text when piped to a file or CI log.

## Internal behaviour

1. **Color setup** (top of file): probes `[[ -t 1 ]]` and `tput colors` to
   decide whether to populate `_ic_c_reset`/`_ic_c_green`/`_ic_c_red`/
   `_ic_c_yellow` with ANSI escape sequences, or leave them empty.
2. **Helper functions**: `_ic_pass` prints a green `PASS` prefix to stdout;
   `_ic_fail`/`_ic_warn` print red/yellow `FAIL`/`WARN` prefixes to stderr.
3. **`main()`**:
   * If `cline` is **not** on `PATH`: checks for `npm` (fails if absent),
     then runs `npm install -g cline`; on failure, fails with a pointer to
     manual install docs.
   * If `cline` **is** already on `PATH`: emits a `WARN` and skips straight
     to verification.
   * **Post-install/skip check**: re-checks `command -v cline`; if still
     absent, fails with an explicit "open a new shell" instruction.
   * **Verification**: captures `cline --version 2>&1` into
     `version_output`; on non-zero exit, fails with that captured output;
     on success, emits two `PASS` lines (version string, resolved binary
     path) followed by one `WARN` noting the IDE-extension surface is
     separate and unautomated.
4. `main "$@"` is invoked unconditionally at the bottom of the file (no
   argument parsing — the script takes none).

## Related scripts

* Sibling `install_<agent>.sh` scripts (same install-if-absent-then-verify
  shape): `install_aider.sh`, `install_claude_code.sh`,
  `install_continue.sh` (documented in this same batch); `install_crush.sh`
  and `install_opencode.sh`/`install_pi.sh` (documented separately).
* `docs/integrations.md` — documents Cline's llmctl provider config for
  **both** surfaces: the IDE extension's `globalState.json` keys (this
  script does not touch that surface) and the standalone CLI's `cline auth
  --provider openai-native ...` configuration command (against the
  binary this script installs).
* Not exercised by any `tests/test_*.sh` in `make test` — per
  `docs/integrations.md`, none of the `install_<agent>.sh` scripts are
  invoked automatically by `llmctl setup` or `make test`; installing
  developer tooling onto a host is a deliberate, manual/release-gating
  step.
* Unrelated to `docs/integrations/normalize_cline.sh` — that sibling script
  (documented by another agent in this batch) filters Cline's *run output*
  for determinism testing, whereas this script installs the `cline` CLI
  binary itself.

## Last verified date

2026-09-17
