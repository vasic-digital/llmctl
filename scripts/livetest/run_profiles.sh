#!/usr/bin/env bash
# run_profiles.sh - thin sequential runner over the guarded live-test driver (vision_live_test.sh).
#
# Usage: run_profiles.sh [--allow-large] [--plan] <profile> [<profile>...]     explicit, ordered list
#        run_profiles.sh [--allow-large] [--plan] --fitting                    every profile the driver would accept on this host
#
# DYNAMIC SWITCHING: the models llmctl runs now are recorded ONCE before the first run (evidence: prior_status.json, prior_set.txt).
# Each profile is loaded with llmctl's own `llmctl switch` (inside the driver), which stops what runs - the resident set for the first
# profile, the previous test model for every later one - so at no time are two test models resident. After the last run, and also
# after a stop/abort/signal, the recorded set is restored ONCE through `vision_live_test.sh --restore-only` (llmctl start, one profile at
# a time, pressure-gated, each verified healthy). A restore skipped for pressure exits 6, a failed/unhealthy one 7, with the manual
# command printed; the sequence's own non-zero exit is never masked by them. --plan prints all this and does nothing.
# This interrupts the resident services (enabled ones such as a decision gateway backend too) for the duration of the sequence.
#
# Strictly sequential, one profile at a time, never in parallel (a flock on <evidence root>/.runner.lock refuses a second
# runner). For each profile in order:
#   0. before ANYTHING starts: every profile of the list is checked statically (catalog, engine, suites, large needs --allow-large);
#   1. (second profile onwards) wait SETTLE seconds, then `vision_live_test.sh --gate-only <p>`: the driver's refusal checks (catalog,
#      plan fits) and the pre-gate are re-checked and nothing is started (the checksum verification is left to the real run);
#      a refusal stops the sequence;
#   2. refuse when ANY profile of the sequence is already running (`llmctl status --json`): a second profile is never started
#      while one is running;
#   3. run the driver for that profile in the foreground (its own watchdog, stop contract and always-stop trap apply).
# The sequence STOPS at the first non-zero exit (refusal 3, watchdog abort 4, watchdog death 5, FAIL 1, undetermined 2): a watchdog
# abort is never continued past. One summary table is printed at the end; profiles not reached say NOT RUN.
#
# --fitting: the list is derived at run time from models/catalog.json + `llmctl plan --json` (lt_profiles.py fitting): profiles with
#   an existing validation suite, engine llama, plan fits=true, downloaded on this host; large profiles (catalog min_tier
#   workstation/datacenter or footprint >= 10 GiB) only with --allow-large; smallest catalog footprint first.
#
# Exit: 0 every profile PASSed | otherwise the exit code of the first profile that did not (1 FAIL, 2 undetermined or interrupted,
#       3 refused/usage/nothing to run, 4 aborted by the watchdog, 5 watchdog died).
# This script sends no signal to anything. Overrides (LT_SETTLE LT_EVIDENCE_ROOT LLMCTL_BIN LT_CATALOG LT_SUITES_ROOT LT_PLAN_BOUND)
# are honoured only with LT_HERMETIC=1 (tests).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/vision_live_test.sh"; LTP="$HERE/lt_profiles.py"
LLMCTL=llmctl; EVROOT="$HOME/.cache/llmctl-livetest"; SETTLE=20; PLAN_BOUND=60
CATALOG="$HERE/../../models/catalog.json"; SUITES_ROOT="$HERE/../../validation/suites"
if [ "${LT_HERMETIC:-0}" = "1" ]; then
  LLMCTL="${LLMCTL_BIN:-llmctl}"; EVROOT="${LT_EVIDENCE_ROOT:-$EVROOT}"; SETTLE="${LT_SETTLE:-$SETTLE}"; PLAN_BOUND="${LT_PLAN_BOUND:-$PLAN_BOUND}"
  CATALOG="${LT_CATALOG:-$CATALOG}"; SUITES_ROOT="${LT_SUITES_ROOT:-$SUITES_ROOT}"
fi
umask 077

usage_refuse() { echo "REFUSED: $*" >&2; echo "usage: run_profiles.sh [--allow-large] [--plan] (--fitting | <profile> [<profile>...])" >&2; exit 3; }
ALLOW=(); FITTING=0; PLAN=0; LIST=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-large) ALLOW=(--allow-large) ;;
    --fitting)     FITTING=1 ;;
    --plan)        PLAN=1 ;;
    -*)            usage_refuse "unknown option '$1'" ;;
    *)             [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || usage_refuse "'$1' is not a valid profile id"
                   for _p in ${LIST[@]+"${LIST[@]}"}; do [ "$_p" != "$1" ] || usage_refuse "profile '$1' listed twice"; done
                   LIST+=("$1") ;;
  esac
  shift
done
[ "${LT_ALLOW_LARGE:-0}" = "1" ] && ALLOW=(--allow-large)
if [ "$FITTING" = 1 ] && [ "${#LIST[@]}" -gt 0 ]; then usage_refuse "--fitting and an explicit profile list are mutually exclusive"; fi
if [ "$FITTING" = 0 ] && [ "${#LIST[@]}" -eq 0 ]; then usage_refuse "give an explicit ordered profile list or --fitting"; fi
command -v python3 >/dev/null 2>&1 || { echo "missing tool: python3" >&2; exit 2; }
command -v "$LLMCTL" >/dev/null 2>&1 || { echo "missing tool: $LLMCTL" >&2; exit 2; }
[ -x "$DRIVER" ] || [ -r "$DRIVER" ] || { echo "driver not found: $DRIVER" >&2; exit 2; }

mkdir -p "$EVROOT" || { echo "cannot create $EVROOT" >&2; exit 2; }
# one runner at a time: a second concurrent runner would start a second profile while one is running
exec 9>"$EVROOT/.runner.lock"
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then usage_refuse "another run_profiles.sh holds $EVROOT/.runner.lock: never two sequences at once"; fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"; SEQ="$EVROOT/$TS-sequence"; mkdir -p "$SEQ" || { echo "cannot create $SEQ" >&2; exit 2; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$SEQ/run.log" >&2; }

# bounded <secs> <outfile> cmd... : detached with a deadline, never signalled (rc 124 = still running at the deadline).
bounded() {
  local secs="$1" out="$2" i=0; shift 2
  rm -f "$out.rc"
  ( "$@" >"$out" 2>>"$SEQ/bounded.err"; echo $? >"$out.rc" ) >/dev/null 2>&1 &
  while [ ! -s "$out.rc" ] && [ "$i" -lt $((secs * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$out.rc" ] || return 124
  return "$(cat "$out.rc")"
}

if [ "$FITTING" = 1 ]; then
  rc=0; bounded "$PLAN_BOUND" "$SEQ/plan.json" "$LLMCTL" plan --json || rc=$?
  [ "$rc" = 0 ] || { log "REFUSED: llmctl plan --json failed or timed out (rc=$rc): cannot derive the fitting profiles"; exit 3; }
  MODELS_DIR="${LLMCTL_MODELS_DIR:-${LLMCTL_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/llmctl}/models}"
  mapfile -t LIST < <(python3 -I "$LTP" fitting --catalog "$CATALOG" --suites-root "$SUITES_ROOT" --plan "$SEQ/plan.json" --models-dir "$MODELS_DIR" ${ALLOW[@]+"${ALLOW[@]}"})
  [ "${#LIST[@]}" -gt 0 ] || { log "REFUSED: no profile is catalogued with a validation suite, fits this host per the plan and is downloaded (large ones need --allow-large)"; exit 3; }
fi
# preflight of the WHOLE list before anything is started: an invalid / unsupported / large-without-flag profile anywhere in the
# list refuses the sequence, so profile 1 is never run only to find out that profile 2 was never allowed.
for p in "${LIST[@]}"; do
  info="$(python3 -I "$LTP" info --catalog "$CATALOG" --suites-root "$SUITES_ROOT" --profile "$p")" || { log "REFUSED: cannot evaluate '$p' against the catalog"; exit 3; }
  why="$(printf '%s\n' "$info" | sed -n 's/^refusal=//p' | head -1)"
  [ -z "$why" ] || { log "REFUSED: $why (nothing was started)"; exit 3; }
  if [ "$(printf '%s\n' "$info" | sed -n 's/^large=//p')" = 1 ] && [ "${#ALLOW[@]}" = 0 ]; then
    log "REFUSED: profile '$p' is large (catalog tier/footprint): it needs --allow-large (nothing was started)"; exit 3
  fi
done
log "sequence (strictly one at a time): ${LIST[*]}"
printf '%s\n' "${LIST[@]}" >"$SEQ/profiles.txt"

# record what llmctl runs NOW (once, before anything is switched off); fail closed when it cannot be read
rc=0; bounded 30 "$SEQ/prior_status.json" "$LLMCTL" status --json || rc=$?
[ "$rc" = 0 ] || { log "REFUSED: llmctl status --json failed (rc=$rc): cannot record the running set before a switch would stop it"; exit 3; }
PRIOR_OUT="$(python3 -I "$LTP" prior --status "$SEQ/prior_status.json")" || { log "REFUSED: llmctl status --json is not parseable"; exit 3; }
mapfile -t PRIOR < <(printf '%s\n' "$PRIOR_OUT" | sed -n 's/^profile=//p')
mapfile -t PRIOR_INST < <(printf '%s\n' "$PRIOR_OUT" | sed -n 's/^instance=//p')
: >"$SEQ/prior_set.txt"; for _p in ${PRIOR[@]+"${PRIOR[@]}"}; do echo "$_p" >>"$SEQ/prior_set.txt"; done
bounded 30 "$SEQ/prior_units.txt" systemctl --user list-units --all --plain --no-legend 'llmctl-*@*.service' || true
: >"$SEQ/RESTORE_MANUAL.txt"
[ "${#PRIOR[@]}" -eq 0 ] || echo "nice -n 19 ionice -c 3 $LLMCTL start ${PRIOR[*]}" >>"$SEQ/RESTORE_MANUAL.txt"
for _p in ${PRIOR_INST[@]+"${PRIOR_INST[@]}"}; do
  _c=0; for _q in ${PRIOR[@]+"${PRIOR[@]}"} ${PRIOR_INST[@]+"${PRIOR_INST[@]}"}; do [ "${_q%%.*}" = "${_p%%.*}" ] && _c=$((_c + 1)); done
  echo "scaled instance $_p was running: nice -n 19 ionice -c 3 $LLMCTL decide scale ${_p%%.*} $_c   # 'llmctl start' brings back ONE instance only" >>"$SEQ/RESTORE_MANUAL.txt"
done
for _p in "${LIST[@]}"; do for _q in ${PRIOR[@]+"${PRIOR[@]}"}; do
  [ "$_p" != "$_q" ] || { log "REFUSED: profile '$_p' of the sequence is already running (never a second profile while one is running; nothing was switched off)"; exit 3; }
done; done
log "llmctl runs now (will be switched off, then restored): ${PRIOR[*]:-nothing}"

if [ "$PLAN" = 1 ]; then
  {
    echo "PLAN (dry run: nothing is stopped, started or restored)"
    echo "llmctl currently runs: ${PRIOR[*]:-nothing}${PRIOR_INST[*]:+ (+ scaled instances: ${PRIOR_INST[*]})}"
    i=0; for _p in "${LIST[@]}"; do i=$((i + 1))
      if [ "$i" = 1 ]; then echo "step $i: $_p - loaded with llmctl switch; that stops: ${PRIOR[*]:-nothing}"
      else echo "step $i: $_p - after ${SETTLE}s the pre-gate is re-checked (--gate-only), then llmctl switch replaces ${LIST[$((i - 2))]}"; fi
    done
    echo "stops at the first non-zero exit; a watchdog abort is never continued past"
    echo "would restore after the last run (and after any stop/abort/signal), one at a time, pressure-gated, health-checked: ${PRIOR[*]:-nothing}"
    echo "this interrupts those services (enabled ones too, e.g. a decision gateway backend) for the duration of the sequence"
  } | tee "$SEQ/plan.txt"
  exit 0
fi

# ev_path <file>: the evidence dir the driver wrote there; accepted only when it is a directory under the evidence root that we own
ev_path() {
  local d; d="$(head -1 "$1" 2>/dev/null)"
  case "$d" in "$EVROOT"/*) ;; *) return 0 ;; esac
  local rd re; rd="$(realpath -e -- "$d" 2>/dev/null)" && re="$(realpath -e -- "$EVROOT" 2>/dev/null)" || return 0
  case "$rd" in "$re"/*) [ -d "$rd" ] && [ -O "$rd" ] && printf '%s' "$rd" ;; esac
  return 0
}
INTERRUPTED=0
# shellcheck disable=SC2329  # invoked via trap
on_sig() { INTERRUPTED=1; log "interrupted: the running driver (if any) finishes its own cleanup; no further profile will start"; }
trap on_sig INT TERM HUP

running_of_sequence() {   # prints the profiles of the sequence that `llmctl status --json` shows running; rc 1 when unreadable
  local o="$SEQ/.status.$$" rc=0; bounded 30 "$o" "$LLMCTL" status --json || rc=$?
  [ "$rc" = 0 ] || { rm -f "$o" "$o.rc"; return 1; }
  python3 -I -c '
import json, sys
want = set(sys.argv[2:])
try: rows = json.load(open(sys.argv[1]))
except Exception: sys.exit(1)
for r in rows:
    base = str(r.get("profile", "")).split(".")[0]
    if base in want: print(r.get("profile"))' "$o" "${LIST[@]}"
  rc=$?; rm -f "$o" "$o.rc"; return "$rc"
}

declare -A EXIT_OF VERDICT_OF EV_OF
STOP_RC=0; STOPPED_AT=""; first=1; SWITCHED=0; EXTRA=(); EXTRA_INST=()
note_extra() {   # note_extra <driver evidence dir>: whatever that driver's own run switched off beyond the recorded initial set
  local d="$1" n q known
  [ -s "$d/prior_set.txt" ] || [ -s "$d/prior_unrestorable.txt" ] || return 0
  while IFS= read -r n; do
    [ -n "$n" ] || continue; known=0
    for q in ${PRIOR[@]+"${PRIOR[@]}"} ${EXTRA[@]+"${EXTRA[@]}"} "${LIST[@]}"; do [ "$q" = "$n" ] && known=1; done
    [ "$known" = 1 ] || EXTRA+=("$n")
  done <"$d/prior_set.txt"
  while IFS= read -r n; do
    n="${n#scaled instance }"; n="${n%% *}"; [ -n "$n" ] || continue
    for q in ${EXTRA_INST[@]+"${EXTRA_INST[@]}"}; do [ "$q" = "$n" ] && n=""; done
    [ -z "$n" ] || EXTRA_INST+=("$n")
  done <"$d/prior_unrestorable.txt" 2>/dev/null
}
for p in "${LIST[@]}"; do
  [ "$INTERRUPTED" = 0 ] || { STOP_RC=2; STOPPED_AT="${STOPPED_AT:-$p}"; break; }
  if [ "$first" = 0 ]; then
    log "settling ${SETTLE}s, then re-checking the pre-gate for '$p' (nothing is started by the check)"
    sleep "$SETTLE"
    grc=0; LT_VIA_RUNNER=1 LT_EVIDENCE_PATH_FILE="$SEQ/$p.gate.evpath" "$DRIVER" ${ALLOW[@]+"${ALLOW[@]}"} --gate-only "$p" 9>&- >"$SEQ/$p.gate.out" 2>&1 || grc=$?
    if [ "$grc" != 0 ]; then
      EXIT_OF[$p]="$grc"; VERDICT_OF[$p]="GATE-REFUSED before start"; EV_OF[$p]="$(ev_path "$SEQ/$p.gate.evpath")"
      STOP_RC="$grc"; STOPPED_AT="$p"; log "STOP: pre-gate re-check for '$p' exited $grc (see $SEQ/$p.gate.out); the sequence ends here"; break
    fi
  fi
  first=0
  busy="$(running_of_sequence)"; src=$?
  if [ "$src" != 0 ] || [ -n "$busy" ]; then
    EXIT_OF[$p]=3; VERDICT_OF[$p]="REFUSED (a profile of the sequence is running or status unreadable: ${busy:-status unreadable})"
    STOP_RC=3; STOPPED_AT="$p"; log "STOP: ${VERDICT_OF[$p]}; never starting a second profile while one is running"; break
  fi
  log "running '$p' (exit codes: 0 PASS 1 FAIL 2 undetermined 3 refused 4 watchdog abort 5 watchdog died)"
  SWITCHED=1
  LT_VIA_RUNNER=1 LT_EVIDENCE_PATH_FILE="$SEQ/$p.evpath" "$DRIVER" ${ALLOW[@]+"${ALLOW[@]}"} --no-restore "$p" 9>&- 2>&1 | tee "$SEQ/$p.out"
  rc="${PIPESTATUS[0]}"
  EXIT_OF[$p]="$rc"
  VERDICT_OF[$p]="$(sed -n 's/^VERDICT  *//p' "$SEQ/$p.out" | tail -1 | cut -c1-90)"; [ -n "${VERDICT_OF[$p]}" ] || VERDICT_OF[$p]="(no verdict line)"
  EV_OF[$p]="$(ev_path "$SEQ/$p.evpath")"
  [ -z "${EV_OF[$p]}" ] || note_extra "${EV_OF[$p]}"
  if [ "$rc" != 0 ]; then STOP_RC="$rc"; STOPPED_AT="$p"; log "STOP: '$p' exited $rc; no further profile is started (a watchdog abort is never continued past)"; break; fi
done

# restore the recorded set ONCE, after the last driver run (also after a stop/abort/interrupt), if anything was switched off
RESTORE_RC=0; RESTORE_WORD=none; RESTORE_TXT="NONE (nothing was running before)"
if [ "${#PRIOR[@]}" -gt 0 ] || [ "${#PRIOR_INST[@]}" -gt 0 ] || [ "${#EXTRA[@]}" -gt 0 ] || [ "${#EXTRA_INST[@]}" -gt 0 ]; then
  if [ "$SWITCHED" = 1 ]; then
    for _p in ${EXTRA[@]+"${EXTRA[@]}"}; do echo "$_p" >>"$SEQ/prior_set.txt"; done
    [ "${#EXTRA[@]}" -eq 0 ] || { log "also switched off during the sequence (not in the initial record): ${EXTRA[*]}"; echo "nice -n 19 ionice -c 3 $LLMCTL start ${EXTRA[*]}" >>"$SEQ/RESTORE_MANUAL.txt"; }
    log "restoring the recorded set: ${PRIOR[*]} ${EXTRA[*]}"
    "$DRIVER" --restore-only "$SEQ/prior_set.txt" 9>&- >"$SEQ/restore.out" 2>&1; RESTORE_RC=$?
    cat "$SEQ/restore.out" >&2
    INST_TXT="${PRIOR_INST[*]:+; scaled instances NOT restorable by llmctl start: ${PRIOR_INST[*]} (see RESTORE_MANUAL.txt)}"
    if [ "${#EXTRA_INST[@]}" -gt 0 ]; then
      INST_TXT+="; scaled instances switched off during the sequence: ${EXTRA_INST[*]} (restore by hand: $LLMCTL decide scale <base> <N>)"
      for _p in "${EXTRA_INST[@]}"; do echo "scaled instance $_p was switched off during the sequence: restore by hand with $LLMCTL decide scale ${_p%%.*} <N>" >>"$SEQ/RESTORE_MANUAL.txt"; done
      [ "$RESTORE_RC" != 0 ] || RESTORE_RC=6
    fi
    case "$RESTORE_RC" in 0) RESTORE_TXT="YES${EXTRA[*]:+ (additionally restored: ${EXTRA[*]})}"; RESTORE_WORD=ok ;;
      6) RESTORE_TXT="NO (SKIPPED: see above; manual: nice -n 19 ionice -c 3 $LLMCTL start ${PRIOR[*]}$INST_TXT)"; RESTORE_WORD=manual ;;
      *) RESTORE_TXT="NO (FAILED/UNHEALTHY: see above; manual: nice -n 19 ionice -c 3 $LLMCTL start ${PRIOR[*]}$INST_TXT)"; RESTORE_WORD=failed ;; esac
  else RESTORE_TXT="n/a (nothing was switched off)"; fi
fi

{
  printf '\n%-3s %-18s %-5s %-34s %s\n' "#" "PROFILE" "EXIT" "VERDICT" "EVIDENCE"
  i=0
  for p in "${LIST[@]}"; do
    i=$((i + 1))
    if [ -n "${EXIT_OF[$p]+x}" ]; then printf '%-3s %-18s %-5s %-34s %s\n' "$i" "$p" "${EXIT_OF[$p]}" "${VERDICT_OF[$p]:0:34}" "${EV_OF[$p]:-}"
    else printf '%-3s %-18s %-5s %-34s %s\n' "$i" "$p" "-" "NOT RUN (sequence stopped)" ""; fi
  done
  if [ "$STOP_RC" = 0 ]; then echo "SEQUENCE: PASS (${#LIST[@]} of ${#LIST[@]} profiles, one at a time)"
  else echo "SEQUENCE: STOPPED at '$STOPPED_AT' (exit $STOP_RC); remaining profiles were NOT run"; fi
  echo "prior set restored: $RESTORE_TXT"
  echo "RESTORE_STATE=$RESTORE_WORD"
} | tee "$SEQ/summary.txt"
echo "$RESTORE_WORD" >"$SEQ/restore_state"
echo "sequence evidence: $SEQ"
[ "$STOP_RC" = 0 ] && STOP_RC="$RESTORE_RC"
exit "$STOP_RC"
