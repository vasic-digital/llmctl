#!/usr/bin/env bash
# install_opencode.sh - install and verify the opencode CLI agent for use
# against a running llmctl profile.
#
# Purpose:
#   Implements FR-011 (specs/001-llmctl-completion/spec.md, T022): opencode
#   MUST be installable via its documented curl setup mechanism and testable
#   against a running llmctl server. This script performs the automated half
#   of that requirement (install-if-absent + capture real verification
#   evidence); docs/integrations.md documents the manual half.
#
# Usage:
#   bash docs/integrations/install_opencode.sh
#   (no arguments; safe to re-run - skips install if opencode is already on
#   PATH)
#
# Inputs:
#   None. Reads only the PATH environment variable to detect an existing
#   opencode install.
#
# Outputs:
#   PASS/FAIL line on stdout with the real captured `opencode --version`
#   output (or the real failure reason). No output is fabricated or assumed:
#   every PASS line carries the command's actual stdout.
#
# Side-effects:
#   If `opencode` is NOT already on PATH, downloads and executes opencode's
#   official install script (https://opencode.ai/install) via curl | bash,
#   which writes the opencode binary under the current user's home directory
#   (observed default: ~/.opencode/bin/opencode) and may append a PATH
#   export line to the user's shell rc file. Performs no llmctl-specific
#   configuration and does not touch any llmctl profile, model, or state
#   directory.
#
# Dependencies:
#   bash, curl. No llmctl lib/ sourcing - this script is meant to be
#   fetchable and runnable standalone, exactly like opencode's own install
#   script, so it carries no dependency on this repository's internal
#   libraries.
#
# Cross-references:
#   docs/integrations.md          - opencode provider config for llmctl
#   specs/001-llmctl-completion/spec.md (FR-011) - the requirement this
#                                    script satisfies
#
# Source verified against (2026-09-15):
#   https://opencode.ai/docs/ (official OpenCode documentation)
set -euo pipefail

_iop_c_reset=""
_iop_c_green=""
_iop_c_red=""
_iop_c_yellow=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  _iop_c_reset=$'\033[0m'
  _iop_c_green=$'\033[32m'
  _iop_c_red=$'\033[31m'
  _iop_c_yellow=$'\033[33m'
fi

_iop_pass() { printf '%sPASS%s %s\n' "${_iop_c_green}" "${_iop_c_reset}" "$1"; }
_iop_fail() { printf '%sFAIL%s %s\n' "${_iop_c_red}" "${_iop_c_reset}" "$1" >&2; }
_iop_warn() { printf '%sWARN%s %s\n' "${_iop_c_yellow}" "${_iop_c_reset}" "$1" >&2; }

main() {
  if ! command -v opencode >/dev/null 2>&1; then
    if ! command -v curl >/dev/null 2>&1; then
      _iop_fail "curl is required to run opencode's official install script but was not found on PATH."
      return 1
    fi
    _iop_warn "opencode not found on PATH; running the official install script (curl -fsSL https://opencode.ai/install | bash)"
    if ! curl -fsSL https://opencode.ai/install | bash; then
      _iop_fail "opencode install script exited non-zero. See https://opencode.ai/docs/ for manual install options (npm/brew/pacman/choco/scoop/docker)."
      return 1
    fi
    # The install script may only update the current shell's rc file, not
    # this (already-running) shell's PATH. Fall back to the documented
    # install location before giving up.
    if ! command -v opencode >/dev/null 2>&1; then
      if [[ -x "${HOME}/.opencode/bin/opencode" ]]; then
        export PATH="${HOME}/.opencode/bin:${PATH}"
      fi
    fi
  else
    _iop_warn "opencode already present on PATH ($(command -v opencode)); skipping install, verifying only."
  fi

  if ! command -v opencode >/dev/null 2>&1; then
    _iop_fail "opencode still not found on PATH after install. Open a new shell (so ~/.opencode/bin is picked up) and re-run this script, or add it manually: export PATH=\"\$HOME/.opencode/bin:\$PATH\""
    return 1
  fi

  local version_output
  if ! version_output="$(opencode --version 2>&1)"; then
    _iop_fail "opencode --version exited non-zero. Output: ${version_output}"
    return 1
  fi

  _iop_pass "opencode installed and verified. \`opencode --version\` -> ${version_output}"
  _iop_pass "opencode binary: $(command -v opencode)"
  return 0
}

main "$@"
