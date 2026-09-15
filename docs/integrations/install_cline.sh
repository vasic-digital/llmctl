#!/usr/bin/env bash
# install_cline.sh - install and verify the Cline CLI agent for use against a
# running llmctl profile.
#
# Purpose:
#   Implements FR-011 (specs/001-llmctl-completion/spec.md, T028, US4):
#   Cline MUST be installable via its documented setup mechanism and
#   testable against a running llmctl server. This script performs the
#   automated half of that requirement (install-if-absent + capture real
#   verification evidence); docs/integrations.md documents the manual half
#   (config keys + how to point Cline at llmctl).
#
#   Research finding (verified this session via WebSearch/WebFetch against
#   Cline's own current docs - see "Source verified against" below):
#   Cline is NO LONGER an IDE-extension-only tool. As of this session it
#   ships THREE distinct surfaces from the same github.com/cline/cline
#   monorepo:
#     1. A genuine standalone CLI, installed with `npm install -g cline`
#        (real curl/npm-class setup mechanism, real `cline --version`
#        verification, real headless/scriptable use - this is what this
#        script automates).
#     2. An IDE extension (VS Code marketplace id `saoudrizwan.claude-dev`,
#        also distributed for Cursor/Windsurf/VSCodium/JetBrains) - this is
#        the surface docs/integrations.md's existing "## Cline" section
#        documents (globalState.json provider keys); this script does not
#        touch it.
#     3. An `@cline/sdk` npm package for embedding Cline in other Node
#        programs (out of scope here).
#   This script automates surface (1), the standalone CLI, because it is
#   the one with a real automatable install + a real version-flag
#   verification, matching this project's other install_<agent>.sh scripts.
#
# Usage:
#   bash docs/integrations/install_cline.sh
#   (no arguments; safe to re-run - skips install if `cline` is already on
#   PATH)
#
# Inputs:
#   None. Reads only the PATH environment variable to detect an existing
#   Cline CLI install and an existing `npm` binary.
#
# Outputs:
#   PASS/FAIL/WARN lines on stdout with the real captured `cline --version`
#   output (or the real failure reason). No output is fabricated or
#   assumed: every PASS line carries the command's actual stdout.
#
# Side-effects:
#   If `cline` is NOT already on PATH, and `npm` IS on PATH, runs
#   `npm install -g cline` (Cline's own documented global-install command).
#   Requires Node.js 20+ (22 recommended per Cline's docs). Performs no
#   llmctl-specific configuration and does not touch any llmctl profile,
#   model, or state directory. Does NOT touch the separate VS
#   Code/Cursor/JetBrains extension surface (`saoudrizwan.claude-dev`) -
#   that remains documented, not scripted, in docs/integrations.md.
#
# Dependencies:
#   bash, npm (Node.js 20+, 22 recommended). No llmctl lib/ sourcing - this
#   script is meant to be fetchable and runnable standalone, exactly like
#   this project's other install_<agent>.sh scripts.
#
# Cross-references:
#   docs/integrations.md          - Cline provider config for llmctl
#                                    (extension surface; not touched here)
#   specs/001-llmctl-completion/spec.md (FR-011) - the requirement this
#                                    script satisfies
#
# Source verified against (2026-09-15, via WebSearch + WebFetch this
# session, per Constitution 11.4.6/11.4.8/11.4.99 - no assumption from
# training data):
#   https://docs.cline.bot/getting-started/installing-cline
#   https://docs.cline.bot/cline-cli/installation
#   https://github.com/cline/cline (repo description: "Autonomous coding
#     agent as an SDK, IDE extension, or CLI assistant.")
#   https://github.com/cline/cline/blob/main/apps/cli/README.md
#   https://cline.bot/cli
#   https://cline.bot/blog/introducing-cline-cli-2-0
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
  if ! command -v cline >/dev/null 2>&1; then
    if ! command -v npm >/dev/null 2>&1; then
      _ic_fail "npm is required to install the Cline CLI (npm install -g cline) but was not found on PATH. See https://docs.cline.bot/cline-cli/installation for Node.js setup (Node.js 20+, 22 recommended)."
      return 1
    fi
    _ic_warn "cline CLI not found on PATH; running the official install command (npm install -g cline)"
    if ! npm install -g cline; then
      _ic_fail "npm install -g cline exited non-zero. See https://docs.cline.bot/cline-cli/installation for manual install options."
      return 1
    fi
  else
    _ic_warn "cline CLI already present on PATH ($(command -v cline)); skipping install, verifying only."
  fi

  if ! command -v cline >/dev/null 2>&1; then
    _ic_fail "cline still not found on PATH after install. Open a new shell (so the global npm bin dir is picked up) and re-run this script."
    return 1
  fi

  local version_output
  if ! version_output="$(cline --version 2>&1)"; then
    _ic_fail "cline --version exited non-zero. Output: ${version_output}"
    return 1
  fi

  _ic_pass "Cline CLI installed and verified. \`cline --version\` -> ${version_output}"
  _ic_pass "cline binary: $(command -v cline)"
  _ic_warn "Note: this only installs/verifies the Cline CLI. The separate VS Code/Cursor/JetBrains extension (marketplace id saoudrizwan.claude-dev) is a distinct install path - see docs/integrations.md '## Cline' for its provider-config steps."
  return 0
}

main "$@"
