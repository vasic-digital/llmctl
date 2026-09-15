#!/usr/bin/env bash
# install_pi.sh - install and verify the pi CLI coding agent for use against
# a running llmctl profile.
#
# Purpose:
#   Implements FR-011 (specs/001-llmctl-completion/spec.md, T023): pi
#   MUST be installable via its documented curl setup mechanism and testable
#   against a running llmctl server. This script performs the automated half
#   of that requirement (install-if-absent + capture real verification
#   evidence); docs/integrations.md documents the manual half.
#
#   "pi" is the coding-agent CLI product published to npm as
#   @earendil-works/pi-coding-agent (binary name: pi; homepage: pi.dev;
#   source: github.com/earendil-works/pi). It is NOT the math-constant
#   "pi" CLI, a Raspberry Pi tool, or any other "pi"-named project -
#   identity confirmed against its config-file layout (~/.pi/agent/
#   models.json + settings.json), which matches this project's
#   docs/integrations.md "pi" section byte-for-byte in path and shape.
#
# Usage:
#   bash docs/integrations/install_pi.sh
#   (no arguments; safe to re-run - skips install if pi is already on PATH)
#
# Inputs:
#   None. Reads only the PATH environment variable to detect an existing
#   pi install.
#
# Outputs:
#   PASS/FAIL line on stdout with the real captured `pi --version` output
#   (or the real failure reason). No output is fabricated or assumed: every
#   PASS line carries the command's actual stdout.
#
# Side-effects:
#   If `pi` is NOT already on PATH, downloads and executes pi's official
#   installer script (https://pi.dev/install.sh) via curl | sh, which
#   installs the pi binary for the current user (observed on this project's
#   reference host: an npm-managed install exposing `pi` on PATH, config
#   under ~/.pi/agent/). Performs no llmctl-specific configuration and does
#   not touch any llmctl profile, model, or state directory.
#
# Dependencies:
#   bash, curl, sh (POSIX shell - the installer's own interpreter). No
#   llmctl lib/ sourcing - this script is meant to be fetchable and runnable
#   standalone, exactly like pi's own install script, so it carries no
#   dependency on this repository's internal libraries.
#
# Cross-references:
#   docs/integrations.md          - pi provider config for llmctl
#   specs/001-llmctl-completion/spec.md (FR-011) - the requirement this
#                                    script satisfies
#
# Source verified against (2026-09-15):
#   https://www.npmjs.com/package/@earendil-works/pi-coding-agent (package
#     metadata: bin name "pi", homepage https://github.com/earendil-works/pi)
#   https://github.com/earendil-works/pi#readme (README "Quick Start" +
#     "Providers & Models" sections: npm install command, curl installer
#     command `curl -fsSL https://pi.dev/install.sh | sh`, and the
#     ~/.pi/agent/models.json + ~/.pi/agent/settings.json config paths)
set -euo pipefail

_ipi_c_reset=""
_ipi_c_green=""
_ipi_c_red=""
_ipi_c_yellow=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  _ipi_c_reset=$'\033[0m'
  _ipi_c_green=$'\033[32m'
  _ipi_c_red=$'\033[31m'
  _ipi_c_yellow=$'\033[33m'
fi

_ipi_pass() { printf '%sPASS%s %s\n' "${_ipi_c_green}" "${_ipi_c_reset}" "$1"; }
_ipi_fail() { printf '%sFAIL%s %s\n' "${_ipi_c_red}" "${_ipi_c_reset}" "$1" >&2; }
_ipi_warn() { printf '%sWARN%s %s\n' "${_ipi_c_yellow}" "${_ipi_c_reset}" "$1" >&2; }

main() {
  if ! command -v pi >/dev/null 2>&1; then
    if ! command -v curl >/dev/null 2>&1; then
      _ipi_fail "curl is required to run pi's official install script but was not found on PATH."
      return 1
    fi
    _ipi_warn "pi not found on PATH; running the official install script (curl -fsSL https://pi.dev/install.sh | sh)"
    if ! curl -fsSL https://pi.dev/install.sh | sh; then
      _ipi_fail "pi install script exited non-zero. See https://github.com/earendil-works/pi#readme for the npm alternative: npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
      return 1
    fi
  else
    _ipi_warn "pi already present on PATH ($(command -v pi)); skipping install, verifying only."
  fi

  if ! command -v pi >/dev/null 2>&1; then
    _ipi_fail "pi still not found on PATH after install. Open a new shell (so the installer's PATH update is picked up) and re-run this script, or install manually: npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
    return 1
  fi

  local version_output
  if ! version_output="$(pi --version 2>&1)"; then
    _ipi_fail "pi --version exited non-zero. Output: ${version_output}"
    return 1
  fi

  _ipi_pass "pi installed and verified. \`pi --version\` -> ${version_output}"
  _ipi_pass "pi binary: $(command -v pi)"
  return 0
}

main "$@"
