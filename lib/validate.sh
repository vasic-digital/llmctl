#!/usr/bin/env bash
# validate.sh - deterministic model validation gate (`llmctl validate`, `llmctl vision validate`,
# `llmctl validate-all`, `llmctl require-validated`, and the post-start hook of start/auto/switch).
#
# Contract (operator mandate 2026-10-12): every model llmctl runs must pass a deterministic validation
# suite BEFORE any project or service uses it. A suite is a set of known-answer prompts (validation/
# suites/<name>/) judged by lib/validate_judge.py with normalised substring / ordered / forbidden /
# first-number / regex / JSON checks - never an LLM judging an LLM. The catalog names each profile's
# suites (`validation.suites`); a profile without one is never reported as validated.
#
# Documentation: docs/validation.md, section "Model validation gate". Tests: tests/test_vision_validate.sh,
# tests/test_validation_suites.sh, tests/test_validation_gate_defects.sh. No real-model run has been recorded yet
# (docs/qa/vision-validate-live-2026-10-12.md).
#
# Exit codes of validate / vision validate / validate-all: 0 every check passed; 1 any wrong result
# (never excused, never loosened); 2 could not determine (not downloaded, not served, endpoint down,
# insufficient resources, no suite). 1 outranks 2.
#
# State: $LLMCTL_STATE_DIR/validation/<profile>.json records status + model sha256 (catalog) + model file
# size/mtime + engine tag + launch fingerprint + per-suite content hash + timestamp. `require-validated`
# exits 0 only when that record is a PASS that still matches all of them and is younger than
# LLMCTL_VALIDATION_MAX_AGE seconds (default 604800 = 7 days).
set -euo pipefail

_val_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_val_dir}/common.sh"
# shellcheck source=catalog.sh
source "${_val_dir}/catalog.sh"

# Suite files carry regexes (regex_all / regex_none) that the judge compiles, so the suites directory is trusted
# input: the environment override is honoured ONLY when LLMCTL_VALIDATE_HERMETIC=1 (the test harness sets it).
if [[ -n "${LLMCTL_VALIDATION_SUITES_DIR:-}" && "${LLMCTL_VALIDATE_HERMETIC:-0}" != "1" ]]; then
  warn "LLMCTL_VALIDATION_SUITES_DIR ignored (set LLMCTL_VALIDATE_HERMETIC=1 to use a suites directory other than ${LLMCTL_ROOT}/validation/suites)"
  LLMCTL_VALIDATION_SUITES_DIR="${LLMCTL_ROOT}/validation/suites"
fi
LLMCTL_VALIDATION_SUITES_DIR="${LLMCTL_VALIDATION_SUITES_DIR:-${LLMCTL_ROOT}/validation/suites}"
LLMCTL_VALIDATION_MAX_AGE="${LLMCTL_VALIDATION_MAX_AGE:-604800}"

_val_judge() { python3 -I "${LLMCTL_ROOT}/lib/validate_judge.py" "$@"; }
_val_state_dir() { echo "${LLMCTL_STATE_DIR}/validation"; }
_val_state_file() { echo "$(_val_state_dir)/$1.json"; }

# _val_engine_tag <profile> - identity of the inference engine build that serves the profile.
_val_engine_tag() {
  local engine bin dir v
  engine="$(catalog_engine "$1")"
  case "${engine}" in
    llama)
      bin="${LLMCTL_LLAMA_SERVER:-${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server}"
      if [[ -x "${bin}" ]]; then
        dir="$(cd "$(dirname "${bin}")" && pwd)"
        v="$(LD_LIBRARY_PATH="${dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" "${bin}" --version 2>&1 \
              | grep -oE 'build [0-9]+, commit [0-9a-f]+' | head -1 || true)"
        echo "${v:-llama-server:unknown-version}"
      else
        echo "llama-server:not-built"
      fi ;;
    colibri) echo "colibri:$(git -C "${LLMCTL_ROOT}/submodules/colibri" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" ;;
    onnx)    echo "onnx:$(sha256sum "${LLMCTL_ROOT}/lib/onnx_server.py" 2>/dev/null | cut -c1-12 || echo unknown)" ;;
    *)       echo "${engine}:unknown" ;;
  esac
}

# _val_key <profile> <out-file> [only-kind] - current validation key (JSON) of the profile.
_val_key() {
  local p="$1" out="$2" kind="${3:-}"
  local env_file="${LLMCTL_SERVICES_DIR}/${p}.env"
  _val_judge key --catalog "${LLMCTL_CATALOG}" --profile "${p}" --models-dir "${LLMCTL_MODELS_DIR}" \
    --suites-dir "${LLMCTL_VALIDATION_SUITES_DIR}" --engine-tag "$(_val_engine_tag "${p}")" \
    --env-file "${env_file}" ${kind:+--only-kind "${kind}"} > "${out}"
}

# _val_suites <profile> [kind] - suites of the profile (one per line); none -> rc 1 + reason on stderr.
_val_suites() {
  local p="$1" kind="${2:-}"
  python3 -I - "${LLMCTL_CATALOG}" "${p}" "${LLMCTL_VALIDATION_SUITES_DIR}" "${kind}" <<'PY'
import json, os, sys
cat, p, sdir, kind = sys.argv[1:5]
prof = json.load(open(cat))["profiles"][p]
v = prof.get("validation") if isinstance(prof.get("validation"), dict) else {}
suites = v.get("suites") or []
if not suites:
    sys.stderr.write("no llmctl validation suite for profile '%s': %s\n" % (p, v.get("reason") or "catalog has no validation.suites"))
    sys.exit(1)
out = []
for s in suites:
    d = os.path.join(sdir, s)
    k = None
    for n in ("expectations.json", "suite.json"):
        if os.path.isfile(os.path.join(d, n)):
            k = json.load(open(os.path.join(d, n))).get("kind")
    if k is None:
        sys.stderr.write("validation suite '%s' named by profile '%s' does not exist in %s\n" % (s, p, sdir))
        sys.exit(1)
    if not kind or k == kind:
        out.append(s)
if not out:
    sys.stderr.write("profile '%s' has no '%s' validation suite (its suites: %s)\n" % (p, kind, ", ".join(suites)))
    sys.exit(1)
print("\n".join(out))
PY
}

# _val_instance_base <key> - for a scaled decision instance key (<profile>.<N>, N >= 2; lib/scheduler.sh
# _sched_scale_key) prints its base catalog profile, rc 0. Any other key (including every real catalog
# profile) -> rc 1. Instance keys have no catalog entry of their own, so they can never have a validation
# key or record; the base profile is the thing that is validated.
_val_instance_base() {
  local k="$1" base n
  [[ "${k}" =~ ^(.+)\.([0-9]+)$ ]] || return 1
  base="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
  (( 10#${n} >= 2 )) || return 1
  catalog_exists "${k}" && return 1
  catalog_exists "${base}" || return 1
  printf '%s\n' "${base}"
}

# _val_expect_model <profile> - the catalog model file name the endpoint must report.
_val_expect_model() {
  local name role
  while IFS='|' read -r name _ _ role; do
    [[ "${role}" != "mmproj" ]] && { echo "${name}"; return 0; }
  done < <(catalog_files "$1")
}

# _val_downloaded <profile> - every catalog file of the profile is present.
_val_downloaded() {
  local name
  while IFS='|' read -r name _ _ _; do
    [[ -f "${LLMCTL_MODELS_DIR}/$1/${name}" ]] || return 1
  done < <(catalog_files "$1")
}

# _val_port <profile> - port of a RUNNING profile (from its reservation), rc 1 when not running.
_val_port() {
  local f="${LLMCTL_RUNTIME_DIR}/$1.run" port
  if [[ ! -f "${f}" ]]; then
    # A unit started by systemd (boot, Restart=, restart) may have no reservation: lib/svc_hook.sh's waiter passes the
    # port of THE started unit so validation probes it instead of starting a second copy.
    # honoured ONLY with the matching profile marker (set together by the waiter): a stray exported port must never
    # redirect the probes of another profile
    [[ "${LLMCTL_VALIDATE_ATTACH_PROFILE:-}" == "$1" && "${LLMCTL_VALIDATE_ATTACH_PORT:-}" =~ ^[0-9]+$ ]] && { echo "${LLMCTL_VALIDATE_ATTACH_PORT}"; return 0; }
    return 1
  fi
  port="$(sed -n 's/^port=//p' "${f}" | head -1)"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  echo "${port}"
}

# _val_restore_traps <saved `trap -p` output> - drop ours, reinstate the caller's INT/TERM/HUP traps.
_val_restore_traps() {
  trap - INT TERM HUP
  if [[ -n "${1:-}" ]]; then eval "$1"; fi
}

# _val_pressure_gate <profile> [psi] - the host-pressure gate of the validation layer (hw_pressure_gate, rc 75 =
# refused). Without "psi" the footprint of the profile is included (a start is about to happen); with "psi" only the
# pressure test runs (the profile is already up; the probe loop is about to send requests). Prints ONE distinct
# message and returns 75 on refusal. A refusal is NOT a verdict: callers map it to exit 2 (UNDETERMINED) and never
# record it as a FAIL. Hosts/builds without the gate function are treated as "no gate" (rc 0).
_val_pressure_gate() {
  local p="$1" mode="${2:-}" rc=0
  declare -F hw_pressure_gate >/dev/null 2>&1 || return 0
  if declare -F _sched_pressure_gate >/dev/null 2>&1; then
    _sched_pressure_gate "${p}" ${mode:+"${mode}"} >/dev/null || rc=$?
  else
    hw_pressure_gate 0 "${p}" >/dev/null || rc=$?
  fi
  [[ "${rc}" -eq 0 ]] && return 0
  err "validation of '${p}' refused under memory pressure (hw_pressure_gate rc ${rc}): nothing was started or probed, nothing is recorded - UNDETERMINED (exit 2); retry when 'head -2 /proc/pressure/memory' is quiet"
  return 75
}

# validate_profile <profile> [--kind vision] [--host URL] [--json] [--keep]
# Runs every (or every <kind>) suite of the profile against its endpoint; prints per-probe verdicts with
# the model's raw answers; returns 0/1/2 (see header). With --host the endpoint is external: the result
# is printed and logged as evidence but never recorded as the local profile's validation state.
validate_profile() {
  local p="" kind="" host="" json=0 keep=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --kind)    kind="${2:?}"; shift 2 ;;
      --host)    [[ "$#" -ge 2 ]] || { err "--host needs a base URL (e.g. http://127.0.0.1:8082)"; return 2; }; host="$2"; shift 2 ;;
      --json)    json=1; shift ;;
      --keep)    keep=1; shift ;;
      --profile) p="${2:?}"; shift 2 ;;
      -*)        err "unknown validate option: $1"; return 2 ;;
      *)         [[ -z "${p}" ]] || { err "only one profile per validate call (got '${p}' and '$1')"; return 2; }; p="$1"; shift ;;
    esac
  done
  [[ -n "${p}" ]] || { err "usage: llmctl validate <profile> [--host URL] [--json]"; return 2; }
  catalog_exists "${p}" || { err "unknown profile: ${p} (see: llmctl models list)"; return 2; }
  ensure_state_dirs
  ensure_dir "$(_val_state_dir)"

  local suites
  suites="$(_val_suites "${p}" "${kind}")" || return 2

  local endpoint started=0 starting=0 jpid="" key_file="" saved_traps
  saved_traps="$(trap -p INT TERM HUP)"      # the caller's traps (e.g. scheduler lock cleanup) are restored on every return
  # Interrupt safety: SIGINT/SIGTERM/SIGHUP removes the temp key file, kills the judge child (by PID, never by
  # process group) and stops a profile THIS call started (unless --keep). The handler reads this function's
  # locals, so it is only ever armed while validate_profile is on the stack.
  _val_on_signal() {
    local code="$1"
    trap - INT TERM HUP
    [[ -n "${jpid}" ]] && kill "${jpid}" 2>/dev/null || true
    [[ -n "${key_file}" ]] && rm -f "${key_file}"
    [[ -n "${vfile:-}" ]] && rm -f "${vfile}"
    if [[ "${started}" == "1" || "${starting}" == "1" ]] && [[ "${keep}" != "1" ]]; then
      warn "interrupted: stopping '${p}' (it was started only for validation)"
      sched_stop "${p}" >/dev/null 2>&1 || true
    fi
    exit "${code}"
  }
  trap '_val_on_signal 130' INT
  trap '_val_on_signal 143' TERM
  trap '_val_on_signal 129' HUP
  if [[ -n "${host}" ]]; then
    endpoint="${host%/}"
    [[ "${json}" == "1" ]] || log "--host: external endpoint $(_val_judge redact "${endpoint}") - the result is evidence only, it is NOT recorded as '${p}' validation state"
  else
    local port
    if ! port="$(_val_port "${p}")"; then
      if ! _val_downloaded "${p}"; then
        err "profile '${p}' is not downloaded (run: llmctl models download ${p}) - cannot validate: could not determine"
        _val_restore_traps "${saved_traps}"
        return 2
      fi
      if ! _val_pressure_gate "${p}"; then
        _val_restore_traps "${saved_traps}"
        return 2
      fi
      log "profile '${p}' is not running - starting it through the scheduler (budget-checked) to validate it"
      starting=1
      if ! sched_start "${p}"; then
        starting=0
        err "could not start '${p}' (see above: insufficient RAM/VRAM or a start failure) - cannot validate: could not determine"
        _val_restore_traps "${saved_traps}"
        return 2
      fi
      started=1
      port="$(_val_port "${p}")" || { err "'${p}' started but has no port reservation"; _val_restore_traps "${saved_traps}"; return 2; }
    fi
    endpoint="http://127.0.0.1:${port}"
    # second gate: pressure may have risen while the model loaded; never hammer a model on a stalling host.
    if ! _val_pressure_gate "${p}" psi; then
      if [[ "${started}" == "1" && "${keep}" != "1" ]]; then
        warn "stopping '${p}' again (it was started only for validation)"
        sched_stop "${p}" >/dev/null 2>&1 || warn "could not stop '${p}'"
      fi
      _val_restore_traps "${saved_traps}"
      return 2
    fi
  fi

  local evidence; evidence="${LLMCTL_VERIFY_DIR}/validate-${p}.log"
  key_file="$(mktemp)"
  if ! _val_key "${p}" "${key_file}" "${kind}"; then
    err "cannot compute the validation key of '${p}' - cannot validate: could not determine"
    rm -f "${key_file}"; key_file=""
    _val_restore_traps "${saved_traps}"
    return 2
  fi
  # evidence may describe a protected endpoint: 0600, and the URL is logged without userinfo/query/fragment
  ( umask 077; : >> "${evidence}" ); chmod 600 "${evidence}"
  printf '\n==== %s llmctl validate %s endpoint=%s kind=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${p}" "$(_val_judge redact "${endpoint}")" "${kind:-all}" >> "${evidence}"
  printf 'KEY %s\n' "$(cat "${key_file}")" >> "${evidence}"

  local s rc=0 one worst=0 saw_undet=0 vfile=""
  for s in ${suites}; do
    one=0
    local -a jargs=(run --suite "${LLMCTL_VALIDATION_SUITES_DIR}/${s}" --endpoint "${endpoint}"
                    --expect-model "$(_val_expect_model "${p}")" --evidence "${evidence}")
    [[ "${json}" == "1" ]] && jargs+=(--json)
    vfile="$(mktemp)"; jargs+=(--verdict-file "${vfile}")
    # background + wait: bash runs a pending trap as soon as `wait` is interrupted (a foreground child would
    # delay the handler until it exits); the judge is killed by the handler by PID.
    # (the interpreter itself is the background job - a shell function would fork a subshell whose python
    # child the handler could not reach by PID)
    python3 -I "${LLMCTL_ROOT}/lib/validate_judge.py" "${jargs[@]}" & jpid=$!
    wait "${jpid}" || one=$?
    jpid=""
    # exit 1 counts as a FAIL ONLY together with the judge's explicit verdict: a crash (traceback, import error,
    # killed interpreter) also exits 1 and must be UNDETERMINED - a FAIL stops the model (docs/validation.md).
    if [[ "${one}" == "1" && "$(cat "${vfile}" 2>/dev/null)" != "FAIL" ]]; then
      warn "the judge exited 1 without an explicit 'VERDICT: FAIL' (crash?) - treated as UNDETERMINED, not as a wrong answer"
      one=2
    fi
    rm -f "${vfile}"; vfile=""
    case "${one}" in
      0) ;;
      1) worst=1 ;;
      *) saw_undet=1 ;;
    esac
  done
  if [[ "${worst}" == "1" ]]; then rc=1; elif [[ "${saw_undet}" == "1" ]]; then rc=2; else rc=0; fi

  if [[ -z "${host}" ]]; then
    local all_suites covered=1
    all_suites="$(_val_suites "${p}" 2>/dev/null || true)"
    [[ "${all_suites}" == "${suites}" ]] || covered=0
    local status=undetermined
    case "${rc}" in 0) status=pass ;; 1) status=fail ;; esac
    if [[ "${covered}" == "1" || "${status}" == "fail" ]]; then
      if ! _val_judge record --key "${key_file}" --status "${status}" --evidence "${evidence}" --out "$(_val_state_file "${p}")"; then
        err "could not record the validation state of '${p}' ($(_val_state_file "${p}")) - NOT validated"
        (( rc == 0 )) && rc=2
      fi
      [[ "${json}" == "1" ]] || log "validation state for '${p}': ${status} -> $(_val_state_file "${p}")"
    else
      [[ "${json}" == "1" ]] || log "only the '${kind}' suites ran; '${p}' also has $(tr '\n' ' ' <<<"${all_suites}")- run 'llmctl validate ${p}' to record its validation state"
    fi
  fi
  rm -f "${key_file}"; key_file=""
  [[ "${json}" == "1" ]] || log "evidence: ${evidence}"
  if [[ "${started}" == "1" && "${keep}" != "1" ]]; then
    log "stopping '${p}' again (it was started only for validation; pass --keep to leave it running)"
    sched_stop "${p}" >/dev/null || warn "could not stop '${p}' after validation"
  fi
  _val_restore_traps "${saved_traps}"
  return "${rc}"
}

# _validate_cli <validate args...> - the `llmctl validate` entry. Exit 1 means exactly "the judge gave a wrong answer":
# validate_profile returns 1 only from an explicit verdict, and an abnormal exit of the shell (die(), set -e, a failed
# source) is mapped to 2 (UNDETERMINED) by an EXIT trap - callers (the systemd waiter) stop a model on exit 1.
_val_cli_done=0
_validate_cli() {
  local rc=0
  _val_cli_done=0
  trap '[[ "${_val_cli_done}" == "1" ]] || { trap - EXIT; exit 2; }' EXIT
  validate_profile "$@" || rc=$?
  _val_cli_done=1
  trap - EXIT
  # a caller that STOPS a model on a wrong answer (the systemd waiter) asks for a private FAIL code: a plain exit 1 of
  # the llmctl process (startup crash, set -e) is then not mistaken for a verdict
  if [[ "${rc}" == "1" && "${LLMCTL_VALIDATE_FAIL_RC:-}" =~ ^[0-9]+$ ]]; then rc="${LLMCTL_VALIDATE_FAIL_RC}"; fi
  return "${rc}"
}

# require_validated <profile> - 0 only when the profile has a FRESH passing validation record.
require_validated() {
  [[ "$#" -eq 1 ]] || { err "usage: llmctl require-validated <profile>"; return 2; }
  local p="$1" key_file rc=0 why
  catalog_exists "${p}" || { err "unknown profile: ${p}"; return 2; }
  key_file="$(mktemp)"
  if ! _val_key "${p}" "${key_file}"; then
    rm -f "${key_file}"
    err "cannot compute the validation key of '${p}' - not validated (could not determine)"
    return 2
  fi
  why="$(_val_judge check --state "$(_val_state_file "${p}")" --key "${key_file}" --max-age "${LLMCTL_VALIDATION_MAX_AGE}")" || rc=$?
  rm -f "${key_file}"
  if [[ "${rc}" == "0" ]]; then
    info "${p}: ${why}"
    return 0
  fi
  err "profile '${p}' is NOT validated for use:"
  printf '  - %s\n' "${why//$'\n'/$'\n'  - }" >&2
  err "run: llmctl validate ${p}"
  return 1
}

# validate_all - validate every RUNNING profile; aggregate exit code (1 > 2 > 0); nothing running -> 2.
validate_all() {
  local p rc=0 one worst=0 undet=0 n=0
  local -a verdicts=()
  ensure_dir "${LLMCTL_RUNTIME_DIR}"
  for p in $(for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do [[ -e "${f}" ]] && basename "${f}" .run; done); do
    if _val_instance_base "${p}" >/dev/null; then
      info "validate-all: '${p}' is a scaled instance of '$(_val_instance_base "${p}")' - covered by its base profile"
      continue
    fi
    n=$((n+1))
    one=0
    validate_profile "${p}" "$@" || one=$?
    case "${one}" in
      0) verdicts+=("${p}: PASS") ;;
      1) verdicts+=("${p}: FAIL"); worst=1 ;;
      *) verdicts+=("${p}: UNDETERMINED"); undet=1 ;;
    esac
  done
  if [[ "${n}" == "0" ]]; then
    err "validate-all: no running profile to validate (start one first) - could not determine"
    return 2
  fi
  bold "validate-all summary"
  printf '  %s\n' "${verdicts[@]}"
  if [[ "${worst}" == "1" ]]; then rc=1; elif [[ "${undet}" == "1" ]]; then rc=2; fi
  return "${rc}"
}

# _val_after_start_one <profile> - one profile of validate_after_start (called under the per-profile validation lock):
# freshness check, validation, and the verdict policy (FAIL -> stop; UNDETERMINED -> keep, or stop in strict mode).
# Returns 1 when the profile failed validation / was stopped, else 0.
_val_after_start_one() {
  local p="$1" rc=0 one key_file base
  [[ -f "${LLMCTL_RUNTIME_DIR}/${p}.run" ]] || return 0
  if base="$(_val_instance_base "${p}")"; then
    info "validation: '${p}' is a scaled instance of '${base}' (no catalog entry of its own) - skipped; its validation state is that of '${base}' (llmctl require-validated ${base})"
    return 0
  fi
  key_file="$(mktemp)"
  if ! _val_key "${p}" "${key_file}"; then
    rm -f "${key_file}"
    warn "validation: '${p}' has no computable validation key (not a catalog profile?) - UNDETERMINED; llmctl require-validated ${p} refuses"
    return 0
  fi
  if _val_judge check --state "$(_val_state_file "${p}")" --key "${key_file}" --max-age "${LLMCTL_VALIDATION_MAX_AGE}" >/dev/null 2>&1; then
    info "validation: '${p}' already has a fresh passing record for this model, engine, launch and suite"
    rm -f "${key_file}"
    return 0
  fi
  rm -f "${key_file}"
  log "validation: running the deterministic validation suite(s) of '${p}' before it is used"
  one=0
  validate_profile "${p}" || one=$?
  case "${one}" in
    0) info "validation: '${p}' PASSED" ;;
    1) err "validation: '${p}' gave WRONG answers (validation FAILED) - stopping it through the normal stop path; it is NOT left running (evidence: ${LLMCTL_VERIFY_DIR}/validate-${p}.log)"
       _val_stop_after_verdict "${p}"
       rc=1 ;;
    *) if [[ "${LLMCTL_VALIDATE_STRICT:-0}" == "1" ]]; then
         err "validation: '${p}' could not be validated (UNDETERMINED) and LLMCTL_VALIDATE_STRICT=1 - stopping it (no validation suite / no answer / refused is not good enough in strict mode)"
         _val_stop_after_verdict "${p}"
         rc=1
       else
         warn "validation: '${p}' could not be validated (UNDETERMINED) - it keeps running, NOT validated; llmctl require-validated ${p} refuses until it passes (LLMCTL_VALIDATE_STRICT=1 would stop it)"
       fi ;;
  esac
  return "${rc}"
}

# _val_stop_after_verdict <profile> - the stop half of the gate: sched_stop (-> svc_stop, reservation removed).
# Callers run OUTSIDE the scheduler lock (sched_stop takes it itself).
_val_stop_after_verdict() {
  sched_stop "$1" || warn "validation: could not stop '$1' - stop it by hand: llmctl stop $1"
}

# validate_after_start <profile...> - post-start hook for start/switch/auto/enable/restart. Runs each running
# profile's suites unless a fresh passing record already covers it (OUTSIDE the scheduler lock).
#   PASS (0)         -> keeps running.
#   FAIL (1)         -> STOPPED through sched_stop, the hook returns 1 (non-zero exit of the command).
#   UNDETERMINED (2) -> never stopped, never a PASS, reported loudly - unless LLMCTL_VALIDATE_STRICT=1, which stops
#                       it and returns 1 (no suite / no answer / refused under pressure is then not good enough).
validate_after_start() {
  if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]]; then
    log "validation not run (LLMCTL_DRY_RUN=1): nothing was started, so there is nothing to validate"
    return 0
  fi
  if [[ "${LLMCTL_VALIDATE_ON_START:-1}" == "0" ]]; then
    warn "validation on start disabled (LLMCTL_VALIDATE_ON_START=0): $* NOT validated - 'llmctl require-validated' will refuse until 'llmctl validate' passes"
    return 0
  fi
  local p rc=0 one lockfd lf
  for p in "$@"; do
    [[ -f "${LLMCTL_RUNTIME_DIR}/${p}.run" ]] || continue
    # per-profile validation lock (NOT the scheduler lock): `enable`/`restart` are also validated by the systemd waiter
    # (lib/svc_hook.sh) - the second validator waits for the first and then finds its fresh record (docs/validation.md)
    lf="${LLMCTL_RUNTIME_DIR}/.validate-${p}.lock"
    exec {lockfd}>"${lf}"
    if ! flock -w "${LLMCTL_VALIDATE_LOCK_WAIT:-900}" "${lockfd}"; then
      exec {lockfd}>&-
      warn "validation: '${p}' is being validated by another process and did not finish within ${LLMCTL_VALIDATE_LOCK_WAIT:-900}s - UNDETERMINED here (nothing stopped)"
      continue
    fi
    one=0
    _val_after_start_one "${p}" || one=$?
    flock -u "${lockfd}"; exec {lockfd}>&-
    [[ "${one}" == "0" ]] || rc=1
  done
  return "${rc}"
}

# _val_run_snapshot - "<key> <started_epoch>" per reservation file in LLMCTL_RUNTIME_DIR (sorted).
_val_run_snapshot() {
  local f k e
  for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do
    [[ -e "${f}" ]] || continue
    k="$(basename "${f}" .run)"
    e="$(sed -n 's/^started_epoch=//p' "${f}" | head -1)"
    printf '%s %s\n' "${k}" "${e:-0}"
  done | sort
}

# validate_auto <auto args...> - `llmctl auto` followed by the validation hook for ONLY the profiles that
# auto started (a key that was absent before, or whose started_epoch changed = restarted). Profiles that
# were already running and untouched (e.g. the decision/colibri services) are not its business.
validate_auto() {
  local before after
  before="$(_val_run_snapshot)"
  sched_auto "$@"
  after="$(_val_run_snapshot)"
  local -a started=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && started+=("${line%% *}")
  done < <(comm -13 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}"))
  validate_after_start ${started[@]+"${started[@]}"}
}

# models_verify_gate <profile> [--live] - the `llmctl models verify` hook: the profile should name an
# existing validation suite (schema gate); with --live (or when it is running) the suite is also run.
# A profile that names NO suite: without --live it warns (loudly: "NOT validated") and returns 0 - the exit
# code of `models verify` stays the checksum verdict; with --live it returns 2 (cannot validate).
models_verify_gate() {
  local p="$1" live="${2:-}"
  local suites
  if ! suites="$(_val_suites "${p}" 2>&1)"; then
    if [[ "${live}" == "--live" ]]; then err "${suites}"; return 2; fi
    warn "${suites}"
    warn "'${p}' checksums were verified above, but it is NOT validated: it names no validation suite (exit 0 = checksums only; llmctl require-validated ${p} refuses)"
    return 0
  fi
  info "validation suites for '${p}': $(tr '\n' ' ' <<<"${suites}")"
  if [[ "${live}" == "--live" || -f "${LLMCTL_RUNTIME_DIR}/${p}.run" ]]; then
    validate_profile "${p}"
    return
  fi
  log "live validation NOT run ('${p}' is not running; run 'llmctl validate ${p}' or 'llmctl models verify ${p} --live')"
}

# cmd_vision <sub> ... - `llmctl vision validate [--profile vision|vision-pro] [--host URL] [--json] [--keep]`
cmd_vision() {
  local sub="${1:-help}"
  [[ "$#" -gt 0 ]] && shift
  case "${sub}" in
    validate)
      local p="vision" a
      local -a rest=()
      while [[ "$#" -gt 0 ]]; do
        a="$1"
        case "${a}" in
          --profile) [[ "$#" -ge 2 ]] || { err "--profile needs a value"; return 2; }; p="$2"; shift 2 ;;
          --host)    [[ "$#" -ge 2 ]] || { err "--host needs a base URL"; return 2; }; rest+=(--host "$2"); shift 2 ;;
          --json|--keep) rest+=("${a}"); shift ;;
          *) err "unknown 'vision validate' option: ${a}"; err "usage: llmctl vision validate [--profile vision|vision-pro] [--host URL] [--json] [--keep]"; return 2 ;;
        esac
      done
      validate_profile "${p}" --kind vision ${rest[@]+"${rest[@]}"}
      ;;
    help|-h|--help)
      cat <<'EOF'
llmctl vision validate [--profile vision|vision-pro] [--host URL] [--json] [--keep]
  Runs the golden screenshots of validation/suites/vision-golden-v1 through the profile's llama-server
  (temperature 0, seed 42, top_k 1) and judges every answer deterministically against the expectation
  file. Starts the profile first when it is downloaded but not running (and stops it afterwards unless
  --keep). --host validates an explicit endpoint (evidence only, never recorded as local state).
  Exit: 0 all pass, 1 any wrong result, 2 could not determine.
EOF
      ;;
    *) err "unknown vision subcommand: ${sub} (validate)"; return 2 ;;
  esac
}
