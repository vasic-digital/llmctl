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
# shellcheck source=portreg.sh
source "${_doc_dir}/portreg.sh"

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

# Decision-gateway prerequisites (T082, FR-032). Every line is prefixed "decide:". Skipped silently
# when llmctl-decide is not built (portreg_bin already WARNed about that above). The API key VALUE is
# never read into output, only its presence and file mode.
_doc_decide_checks() {
  local bin; bin="$(portreg_bin 2>/dev/null)" || return 0
  local home="${LLMCTL_HOME:-${HOME}/llmctl}"
  local envf="${LLMCTL_ENV_FILE:-${LLMCTL_ROOT}/.env}"

  # API key file: presence + mode.
  local keyval=""
  if [[ -f "${envf}" ]]; then
    keyval="$(sed -n 's/^LLMCTL_API_KEY=//p' "${envf}" 2>/dev/null | tail -n1 | tr -d "'\" \t\r")"
  fi
  if [[ -n "${keyval}" ]]; then
    local m; m="$(stat -c %a "${envf}" 2>/dev/null || stat -f %Lp "${envf}" 2>/dev/null || echo '?')"
    if [[ "${m}" =~ ^[0-7]00$ ]]; then
      _doc_pass "decide: API key present in ${envf} (mode ${m})"
    else
      _doc_fail "decide: API key file ${envf} is mode ${m} (want 600; fix: chmod 600 '${envf}')"
    fi
  elif [[ -n "${LLMCTL_API_KEY:-}" ]]; then
    _doc_pass "decide: API key supplied via the environment"
  else
    _doc_warn "decide: no API key yet in ${envf} (the gateway generates one on first 'serve')"
  fi

  # Certificate: delegate to the real `cert doctor` (key match, expiry, chain, SAN drift, modes).
  if [[ -d "${home}/cert" ]]; then
    local line st name detail cout crc=0 nparsed=0 nfail=0
    cout="$("${bin}" cert --home "${home}" doctor 2>&1)" || crc=$?
    while IFS= read -r line; do
      st="${line%% *}"; line="${line#"${st}"}"; line="${line#"${line%%[![:space:]]*}"}"
      name="${line%% *}"; detail="${line#"${name}"}"; detail="${detail#"${detail%%[![:space:]]*}"}"
      case "${st}" in
        OK|ok)     nparsed=$((nparsed+1)); _doc_pass "decide: certificate ${name} - ${detail}" ;;
        WARN|warn) nparsed=$((nparsed+1)); _doc_warn "decide: certificate ${name} - ${detail}" ;;
        FAIL|fail) nparsed=$((nparsed+1)); nfail=$((nfail+1)); _doc_fail "decide: certificate ${name} - ${detail}" ;;
      esac
    done <<< "${cout}"
    if [[ "${nparsed}" -eq 0 || ( "${crc}" -ne 0 && "${nfail}" -eq 0 ) ]]; then
      _doc_fail "decide: certificate doctor failed (exit ${crc}): $(printf '%s' "${cout}" | head -c 300 | paste -sd' ' -)"
    fi
  else
    _doc_warn "decide: no gateway certificate under ${home}/cert (created on first 'serve' or: llmctl-decide cert ensure)"
  fi

  # Private venv for the onnx engine (import checks follow below).
  if [[ -x "${LLMCTL_DATA_DIR}/venv-onnx/bin/python" ]]; then
    _doc_pass "decide: private venv ${LLMCTL_DATA_DIR}/venv-onnx present"
  else
    _doc_warn "decide: private venv ${LLMCTL_DATA_DIR}/venv-onnx absent (only needed for onnx encoder profiles: llmctl build onnx)"
  fi

  # Engine HTTPS: the engine must accept --ssl-key-file for the TLS-to-engine hop.
  local ls="${LLMCTL_LLAMA_SERVER_BIN:-${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server}"
  if [[ -x "${ls}" ]]; then
    local lhelp; lhelp="$("${ls}" --help 2>&1 || true)"
    if [[ "${lhelp}" == *--ssl-key-file* ]]; then
      _doc_pass "decide: engine HTTPS supported (${ls} accepts --ssl-key-file)"
    else
      _doc_warn "decide: engine HTTPS not supported by ${ls} (no --ssl-key-file; rebuild with SSL: llmctl build llama)"
    fi
  else
    _doc_warn "decide: engine HTTPS unknown - llama-server not built (llmctl build llama)"
  fi

  # T138: per-profile x question-type maturity of every decision profile, read from the catalog (the same
  # derived block /v1/models and `llmctl plan` use). All three types measured above baseline -> PASS;
  # anything else (experimental | unmeasured) -> WARN naming the types, never a silent PASS.
  local matout
  if matout="$(json_query "${LLMCTL_CATALOG}" '"\n".join(
      ("%s %s %s" % (n, "|".join("%s=%s" % (t, ((p.get("maturity") or {}).get(t) or {}).get("status", "unmeasured")) for t in ("noul", "choice", "score")),
                     ",".join(t for t in ("noul", "choice", "score") if ((p.get("maturity") or {}).get(t) or {}).get("status", "unmeasured") != "measured")))
      for n, p in sorted(d["profiles"].items(), key=lambda kv: kv[1].get("port", 0)) if "decide" in p.get("capability", []))' 2>/dev/null)"; then
    local mline mname mrest mtypes mexp
    while IFS= read -r mline; do
      [[ -n "${mline}" ]] || continue
      mname="${mline%% *}"; mrest="${mline#* }"; mtypes="${mrest%% *}"; mexp="${mrest#* }"
      [[ "${mrest}" == *" "* ]] || mexp=""
      mtypes="${mtypes//|/ }"
      if [[ -z "${mexp}" ]]; then
        _doc_pass "decide: maturity ${mname}: ${mtypes}"
      else
        _doc_warn "decide: maturity ${mname}: ${mtypes} (experimental: ${mexp//,/, })"
      fi
    done <<< "${matout}"
  fi

  # Gateway port: free, or already served by our own running gateway.
  local port="${LLMCTL_DECIDE_PORT:-8095}"
  local gstat gpid=""
  if gstat="$("${bin}" serve --status 2>/dev/null)"; then
    gpid="$(printf '%s' "${gstat}" | sed -n 's/.*running pid \([0-9][0-9]*\).*/\1/p')"
    if ! have_cmd ss || [[ -z "${gpid}" ]]; then
      _doc_warn "decide: gateway is running but its listening port cannot be verified (ss or pid unavailable)"
    elif ss -ltnpH "sport = :${port}" 2>/dev/null | grep -q "pid=${gpid},"; then
      _doc_pass "decide: gateway port ${port} served by the running llmctl gateway (pid ${gpid})"
    else
      _doc_warn "decide: gateway pid ${gpid} is not listening on port ${port} (configured LLMCTL_DECIDE_PORT=${port}; it was started on another port: restart it or fix the setting)"
    fi
  elif python3 -c 'import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError: sys.exit(1)' "${port}" 2>/dev/null; then
    _doc_pass "decide: gateway port ${port} is free"
  else
    _doc_warn "decide: gateway port ${port} is in use by another process (set LLMCTL_DECIDE_PORT or stop it)"
  fi

  # Firewall / bind note.
  local bind="${LLMCTL_DECIDE_BIND:-${LLMCTL_BIND_HOST:-0.0.0.0}}"
  case "${bind}" in
    127.*|::1|localhost) _doc_pass "decide: gateway binds loopback only (${bind}); no firewall exposure" ;;
    *) _doc_warn "decide: gateway binds ${bind} (reachable from the network): put a firewall allow-list or reverse proxy in front, see docs/cloud-exposure.md" ;;
  esac
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
  for m in submodules/llama.cpp submodules/colibri; do
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
  if [[ -x "${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server" ]]; then
    _doc_pass "llama-server built"
  else
    _doc_warn "llama-server not built yet (llmctl build llama)"
  fi

  # Port allocator / service registry (FR-088..FR-091). Only meaningful when
  # the llmctl-decide binary exists; WARN (never FAIL) when it is absent so a
  # plain chat-only install keeps a clean report. When active, the registry
  # rows MUST equal the live service set - a row without a live service, or a
  # live service without a row, is a defect (FR-089).
  if declare -F portreg_bin >/dev/null 2>&1; then
    if portreg_bin >/dev/null 2>&1; then
      local _doc_reg_out
      if declare -F sched_load_backend >/dev/null 2>&1; then sched_load_backend 2>/dev/null || true; fi
      if ! portreg_active; then
        _doc_pass "service registry check skipped (adapter off: dry run or LLMCTL_PORTREG=0)"
      elif _doc_reg_out="$(portreg_diff_report 2>&1)"; then
        _doc_pass "service registry == live service set (${_doc_reg_out})"
      else
        _doc_fail "service registry differs from the live service set: $(printf '%s' "${_doc_reg_out}" | paste -sd';' -) (fix: llmctl-decide registry reconcile)"
      fi
    else
      _doc_warn "llmctl-decide not built - dynamic ports and the service registry are unavailable (llmctl build decide)"
    fi
  fi

  # Registry rows that stay "unknown" (an https service with no CA to verify it against) are never
  # removed by default (a missing CA is not proof the service is gone, G-068); they pile up until a
  # CA appears or the operator opts in to forgetting them (G-074).
  if declare -F portreg_active >/dev/null 2>&1 && portreg_active 2>/dev/null; then
    local _doc_unknown
    _doc_unknown="$("$(portreg_bin)" registry list --json 2>/dev/null | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin).get("services", [])
except Exception:
    rows = []
u = [r["name"] + " (since " + r["unknown_since"] + ")" for r in rows if r.get("unknown_since")]
print("; ".join(u))' 2>/dev/null || true)"
    if [[ -n "${_doc_unknown}" ]]; then
      _doc_warn "registry rows that cannot be certified (https, no CA found): ${_doc_unknown} - set LLMCTL_CACERT, or forget them with: llmctl-decide registry reconcile --prune-unknown-after 24h"
    fi
  fi

  _doc_decide_checks

  # Units installed by an earlier llmctl keep their old body until `llmctl install` is re-run
  # (G-067: StartLimitIntervalSec in [Service] is ignored by systemd).
  if declare -F sched_load_backend >/dev/null 2>&1; then sched_load_backend 2>/dev/null || true; fi
  if declare -F svc_stale_units >/dev/null 2>&1; then
    local _doc_stale
    _doc_stale="$(svc_stale_units 2>/dev/null | paste -sd';' - || true)"
    if [[ -n "${_doc_stale}" ]]; then
      _doc_warn "stale service unit(s): ${_doc_stale}"
    fi
  fi

  # onnx engine (encoder decision profiles, e.g. decide-nli): WARN not FAIL
  # when the python deps are missing - the llama decision path (decide-tiny/
  # decide/decide-pro/decide-2b/decide-max) remains fully functional without
  # them, and the onnx runner dies with a clear message at launch anyway.
  local _doc_onnx_py="${LLMCTL_DATA_DIR}/venv-onnx/bin/python"
  [[ -x "${_doc_onnx_py}" ]] || _doc_onnx_py="python3"
  if "${_doc_onnx_py}" -B -c 'import onnxruntime' 2>/dev/null; then
    _doc_pass "onnx: onnxruntime importable (${_doc_onnx_py})"
  else
    _doc_warn "onnx: onnxruntime NOT importable - decide-nli (onnx engine) cannot run real inference (run: llmctl build onnx - hash-locked private venv; llama decision profiles are unaffected)"
  fi
  if "${_doc_onnx_py}" -B -c 'import sentencepiece' 2>/dev/null; then
    _doc_pass "onnx: sentencepiece importable"
  else
    _doc_warn "onnx: sentencepiece NOT importable - DeBERTa-class spm.model tokenizers need it (run: llmctl build onnx; llama decision profiles are unaffected)"
  fi

  # Cluster mode (optional): only relevant when the operator enables llmctld.
  # Never a FAIL for single-host use — these are informational SKIP/WARN only.
  if have_cmd curl; then
    if curl --version 2>/dev/null | grep -qiE '(^| )HTTP3( |$)'; then
      _doc_pass "curl supports HTTP/3 - llmctld client calls can use --http3"
    else
      _doc_warn "curl lacks HTTP/3 (Features: $(curl --version 2>/dev/null | awk -F': ' '/^Features/{print $2}')) - llmctl cluster commands will use HTTP/2 against llmctld (llmctld itself always serves both)"
    fi
  fi
  if have_cmd go; then
    _doc_pass "go toolchain available ($(go version 2>/dev/null | awk '{print $3}')) - can build llmctld from source (make llmctld-build)"
  else
    _doc_warn "go not installed - only needed to build the opt-in llmctld cluster daemon; single-host llmctl is unaffected"
  fi

  echo
  echo "doctor: ${DOCTOR_FAILS} failure(s), ${DOCTOR_WARNS} warning(s)"
  [[ "${DOCTOR_FAILS}" -eq 0 ]]
}
