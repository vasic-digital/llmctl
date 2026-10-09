#!/usr/bin/env bash
# decide_timeout.sh - launcher-side, CPU-adaptive default for the decision gateway's per-request
# deadline (gap G-156). Sourced by lib/svc_hook.sh (run-gateway: the systemd unit / launchd agent) and
# lib/decide.sh (decide_serve: `llmctl decide serve`), the two ways the gateway is launched.
#
# Why: the Go default LLMCTL_DECIDE_TIMEOUT is 8 s - deliberately below the hosted SDK's 10 s timeout
# (internal/server/limits.go, docs/decide-gateway.md, specs/009-jev-decision-models/contracts/env-vars.md) -
# and that contract does NOT change. But a decision engine placed on CPU (llama.cpp --n-gpu-layers 0)
# answers in 7-22 s on the measured reference host (nezha.local, 8 threads:
# decide-pro median 7.6 s / max 21.0 s, decide-max median 13.3 s / max 22.0 s), so with the 8 s default
# 45 of 132 golden requests came back HTTP 502 deadline_exceeded; with LLMCTL_DECIDE_TIMEOUT=300 the
# same host answered 131/132 with no 502 (specs/009-jev-decision-models/evidence/live-models/
# nezha-pinned-decide-pro-default8s-control-2026-10-09 vs nezha-pinned-decide-pro-2026-10-09).
#
# The CPU-only onnx NLI encoder (decide-nli) deliberately does NOT trigger the rule: measured on CPU it answers
# in median 433 ms / p95 1585 ms / max 2837 ms (evidence/live-models/nezha-pinned-decide-nli-2026-10-09), well
# inside 8 s, and counting it would raise the global deadline to 120 s on every GPU host that merely runs the
# encoder.
#
# Rule (decide_timeout_adapt): when LLMCTL_DECIDE_TIMEOUT is NOT in the environment AND at least one
# decision instance that is running or enabled has a CPU-only placement, export
#   LLMCTL_DECIDE_TIMEOUT=120               (about 5 x the slowest measured llama CPU answer, 22 s)
#   LLMCTL_DECIDE_TIMEOUT_SOURCE=cpu-adaptive
#   LLMCTL_DECIDE_TIMEOUT_NOTE=<profiles>   (space-separated CPU-placed profiles, for the banner)
# An explicit LLMCTL_DECIDE_TIMEOUT (environment, systemd EnvironmentFile gateway.conf, plist env) always
# wins and is left untouched (an inherited SOURCE/NOTE is dropped so the banner cannot mislabel it). A pure-GPU
# host exports nothing, so the Go default (8 s) applies. The deadline is ONE global value: a single CPU llama
# instance raises it for ALL profiles, including GPU ones (a wedged GPU engine is then cut off at 120 s, not 8 s).
#
# Recognised CPU placements (llama engine, in the instance's LLMCTL_ARGS): the layer-offload flag in any of
# --n-gpu-layers N | --n-gpu-layers=N | --gpu-layers N | --gpu-layers=N | -ngl N | -ngl=N whose value is 0
# (leading zeros allowed). When the flag is repeated the LAST occurrence wins (llama.cpp semantics). Any value
# above 0 (partial offload) or no flag at all counts as not-CPU.
# The gateway start-up banner prints the effective value and its source (default | cpu-adaptive | env).
#
# The decision is taken at gateway start from the instance records ($LLMCTL_SERVICES_DIR/*.env, written by
# svc_write_env, persistent across reboots) - not from the tmpfs reservations alone - so a gateway that
# boots before any llmctl command still sees the placement. An instance started AFTER the gateway does not
# change a running gateway: restart it (documented in docs/decide-gateway.md).
#
# Needs: common.sh (LLMCTL_SERVICES_DIR / LLMCTL_RUNTIME_DIR).

set -euo pipefail

LLMCTL_DECIDE_TIMEOUT_CPU_DEFAULT=120

# _dta_get <env-file> <KEY> - value of KEY (raw, first match), empty when absent.
_dta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1 || true; }

# _dta_is_cpu <engine> <args-line> - 0 when the instance is a llama.cpp engine with layer offload 0 (see header).
_dta_is_cpu() {
  local engine="$1" args="$2" val="" want=0 t
  [[ "${engine}" == "onnx" ]] && return 1   # the NLI encoder never triggers (see header)
  local -a toks=()
  read -r -a toks <<<"${args}" || true
  for t in ${toks[@]+"${toks[@]}"}; do
    if ((want)); then val="${t}"; want=0; continue; fi
    case "${t}" in
      --n-gpu-layers|--gpu-layers|-ngl) want=1 ;;
      --n-gpu-layers=*) val="${t#*=}" ;;
      --gpu-layers=*) val="${t#*=}" ;;
      -ngl=*) val="${t#*=}" ;;
    esac
  done
  [[ "${val}" =~ ^0+$ ]]
}

# decide_timeout_adapt - see the header. Always returns 0; exports at most the three variables above.
decide_timeout_adapt() {
  # Display-only companions are ours to set: never trust an inherited value (it would mislabel an explicit one).
  unset LLMCTL_DECIDE_TIMEOUT_SOURCE LLMCTL_DECIDE_TIMEOUT_NOTE
  # printenv, not ${VAR+x}: lib/decide.sh assigns a non-exported shell default for its own client, and
  # only what the gateway would actually INHERIT counts as explicit.
  if [[ -n "$(printenv LLMCTL_DECIDE_TIMEOUT 2>/dev/null || true)" ]]; then
    return 0
  fi
  local sdir="${LLMCTL_SERVICES_DIR:-}" rdir="${LLMCTL_RUNTIME_DIR:-}" f inst base kind engine args profile
  [[ -n "${sdir}" && -d "${sdir}" ]] || return 0
  local notes=""
  for f in "${sdir}"/*.env; do
    [[ -e "${f}" ]] || continue
    inst="$(basename "${f}" .env)"
    kind="$(_dta_get "${f}" LLMCTL_REG_KIND | tr -d "'\"")"
    [[ "${kind}" == "decide" ]] || continue
    base="${inst%%.*}"
    # served = running (reservation) or enabled (autostart marker): a stale record of a stopped,
    # never-enabled instance must not widen the deadline.
    if [[ ! -f "${rdir}/${inst}.run" && ! -f "${sdir}/${inst}.enabled" && ! -f "${sdir}/${base}.enabled" ]]; then
      continue
    fi
    engine="$(_dta_get "${f}" LLMCTL_ENGINE | tr -d "'\"")"
    args="$(_dta_get "${f}" LLMCTL_ARGS)"
    _dta_is_cpu "${engine}" "${args}" || continue
    profile="$(_dta_get "${f}" LLMCTL_REG_PROFILE | tr -d "'\"")"
    [[ -n "${profile}" ]] || profile="${base}"
    case " ${notes} " in *" ${profile} "*) ;; *) notes+="${notes:+ }${profile}" ;; esac
  done
  [[ -n "${notes}" ]] || return 0
  export LLMCTL_DECIDE_TIMEOUT="${LLMCTL_DECIDE_TIMEOUT_CPU_DEFAULT}"
  export LLMCTL_DECIDE_TIMEOUT_SOURCE="cpu-adaptive"
  export LLMCTL_DECIDE_TIMEOUT_NOTE="${notes}"
  return 0
}
