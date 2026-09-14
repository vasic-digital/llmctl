#!/usr/bin/env bash
# doctor.sh - environment self-diagnosis for llmctl.
# Every check prints PASS/WARN/FAIL with evidence; exit code is non-zero when
# any FAIL occurred.
set -euo pipefail

_doc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_doc_dir}/common.sh"
# shellcheck source=os_detect.sh
source "${_doc_dir}/os_detect.sh"

DOCTOR_FAILS=0
DOCTOR_WARNS=0

_doc_pass() { printf '%sPASS%s %s\n' "${LLMCTL_C_GREEN}" "${LLMCTL_C_RESET}" "$1"; }
_doc_warn() { DOCTOR_WARNS=$((DOCTOR_WARNS+1)); printf '%sWARN%s %s\n' "${LLMCTL_C_YELLOW}" "${LLMCTL_C_RESET}" "$1"; }
_doc_fail() { DOCTOR_FAILS=$((DOCTOR_FAILS+1)); printf '%sFAIL%s %s\n' "${LLMCTL_C_RED}" "${LLMCTL_C_RESET}" "$1"; }

_doc_check_cmd() {
  # _doc_check_cmd <cmd> <required|optional> [hint]
  local cmd="$1" level="$2" hint="${3:-}"
  if have_cmd "${cmd}"; then
    _doc_pass "command '${cmd}' -> $(command -v "${cmd}")"
  elif [[ "${level}" == "required" ]]; then
    _doc_fail "missing required command '${cmd}'. ${hint:-$(llmctl_pkg_hint | sed "s/<pkg>/${cmd}/")}"
  else
    _doc_warn "missing optional command '${cmd}'. ${hint}"
  fi
}

doctor_run() {
  bold "llmctl doctor - environment self-diagnosis"

  local os; os="$(llmctl_os)" || { _doc_fail "unsupported OS: $(uname -s)"; os="unknown"; }
  [[ "${os}" != "unknown" ]] && _doc_pass "OS: ${os} ($(llmctl_arch))"

  _doc_check_cmd bash required
  _doc_check_cmd curl required
  _doc_check_cmd git required
  _doc_check_cmd python3 required
  _doc_check_cmd cmake optional "needed to build llama.cpp (llmctl build llama)"
  _doc_check_cmd make optional "needed to build colibri (llmctl build colibri)"
  if have_cmd gcc || have_cmd clang || have_cmd cc; then
    _doc_pass "C compiler available"
  else
    _doc_warn "no C compiler (gcc/clang) - colibri build unavailable"
  fi

  # Checksum tool.
  if have_cmd sha256sum || have_cmd shasum || have_cmd openssl; then
    _doc_pass "sha256 tool available"
  else
    _doc_fail "no sha256 tool (sha256sum/shasum/openssl) - downloads cannot be verified"
  fi

  # Submodules.
  local m
  for m in vendor/llama.cpp vendor/colibri; do
    if [[ -e "${LLMCTL_ROOT}/${m}/.git" ]]; then
      _doc_pass "submodule ${m} initialized ($(git -C "${LLMCTL_ROOT}/${m}" rev-parse --short HEAD 2>/dev/null || echo '?'))"
    else
      _doc_warn "submodule ${m} not initialized (run: llmctl build)"
    fi
  done

  # Catalog.
  if json_query "${LLMCTL_CATALOG}" 'len(d["profiles"])' >/dev/null 2>&1; then
    _doc_pass "catalog valid JSON ($(json_query "${LLMCTL_CATALOG}" 'len(d["profiles"])') profiles)"
  else
    _doc_fail "catalog invalid or missing: ${LLMCTL_CATALOG}"
  fi

  # State dirs writable.
  if ensure_state_dirs 2>/dev/null && [[ -w "${LLMCTL_STATE_DIR}" ]]; then
    _doc_pass "state dir writable: ${LLMCTL_STATE_DIR}"
  else
    _doc_fail "state dir not writable: ${LLMCTL_STATE_DIR}"
  fi

  # GPU tooling (informational).
  if have_cmd nvidia-smi; then
    _doc_pass "nvidia-smi present ($(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | paste -sd+ -))"
  elif [[ "${os}" == "macos" && "$(llmctl_arch)" == "arm64" ]]; then
    _doc_pass "Apple Silicon (unified memory GPU)"
  elif have_cmd rocm-smi; then
    _doc_pass "rocm-smi present"
  else
    _doc_warn "no GPU tooling detected - CPU-only inference"
  fi

  # Service backend.
  case "${os}" in
    linux)
      if have_cmd systemctl && systemctl --user list-units >/dev/null 2>&1; then
        _doc_pass "systemd --user session available"
      else
        _doc_warn "systemd --user not available in this session (services need a user systemd session; headless servers: sudo loginctl enable-linger <user>)"
      fi
      ;;
    macos)
      have_cmd launchctl && _doc_pass "launchctl available" || _doc_fail "launchctl missing on macOS?"
      ;;
  esac

  # Built engines.
  if [[ -x "${LLMCTL_ROOT}/vendor/llama.cpp/build/bin/llama-server" ]]; then
    _doc_pass "llama-server built"
  else
    _doc_warn "llama-server not built yet (llmctl build llama)"
  fi

  echo
  echo "doctor: ${DOCTOR_FAILS} failure(s), ${DOCTOR_WARNS} warning(s)"
  [[ "${DOCTOR_FAILS}" -eq 0 ]]
}
