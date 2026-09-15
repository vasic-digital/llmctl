#!/usr/bin/env bash
# install_crush.sh - install and verify Charm's crush CLI agent for use
# against a running llmctl profile.
#
# Purpose:
#   Implements FR-011 (specs/001-llmctl-completion/spec.md, T024): crush
#   MUST be installable via its documented setup mechanisms and testable
#   against a running llmctl server. This script performs the automated
#   half of that requirement (install-if-absent + capture real
#   verification evidence); docs/integrations.md documents the manual half
#   and the llmctl provider config crush.json needs.
#
# Usage:
#   bash docs/integrations/install_crush.sh
#   (no arguments; safe to re-run - skips install if crush is already on
#   PATH)
#
# Inputs:
#   None required. Reads PATH to detect an existing crush install and
#   probes for `npm`, `brew`, and `go` on PATH to pick an install method.
#
# Outputs:
#   PASS/FAIL line on stdout with the real captured `crush --version`
#   output (or the real failure reason). No output is fabricated or
#   assumed: every PASS line carries the command's actual stdout.
#
# Side-effects:
#   If `crush` is NOT already on PATH, runs ONE of crush's own official,
#   non-interactive install commands, tried in this order until one
#   succeeds (no method is invented - all are taken verbatim from
#   charmbracelet/crush's README, see "Source verified against" below):
#     1. `npm install -g @charmland/crush`   (if `npm` is on PATH)
#     2. `brew install charmbracelet/tap/crush` (if `brew` is on PATH)
#     3. `go install github.com/charmbracelet/crush@latest` (if `go` is
#        on PATH; installs to `$(go env GOPATH)/bin`, or `~/go/bin` if
#        GOPATH is unset)
#   Charm's crush ships NO `curl | bash` one-liner installer (unlike some
#   other Charm tools) - its documented automatable paths are exactly the
#   three package-manager commands above, plus interactive-only paths
#   (winget/scoop on Windows, an apt/yum repo requiring `sudo`) that this
#   script deliberately does not attempt non-interactively. If none of
#   npm/brew/go is present, the script fails with the manual install
#   commands so the operator can choose one (Constitution §11.4.6 - never
#   fabricate an install command that isn't real).
#
# Dependencies:
#   bash, and at least one of: npm, brew, go. No llmctl lib/ sourcing -
#   this script is meant to be fetchable and runnable standalone.
#
# Cross-references:
#   docs/integrations.md          - crush provider config for llmctl
#                                    (~/.config/crush/crush.json)
#   specs/001-llmctl-completion/spec.md (FR-011) - the requirement this
#                                    script satisfies
#
# Source verified against (2026-09-15):
#   https://github.com/charmbracelet/crush (README.md, Installation section)
set -euo pipefail

_icr_c_reset=""
_icr_c_green=""
_icr_c_red=""
_icr_c_yellow=""
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  _icr_c_reset=$'\033[0m'
  _icr_c_green=$'\033[32m'
  _icr_c_red=$'\033[31m'
  _icr_c_yellow=$'\033[33m'
fi

_icr_pass() { printf '%sPASS%s %s\n' "${_icr_c_green}" "${_icr_c_reset}" "$1"; }
_icr_fail() { printf '%sFAIL%s %s\n' "${_icr_c_red}" "${_icr_c_reset}" "$1" >&2; }
_icr_warn() { printf '%sWARN%s %s\n' "${_icr_c_yellow}" "${_icr_c_reset}" "$1" >&2; }

_icr_manual_install_help() {
  cat >&2 <<'EOF'
No supported package manager (npm, brew, go) was found on PATH to install
crush automatically. Install it manually with ONE of these documented
methods (source: https://github.com/charmbracelet/crush README):

  npm:      npm install -g @charmland/crush
  Homebrew: brew install charmbracelet/tap/crush
  Go:       go install github.com/charmbracelet/crush@latest
  Arch:     yay -S crush-bin
  Nix:      nix run github:numtide/nix-ai-tools#crush
  FreeBSD:  pkg install crush
  Winget:   winget install charmbracelet.crush
  Scoop:    scoop bucket add charm https://github.com/charmbracelet/scoop-bucket.git
            scoop install crush
  Debian/Ubuntu (apt repo, requires sudo):
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor \
              -o /etc/apt/keyrings/charm.gpg
            echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
              | sudo tee /etc/apt/sources.list.d/charm.list
            sudo apt update && sudo apt install crush
  Fedora/RHEL: sudo yum install crush

Then re-run: bash docs/integrations/install_crush.sh
EOF
}

main() {
  if ! command -v crush >/dev/null 2>&1; then
    if command -v npm >/dev/null 2>&1; then
      _icr_warn "crush not found on PATH; installing via npm (npm install -g @charmland/crush)"
      if ! npm install -g @charmland/crush; then
        _icr_fail "npm install -g @charmland/crush exited non-zero."
        _icr_manual_install_help
        return 1
      fi
    elif command -v brew >/dev/null 2>&1; then
      _icr_warn "crush not found on PATH; installing via Homebrew (brew install charmbracelet/tap/crush)"
      if ! brew install charmbracelet/tap/crush; then
        _icr_fail "brew install charmbracelet/tap/crush exited non-zero."
        _icr_manual_install_help
        return 1
      fi
    elif command -v go >/dev/null 2>&1; then
      _icr_warn "crush not found on PATH; installing via Go (go install github.com/charmbracelet/crush@latest)"
      if ! go install github.com/charmbracelet/crush@latest; then
        _icr_fail "go install github.com/charmbracelet/crush@latest exited non-zero."
        _icr_manual_install_help
        return 1
      fi
      # `go install` places the binary in GOBIN, or GOPATH/bin, or
      # ~/go/bin by default - none of which are guaranteed to be on the
      # current shell's PATH yet.
      if ! command -v crush >/dev/null 2>&1; then
        local go_bin
        go_bin="$(go env GOBIN 2>/dev/null || true)"
        if [[ -z "${go_bin}" ]]; then
          local go_path
          go_path="$(go env GOPATH 2>/dev/null || echo "${HOME}/go")"
          go_bin="${go_path}/bin"
        fi
        if [[ -x "${go_bin}/crush" ]]; then
          export PATH="${go_bin}:${PATH}"
        fi
      fi
    else
      _icr_fail "No supported installer (npm, brew, go) found on PATH."
      _icr_manual_install_help
      return 1
    fi
  else
    _icr_warn "crush already present on PATH ($(command -v crush)); skipping install, verifying only."
  fi

  if ! command -v crush >/dev/null 2>&1; then
    _icr_fail "crush still not found on PATH after install. Open a new shell and re-run this script, or add the install location to PATH manually."
    return 1
  fi

  local version_output
  if ! version_output="$(crush --version 2>&1)"; then
    _icr_fail "crush --version exited non-zero. Output: ${version_output}"
    return 1
  fi

  _icr_pass "crush installed and verified. \`crush --version\` -> ${version_output}"
  _icr_pass "crush binary: $(command -v crush)"
  return 0
}

main "$@"
