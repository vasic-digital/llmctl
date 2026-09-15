#!/usr/bin/env bash
# install_claude_code.sh - install and verify the Claude Code CLI agent for
# use against a running llmctl profile.
#
# Purpose:
#   Implements FR-011 (specs/001-llmctl-completion/spec.md, T025): Claude
#   Code MUST be installable via its documented curl setup mechanism and
#   testable against a running llmctl server. This script performs the
#   automated half of that requirement (install-if-absent + capture real
#   verification evidence); docs/integrations.md documents the manual half,
#   including how to point Claude Code at llmctl's native-Anthropic-API
#   `colibri-qwen36` profile via ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN.
#
# Usage:
#   bash docs/integrations/install_claude_code.sh
#   (no arguments; safe to re-run - skips install if claude is already on
#   PATH)
#
# Inputs:
#   None. Reads only the PATH environment variable to detect an existing
#   claude install.
#
# Outputs:
#   PASS/FAIL line on stdout with the real captured `claude --version`
#   output (or the real failure reason). No output is fabricated or assumed:
#   every PASS line carries the command's actual stdout.
#
# Side-effects:
#   If `claude` is NOT already on PATH, downloads and executes Anthropic's
#   official native installer (https://claude.ai/install.sh) via curl | bash,
#   which writes the claude binary under the current user's home directory
#   (observed default: ~/.local/bin/claude, versions under
#   ~/.local/share/claude/versions/). Performs no llmctl-specific
#   configuration and does not touch any llmctl profile, model, or state
#   directory. Falls back to `npm install -g @anthropic-ai/claude-code` only
#   when curl or the native installer is unavailable and npm is present -
#   both are genuinely current, documented install paths for Claude Code
#   (native installer is Anthropic's own recommended default; npm is the
#   documented alternative for existing Node.js toolchains).
#
# Dependencies:
#   bash, curl (preferred path) or npm (fallback path). No llmctl lib/
#   sourcing - this script is meant to be fetchable and runnable standalone,
#   exactly like Claude Code's own install script, so it carries no
#   dependency on this repository's internal libraries.
#
# Cross-references:
#   docs/integrations.md          - Claude Code provider config for llmctl
#   specs/001-llmctl-completion/spec.md (FR-011) - the requirement this
#                                    script satisfies
#
# Source verified against (2026-09-15):
#   https://code.claude.com/docs/en/setup (official Claude Code setup docs;
#   docs.claude.com/en/docs/claude-code/setup redirects here)
set -euo pipefail

_icc_c_reset=""
_icc_c_green=""
_icc_c_red=""
_icc_c_yellow=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  _icc_c_reset=$'\033[0m'
  _icc_c_green=$'\033[32m'
  _icc_c_red=$'\033[31m'
  _icc_c_yellow=$'\033[33m'
fi

_icc_pass() { printf '%sPASS%s %s\n' "${_icc_c_green}" "${_icc_c_reset}" "$1"; }
_icc_fail() { printf '%sFAIL%s %s\n' "${_icc_c_red}" "${_icc_c_reset}" "$1" >&2; }
_icc_warn() { printf '%sWARN%s %s\n' "${_icc_c_yellow}" "${_icc_c_reset}" "$1" >&2; }

main() {
  if ! command -v claude >/dev/null 2>&1; then
    if command -v curl >/dev/null 2>&1; then
      _icc_warn "claude not found on PATH; running the official native installer (curl -fsSL https://claude.ai/install.sh | bash)"
      if ! curl -fsSL https://claude.ai/install.sh | bash; then
        _icc_fail "Claude Code native installer exited non-zero. See https://code.claude.com/docs/en/troubleshoot-install for manual install options (Homebrew/WinGet/apt/dnf/apk/npm)."
        return 1
      fi
      # The native installer writes ~/.local/bin/claude but may only update
      # the current shell's rc file, not this (already-running) shell's
      # PATH. Fall back to the documented install location before giving up.
      if ! command -v claude >/dev/null 2>&1 && [[ -x "${HOME}/.local/bin/claude" ]]; then
        export PATH="${HOME}/.local/bin:${PATH}"
      fi
    elif command -v npm >/dev/null 2>&1; then
      _icc_warn "curl not found; falling back to documented npm install (npm install -g @anthropic-ai/claude-code)"
      if ! npm install -g @anthropic-ai/claude-code; then
        _icc_fail "npm install -g @anthropic-ai/claude-code exited non-zero. See https://code.claude.com/docs/en/setup for manual install options."
        return 1
      fi
    else
      _icc_fail "Neither curl nor npm is available; cannot run any documented Claude Code install method. Install curl or npm first, or install manually per https://code.claude.com/docs/en/setup"
      return 1
    fi
  else
    _icc_warn "claude already present on PATH ($(command -v claude)); skipping install, verifying only."
  fi

  if ! command -v claude >/dev/null 2>&1; then
    _icc_fail "claude still not found on PATH after install. Open a new shell (so ~/.local/bin is picked up) and re-run this script, or add it manually: export PATH=\"\$HOME/.local/bin:\$PATH\""
    return 1
  fi

  local version_output
  if ! version_output="$(claude --version 2>&1)"; then
    _icc_fail "claude --version exited non-zero. Output: ${version_output}"
    return 1
  fi

  _icc_pass "Claude Code installed and verified. \`claude --version\` -> ${version_output}"
  _icc_pass "claude binary: $(command -v claude)"
  return 0
}

main "$@"
