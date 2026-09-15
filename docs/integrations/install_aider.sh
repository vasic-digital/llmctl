#!/usr/bin/env bash
# install_aider.sh - install and verify the aider CLI agent for use against a
# running llmctl profile.
#
# Purpose:
#   Implements FR-011 (specs/001-llmctl-completion/spec.md, T026, US4
#   Acceptance Scenario 2): aider MUST be installable via its documented curl
#   setup mechanism and testable against a running llmctl server. This
#   script performs the automated half of that requirement (install-if-absent
#   + capture real verification evidence); docs/integrations.md documents the
#   manual half (config env vars + how to point aider at llmctl).
#
# Usage:
#   bash docs/integrations/install_aider.sh
#   (no arguments; safe to re-run - skips install if aider is already on
#   PATH)
#
# Inputs:
#   None. Reads only the PATH environment variable to detect an existing
#   aider install.
#
# Outputs:
#   PASS/FAIL line on stdout with the real captured `aider --version` output
#   (or the real failure reason). No output is fabricated or assumed: every
#   PASS line carries the command's actual stdout.
#
# Side-effects:
#   If `aider` is NOT already on PATH, downloads and executes aider's
#   official install script (https://aider.chat/install.sh) via curl | sh,
#   which installs `uv` if needed and then places a self-contained `aider`
#   binary on the current user's PATH (observed default:
#   ~/.local/bin/aider). Performs no llmctl-specific configuration and does
#   not touch any llmctl profile, model, or state directory.
#
# Dependencies:
#   bash, curl. No llmctl lib/ sourcing - this script is meant to be
#   fetchable and runnable standalone, exactly like aider's own install
#   script, so it carries no dependency on this repository's internal
#   libraries.
#
# Cross-references:
#   docs/integrations.md          - aider provider config for llmctl
#   specs/001-llmctl-completion/spec.md (FR-011) - the requirement this
#                                    script satisfies
#
# Source verified against (2026-09-15):
#   https://aider.chat/docs/install.html (official aider Installation docs)
set -euo pipefail

_ia_c_reset=""
_ia_c_green=""
_ia_c_red=""
_ia_c_yellow=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  _ia_c_reset=$'\033[0m'
  _ia_c_green=$'\033[32m'
  _ia_c_red=$'\033[31m'
  _ia_c_yellow=$'\033[33m'
fi

_ia_pass() { printf '%sPASS%s %s\n' "${_ia_c_green}" "${_ia_c_reset}" "$1"; }
_ia_fail() { printf '%sFAIL%s %s\n' "${_ia_c_red}" "${_ia_c_reset}" "$1" >&2; }
_ia_warn() { printf '%sWARN%s %s\n' "${_ia_c_yellow}" "${_ia_c_reset}" "$1" >&2; }

main() {
  if ! command -v aider >/dev/null 2>&1; then
    if ! command -v curl >/dev/null 2>&1; then
      _ia_fail "curl is required to run aider's official install script but was not found on PATH."
      return 1
    fi
    _ia_warn "aider not found on PATH; running the official install script (curl -LsSf https://aider.chat/install.sh | sh)"
    if ! curl -LsSf https://aider.chat/install.sh | sh; then
      _ia_fail "aider install script exited non-zero. See https://aider.chat/docs/install.html for manual install options (aider-install/uv/pipx/pip)."
      return 1
    fi
    # The install script may only update the current shell's rc file, not
    # this (already-running) shell's PATH. Fall back to the documented
    # install location before giving up.
    if ! command -v aider >/dev/null 2>&1; then
      if [[ -x "${HOME}/.local/bin/aider" ]]; then
        export PATH="${HOME}/.local/bin:${PATH}"
      fi
    fi
  else
    _ia_warn "aider already present on PATH ($(command -v aider)); skipping install, verifying only."
  fi

  if ! command -v aider >/dev/null 2>&1; then
    _ia_fail "aider still not found on PATH after install. Open a new shell (so ~/.local/bin is picked up) and re-run this script, or add it manually: export PATH=\"\$HOME/.local/bin:\$PATH\""
    return 1
  fi

  local version_output
  if ! version_output="$(aider --version 2>&1)"; then
    _ia_fail "aider --version exited non-zero. Output: ${version_output}"
    return 1
  fi

  _ia_pass "aider installed and verified. \`aider --version\` -> ${version_output}"
  _ia_pass "aider binary: $(command -v aider)"
  return 0
}

main "$@"
