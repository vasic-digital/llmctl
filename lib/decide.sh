#!/usr/bin/env bash
# decide.sh - THIN bash front end of llmctl's typed-decision commands.
#
# All decision logic lives in the Go binary `llmctl-decide` (cmd/llmctl-decide,
# internal/client, internal/server, internal/gateway). This file only
#   * locates that binary (decide_bin),
#   * delegates `ask`, `batch`, `models`, `serve`, `key`, `cert` (and the other
#     Go subcommands) to it, passing every argument through unchanged - the
#     state is NEVER put on a command line by this file (use --state-file /
#     --stdin; N-01), and the access key is never read here (the Go client
#     resolves it, FR-058),
#   * keeps the two read-only reports that need the shell libraries
#     (`capacity` = the planner's decision_instances, `status`),
#   * keeps the interactive wizard (a thin prompter over `decide ask`).
#
# The Python gateway/test-seam path of the candidate is gone: there is no
# backend host/port override, no fake-model flag and no second credential
# variable in this file (D-02, D-03, D-05, D-11, D-29). Trust is the CA file
# only; there is no switch that disables certificate verification (FR-068).
# The post-download decision smoke of lib/download.sh runs `llmctl-decide smoke`
# (the production Go driver) - the former shell/Python prompt/logprob helpers
# were retired with the Python gateway (history: CHANGELOG, docs/decide-gateway.md).
#
# Environment (${VAR:-default} convention, same as the other libs):
#   LLMCTL_DECIDE_BIN            path of the llmctl-decide binary
#                                (default: ${LLMCTL_DECIDE_BUILD_OUT:-$LLMCTL_ROOT/build/llmctl-decide};
#                                built by `llmctl build decide` when absent and Go exists)
#   LLMCTL_API_KEY / LLMCTL_ENV_FILE / LLMCTL_HOME / LLMCTL_CACERT / LLMCTL_ENDPOINT /
#   LLMCTL_DECIDE_PORT ...       read by the Go binary (see docs/decision-models.md)
#   LLMCTL_DECIDE_NO_INTERACTIVE if 1, the wizard errors instead of prompting
#   LLMCTL_DECIDE_PROFILE        wizard default profile (the client sends no profile otherwise)
#
# Source-order note: lib/download.sh's decision smoke calls decide_bin from this
# file; bash resolves functions at call time and both files are sourced at CLI
# startup, so this is safe.
set -euo pipefail

_decide_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_decide_dir}/common.sh"
# shellcheck source=catalog.sh
source "${_decide_dir}/catalog.sh"
# shellcheck source=decide_timeout.sh
source "${_decide_dir}/decide_timeout.sh"

LLMCTL_DECIDE_PORT="${LLMCTL_DECIDE_PORT:-8095}"
LLMCTL_DECIDE_NO_INTERACTIVE="${LLMCTL_DECIDE_NO_INTERACTIVE:-0}"
LLMCTL_DECIDE_TIMEOUT="${LLMCTL_DECIDE_TIMEOUT:-30}"

decide_usage() {
  cat <<'EOF'
llmctl decide - typed decisions (noul/choice/score) against the local decision gateway

USAGE
  llmctl decide ask --type {noul|choice|score} (--state TEXT | --state-file F | --stdin)
        --instructions I [--criteria JSON | --criteria-file F] [--profile P]
        [--endpoint URL] [--cacert F] [--json] [--explain] [--dry-run]
        [--min-confidence X] [--retries N] [--timeout SEC]
  llmctl decide ask --question-file F (--state-file F | --stdin | --state TEXT) [...]
  llmctl decide batch [--in FILE|-] [--out FILE|-] [--profile P] [--min-confidence X]
                                newline-delimited JSON in/out
  llmctl decide models [--json]     models the gateway serves
  llmctl decide smoke --url URL --protocol letter-logit|nli-onnx|systemone-native
        [--key-file F] [--options N] [--expect-choice KEY] [--json]
                                one deterministic question against ONE engine (exit 0 only for a
                                valid typed answer; 1 backend failure, 2 usage, 6 unreachable)
  llmctl decide capacity [--json]   parallel-instance plan per decision profile
  llmctl decide status [--json]     profiles, gateway and registry state
  llmctl decide interactive [--profile P] [--type T] [--state S] ...
                                wizard (TTY, or --interactive for piped stdin)
  llmctl decide serve [--foreground] [--status] [--stop] [--bind H] [--port N]
                                HTTPS gateway (POST /v1/systemone, default port 8095)
  llmctl decide serve --enable [--now] | --disable
                                install+enable+start (or stop+disable+remove) the gateway as a boot-time
                                user service (systemd user unit / launchd agent); idempotent; refuses while
                                an installed engine unit is stale (fix: llmctl install)
  llmctl decide scale <profile> <N>  start/stop instances of one decision profile until N run
                                (admission-bounded; refusal exit 3 with exact numbers)
  llmctl decide calibrate --profile P --labels F [--method temperature|platt|isotonic]
        [--catalog F] [--state-dir D] [--model-sha H] [--template-hash H] [--unbound] [--dry-run] [--json]
                                accuracy +- Wilson interval, baseline, ECE/MCE/Brier over labelled answers
                                (CSV or scripts/golden/run_golden.py JSON); fits the method and writes a
                                calibration profile bound to the model sha256 + template hash (0600,
                                atomic). Below 200 labels: report only, "insufficient for ECE", no profile.
  llmctl decide probe-order --questions F [--profile P] [--permute K] [--state-file F] [--json]
                                re-ask each choice question with its options in K cyclic orders; prints
                                the answer-flip rate and per-position bias (K calls per request)
  llmctl decide completions {bash|zsh}
                                shell completion script for the real commands and flags
                                  eval "$(llmctl decide completions bash)"
                                  source <(llmctl decide completions zsh)   # after compinit
  llmctl decide key ...             access key management (doctor|show|path|rotate|export)
  llmctl decide cert ...            certificate management (ensure|show|export|renew|doctor)
  llmctl decide help                this help

EXIT CODES
  0 ok   1 backend/readout failure   2 usage error   4 access-key problem
  5 certificate/TLS problem   6 gateway not ready / unreachable   10 abstained

CRITERIA SHAPES
  noul    optional {"true": "desc of yes", "false": "desc of no"}
  choice  required {"option-key": "description", ...} (2..20 options, hard cap 26)
  score   required ["level 0 desc", "level 1 desc", ...] (2..10 levels, ordered)

EXAMPLES
  llmctl decide ask --type noul --state "Arithmetic facts." --instructions "Is 2+2=4?"
  llmctl decide ask --type choice --state-file ticket.txt --instructions "Which team?" \
      --criteria '{"billing":"handles invoices","legal":"contracts"}' --json
  cat big.log | llmctl decide ask --type noul --stdin --instructions "Any errors?"
  llmctl auto decide                pick the best fitting decision profile
EOF
}

# ---------------------------------------------------------------- binary lookup

# _decide_bin_path - prints where the binary is expected (no checks).
_decide_bin_path() {
  if [[ -n "${LLMCTL_DECIDE_BIN:-}" ]]; then
    printf '%s\n' "${LLMCTL_DECIDE_BIN}"
  else
    printf '%s\n' "${LLMCTL_DECIDE_BUILD_OUT:-${LLMCTL_ROOT}/build/llmctl-decide}"
  fi
}

# _decide_bin_quiet - prints the binary path when it exists and is executable;
# never builds, never prints diagnostics (used by `status`, which tolerates absence).
_decide_bin_quiet() {
  local bin
  bin="$(_decide_bin_path)"
  [[ -f "${bin}" && -x "${bin}" ]] || return 1
  printf '%s\n' "${bin}"
}

# decide_bin - prints the path of the llmctl-decide binary. An explicit
# LLMCTL_DECIDE_BIN must be usable (never silently replaced). Otherwise the
# default build output is used; when it is absent and Go is installed, it is
# built once with `llmctl build decide`; when Go is missing the error says
# exactly what to run. Returns 1 on any failure (never 3).
decide_bin() {
  local bin
  bin="$(_decide_bin_path)"
  if [[ -f "${bin}" && -x "${bin}" ]]; then
    printf '%s\n' "${bin}"
    return 0
  fi
  if [[ -n "${LLMCTL_DECIDE_BIN:-}" ]]; then
    err "LLMCTL_DECIDE_BIN=${LLMCTL_DECIDE_BIN} is not an executable file; fix the path or unset it to use ${LLMCTL_ROOT}/build/llmctl-decide"
    return 1
  fi
  if ! command -v go >/dev/null 2>&1; then
    err "the decision binary ${bin} is missing and Go is not installed. Install Go (https://go.dev/dl/) and run: llmctl build decide  - or copy a prebuilt llmctl-decide to ${bin} (or set LLMCTL_DECIDE_BIN)"
    return 1
  fi
  log "building the decision binary (llmctl build decide) -> ${bin}" >&2
  if ! "${LLMCTL_ROOT}/bin/llmctl" build decide >&2; then
    err "building the decision binary failed; run 'llmctl build decide' to see why"
    return 1
  fi
  if [[ ! -f "${bin}" || ! -x "${bin}" ]]; then
    err "'llmctl build decide' finished but ${bin} was not created; set LLMCTL_DECIDE_BUILD_OUT/LLMCTL_DECIDE_BIN consistently"
    return 1
  fi
  printf '%s\n' "${bin}"
}

# _decide_exec <subcommand> [args...] - runs the Go binary, returns its exit
# code unchanged (0/1/2/4/5/6/10 per contracts/cli.md). Arguments are passed
# through verbatim; the state never travels on a command line from this file.
_decide_exec() {
  local bin rc=0
  bin="$(decide_bin)" || return 1
  "${bin}" "$@" || rc=$?
  return "${rc}"
}

# ---------------------------------------------------------------- delegated commands

# decide_ask <flags...> - the Go client. `--interactive` is the wizard's
# sanctioned activation path (handled here, not by the client).
decide_ask() {
  local a wiz=0 rest=()
  for a in "$@"; do
    if [[ "${a}" == "--interactive" ]]; then wiz=1; else rest+=("${a}"); fi
  done
  if [[ "${wiz}" == "1" ]]; then
    decide_interactive --interactive ${rest[@]+"${rest[@]}"}
    return $?
  fi
  _decide_exec ask ${rest[@]+"${rest[@]}"}
}

decide_batch()  { _decide_exec batch "$@"; }
decide_models() { _decide_exec models "$@"; }
decide_key()    { _decide_exec key "$@"; }
decide_cert()   { _decide_exec cert "$@"; }

# decide_serve [flags...] - the Go gateway lifecycle (start/--foreground/--status/--stop) plus the boot-time
# service front end (--enable [--now] / --disable, handled here: the unit/agent logic is the service backend's
# decide_service_enable/disable in lib/service_linux.sh / lib/service_macos.sh).
# LLMCTL_DRY_RUN=1 prints the command line (or the service-manager commands) and starts/changes nothing.
decide_serve() {
  local a enable=0 disable=0 now=0 other=0
  for a in "$@"; do
    case "${a}" in
      --enable)  enable=1 ;;
      --disable) disable=1 ;;
      --now)     now=1 ;;
      *)         other=1 ;;
    esac
  done
  if (( enable || disable || now )); then
    if (( enable && disable )); then err "decide serve: --enable and --disable are mutually exclusive"; return 2; fi
    if (( ! enable && ! disable )); then err "decide serve: --now only applies to --enable"; return 2; fi
    if (( disable && now )); then err "decide serve: --now only applies to --enable"; return 2; fi
    if (( other )); then
      err "decide serve: --enable/--disable take no other flag (set port/bind in ${LLMCTL_STATE_DIR}/decide/gateway.conf); --now is optional and means start immediately"
      return 2
    fi
    decide_serve_service "$([[ "${enable}" == 1 ]] && echo enable || echo disable)"
    return $?
  fi
  if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]]; then
    printf 'DRY-RUN: %s serve %s\n' "$(_decide_bin_path)" "$*"
    return 0
  fi
  # G-156: CPU-placed decision engines get a larger documented deadline unless one is set explicitly.
  decide_timeout_adapt
  _decide_exec serve "$@"
}

# decide_serve_service enable|disable - install/enable/start (or stop/disable/remove) the gateway as a boot-time
# user service (systemd user unit on Linux, launchd agent on macOS). Idempotent. `enable` starts the service
# right away (--now is accepted as the explicit spelling of that default); it refuses while an installed engine
# unit template is stale, with the same message style as the restart-bound refusal of `llmctl enable`.
decide_serve_service() {
  local op="$1" stale
  sched_load_backend
  if [[ "${op}" == "enable" ]]; then
    stale="$(svc_stale_units 2>/dev/null | grep -v '^llmctl-decide-gateway\.service:' || true)"
    if [[ -n "${stale}" ]]; then
      err "refusing to enable the decision gateway service: an installed unit predates the current generator ($(printf '%s' "${stale}" | paste -sd';' - | sed 's/;/; /g')). Regenerate the units with: llmctl install"
      return 1
    fi
    decide_service_enable
  else
    decide_service_disable
  fi
}

# decide_scale <profile> <N> - start/stop instances of one decision profile until N run (admission-bounded,
# refusal exit 3 with exact numbers). The logic lives in the scheduler (lib/scheduler.sh sched_decision_scale),
# the one place that owns budgets, reservations and service keys; this is only the front-end entry.
decide_scale() { sched_decision_scale "$@"; }

# The ONE list of Go subcommands the front end forwards verbatim (those with their own wrapper -
# ask batch models key cert serve - are handled in cmd_decide). tests/test_decide_cli.sh compares it
# with the commands the binary registers, so a new Go subcommand cannot be silently unreachable.
_DECIDE_FORWARDED="calibrate probe-order schema completions registry port discover smoke mcp vantage"
_decide_is_forwarded() {
  local w
  for w in ${_DECIDE_FORWARDED}; do [[ "$1" == "${w}" ]] && return 0; done
  return 1
}

# decide_passthrough <subcommand> [flags...] - any other Go subcommand
# (scale, calibrate, probe-order, schema, completions, registry, port, discover).
decide_passthrough() { _decide_exec "$@"; }

# decide_capacity [--json] - wraps hw_probe_json | catalog_plan_json's
# decision_instances subtree (single source of truth for the budgets).
decide_capacity() {
  local as_json=0
  case "${1:-}" in
    "") ;;
    --json) as_json=1 ;;
    *) err "decide capacity: unknown argument: $1 (usage: llmctl decide capacity [--json])"; return 2 ;;
  esac
  [[ "$#" -le 1 ]] || { err "decide capacity: unexpected extra argument: $2"; return 2; }
  local plan
  plan="$(hw_probe_json | catalog_plan_json)"
  if [[ "${as_json}" == "1" ]]; then
    printf '%s' "${plan}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({"tier": d["tier"], "budgets": d["budgets"],
                  "decision_instances": d["decision_instances"]}, indent=2))
'
    return 0
  fi
  LLMCTL_PLAN_DOC="${plan}" python3 - <<'PYEOF'
import json, os
plan = json.loads(os.environ["LLMCTL_PLAN_DOC"])
b = plan["budgets"]
print("Host tier: %s   RAM budget %d MiB, VRAM budget %d MiB" % (plan["tier"], b["ram_mb"], b["vram_mb"]))
print("%-14s %-8s %-14s %-14s %-15s %-18s %s" %
      ("profile", "tier-ok", "gpu-instances", "cpu-instances", "slots/instance", "ram/instance", "detail"))
for name, r in sorted(plan.get("decision_instances", {}).items()):
    gated = "reason" in r and "tier gate" in r["reason"]
    if r["instances_gpu"] == 0 and r["instances_cpu"] == 0 and "reason" in r:
        detail = r["reason"]
    else:
        detail = "VRAM %d MiB/instance" % r["per_instance"]["vram_mb"] if r["per_instance"]["vram_mb"] else ""
    print("%-14s %-8s %-14s %-14s %-15s %-18s %s" %
          (name, "no" if gated else "yes", r["instances_gpu"], r["instances_cpu"],
           r["per_instance"]["slots"], "%d MiB" % r["per_instance"]["ram_mb"], detail))
PYEOF
}

# decide_status [--json] - decision profiles (scheduler view), gateway state and
# registry rows. The gateway/registry parts come from the Go binary when it
# exists and are reported as unavailable otherwise (never an error).
decide_status() {
  local as_json=0
  case "${1:-}" in
    "") ;;
    --json) as_json=1 ;;
    *) err "decide status: unknown argument: $1 (usage: llmctl decide status [--json])"; return 2 ;;
  esac
  [[ "$#" -le 1 ]] || { err "decide status: unexpected extra argument: $2"; return 2; }
  local rows="" p port running enabled
  for p in $(catalog_profiles); do
    case " $(catalog_capability "${p}") " in *" decide "*) ;; *) continue ;; esac
    port="$(catalog_port "${p}")"
    if sched_is_running "${p}"; then running="yes"; else running="no"; fi
    if sched_is_enabled "${p}"; then enabled="yes"; else enabled="no"; fi
    rows+="${p}"$'\t'"${port}"$'\t'"${running}"$'\t'"${enabled}"$'\n'
  done
  local bin gw_text="" gw_rc="" reg_json=""
  if bin="$(_decide_bin_quiet)"; then
    gw_rc=0
    gw_text="$("${bin}" serve --status 2>&1)" || gw_rc=$?
    reg_json="$("${bin}" discover --json 2>/dev/null)" || reg_json=""
  fi
  if [[ "${as_json}" == "1" ]]; then
    LLMCTL_ROWS="${rows}" LLMCTL_GW_TEXT="${gw_text}" LLMCTL_GW_RC="${gw_rc}" LLMCTL_REG_JSON="${reg_json}" python3 -c '
import json, os
profiles = []
for line in os.environ["LLMCTL_ROWS"].splitlines():
    if not line:
        continue
    p, port, running, enabled = line.split("\t")
    profiles.append({"profile": p, "port": int(port),
                     "running": running == "yes", "enabled": enabled == "yes"})
rc = os.environ["LLMCTL_GW_RC"]
gateway = ({"available": False} if rc == "" else
           {"available": True, "running": rc == "0", "detail": os.environ["LLMCTL_GW_TEXT"]})
reg = os.environ["LLMCTL_REG_JSON"]
try:
    registry = json.loads(reg) if reg else None
except ValueError:
    registry = None
print(json.dumps({"profiles": profiles, "gateway": gateway, "registry": registry}, indent=2))
'
    return 0
  fi
  if [[ -z "${rows}" ]]; then
    echo "no decision profiles in catalog"
  else
    printf '%-16s %-6s %-8s %-8s\n' "profile" "port" "running" "enabled"
    local rprofile rport rrunning renabled
    while IFS=$'\t' read -r rprofile rport rrunning renabled; do
      [[ -n "${rprofile}" ]] || continue
      printf '%-16s %-6s %-8s %-8s\n' "${rprofile}" "${rport}" "${rrunning}" "${renabled}"
    done <<< "${rows}"
  fi
  if [[ -n "${gw_rc}" ]]; then
    printf '\n%s\n' "${gw_text}"
    if [[ -n "${reg_json}" ]]; then
      printf '\nregistry:\n'
      "${bin}" discover 2>/dev/null || true
    fi
  else
    printf '\n(gateway/registry state unavailable: the llmctl-decide binary is not built; run: llmctl build decide)\n'
  fi
  return 0
}

# _decide_profile_downloaded <profile> - engine-aware on-disk check:
# llama profiles carry a non-empty .gguf; onnx profiles carry a non-empty
# model.onnx (top-level or under onnx/).
_decide_profile_downloaded() {
  local p="$1"
  [[ -d "${LLMCTL_MODELS_DIR}/${p}" ]] || return 1
  case "$(catalog_engine "${p}" 2>/dev/null || echo llama)" in
    onnx)
      [[ -s "${LLMCTL_MODELS_DIR}/${p}/model.onnx" ]] && return 0
      [[ -s "${LLMCTL_MODELS_DIR}/${p}/onnx/model.onnx" ]] && return 0
      return 1
      ;;
    *)
      find "${LLMCTL_MODELS_DIR}/${p}" -name '*.gguf' -size +0 2>/dev/null | grep -q .
      ;;
  esac
}

# _decide_downloaded_profiles - decide-capable profiles that have a non-empty
# .gguf (or model.onnx) on disk, one per line. Falls back to ALL decide-capable
# profiles when none are downloaded (so the wizard can still offer a name).
_decide_downloaded_profiles() {
  local p any_downloaded=1
  for p in $(catalog_profiles); do
    case " $(catalog_capability "${p}") " in *" decide "*) ;; *) continue ;; esac
    if _decide_profile_downloaded "${p}"; then
      printf '%s\n' "${p}"
      any_downloaded=0
    fi
  done
  if [[ "${any_downloaded}" == "1" ]]; then
    for p in $(catalog_profiles); do
      case " $(catalog_capability "${p}") " in *" decide "*) printf '%s\n' "${p}" ;; esac
    done
  fi
}

# _decide_read <var> <prompt> - prompt on STDERR (so it is visible with piped
# stdin too - N-09), read one line into <var>. Returns 1 at end of input
# without data (N-06); a final line without newline still counts.
_decide_read() {
  local __line=""
  printf '%s' "$2" >&2
  IFS= read -r __line || [[ -n "${__line}" ]] || return 1
  printf -v "$1" '%s' "${__line}"
}

# _decide_eof <what> - the one end-of-input diagnostic of the wizard.
_decide_eof() {
  err "decide interactive: end of input while waiting for: $1 (give it as a flag, or run on a terminal)"
  return 2
}

# decide_interactive [--profile P] [--type T] [--state S] [--state-file F]
#                    [--instructions I] [--criteria JSON] [--interactive]
# Interactive wizard (design §2.4): a THIN PROMPTER over decide_ask - it
# contains no decision logic of its own. Every step has a flag/env
# equivalent (the flags above, plus LLMCTL_DECIDE_PROFILE); any step given
# via flag/env is never prompted for. All prompts go to STDERR (printf, not
# `read -p`, so they appear with piped stdin too); stdout stays
# machine-pipeable: only the final JSON lands there. End of input at any
# prompt is rc 2 with a message, never a silent exit. Bash >= 3.2 portable.
#
# Activation (enforced here AND by cmd_decide/dispatch):
#   - explicit `llmctl decide interactive` subcommand on a TTY;
#   - `--interactive` flag (allows piped stdin, e.g. scripted heredocs);
#   - bare `llmctl decide` on a TTY (dispatched from cmd_decide);
#   - non-TTY stdin WITHOUT --interactive -> rc 2 with a clear error;
#   - LLMCTL_DECIDE_NO_INTERACTIVE=1 -> always rc 2.
decide_interactive() {
  local profile="${LLMCTL_DECIDE_PROFILE:-}" type="" state="" state_file=""
  local instructions="" criteria="" force=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --profile)      [[ "$#" -ge 2 ]] || { err "decide interactive: --profile needs a value"; return 2; }
                      profile="$2"; shift 2 ;;
      --type)         [[ "$#" -ge 2 ]] || { err "decide interactive: --type needs a value"; return 2; }
                      type="$2"; shift 2 ;;
      --state)        [[ "$#" -ge 2 ]] || { err "decide interactive: --state needs a value"; return 2; }
                      state="$2"; shift 2 ;;
      --state-file)   [[ "$#" -ge 2 ]] || { err "decide interactive: --state-file needs a value"; return 2; }
                      state_file="$2"; shift 2 ;;
      --instructions) [[ "$#" -ge 2 ]] || { err "decide interactive: --instructions needs a value"; return 2; }
                      instructions="$2"; shift 2 ;;
      --criteria)     [[ "$#" -ge 2 ]] || { err "decide interactive: --criteria needs a value"; return 2; }
                      criteria="$2"; shift 2 ;;
      --interactive)  force=1; shift ;;
      *)              err "decide interactive: unknown flag: $1"; return 2 ;;
    esac
  done

  if [[ "${LLMCTL_DECIDE_NO_INTERACTIVE}" == "1" ]]; then
    err "decide interactive: interactive mode disabled (LLMCTL_DECIDE_NO_INTERACTIVE=1); use 'llmctl decide ask ...' flags"
    return 2
  fi
  if [[ "${force}" != "1" && ! -t 0 ]]; then
    err "decide: interactive mode requires a TTY; use 'llmctl decide ask ...' flags or --interactive"
    return 2
  fi

  # --- step 1: profile (numbered list of downloaded decide profiles) -------
  if [[ -z "${profile}" ]]; then
    local plist="" p idx=1 pick=""
    printf 'Decision profiles:\n' >&2
    for p in $(_decide_downloaded_profiles); do
      printf '  %d) %s\n' "${idx}" "${p}" >&2
      plist+="${idx}:${p}"$'\n'
      idx=$((idx + 1))
    done
    _decide_read pick "Profile [gateway default]: " || { _decide_eof "profile"; return 2; }
    if [[ -n "${pick}" ]]; then
      profile="$(printf '%s' "${plist}" | awk -F: -v n="${pick}" '$1 == n {print $2}')"
      [[ -n "${profile}" ]] || { err "decide interactive: invalid selection: ${pick}"; return 2; }
    fi
  fi

  # --- step 2: type ---------------------------------------------------------
  if [[ -z "${type}" ]]; then
    _decide_read type "Type (noul/choice/score) [noul]: " || { _decide_eof "type"; return 2; }
    [[ -n "${type}" ]] || type="noul"
  fi
  case "${type}" in noul|choice|score) ;; *)
    err "decide interactive: unknown type '${type}' (noul|choice|score)"; return 2 ;; esac

  # --- step 3: state (multi-line until a lone '.'; end of input also ends it) --
  if [[ -n "${state_file}" && -z "${state}" ]]; then
    [[ -r "${state_file}" ]] || { err "decide interactive: cannot read --state-file: ${state_file}"; return 2; }
    state="$(cat "${state_file}")"
  fi
  if [[ -z "${state}" ]]; then
    printf 'State (multi-line; end with a single "." on its own line):\n' >&2
    local line=""
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" == "." ]] && break
      state+="${line}"$'\n'
      line=""
    done
    state="${state%$'\n'}"
  fi
  [[ -n "${state}" ]] || { err "decide interactive: state is required"; return 2; }

  # --- step 4: instructions (one line) --------------------------------------
  if [[ -z "${instructions}" ]]; then
    _decide_read instructions "Instructions (the question to answer): " || { _decide_eof "instructions"; return 2; }
  fi
  [[ -n "${instructions}" ]] || { err "decide interactive: instructions are required"; return 2; }

  # --- step 5: criteria ------------------------------------------------------
  if [[ -z "${criteria}" ]]; then
    case "${type}" in
      choice)
        printf 'Options as "key = description", one per line; empty line to finish:\n' >&2
        local pairs="" kv=""
        while IFS= read -r kv || [[ -n "${kv}" ]]; do
          [[ -z "${kv}" ]] && break
          case "${kv}" in
            *=*) ;; *) err "decide interactive: option line must be 'key = description': ${kv}"; return 2 ;;
          esac
          pairs+="${kv}"$'\n'
          kv=""
        done
        [[ -n "${pairs}" ]] || { err "decide interactive: choice needs at least 2 options"; return 2; }
        criteria="$(LLMCTL_DECIDE_PAIRS="${pairs}" python3 -c '
import json, os
opts = {}
for line in os.environ["LLMCTL_DECIDE_PAIRS"].splitlines():
    if not line:
        continue
    key, desc = line.split("=", 1)
    opts[key.strip()] = desc.strip()
print(json.dumps(opts))
')" || return 2
        ;;
      score)
        printf 'Score levels in order (worst first), one per line, 2-10 levels; empty line to finish:\n' >&2
        local levels="" lv=""
        while IFS= read -r lv || [[ -n "${lv}" ]]; do
          [[ -z "${lv}" ]] && break
          levels+="${lv}"$'\n'
          lv=""
        done
        criteria="$(LLMCTL_DECIDE_LEVELS="${levels}" python3 -c '
import json, os
levels = [l for l in os.environ["LLMCTL_DECIDE_LEVELS"].splitlines() if l]
if not (2 <= len(levels) <= 10):
    raise SystemExit("decide: score needs 2-10 levels")
print(json.dumps(levels))
')" || { err "decide interactive: score needs 2-10 levels"; return 2; }
        ;;
      noul)
        local tdesc="" fdesc=""
        _decide_read tdesc "Description for 'yes' (optional): " || { _decide_eof "the 'yes' description"; return 2; }
        _decide_read fdesc "Description for 'no' (optional): " || { _decide_eof "the 'no' description"; return 2; }
        if [[ -n "${tdesc}" || -n "${fdesc}" ]]; then
          criteria="$(LLMCTL_DECIDE_TRUE="${tdesc}" LLMCTL_DECIDE_FALSE="${fdesc}" python3 -c '
import json, os
print(json.dumps({"true": os.environ["LLMCTL_DECIDE_TRUE"],
                  "false": os.environ["LLMCTL_DECIDE_FALSE"]}))
')"
        fi
        ;;
    esac
  fi

  # --- step 6: confirmation ---------------------------------------------------
  {
    printf '\nAbout to ask:\n'
    printf '  profile:      %s\n' "${profile:-<gateway default>}"
    printf '  type:         %s\n' "${type}"
    printf '  state:        %.200s%s\n' "${state}" "$([[ ${#state} -gt 200 ]] && printf '...')"
    printf '  instructions: %s\n' "${instructions}"
    printf '  criteria:     %s\n' "${criteria:-<none>}"
  } >&2
  local proceed=""
  _decide_read proceed "Proceed? [Y/n] " || { _decide_eof "the confirmation"; return 2; }
  case "${proceed}" in
    ""|y|Y|yes|YES) ;;
    *) printf 'decide interactive: aborted\n' >&2; return 0 ;;
  esac

  # --- step 7: run the SAME ask path (state travels on stdin, never argv) ------
  local args=(--type "${type}" --instructions "${instructions}" --stdin --json)
  [[ -n "${profile}" ]] && args+=(--profile "${profile}")
  [[ -n "${criteria}" ]] && args+=(--criteria "${criteria}")
  local out rc=0
  out="$(printf '%s' "${state}" | _decide_exec ask "${args[@]}")" || rc=$?
  # exit 10 (abstained) still carries a JSON answer; every other non-zero is a failure
  if [[ "${rc}" -ne 0 && "${rc}" -ne 10 ]]; then
    return "${rc}"
  fi
  printf '%s\n' "${out}"
  # Human rendering on stderr (stdout stays machine-pipeable).
  printf '%s' "${out}" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
for name, a in d.get("answers", {}).items():
    t = a.get("type")
    if t == "noul":
        print("answer: %s (p(yes)=%.3f)" % ("yes" if a["noul"] >= 0.5 else "no", a["noul"]), file=sys.stderr)
    elif t == "choice":
        print("answer: %s (confidence %.3f)" % (a["choice"], a.get("confidence", 0.0)), file=sys.stderr)
    elif t == "score":
        print("answer: score %.3f (confidence %.3f)" % (a["score"], a.get("confidence", 0.0)), file=sys.stderr)
' || true
  return "${rc}"
}

cmd_decide() {
  local sub="${1:-}"
  [[ "$#" -gt 0 ]] && shift
  case "${sub}" in
    ask)         decide_ask "$@" ;;
    batch)       decide_batch "$@" ;;
    models)      decide_models "$@" ;;
    capacity)    decide_capacity "$@" ;;
    status)      decide_status "$@" ;;
    interactive) decide_interactive "$@" ;;
    serve)       decide_serve "$@" ;;
    key)         decide_key "$@" ;;
    cert)        decide_cert "$@" ;;
    scale)       decide_scale "$@" ;;
    help|-h|--help) decide_usage ;;
    "")
      # Bare 'llmctl decide': the interactive wizard is the TTY intent;
      # non-TTY stays strictly non-interactive.
      if [[ -t 0 && -t 1 ]]; then
        decide_interactive
      else
        err "decide: missing subcommand (ask|batch|models|capacity|status|interactive|serve|key|cert|scale|calibrate|probe-order|completions|help)"
        return 2
      fi
      ;;
    *)
      if _decide_is_forwarded "${sub}"; then
        decide_passthrough "${sub}" "$@"
        return $?
      fi
      err "unknown decide subcommand: ${sub} (ask|batch|models|capacity|status|interactive|serve|key|cert|scale|calibrate|probe-order|completions|help)"
      return 2
      ;;
  esac
}
