## Overview

`docs/integrations/install_continue.sh` installs and verifies the Continue
CLI (`cn`) for use against a running llmctl profile. It implements FR-011
of `specs/001-llmctl-completion/spec.md` (T027): continue.dev must be
installable via its documented curl setup mechanism and testable against a
running llmctl server. This script performs the *automated* half of that
requirement (install-if-absent, then capture real verification evidence);
`docs/integrations.md` documents the manual half (the `config.yaml`
provider wiring for llmctl).

The script's header records an important project-status finding (verified
2026-09-15 via live web research, not training data): Continue Dev, Inc.
was acquired by Cursor in June 2026, shipped its final release (2.0.0) on
2026-06-19, and the upstream `continuedev/continue` GitHub repository is
now explicitly marked read-only/no-longer-actively-maintained. Despite
this, the Apache-2.0 source, the published `@continuedev/cli` npm package,
and the install scripts this file automates are still live and
installable — the final 2.0.0 release deliberately removed the
hosted-account authentication dependency, so `cn` still runs fully
standalone against an OpenAI-compatible `apiBase` (e.g. llmctl) with no
Continue account required.

## Prerequisites

* `bash` (`set -euo pipefail`).
* `curl` — required to run Continue's official install script; if `cn` is
  not already on `PATH` and `curl` is also absent, the script fails
  immediately with no install attempt.
* No llmctl `lib/` sourcing and no environment variables are read (only
  `PATH` is consulted, implicitly, via `command -v`) — the script is
  standalone and fetchable/runnable on its own, exactly like Continue's own
  install script.
* Network access to
  `https://raw.githubusercontent.com/continuedev/continue/main/extensions/cli/scripts/install.sh`
  if `cn` is not already installed (that upstream script in turn installs
  Node.js via `fnm` if needed, then the `@continuedev/cli` npm package).

## Usage examples

Run it directly, with no arguments:

```bash
bash docs/integrations/install_continue.sh
```

Safe to re-run — if `cn` is already on `PATH` the script skips installation
entirely and only re-verifies:

```bash
bash docs/integrations/install_continue.sh
# ... WARN cn (Continue CLI) already present on PATH (/home/user/.local/share/fnm/aliases/default/bin/cn); skipping install, verifying only.
# ... PASS cn (Continue CLI) installed and verified. `cn --help` exited 0 with 42 line(s) of usage output.
```

There are no flags or arguments this script accepts — the only exposed
"surface" is the `PATH` environment variable it reads implicitly.

## Edge cases

* **`curl` missing when `cn` is also absent**: `_ic_fail`s with `"curl is
  required to run Continue's official install script but was not found on
  PATH."` and returns 1 before attempting any install.
* **`cn` already on `PATH`**: emits an `_ic_warn` naming the existing
  binary path (`$(command -v cn)`) and skips straight to verification — the
  install script is never invoked at all.
* **Install script exits non-zero**: `_ic_fail`s with the exact failing
  command and a pointer to `https://docs.continue.dev/cli/install` for
  manual alternatives (`npm i -g @continuedev/cli`, requires Node.js 20+),
  then returns 1.
* **Install succeeds but `cn` still isn't resolvable on this shell's
  `PATH`** (the installer may only update a shell rc file, not this
  already-running process): the script tries **two** documented fallback
  locations in order — first `npm bin -g` (falling back to
  `npm prefix -g`/`bin` if `npm bin -g` itself is unsupported) if `npm` is
  present and `${npm_bin}/cn` is executable; then, independently,
  `${HOME}/.npm-global/bin/cn` if executable — each PATH-prepending only if
  the binary is genuinely found there, never assumed.
* **No documented `--version` flag upstream**: rather than inventing one,
  the script uses `cn --help` as its verification command — the same check
  Continue's own official installer uses as its self-verification step
  (cited in the header's "Source verified against" list).
* **`cn --help` itself exits non-zero** after an apparently successful
  install: `_ic_fail`s and includes the command's actual captured combined
  stdout+stderr (`cn --help 2>&1`) in the failure message — never a bare
  "failed" with no evidence.
* **Upstream-archived-but-still-installable status is surfaced on every
  successful run**: the final `_ic_warn` on success explicitly states that
  Continue's upstream repository is archived/read-only as of 2026-06-19
  (Cursor acquisition), yet the CLI still installs and runs standalone
  against llmctl's OpenAI-compatible API — an honest, non-silent status
  note rather than presenting an unmaintained tool as actively developed.
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
   * If `cn` is **not** on `PATH`: checks for `curl` (fails if absent), then
     runs Continue's official install script via
     `curl -fsSL <install.sh URL> | bash`; on failure, fails with a pointer
     to manual install docs. On success, if `cn` still isn't resolvable,
     tries the `npm bin -g`/`npm prefix -g` location, then the
     `${HOME}/.npm-global/bin/cn` location, PATH-prepending whichever is
     found executable.
   * If `cn` **is** already on `PATH`: emits a `WARN` and skips straight to
     verification.
   * **Post-install/skip check**: re-checks `command -v cn`; if still
     absent, fails with an explicit "open a new shell, or install manually"
     instruction.
   * **Verification**: captures `cn --help 2>&1` into `help_output`; on
     non-zero exit, fails with that captured output; on success, emits two
     `PASS` lines (exit-0 confirmation with a line count via `wc -l`, and
     the resolved binary path) followed by one `WARN` about the
     upstream-archived status.
4. `main "$@"` is invoked unconditionally at the bottom of the file (no
   argument parsing — the script takes none).

## Related scripts

* Sibling `install_<agent>.sh` scripts (same install-if-absent-then-verify
  shape): `install_aider.sh`, `install_claude_code.sh`, `install_cline.sh`
  (documented in this same batch); `install_crush.sh` and
  `install_opencode.sh`/`install_pi.sh` (documented separately).
* `docs/integrations.md` — documents continue.dev's llmctl provider config
  (`~/.continue/config.yaml`'s `apiBase`/`apiKey` wiring) and links to this
  script under "Installing continue.dev", including the Cursor-acquisition
  status note.
* Not exercised by any `tests/test_*.sh` in `make test` — per
  `docs/integrations.md`, none of the `install_<agent>.sh` scripts are
  invoked automatically by `llmctl setup` or `make test`; installing
  developer tooling onto a host is a deliberate, manual/release-gating
  step.
* Unrelated to `docs/integrations/normalize_continue.sh` — that sibling
  script (documented by another agent in this batch) filters continue.dev's
  *run output* for determinism testing, whereas this script installs the
  `cn` binary itself.

## Last verified date

2026-09-17
