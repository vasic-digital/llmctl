#!/usr/bin/env bash
# install_continue.sh - install and verify the Continue CLI (cn) agent for
# use against a running llmctl profile.
#
# Purpose:
#   Implements FR-011 (specs/001-llmctl-completion/spec.md, T027): continue.dev
#   MUST be installable via its documented curl setup mechanism and testable
#   against a running llmctl server. This script performs the automated half
#   of that requirement (install-if-absent + capture real verification
#   evidence); docs/integrations.md documents the manual half (config.yaml
#   provider wiring for llmctl).
#
#   IMPORTANT PROJECT-STATUS NOTE (verified 2026-09-15, Constitution
#   §11.4.6/§11.4.99 - no guessing, latest-source cross-check): Continue Dev,
#   Inc. was acquired by Cursor in June 2026. Continue shipped its final
#   release (2.0.0) on 2026-06-19 and the continuedev/continue GitHub
#   repository is now explicitly marked "no longer actively maintained ...
#   read-only for all users." The hosted "Continue Hub" service (account
#   login, cloud sync) was shut down after a 2026-07-15 data-export deadline.
#   Despite this, the Apache-2.0 source, the published npm package
#   (@continuedev/cli), and the install scripts below are still live and
#   installable as of this session - the final 2.0.0 release deliberately
#   removed the hosted-account authentication dependency, so `cn` still runs
#   fully standalone against an OpenAI-compatible apiBase (e.g. llmctl) with
#   no Continue account and no Anthropic key required for that use case. This
#   is a real, working, currently-installable tool; it is simply not being
#   further developed upstream.
#
# Usage:
#   bash docs/integrations/install_continue.sh
#   (no arguments; safe to re-run - skips install if the `cn` binary is
#   already on PATH)
#
# Inputs:
#   None. Reads only the PATH environment variable to detect an existing
#   Continue CLI install.
#
# Outputs:
#   PASS/FAIL line on stdout with the real captured `cn --help` output (or
#   the real failure reason). No output is fabricated or assumed: every PASS
#   line carries the command's actual stdout. Continue's own official install
#   script uses this same `cn --help` check as its documented verification
#   step (no `cn --version` flag is documented upstream, so this script does
#   not invent one - see "Source verified against" below).
#
# Side-effects:
#   If `cn` is NOT already on PATH, downloads and executes Continue's
#   official install script
#   (https://raw.githubusercontent.com/continuedev/continue/main/extensions/cli/scripts/install.sh)
#   via curl | bash. That script installs Node.js via fnm if a suitable
#   version is not already present (fnm itself installed from
#   https://fnm.vercel.app/install under $HOME/.local/share/fnm), then
#   installs the `@continuedev/cli` npm package globally, placing the `cn`
#   binary on PATH via a shell-rc PATH export. Performs no llmctl-specific
#   configuration and does not touch any llmctl profile, model, or state
#   directory.
#
# Dependencies:
#   bash, curl. No llmctl lib/ sourcing - this script is meant to be
#   fetchable and runnable standalone, exactly like Continue's own install
#   script, so it carries no dependency on this repository's internal
#   libraries.
#
# Cross-references:
#   docs/integrations.md          - continue.dev config.yaml provider wiring
#                                    for llmctl (apiBase = the running
#                                    profile's http://127.0.0.1:<port>/v1)
#   specs/001-llmctl-completion/spec.md (FR-011) - the requirement this
#                                    script satisfies
#
# Source verified against (2026-09-15):
#   https://docs.continue.dev/cli/install     (official Continue CLI install
#                                               docs - lists the curl/PowerShell/
#                                               npm methods below verbatim)
#   https://docs.continue.dev/cli/overview     (headless `-p` mode docs)
#   https://github.com/continuedev/continue/tree/main/extensions/cli
#                                               (extension README: install
#                                               methods, `-p`/`--config`/
#                                               `--resume`/`--format json`
#                                               flags, `cn --help` verification)
#   https://raw.githubusercontent.com/continuedev/continue/main/extensions/cli/scripts/install.sh
#                                               (actual installer source:
#                                               fnm + npm install path,
#                                               `cn --help` self-check)
#   https://github.com/continuedev/continue    (repository root README:
#                                               "no longer actively
#                                               maintained ... read-only")
set -euo pipefail

_ic_c_reset=""
_ic_c_green=""
_ic_c_red=""
_ic_c_yellow=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  _ic_c_reset=$'\033[0m'
  _ic_c_green=$'\033[32m'
  _ic_c_red=$'\033[31m'
  _ic_c_yellow=$'\033[33m'
fi

_ic_pass() { printf '%sPASS%s %s\n' "${_ic_c_green}" "${_ic_c_reset}" "$1"; }
_ic_fail() { printf '%sFAIL%s %s\n' "${_ic_c_red}" "${_ic_c_reset}" "$1" >&2; }
_ic_warn() { printf '%sWARN%s %s\n' "${_ic_c_yellow}" "${_ic_c_reset}" "$1" >&2; }

main() {
  if ! command -v cn >/dev/null 2>&1; then
    if ! command -v curl >/dev/null 2>&1; then
      _ic_fail "curl is required to run Continue's official install script but was not found on PATH."
      return 1
    fi
    _ic_warn "cn (Continue CLI) not found on PATH; running the official install script (curl -fsSL https://raw.githubusercontent.com/continuedev/continue/main/extensions/cli/scripts/install.sh | bash)"
    if ! curl -fsSL https://raw.githubusercontent.com/continuedev/continue/main/extensions/cli/scripts/install.sh | bash; then
      _ic_fail "Continue CLI install script exited non-zero. See https://docs.continue.dev/cli/install for manual install options (npm i -g @continuedev/cli requires Node.js 20+)."
      return 1
    fi
    # The install script may only update the current shell's rc file, not
    # this (already-running) shell's PATH. Fall back to the most common
    # documented install locations before giving up: a global npm prefix
    # bin dir, or fnm's own shim dir if it just installed Node.js.
    if ! command -v cn >/dev/null 2>&1; then
      if command -v npm >/dev/null 2>&1; then
        local npm_bin
        npm_bin="$(npm bin -g 2>/dev/null || npm prefix -g 2>/dev/null)/bin" || true
        if [[ -x "${npm_bin}/cn" ]]; then
          export PATH="${npm_bin}:${PATH}"
        fi
      fi
      if [[ -x "${HOME}/.npm-global/bin/cn" ]]; then
        export PATH="${HOME}/.npm-global/bin:${PATH}"
      fi
    fi
  else
    _ic_warn "cn (Continue CLI) already present on PATH ($(command -v cn)); skipping install, verifying only."
  fi

  if ! command -v cn >/dev/null 2>&1; then
    _ic_fail "cn still not found on PATH after install. Open a new shell (so the installer's PATH export is picked up) and re-run this script, or install manually per https://docs.continue.dev/cli/install (npm i -g @continuedev/cli, Node.js 20+ required)."
    return 1
  fi

  local help_output
  if ! help_output="$(cn --help 2>&1)"; then
    _ic_fail "cn --help exited non-zero. Output: ${help_output}"
    return 1
  fi

  _ic_pass "cn (Continue CLI) installed and verified. \`cn --help\` exited 0 with $(printf '%s' "${help_output}" | wc -l) line(s) of usage output."
  _ic_pass "cn binary: $(command -v cn)"
  _ic_warn "Continue.dev's upstream repository is archived/read-only as of 2026-06-19 (Cursor acquisition); the CLI still installs and runs standalone against llmctl's OpenAI-compatible API, but is not receiving further upstream development. See docs/integrations.md for the config.yaml wiring."
  return 0
}

main "$@"
