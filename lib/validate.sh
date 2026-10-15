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
# Documentation: docs/validation.md, section "Model validation gate". Tests: tests/test_validation_*.sh, tests/test_vision_validate.sh,
# tests/test_gate_wiring_*.sh. Real-model runs on record (docs/qa/): `vision` and `small` on the authoring host and a --host run on a second
# host, all made with the judge BEFORE the 2026-10-14 fix round (their suites changed since, so none of their records is current); colibri
# and decide-* profiles have never been run against their real model.
#
# Exit codes of validate / vision validate / validate-all: 0 every check passed; 1 any wrong result
# (never excused, never loosened); 2 could not determine (not downloaded, not served, endpoint down,
# insufficient resources, no suite, suite defect, quick mode). 1 outranks 2.
#
# State: $LLMCTL_STATE_DIR/validation/<profile>.json - a SIGNED record (HMAC-SHA256, key .hmac.key 0600) of the status, the real sha256
# of every model file (= its catalog pin), engine tag, launch fingerprint, per-suite content hash, machine id (hashed), the probed
# process's model file, the repeat count and the sha256 of the run's own evidence file. `require-validated` exits 0 only when that record
# verifies, is a PASS that matches all of them now and is younger than LLMCTL_VALIDATION_MAX_AGE whole seconds (default 604800 = 7 days).
# ENFORCEMENT (strict by default): a profile without such a record is never served - see "ENFORCEMENT" below and lib/scheduler.sh.
set -euo pipefail

_val_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_val_dir}/common.sh"
# shellcheck source=catalog.sh
source "${_val_dir}/catalog.sh"

# LLMCTL_VALIDATE_HERMETIC counts only inside the test harness (lib/common.sh validation_hermetic; finding 9 of the
# 2026-10-15 review): otherwise it is reset here, so neither this process nor the judge / llmctl children it starts
# honour a test-only override or relaxation.
if [[ "${LLMCTL_VALIDATE_HERMETIC:-0}" == "1" ]] && ! validation_hermetic; then
  warn "LLMCTL_VALIDATE_HERMETIC=1 ignored: it is honoured only inside the llmctl test harness (no ${LLMCTL_STATE_DIR}/.test-harness)"
  export LLMCTL_VALIDATE_HERMETIC=0
fi
# Suite files carry regexes (regex_all / regex_none) that the judge compiles, so the suites directory is trusted
# input: the environment override is honoured ONLY inside the test harness (validation_hermetic).
if [[ -n "${LLMCTL_VALIDATION_SUITES_DIR:-}" ]] && ! validation_hermetic; then
  warn "LLMCTL_VALIDATION_SUITES_DIR ignored (set LLMCTL_VALIDATE_HERMETIC=1 to use a suites directory other than ${LLMCTL_ROOT}/validation/suites)"
  LLMCTL_VALIDATION_SUITES_DIR="${LLMCTL_ROOT}/validation/suites"
fi
LLMCTL_VALIDATION_SUITES_DIR="${LLMCTL_VALIDATION_SUITES_DIR:-${LLMCTL_ROOT}/validation/suites}"
LLMCTL_VALIDATION_MAX_AGE="${LLMCTL_VALIDATION_MAX_AGE:-604800}"

_val_judge() { python3 -I "${LLMCTL_ROOT}/lib/validate_judge.py" "$@"; }
_val_state_dir() { echo "${LLMCTL_STATE_DIR}/validation"; }
_val_state_file() { echo "$(_val_state_dir)/$1.json"; }
# record signing key + model-file sha256 cache (both 0600, created by the judge on first use; docs/validation.md)
_val_hmac_key() { echo "$(_val_state_dir)/.hmac.key"; }
_val_hash_cache() { echo "$(_val_state_dir)/.hashcache.json"; }
# 0700 also for a directory created by an older llmctl (finding 11 of the 2026-10-15 review): records, evidence and the signing key
_val_ensure_state_dir() {
  [[ -d "$(_val_state_dir)" ]] || ( umask 077; mkdir -p "$(_val_state_dir)" )
  [[ -O "$(_val_state_dir)" ]] && chmod 700 "$(_val_state_dir)" 2>/dev/null
  return 0
}

# _val_max_age - LLMCTL_VALIDATION_MAX_AGE as whole seconds >= 0 on stdout; anything else (nan, inf, -1, 1e9, abc) -> a
# message and rc 2: a non-finite age would make every record "fresh" forever.
# The maximum is 400 days (34560000 s; finding 11 of the 2026-10-15 review: a 12-digit value made every record "fresh" for
# millennia).
_val_max_age() {
  local a="${LLMCTL_VALIDATION_MAX_AGE}"
  if [[ "${a}" =~ ^[0-9]{1,8}$ ]] && (( 10#${a} <= 34560000 )); then echo "$(( 10#${a} ))"; return 0; fi
  err "LLMCTL_VALIDATION_MAX_AGE='${a}' is not a whole number of seconds between 0 and 34560000 (400 days; nan, inf, negative, exponent and larger values are refused) - cannot determine freshness"
  return 2
}

# _val_check <profile> <key-file> - the judge's freshness + signature check of the profile's record (stdout: reasons).
_val_check() {
  local age
  age="$(_val_max_age)" || return 2
  _val_judge check --state "$(_val_state_file "$1")" --key "$2" --max-age "${age}" --hmac-key "$(_val_hmac_key)"
}

# _val_engine_tag <profile> - identity of the inference engine build that serves the profile.
_val_engine_tag() {
  local engine bin dir v
  engine="$(catalog_engine "$1")"
  case "${engine}" in
    llama)
      bin="${LLMCTL_LLAMA_SERVER:-${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server}"
      if [[ -x "${bin}" ]]; then
        dir="$(cd "$(dirname "${bin}")" && pwd)"
        v="$(LD_LIBRARY_PATH="${dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" timeout 10 "${bin}" --version 2>&1 \
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

# _val_key <profile> <out-file> [only-kind] [env-file] - validation key (JSON) of the profile; the launch fingerprint
# comes from <env-file> (default: the profile's service env record = the launch that runs / ran last).
_val_key() {
  local p="$1" out="$2" kind="${3:-}"
  local env_file="${4:-${LLMCTL_SERVICES_DIR}/${p}.env}"
  _val_ensure_state_dir
  _val_judge key --catalog "${LLMCTL_CATALOG}" --profile "${p}" --models-dir "${LLMCTL_MODELS_DIR}" \
    --suites-dir "${LLMCTL_VALIDATION_SUITES_DIR}" --engine-tag "$(_val_engine_tag "${p}")" \
    --env-file "${env_file}" --hash-cache "$(_val_hash_cache)" --hmac-key "$(_val_hmac_key)" \
    ${kind:+--only-kind "${kind}"} > "${out}"
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

# _val_expect_model <profile> - the model id the endpoint must report: the catalog's validation.expect_model_id when set
# (colibri reports its family's default_model_id, not a file name - review 2026-10-14 finding 2), else the first
# non-mmproj catalog file name (llama-server reports the model path; its basename must be this).
_val_expect_model() {
  local id
  id="$(json_query "${LLMCTL_CATALOG}" '(d["profiles"][argv[0]].get("validation") or {}).get("expect_model_id") or ""' "$1" 2>/dev/null || true)"
  if [[ -n "${id}" ]]; then echo "${id}"; return 0; fi
  _val_expect_model_file "$1"
}

# _val_decide_args <profile> <local:0|1> - the judge's decide-driver arguments (decision profiles only): protocol, the
# llmctl-decide binary (never built here) and - for a local run - the engine key FILE from the profile's env record.
_val_decide_args() {
  local p="$1" local_run="$2" proto bin kf=""
  proto="$(catalog_decision_protocol "${p}")"
  [[ -n "${proto}" ]] || return 0
  if declare -F _decide_bin_path >/dev/null 2>&1; then bin="$(_decide_bin_path)"; else bin="${LLMCTL_DECIDE_BIN:-${LLMCTL_ROOT}/build/llmctl-decide}"; fi
  if [[ "${local_run}" == "1" ]]; then
    # parsed like lib/svc_hook.sh _hk_get (the env record is never sourced); the path is passed on, the key never read
    kf="$(sed -n 's/^LLMCTL_KEY_FILE=//p' "${LLMCTL_SERVICES_DIR}/${p}.env" 2>/dev/null | head -1 \
          | sed -e 's/\\\(.\)/\1/g' -e "s/^'\\(.*\\)'\$/\\1/")"
  else
    kf="${LLMCTL_VALIDATE_DECIDE_KEY_FILE:-}"
  fi
  printf '%s\n' --decide-protocol "${proto}" --decide-bin "${bin}"
  [[ -n "${kf}" ]] && printf '%s\n' --decide-key-file "${kf}"
  return 0
}

# _val_expect_model_path <profile> - what a server of the profile loads: the profile directory (colibri, onnx) or the
# first non-mmproj catalog file (llama). The judge compares the probed process's model with it (finding 6).
_val_expect_model_path() {
  case "$(catalog_engine "$1")" in
    colibri|onnx) echo "${LLMCTL_MODELS_DIR}/$1" ;;
    *) echo "${LLMCTL_MODELS_DIR}/$1/$(_val_expect_model_file "$1")" ;;
  esac
}

# _val_expect_model_file <profile> - the first non-mmproj catalog file of the profile.
_val_expect_model_file() {
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
  local act=start
  [[ "${mode}" == "psi" ]] && act="send validation probes to"
  if declare -F _sched_pressure_gate >/dev/null 2>&1; then
    LLMCTL_GATE_ACTION="${act}" _sched_pressure_gate "${p}" ${mode:+"${mode}"} >/dev/null || rc=$?
  else
    LLMCTL_GATE_ACTION="${act}" hw_pressure_gate 0 "${p}" >/dev/null || rc=$?
  fi
  [[ "${rc}" -eq 0 ]] && return 0
  if [[ "${mode}" == "psi" ]]; then
    # the profile is ALREADY up at this point (a start may have just happened): only the probes are withheld. Whether the
    # profile is then stopped is said by the caller's cleanup (finding 8 of the 2026-10-14 review: this used to claim
    # "nothing was started" right after a start).
    err "validation of '${p}' refused under memory pressure (hw_pressure_gate rc ${rc}): the probes were NOT sent, nothing is recorded - UNDETERMINED (exit 2); retry when 'head -2 /proc/pressure/memory' is quiet"
  else
    err "validation of '${p}' refused under memory pressure (hw_pressure_gate rc ${rc}): nothing was started or probed, nothing is recorded - UNDETERMINED (exit 2); retry when 'head -2 /proc/pressure/memory' is quiet"
  fi
  return 75
}

# _val_start_for_validation <profile> - start a profile that is not running so it can be validated. Overridden by the
# enforcement layer (lib/scheduler.sh sched_start_unpublished) when present: a validation-only start is never published.
_val_start_for_validation() {
  if declare -F sched_start_unpublished >/dev/null 2>&1; then sched_start_unpublished "$1"; else sched_start "$1"; fi
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
  _val_ensure_state_dir

  local suites
  suites="$(_val_suites "${p}" "${kind}")" || return 2

  local endpoint started=0 starting=0 jpid="" key_file="" saved_traps
  # everything the signal handler reads is declared BEFORE the traps are armed (review 2026-10-15 finding 2: under
  # `set -u` the handler aborted on the then-undeclared rfiles and never stopped the profile it had started)
  local evidence="" run_ev="" vfile=""
  local -a rfiles=()
  local env_bak="" env_had=0      # the profile's env record before a validation-only start (finding 8 of the 2026-10-15 review)
  saved_traps="$(trap -p INT TERM HUP)"      # the caller's traps (e.g. scheduler lock cleanup) are restored on every return
  # _val_cleanup_started - the ONE stop path for a profile THIS call started (finding 4 of the 2026-10-14 review: two early
  # `return 2`s after a start left the profile running). Every return after `started=1` goes through it; it stops the
  # profile unless --keep, and says plainly when --keep leaves it running NOT validated. Idempotent.
  # _val_restore_env - after the validation-only start was stopped: the profile's env record is put back as it was (an
  # enabled unit otherwise boots from the quarantine record and its ExecCondition refuses it once the deadline passed -
  # finding 8 of the 2026-10-15 review); a quarantine record this call created where there was none is removed.
  _val_restore_env() {
    local envf="${LLMCTL_SERVICES_DIR}/${p}.env"
    if [[ "${env_had}" == "1" && -n "${env_bak}" && -f "${env_bak}" ]]; then
      if cp -p -- "${env_bak}" "${envf}.restore.$$" && mv -f -- "${envf}.restore.$$" "${envf}"; then
        log "restored the env record of '${p}' (the validation-only start had replaced it)"
      else
        warn "could not restore ${envf} (its previous content: ${env_bak}) - restore it by hand before the unit is started"
        return 0
      fi
    elif [[ "${env_had}" == "0" ]] && grep -q '^LLMCTL_QUARANTINE_UNTIL=' "${envf}" 2>/dev/null; then
      rm -f -- "${envf:?}"
    fi
    [[ -z "${env_bak}" ]] || rm -f -- "${env_bak:?}"
    env_bak=""
  }
  _val_cleanup_started() {
    if [[ "${started}" == "1" ]]; then
      if [[ "${keep}" != "1" ]]; then
        log "stopping '${p}' again (it was started only for validation; pass --keep to leave it running)"
        sched_stop "${p}" >/dev/null 2>&1 || warn "could not stop '${p}' after validation - stop it by hand: llmctl stop ${p}"
        _val_restore_env
      else
        warn "'${p}' keeps running (--keep) - it was started for this validation; use it only if 'llmctl require-validated ${p}' passes"
        [[ -z "${env_bak}" ]] || rm -f -- "${env_bak:?}"
      fi
      started=0
    fi
  }
  # Interrupt safety: SIGINT/SIGTERM/SIGHUP removes the temp files, kills the judge child (by PID, never by
  # process group) and stops a profile THIS call started (unless --keep). The handler reads this function's
  # locals, so it is only ever armed while validate_profile is on the stack.
  _val_on_signal() {
    local code="$1"
    trap - INT TERM HUP
    [[ -n "${jpid}" ]] && kill "${jpid}" 2>/dev/null || true
    [[ -n "${key_file}" ]] && rm -f "${key_file}"
    [[ -n "${vfile:-}" ]] && rm -f "${vfile}"
    [[ -n "${run_ev:-}" ]] && rm -f "${run_ev}"
    [[ ${#rfiles[@]} -gt 0 ]] && rm -f "${rfiles[@]}"
    if [[ "${started}" == "1" || "${starting}" == "1" ]] && [[ "${keep}" != "1" ]]; then
      warn "interrupted: stopping '${p}' (it was started only for validation)"
      sched_stop "${p}" >/dev/null 2>&1 || true
      _val_restore_env
    elif [[ -z "${host}" ]] && _val_is_quarantined "${p}"; then
      # a QUARANTINED profile exists only to be validated: an interrupted validation never leaves it behind (finding 2c)
      warn "interrupted: stopping the quarantined '${p}' (unpublished, never validated)"
      sched_stop "${p}" >/dev/null 2>&1 || true
    fi
    _val_cli_done=1      # the documented signal status (130/143/129), not _validate_cli's "unexpected exit -> 2"
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
      log "profile '${p}' is not running - starting it (unpublished, for validation only) to validate it"
      if [[ -f "${LLMCTL_SERVICES_DIR}/${p}.env" ]]; then
        env_bak="$(mktemp)"; env_had=1
        cp -p -- "${LLMCTL_SERVICES_DIR}/${p}.env" "${env_bak}"
      fi
      starting=1
      if ! _val_start_for_validation "${p}"; then
        starting=0
        _val_restore_env
        err "could not start '${p}' (see above: insufficient RAM/VRAM or a start failure) - cannot validate: could not determine"
        _val_restore_traps "${saved_traps}"
        return 2
      fi
      starting=0; started=1
      if ! port="$(_val_port "${p}")"; then
        err "'${p}' started but has no port reservation - cannot validate: could not determine"
        _val_cleanup_started
        _val_restore_traps "${saved_traps}"
        return 2
      fi
    fi
    endpoint="http://127.0.0.1:${port}"
    # second gate: pressure may have risen while the model loaded; never hammer a model on a stalling host.
    if ! _val_pressure_gate "${p}" psi; then
      _val_cleanup_started
      _val_restore_traps "${saved_traps}"
      return 2
    fi
  fi

  evidence="${LLMCTL_VERIFY_DIR}/validate-${p}.log"
  key_file="$(mktemp)"
  if ! _val_key "${p}" "${key_file}" "${kind}"; then
    err "cannot compute the validation key of '${p}' - cannot validate: could not determine"
    rm -f "${key_file}"; key_file=""
    _val_cleanup_started
    _val_restore_traps "${saved_traps}"
    return 2
  fi
  # evidence may describe a protected endpoint: 0600, and the URL is logged without userinfo/query/fragment. This run's
  # evidence goes to its own file first: a PASS/FAIL record binds that file's sha256 (finding 3); the cumulative log
  # validate-<profile>.log still receives every run.
  ( umask 077; : >> "${evidence}" ); chmod 600 "${evidence}"
  run_ev="$(_val_state_dir)/${p}.evidence.$(date -u +%Y%m%dT%H%M%SZ).$$.log"
  ( umask 077; : > "${run_ev}" ); chmod 600 "${run_ev}"
  printf '\n==== %s llmctl validate %s endpoint=%s kind=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${p}" "$(_val_judge redact "${endpoint}")" "${kind:-all}" >> "${run_ev}"
  printf 'KEY %s\n' "$(cat "${key_file}")" >> "${run_ev}"

  local s rc=0 one worst=0 saw_undet=0 rf
  for s in ${suites}; do
    one=0
    local -a jargs=(run --suite "${LLMCTL_VALIDATION_SUITES_DIR}/${s}" --endpoint "${endpoint}"
                    --expect-model "$(_val_expect_model "${p}")" --evidence "${run_ev}")
    [[ "${json}" == "1" ]] && jargs+=(--json)
    [[ -z "${host}" ]] && jargs+=(--expect-model-path "$(_val_expect_model_path "${p}")")
    [[ -z "${host}" && -f "${LLMCTL_SERVICES_DIR}/${p}.env" ]] && jargs+=(--expect-launch-env "${LLMCTL_SERVICES_DIR}/${p}.env")
    local da
    while IFS= read -r da; do [[ -n "${da}" ]] && jargs+=("${da}"); done < <(_val_decide_args "${p}" "$([[ -z "${host}" ]] && echo 1 || echo 0)")
    vfile="$(mktemp)"; jargs+=(--verdict-file "${vfile}")
    rf="$(mktemp)"; rfiles+=("${rf}"); jargs+=(--report-file "${rf}")
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
  cat "${run_ev}" >> "${evidence}"

  if [[ -z "${host}" ]]; then
    local all_suites covered=1
    all_suites="$(_val_suites "${p}" 2>/dev/null || true)"
    [[ "${all_suites}" == "${suites}" ]] || covered=0
    local status=undetermined rrc=0
    case "${rc}" in 0) status=pass ;; 1) status=fail ;; esac
    if [[ "${covered}" == "1" || "${status}" == "fail" ]]; then
      local -a rargs=()
      for rf in ${rfiles[@]+"${rfiles[@]}"}; do rargs+=(--report "${rf}"); done
      _val_judge record --key "${key_file}" --status "${status}" --evidence "${run_ev}" --out "$(_val_state_file "${p}")" \
        --hmac-key "$(_val_hmac_key)" ${rargs[@]+"${rargs[@]}"} || rrc=$?
      case "${rrc}" in
        0) [[ "${json}" == "1" ]] || log "validation state for '${p}': ${status} -> $(_val_state_file "${p}")" ;;
        4) warn "'${p}' PASSED in quick mode only (LLMCTL_VALIDATE_REPEAT < 3): NOT recorded, NOT validated for use - rerun without LLMCTL_VALIDATE_REPEAT"
           (( rc == 0 )) && rc=2 ;;
        5) err "'${p}' is NOT validated: its model files are not the bytes the catalog pins / the run validated (see above) - nothing recorded as PASS"
           (( rc == 0 )) && rc=2 ;;
        *) err "could not record the validation state of '${p}' ($(_val_state_file "${p}")) - NOT validated"
           (( rc == 0 )) && rc=2 ;;
      esac
    else
      [[ "${json}" == "1" ]] || log "only the '${kind}' suites ran; '${p}' also has $(tr '\n' ' ' <<<"${all_suites}")- run 'llmctl validate ${p}' to record its validation state"
    fi
  fi
  # the run's evidence file survives only as the evidence of the record that now names it
  if [[ "$(python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("evidence_file") or "")
except Exception: print("")' "$(_val_state_file "${p}")" 2>/dev/null)" != "${run_ev}" ]]; then
    rm -f "${run_ev}"
  fi
  run_ev=""
  rm -f "${key_file}" ${rfiles[@]+"${rfiles[@]}"}; key_file=""; rfiles=()
  [[ "${json}" == "1" ]] || log "evidence: ${evidence}"
  _val_cleanup_started
  _val_restore_traps "${saved_traps}"
  return "${rc}"
}

# Per-profile validation lock for the MANUAL entry points (review 3 of 2026-10-15, finding 10: `llmctl validate` took no
# lock although docs/validation.md said every validator serialises on it). <runtime>/.validate-<profile>.lock is the file
# validate_after_start and the systemd waiter (lib/svc_hook.sh) already hold around their validation. Re-entrant, like the
# scheduler lock: a process that holds it (_VAL_LOCK_HELD) runs inline, and the waiter's own `llmctl validate` child runs
# inline when LLMCTL_VALIDATE_LOCK_HELD=<profile>:<pid> names a holder that is its ANCESTOR (a stale or foreign value is
# ignored: the lock is then taken normally). Lock order everywhere: validation lock, then the scheduler lock.
# LLMCTL_VALIDATE_LOCK_WAIT (default 900 s) bounds the wait; a timeout is UNDETERMINED (2). --host (an external
# endpoint) takes no lock: it never touches the local profile.
_VAL_LOCK_HELD=" "
_val_lock_ancestor_holds() {
  local p="$1" v="${LLMCTL_VALIDATE_LOCK_HELD:-}" want cur i f lf
  [[ "${v%:*}" == "${p}" && "${v##*:}" =~ ^[0-9]+$ ]] || return 1
  want="${v##*:}"; cur="$$"
  if [[ -d "/proc/$$/fd" ]]; then     # Linux: the holder's descriptor of the lock file must really be inherited here
    lf="$(cd "${LLMCTL_RUNTIME_DIR}" 2>/dev/null && pwd -P)/.validate-${p}.lock"
    for f in /proc/$$/fd/*; do [[ "$(readlink "${f}" 2>/dev/null)" == "${lf}" ]] && { lf=ok; break; }; done
    [[ "${lf}" == ok ]] || return 1
  fi
  [[ "${cur}" == "${want}" ]] && return 0       # the holder exec'd into this process (the last command of a subshell)
  for (( i=0; i<16; i++ )); do
    cur="$(ps -o ppid= -p "${cur}" 2>/dev/null | tr -d ' ')"
    [[ "${cur}" =~ ^[0-9]+$ && "${cur}" -gt 1 ]] || return 1
    [[ "${cur}" == "${want}" ]] && return 0
  done
  return 1
}
# _val_with_profile_lock <profile> <command...>
_val_with_profile_lock() {
  local p="$1" lockfd rc=0
  shift
  if [[ "${_VAL_LOCK_HELD}" == *" ${p} "* ]] || _val_lock_ancestor_holds "${p}"; then
    "$@"; return
  fi
  ensure_dir "${LLMCTL_RUNTIME_DIR}"
  exec {lockfd}>"${LLMCTL_RUNTIME_DIR}/.validate-${p}.lock"
  if ! flock -w "${LLMCTL_VALIDATE_LOCK_WAIT:-900}" "${lockfd}"; then
    exec {lockfd}>&-
    err "validation: '${p}' is being validated by another process and did not finish within ${LLMCTL_VALIDATE_LOCK_WAIT:-900}s - could not determine"
    return 2
  fi
  _VAL_LOCK_HELD="${_VAL_LOCK_HELD}${p} "
  "$@" || rc=$?
  _VAL_LOCK_HELD="${_VAL_LOCK_HELD/ ${p} / }"
  flock -u "${lockfd}"; exec {lockfd}>&-
  return "${rc}"
}
# _val_locked_profile_validate <profile> <validate_profile args...> - validate_profile under the profile's validation lock
# (no lock for --host).
_val_locked_profile_validate() {
  local p="$1" a
  for a in "${@:2}"; do [[ "${a}" == --host ]] && { validate_profile "${@:2}"; return; }; done
  _val_with_profile_lock "${p}" validate_profile "${@:2}"
}

# _validate_cli <validate args...> - the `llmctl validate` entry. Exit 1 means exactly "the judge gave a wrong answer":
# validate_profile returns 1 only from an explicit verdict, and an abnormal exit of the shell (die(), set -e, a failed
# source) is mapped to 2 (UNDETERMINED) by an EXIT trap - callers (the systemd waiter) stop a model on exit 1.
_val_cli_done=0
_validate_cli() {
  local rc=0
  _val_cli_done=0
  trap '[[ "${_val_cli_done}" == "1" ]] || { trap - EXIT; exit 2; }' EXIT
  local lp="" a skip=0
  for a in "$@"; do
    if (( skip )); then skip=0; continue; fi
    case "${a}" in --host|--kind) skip=1 ;; -*) ;; *) [[ -n "${lp}" ]] || lp="${a}" ;; esac
  done
  if [[ -n "${lp}" ]] && valid_id "${lp}" 2>/dev/null; then
    _val_locked_profile_validate "${lp}" "$@" || rc=$?
  else
    validate_profile "$@" || rc=$?       # usage errors / an invalid name: validate_profile reports them (no lock file named by it)
  fi
  _val_cli_done=1
  trap - EXIT
  _val_cli_policy "${rc}" "$@" || true
  # a caller that STOPS a model on a wrong answer (the systemd waiter) asks for a private FAIL code: a plain exit 1 of
  # the llmctl process (startup crash, set -e) is then not mistaken for a verdict
  if [[ "${rc}" == "1" && "${LLMCTL_VALIDATE_FAIL_RC:-}" =~ ^[0-9]+$ ]]; then rc="${LLMCTL_VALIDATE_FAIL_RC}"; fi
  return "${rc}"
}

# _val_cli_policy <rc> <validate args...> - finding 6 of the 2026-10-15 review: a manual validation (`llmctl validate <p>`,
# `llmctl vision validate`, every profile of `llmctl validate-all`, `llmctl models verify <p>` of a running profile) of a profile
# that is SERVED (running, published: not quarantined) applies the verdict policy. FAIL (wrong answers) -> stopped through
# the normal stop path, its registry row withdrawn (sched_stop). UNDETERMINED -> it keeps running NOT validated: `llmctl
# status`, `require-validated` and `endpoint` say so / refuse (documented in docs/validation.md). Not applied to --host
# (an external endpoint) and not to the unit waiter's own call (LLMCTL_VALIDATE_ATTACH_PROFILE), which applies its own.
_val_cli_policy() {
  local rc="$1" p="" host=0 a
  shift
  [[ -z "${LLMCTL_VALIDATE_ATTACH_PROFILE:-}" ]] || return 0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --host) host=1; shift 2 || shift ;;
      --kind|--profile) [[ "$1" == --profile ]] && p="${2:-}"; shift 2 || shift ;;
      -*) shift ;;
      *) [[ -n "${p}" ]] || p="$1"; shift ;;
    esac
  done
  [[ "${host}" == "0" && -n "${p}" ]] || return 0
  [[ -f "${LLMCTL_RUNTIME_DIR}/${p}.run" ]] || return 0
  _val_is_quarantined "${p}" && return 0
  case "${rc}" in
    1) err "validation: the SERVED profile '${p}' gave WRONG answers - stopping it through the normal stop path and withdrawing it from the registry"
       sched_stop "${p}" || warn "validation: could not stop '${p}' - stop it by hand: llmctl stop ${p}" ;;
    0) ;;
    *) warn "validation: '${p}' could not be validated (UNDETERMINED); it keeps running NOT validated - 'llmctl status' says so, 'llmctl require-validated ${p}' and 'llmctl endpoint ${p}' refuse" ;;
  esac
  return 0
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
  why="$(_val_check "${p}" "${key_file}")" || rc=$?
  rm -f "${key_file}"
  if [[ "${rc}" == "0" ]]; then
    info "${p}: ${why}"
    return 0
  fi
  if [[ "${rc}" == "2" ]]; then
    err "profile '${p}': validation state could not be determined${why:+: ${why}}"
    return 2
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
    _val_locked_profile_validate "${p}" "${p}" "$@" || one=$?
    _val_cli_policy "${one}" "${p}" "$@" || true     # a FAILING served profile is stopped (finding 6 of the 2026-10-15 review)
    case "${one}" in
      0) verdicts+=("${p}: PASS") ;;
      1) verdicts+=("${p}: FAIL"); worst=1 ;;
      *) verdicts+=("${p}: UNDETERMINED"); undet=1 ;;
    esac
  done
  if [[ "${n}" == "0" ]]; then
    err "validate-all: no running profile to validate (start one first) - could not determine"
    _val_coverage || true
    return 2
  fi
  bold "validate-all summary"
  printf '  %s\n' "${verdicts[@]}"
  _val_coverage || true
  if [[ "${worst}" == "1" ]]; then rc=1; elif [[ "${undet}" == "1" ]]; then rc=2; fi
  return "${rc}"
}

# _val_coverage - every catalog profile and whether it has a signed, unexpired PASS record (review 2026-10-14 finding 2):
# a profile that cannot be or never was validated is listed as NOT VALIDATED, never left out. Cheap: the record's
# signature and age are checked here; the model BYTES are re-checked by require-validated, not by this listing.
_val_coverage() {
  local age
  age="$(_val_max_age 2>/dev/null)" || age=0
  bold "validation coverage (every catalog profile)"
  _val_judge coverage --catalog "${LLMCTL_CATALOG}" --state-dir "$(_val_state_dir)" \
    --suites-dir "${LLMCTL_VALIDATION_SUITES_DIR}" --hmac-key "$(_val_hmac_key)" --max-age "${age}"
}

# --- ENFORCEMENT (review 2026-10-14 finding 1) -----------------------------------------------------------------------
# A profile is served to consumers (documented port, catalog bind host, registry row, enabled unit) ONLY when it has a
# fresh, signed PASS record for its current model bytes, engine build, launch flags and suites. Otherwise the scheduler
# starts it in QUARANTINE (loopback, private ephemeral port, never registered); validate_after_start then validates it
# and publishes it on PASS. Strict is the DEFAULT: FAIL and UNDETERMINED are never served.
#   LLMCTL_VALIDATE_STRICT=0   opt-out: an UNDETERMINED profile is published (marked UNVALIDATED in status) - REFUSED for a
#                              consumer-facing profile (catalog validation.consumer_facing, default true)
#   LLMCTL_VALIDATE_ON_START=0 no validation at start: the same refusal for a consumer-facing profile (allowed only under
#                              LLMCTL_VALIDATE_HERMETIC=1, the test harness)

# _val_consumer_facing <profile> - rc 0 unless the catalog says validation.consumer_facing: false (fail-closed default).
_val_consumer_facing() {
  [[ "$(json_query "${LLMCTL_CATALOG}" 'str((d["profiles"].get(argv[0], {}).get("validation") or {}).get("consumer_facing", True))' "$1" 2>/dev/null || echo True)" != "False" ]]
}

# _val_strict <profile> - rc 0 when an UNDETERMINED validation must NOT be served (the default); rc 1 only for the
# documented opt-out on a profile that is not consumer-facing.
_val_strict() {
  [[ "${LLMCTL_VALIDATE_STRICT:-1}" == "0" ]] || return 0
  _val_consumer_facing "$1" && return 0
  return 1
}

# _val_fresh <profile> [env-file] - rc 0 when the profile has a fresh, signed PASS record for the launch in <env-file>
# (default: its env record). The scheduler passes the launch it is ABOUT to run (finding 5 of the 2026-10-15 review:
# the previous launch's record used to decide a start whose flags had changed).
_val_fresh() {
  local kf rc=0
  kf="$(mktemp)"
  if _val_key "$1" "${kf}" "" "${2:-}" 2>/dev/null; then _val_check "$1" "${kf}" >/dev/null 2>&1 || rc=1; else rc=1; fi
  rm -f "${kf}"
  return "${rc}"
}

# _val_gate_mode <profile> [env-file] -> public | quarantine | public-unvalidated:<why> | refuse:<why>
# (lib/scheduler.sh _sched_gate_for). <env-file>: the launch about to run (default: the profile's env record).
#   * a fresh, signed PASS record for that launch -> public, whatever LLMCTL_VALIDATE_ON_START says (finding 3 of the
#     2026-10-15 review: ON_START=0 used to refuse even a validated profile);
#   * LLMCTL_VALIDATE_ON_START=external -> quarantine, and validate_after_start leaves it there unvalidated for an
#     external validator (scripts/livetest): it is never published by that command;
#   * LLMCTL_VALIDATE_ON_START=0 -> refused for a consumer-facing profile (served unvalidated only for a profile that is
#     not consumer-facing, or inside the test harness: lib/common.sh validation_hermetic, finding 9);
#   * the publish step (_sched_gate_pass) re-checks the record against the launch it publishes (finding 5).
_val_gate_mode() {
  local p="$1" envf="${2:-}"
  if [[ "${_sched_force_quarantine:-0}" == "1" ]]; then echo quarantine; return 0; fi
  if [[ -n "${_sched_gate_pass:-}" && "${_sched_gate_pass}" == "${p}" ]]; then
    if [[ -n "${_sched_gate_unvalidated:-}" ]]; then echo "public-unvalidated:${_sched_gate_unvalidated}"; return 0; fi
    if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]] || _val_fresh "${p}" "${envf}"; then echo public; return 0; fi
    echo "refuse:'${p}' passed its validation, but the launch about to be published is not the one that was validated (its flags or environment changed in between) - it is NOT published; run: llmctl start ${p}"
    return 0
  fi
  if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]]; then echo public; return 0; fi
  # inside the test harness the ON_START=0 relaxation is decided before the record (fixture engines are no real servers; a
  # freshness check would run their `--version`); outside it the fresh record counts first (finding 3)
  if [[ "${LLMCTL_VALIDATE_ON_START:-1}" == "0" ]] && validation_hermetic; then
    echo "public-unvalidated:LLMCTL_VALIDATE_ON_START=0 (hermetic test harness)"; return 0
  fi
  if _val_fresh "${p}" "${envf}"; then echo public; return 0; fi
  case "${LLMCTL_VALIDATE_ON_START:-1}" in
    0)
      if validation_hermetic; then echo "public-unvalidated:LLMCTL_VALIDATE_ON_START=0 (hermetic test harness)"; return 0; fi
      if ! _val_consumer_facing "${p}"; then echo "public-unvalidated:LLMCTL_VALIDATE_ON_START=0 (opt-out; '${p}' is not consumer-facing)"; return 0; fi
      echo "refuse:LLMCTL_VALIDATE_ON_START=0 is refused for the consumer-facing profile '${p}', which has no fresh validation record for this launch: every model must pass its validation before it is used (unset it, validate first: llmctl validate ${p}, or start it unpublished for an external validator: LLMCTL_VALIDATE_ON_START=external)"
      return 0 ;;
  esac
  echo quarantine
}

# _val_is_quarantined <profile> - rc 0 when the running reservation of the profile is a quarantine start.
_val_is_quarantined() { grep -qx 'quarantine=1' "${LLMCTL_RUNTIME_DIR}/$1.run" 2>/dev/null; }

# _val_stop_after_verdict <profile> - the stop half of the gate: sched_stop (-> svc_stop, reservation removed).
# Callers run OUTSIDE the scheduler lock (sched_stop takes it itself).
_val_stop_after_verdict() {
  sched_stop "$1" || warn "validation: could not stop '$1' - stop it by hand: llmctl stop $1"
}

# _val_verdict_policy <profile> <rc> <published:0|1> - what a verdict means for a running profile: PASS -> publish (when
# quarantined); FAIL -> stop; UNDETERMINED -> stop (strict default) or, opt-out on a non-consumer-facing profile only,
# serve it marked UNVALIDATED. Returns 1 when the profile is not served.
_val_verdict_policy() {
  local p="$1" one="$2" quarantined="$3"
  case "${one}" in
    0)
      if [[ "${quarantined}" == "1" ]]; then
        if sched_publish "${p}"; then
          info "validation: '${p}' PASSED - published on its documented port (llmctl endpoint ${p})"
        else
          err "validation: '${p}' PASSED but could not be published (see above) - it is NOT served"
          return 1
        fi
      else
        info "validation: '${p}' PASSED"
      fi
      return 0 ;;
    1)
      err "validation: '${p}' gave WRONG answers (validation FAILED) - stopping it through the normal stop path; it is NOT left running (evidence: ${LLMCTL_VERIFY_DIR}/validate-${p}.log)"
      _val_stop_after_verdict "${p}"
      return 1 ;;
  esac
  if _val_strict "${p}"; then
    if [[ "${LLMCTL_VALIDATE_STRICT:-1}" == "0" ]]; then
      err "validation: '${p}' could not be validated (UNDETERMINED); LLMCTL_VALIDATE_STRICT=0 is REFUSED for the consumer-facing profile '${p}' - stopping it, it is NOT served"
    else
      err "validation: '${p}' could not be validated (UNDETERMINED) - stopping it: an unvalidated model is never served (strict is the default; see docs/validation.md)"
    fi
    _val_stop_after_verdict "${p}"
    return 1
  fi
  warn "validation: '${p}' could not be validated (UNDETERMINED) and LLMCTL_VALIDATE_STRICT=0 (opt-out; '${p}' is not consumer-facing): it is SERVED UNVALIDATED - 'llmctl status' says so and 'llmctl require-validated ${p}' / 'llmctl endpoint ${p}' refuse"
  if [[ "${quarantined}" == "1" ]]; then
    sched_publish "${p}" "LLMCTL_VALIDATE_STRICT=0 opt-out after an UNDETERMINED validation" || return 1
  fi
  return 0
}

# _val_after_start_one <profile> - one profile of validate_after_start (called under the per-profile validation lock).
# Returns 1 when the profile failed validation / was stopped / is not served, else 0.
_val_after_start_one() {
  local p="$1" one base q=0
  [[ -f "${LLMCTL_RUNTIME_DIR}/${p}.run" ]] || return 0
  if base="$(_val_instance_base "${p}")"; then
    info "validation: '${p}' is a scaled instance of '${base}' (no catalog entry of its own) - skipped; its validation state is that of '${base}' (llmctl require-validated ${base})"
    return 0
  fi
  _val_is_quarantined "${p}" && q=1
  if [[ "${q}" == "0" ]] && _val_fresh "${p}"; then
    info "validation: '${p}' already has a fresh passing record for this model, engine, launch and suite"
    return 0
  fi
  log "validation: running the deterministic validation suite(s) of '${p}' before it is used$([[ "${q}" == "1" ]] && echo ' (it is quarantined: loopback, private port, unpublished)')"
  one=0
  validate_profile "${p}" || one=$?
  _val_verdict_policy "${p}" "${one}" "${q}"
}
# validate_after_start <profile...> - post-start hook for start/switch/auto/enable/restart (OUTSIDE the scheduler lock).
# A quarantined profile (no fresh record: started loopback-only on a private port, unpublished) is validated and then
#   PASS (0)         -> PUBLISHED on its documented port (sched_publish), keeps serving.
#   FAIL (1)         -> STOPPED through sched_stop, the hook returns 1 (non-zero exit of the command).
#   UNDETERMINED (2) -> STOPPED (strict is the default), the hook returns 1; LLMCTL_VALIDATE_STRICT=0 publishes it marked
#                       UNVALIDATED, but ONLY for a profile that is not consumer-facing (refused otherwise).
# A profile already published with a fresh record is left alone; one published without (started before the gate existed,
# record expired) is validated in place under the same policy.
validate_after_start() {
  if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]]; then
    log "validation not run (LLMCTL_DRY_RUN=1): nothing was started, so there is nothing to validate"
    return 0
  fi
  if [[ "${LLMCTL_VALIDATE_ON_START:-1}" == "0" ]]; then
    warn "validation on start disabled (LLMCTL_VALIDATE_ON_START=0): $* NOT validated - 'llmctl require-validated' will refuse until 'llmctl validate' passes"
    return 0
  fi
  if [[ "${LLMCTL_VALIDATE_ON_START:-1}" == "external" ]]; then
    local _x
    for _x in "$@"; do
      _val_is_quarantined "${_x}" || continue
      warn "LLMCTL_VALIDATE_ON_START=external: '${_x}' is left in QUARANTINE for an external validator (loopback 127.0.0.1:$(sed -n 's/^port=//p' "${LLMCTL_RUNTIME_DIR}/${_x}.run" | head -1), unpublished, NOT validated); this command never publishes it - stop it with: llmctl stop ${_x}"
    done
    return 0
  fi
  local p rc=0 one lockfd lf
  # interrupted outside validate_profile (lock wait, publish): a quarantined profile of this call is stopped, never left
  # QUARANTINE forever (finding 2c). validate_profile installs its own handler while it runs and restores this one.
  _val_after_start_on_signal() {
    local code="$1" q
    trap - INT TERM HUP
    for q in "${@:2}"; do
      if _val_is_quarantined "${q}"; then
        warn "interrupted: stopping the quarantined '${q}' (unpublished, never validated)"
        sched_stop "${q}" >/dev/null 2>&1 || true
      fi
    done
    exit "${code}"
  }
  local _vas_saved; _vas_saved="$(trap -p INT TERM HUP)"
  local _vas_q; _vas_q="$(printf '%q ' "$@")"
  # shellcheck disable=SC2064  # the profile list is fixed now, on purpose
  trap "_val_after_start_on_signal 130 ${_vas_q}" INT
  # shellcheck disable=SC2064
  trap "_val_after_start_on_signal 143 ${_vas_q}" TERM
  # shellcheck disable=SC2064
  trap "_val_after_start_on_signal 129 ${_vas_q}" HUP
  for p in "$@"; do
    [[ -f "${LLMCTL_RUNTIME_DIR}/${p}.run" ]] || continue
    # per-profile validation lock (NOT the scheduler lock): `enable`/`restart` are also validated by the systemd waiter
    # (lib/svc_hook.sh) - the second validator waits for the first and then finds its fresh record (docs/validation.md)
    lf="${LLMCTL_RUNTIME_DIR}/.validate-${p}.lock"
    exec {lockfd}>"${lf}"
    if ! flock -w "${LLMCTL_VALIDATE_LOCK_WAIT:-900}" "${lockfd}"; then
      exec {lockfd}>&-
      warn "validation: '${p}' is being validated by another process and did not finish within ${LLMCTL_VALIDATE_LOCK_WAIT:-900}s - UNDETERMINED here (that validator publishes or stops it)"
      rc=1
      continue
    fi
    one=0
    _VAL_LOCK_HELD="${_VAL_LOCK_HELD}${p} "
    _val_after_start_one "${p}" || one=$?
    _VAL_LOCK_HELD="${_VAL_LOCK_HELD/ ${p} / }"
    flock -u "${lockfd}"; exec {lockfd}>&-
    [[ "${one}" == "0" ]] || rc=1
  done
  trap - INT TERM HUP
  [[ -n "${_vas_saved}" ]] && eval "${_vas_saved}"
  return "${rc}"
}

# validate_before_enable <profile> - `llmctl enable` / `llmctl restart` gate: a unit is enabled / restarted on its public
# port only for a profile with a fresh PASS record. Without one, the profile is first validated in quarantine (started
# loopback-only on a private port, validated, stopped again). Returns 0 when it may be served, 1 otherwise.
validate_before_enable() {
  local p="$1" gate one=0
  catalog_exists "${p}" || { err "unknown profile: ${p}"; return 1; }
  gate="$(_val_gate_mode "${p}")"
  case "${gate}" in
    public|public-unvalidated:*) return 0 ;;
    refuse:*) err "${gate#refuse:}"; return 1 ;;
  esac
  log "'${p}' has no fresh validation record - validating it in quarantine (loopback, private port, unpublished) before it is enabled/served"
  if [[ -f "${LLMCTL_RUNTIME_DIR}/${p}.run" ]]; then
    # running already (published before the gate existed, or its record expired): the running-profile policy applies
    _val_after_start_one "${p}"
    return
  fi
  validate_profile "${p}" || one=$?      # starts it unpublished (sched_start_unpublished) and stops it again
  case "${one}" in
    0) return 0 ;;
    1) err "'${p}' gave WRONG answers (validation FAILED) - it is NOT enabled/served"; return 1 ;;
  esac
  if _val_strict "${p}"; then
    err "'${p}' could not be validated (UNDETERMINED) - it is NOT enabled/served (strict is the default; LLMCTL_VALIDATE_STRICT=0 is refused for consumer-facing profiles)"
    return 1
  fi
  warn "'${p}' could not be validated (UNDETERMINED); LLMCTL_VALIDATE_STRICT=0 opt-out on a non-consumer-facing profile: enabling it UNVALIDATED"
  # global on purpose: the scheduler's gate (_val_gate_mode, called under the lock by _enable_impl) reads it
  _sched_gate_pass="${p}"
  _sched_gate_unvalidated="LLMCTL_VALIDATE_STRICT=0 opt-out after an UNDETERMINED validation"
  return 0
}

# validation_state <profile> -> one line for `llmctl status`: validated (...) | QUARANTINE | UNVALIDATED (<why>) | NOT VALIDATED (<reason>).
# Cheap on purpose (status runs it per profile): the record's signature, status and age; the model BYTES are re-checked by
# require-validated / endpoint, which is what a consumer calls.
validation_state() {
  local p="$1" f="${LLMCTL_RUNTIME_DIR}/$1.run" why base line age
  if base="$(_val_instance_base "${p}" 2>/dev/null)"; then p="${base}"; fi
  if _val_is_quarantined "$1"; then echo "QUARANTINE (validating: loopback, private port, unpublished)"; return 0; fi
  why="$(sed -n 's/^unvalidated=//p' "${f}" 2>/dev/null | head -1)"
  if [[ -n "${why}" ]]; then echo "UNVALIDATED (${why})"; return 0; fi
  catalog_exists "${p}" || { echo "NOT VALIDATED (not a catalog profile)"; return 0; }
  age="$(_val_max_age 2>/dev/null)" || age=0
  line="$(_val_judge coverage --catalog "${LLMCTL_CATALOG}" --state-dir "$(_val_state_dir)" --suites-dir "${LLMCTL_VALIDATION_SUITES_DIR}" \
          --hmac-key "$(_val_hmac_key)" --max-age "${age}" --profile "${p}" 2>/dev/null | head -1)"
  line="${line#*: }"
  # "validated" only when require-validated would accept it NOW (finding 11 of the 2026-10-15 review: the label used to show a
  # signed record whose model bytes or launch no longer matched): the same key + check, with the cached hashes
  if [[ "${line}" == validated* ]] && ! _val_fresh "${p}"; then
    echo "NOT VALIDATED (a signed PASS record exists, but not for the bytes / engine / launch running now: llmctl require-validated ${p})"
    return 0
  fi
  case "${line}" in
    validated*) echo "validated (signed PASS record for the running model bytes, engine and launch)" ;;
    "NOT VALIDATED - "*) echo "NOT VALIDATED (${line#NOT VALIDATED - })" ;;
    *) echo "NOT VALIDATED (state could not be determined)" ;;
  esac
}

# endpoint <profile> - `llmctl endpoint`: prints the profile's URL ONLY when it is running, published and has a fresh,
# signed PASS record - the one call a consuming project needs. rc 0 URL printed; 1 not validated / not served (reason on
# stderr); 2 usage / unknown profile.
endpoint() {
  [[ "$#" -eq 1 ]] || { err "usage: llmctl endpoint <profile>"; return 2; }
  local p="$1" port host
  catalog_exists "${p}" || { err "unknown profile: ${p}"; return 2; }
  if [[ ! -f "${LLMCTL_RUNTIME_DIR}/${p}.run" ]]; then err "'${p}' is not running (start it: llmctl start ${p})"; return 1; fi
  if _val_is_quarantined "${p}"; then err "'${p}' is being validated (quarantine: unpublished) - not served yet"; return 1; fi
  local why vrc=0
  why="$(require_validated "${p}" 2>&1)" || vrc=$?
  if [[ "${vrc}" != "0" ]]; then printf '%s\n' "${why}" >&2; return 1; fi
  port="$(sed -n 's/^port=//p' "${LLMCTL_RUNTIME_DIR}/${p}.run" | head -1)"
  [[ "${port}" =~ ^[0-9]+$ ]] || { err "'${p}' has no port in its reservation"; return 1; }
  host="127.0.0.1"
  printf 'http://%s:%s\n' "${host}" "${port}"
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
    local vrc=0
    _val_locked_profile_validate "${p}" "${p}" || vrc=$?
    _val_cli_policy "${vrc}" "${p}" || true          # a FAILING served profile is stopped (finding 6 of the 2026-10-15 review)
    return "${vrc}"
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
      local vrc=0
      _val_locked_profile_validate "${p}" "${p}" --kind vision ${rest[@]+"${rest[@]}"} || vrc=$?
      _val_cli_policy "${vrc}" "${p}" ${rest[@]+"${rest[@]}"} || true   # finding 6 of the 2026-10-15 review
      return "${vrc}"
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
