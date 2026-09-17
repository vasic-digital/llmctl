## Overview

`docs/integrations/install_claude_code.sh` installs and verifies the
Claude Code CLI agent for use against a running llmctl profile. It
implements FR-011 of `specs/001-llmctl-completion/spec.md` (T025): Claude
Code must be installable via its documented curl setup mechanism and
testable against a running llmctl server. This script performs the
*automated* half of that requirement (install-if-absent, then capture real
verification evidence); `docs/integrations.md` documents the manual half,
including how to point Claude Code at llmctl's native-Anthropic-API
`colibri-qwen36` profile via `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`.

Unlike the other agent-install scripts, Claude Code has two genuinely
current, documented install paths, and this script tries both: the native
installer (Anthropic's own recommended default) first, falling back to an
`npm install -g @anthropic-ai/claude-code` only when `curl`/the native
installer path is unavailable.

## Prerequisites

* `bash` (`set -euo pipefail`).
* `curl` (preferred path) **or** `npm` (fallback path) — at least one must
  be present if `claude` is not already on `PATH`; if neither is available,
  the script fails immediately.
* `tput` is optional (only used to detect an interactive terminal for color
  output); its absence just means plain, uncolored `PASS`/`FAIL`/`WARN`
  lines.
* No llmctl `lib/` sourcing and no environment variables are read (only
  `PATH` is consulted, implicitly, via `command -v`) — the script is
  standalone and fetchable/runnable on its own, exactly like Claude Code's
  own install script.
* Network access to `https://claude.ai/install.sh` (native path) or the npm
  registry (fallback path) if `claude` is not already installed.

## Usage examples

Run it directly, with no arguments:

```bash
bash docs/integrations/install_claude_code.sh
```

Safe to re-run — if `claude` is already on `PATH` the script skips
installation entirely and only re-verifies:

```bash
bash docs/integrations/install_claude_code.sh
# ... WARN claude already present on PATH (/home/user/.local/bin/claude); skipping install, verifying only.
# ... PASS Claude Code installed and verified. `claude --version` -> 2.1.263 (Claude Code)
```

There are no flags or arguments this script accepts — the only exposed
"surface" is the `PATH` environment variable it reads implicitly, and which
of `curl`/`npm` happen to already be present on the host (which
deterministically selects the install path taken).

## Edge cases

* **Neither `curl` nor `npm` available, and `claude` is absent**: `_icc_fail`s
  with `"Neither curl nor npm is available; cannot run any documented
  Claude Code install method. Install curl or npm first, or install
  manually per https://code.claude.com/docs/en/setup"` and returns 1.
* **claude already on `PATH`**: emits an `_icc_warn` naming the existing
  binary path (`$(command -v claude)`) and skips straight to verification —
  neither installer is invoked at all.
* **`curl` present**: runs `curl -fsSL https://claude.ai/install.sh | bash`
  (Anthropic's own native installer). On non-zero exit, `_icc_fail`s with a
  pointer to `https://code.claude.com/docs/en/troubleshoot-install` for
  manual alternatives (Homebrew/WinGet/apt/dnf/apk/npm), then returns 1.
* **Native installer succeeds but `claude` still isn't resolvable on this
  shell's `PATH`** (the installer may only update a shell rc file, not this
  already-running process): the script checks the documented default
  location `${HOME}/.local/bin/claude` and, if executable, prepends it to
  `PATH` in-process — it only does this if the binary is genuinely found
  there, combined into a single condition
  (`! command -v claude && [[ -x "${HOME}/.local/bin/claude" ]]`).
* **`curl` absent but `npm` present**: falls back to
  `npm install -g @anthropic-ai/claude-code`; on non-zero exit, `_icc_fail`s
  with a pointer to `https://code.claude.com/docs/en/setup`, then returns
  1. This path performs no `PATH`-fallback check (unlike the curl path) —
  npm global installs are expected to already be on `PATH`.
* **Still not found after install (either path)**: `_icc_fail`s with an
  explicit instruction to open a new shell or export `PATH` manually,
  rather than silently reporting success.
* **`claude --version` itself exits non-zero** after an apparently
  successful install: `_icc_fail`s and includes the command's actual
  captured combined stdout+stderr (`claude --version 2>&1`) in the failure
  message — never a bare "failed" with no evidence.
* **Non-interactive / non-TTY output**: color codes (`_icc_c_green` etc.)
  are only set when `[[ -t 1 ]]` is true and `tput colors` reports ≥8
  colors; otherwise they stay empty strings, so `PASS`/`FAIL`/`WARN`
  prefixes degrade gracefully to plain text when piped to a file or CI log.

## Internal behaviour

1. **Color setup** (top of file): probes `[[ -t 1 ]]` and `tput colors` to
   decide whether to populate `_icc_c_reset`/`_icc_c_green`/`_icc_c_red`/
   `_icc_c_yellow` with ANSI escape sequences, or leave them empty.
2. **Helper functions**: `_icc_pass` prints a green `PASS` prefix to
   stdout; `_icc_fail`/`_icc_warn` print red/yellow `FAIL`/`WARN` prefixes
   to stderr.
3. **`main()`**:
   * If `claude` is **not** on `PATH`: tries, in order, the native
     installer (if `curl` exists) with a `PATH`-fallback check afterward;
     else the npm fallback (if `npm` exists); else fails outright naming
     both prerequisites missing.
   * If `claude` **is** already on `PATH`: emits a `WARN` and skips
     straight to verification.
   * **Post-install/skip check**: re-checks `command -v claude`; if still
     absent, fails with an explicit "open a new shell" instruction.
   * **Verification**: captures `claude --version 2>&1` into
     `version_output`; on non-zero exit, fails with that captured output;
     on success, emits two `PASS` lines — the version string, and the
     resolved binary path (`command -v claude`).
4. `main "$@"` is invoked unconditionally at the bottom of the file (no
   argument parsing — the script takes none).

## Related scripts

* Sibling `install_<agent>.sh` scripts (same install-if-absent-then-verify
  shape): `install_aider.sh`, `install_cline.sh`, `install_continue.sh`
  (documented in this same batch); `install_crush.sh` and
  `install_opencode.sh`/`install_pi.sh` (documented separately).
* `docs/integrations.md` — documents Claude Code's llmctl provider config
  (the `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` wiring against
  `colibri-qwen36`, port 8090) and links to this script under "Installing
  Claude Code".
* Not exercised by any `tests/test_*.sh` in `make test` — per
  `docs/integrations.md`, none of the `install_<agent>.sh` scripts are
  invoked automatically by `llmctl setup` or `make test`; installing
  developer tooling onto a host is a deliberate, manual/release-gating
  step.
* Unrelated to `docs/integrations/normalize_claude_code.sh` — that sibling
  script (documented by another agent in this batch) filters Claude Code's
  *run output* for determinism testing, whereas this script installs the
  `claude` binary itself.

## Last verified date

2026-09-17
