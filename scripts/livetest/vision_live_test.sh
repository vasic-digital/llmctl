#!/usr/bin/env bash
# vision_live_test.sh - guarded live known-answer test of ONE llmctl profile (default `vision`).
#
# Usage: vision_live_test.sh [--allow-large] [--gate-only | --plan] [--no-restore] [<profile>]   (env LT_ALLOW_LARGE=1 = --allow-large)
#        vision_live_test.sh --restore-only <set-file>      (restore a recorded prior set; used by run_profiles.sh)
#
# DYNAMIC SWITCHING (operator decision): the models llmctl currently runs are RECORDED first (status json + llmctl units ->
# evidence), the profile under test is loaded with llmctl's own `llmctl switch <profile>` (it stops every running profile and starts
# exactly that one, under the scheduler lock and llmctl's pressure gate), and afterwards - on EVERY exit path - the recorded set is
# RESTORED with `llmctl start`, one profile at a time, pressure-gated, each verified healthy. A restore that is skipped (host under
# pressure, test model not confirmed stopped) exits 6, one that failed or left a profile unhealthy exits 7, both with the exact manual
# command printed; a run's own non-zero exit (FAIL, abort, ...) is never masked by them. --plan prints what would be stopped, started
# and restored and does nothing. This interrupts enabled services (e.g. the decision gateway backend) for the duration of a run.
#
# The profile is accepted only when ALL hold, derived at run time (nothing is hard-coded by name or size):
#   in models/catalog.json | engine llama | has validation suites that exist | `llmctl plan --json` lists it with fits=true
#   | `llmctl models verify <p>` (checksum) rc 0 | not already running | large profiles (catalog min_tier workstation/
#   datacenter, or footprint >= 10 GiB; e.g. vision-pro) additionally need --allow-large. Anything else: exit 3, nothing started.
# --gate-only runs every refusal check and the pre-gate, starts NOTHING, exits 0 when they pass (the runner uses it between runs).
#
# Exit: 0 PASS | 1 wrong answer (FAIL) | 2 undetermined | 3 pre-gate refusal | 4 aborted by watchdog | 5 watchdog died (model stopped)
#
# Safety contract (see docs/live-test-protocol.md):
#  * pre-gate refuses unless MemAvailable>=max(12000 MiB, catalog footprint+4 GiB+2 GiB), PSI some<5 & full<1, GPU used<6000 MiB,
#    GPU free VRAM >= the plan's VRAM for the profile + 1 GiB (MemAvailable/GPU figures count the RAM/VRAM llmctl has reserved for
#    the resident set as free, because the switch stops that set), no failed profile / failed-restarting unit for the profile;
#  * watchdog.sh is started BEFORE the model and stops the profile on any breach;
#  * the model is started ONLY via `LLMCTL_VALIDATE_ON_START=0 nice -n 19 ionice -c 3 llmctl switch <profile>`;
#  * the only signal this script ever sends is to the watchdog PID it started (safe_kill); only llmctl starts/stops anything else;
#  * trap on EXIT/INT/TERM/HUP always runs `llmctl stop <profile>`;
#  * no retries, thresholds are constants (overridable only with LT_HERMETIC=1, used by tests).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sensor/binary redirections exist for the hermetic tests ONLY: honoured exclusively when LT_HERMETIC=1.
LLMCTL=llmctl; NVSMI=nvidia-smi; SYSCTL=systemctl; MEMINFO=/proc/meminfo; PSI=/proc/pressure/memory; IOPSI=/proc/pressure/io
OVERRIDE_NAMES="LT_MEMINFO LT_PSI LT_IOPSI NVIDIA_SMI_BIN LLMCTL_BIN SYSTEMCTL_BIN LT_SUITE_DIR LT_SUITES_ROOT LT_CATALOG LLAMA_SERVER_BIN LT_BOUND_DEFAULT LT_EVIDENCE_ROOT"
LLAMA_BIN=llama-server; EVROOT="$HOME/.cache/llmctl-livetest"
if [ "${LT_HERMETIC:-0}" = "1" ]; then
  LLMCTL="${LLMCTL_BIN:-llmctl}"; NVSMI="${NVIDIA_SMI_BIN:-nvidia-smi}"; SYSCTL="${SYSTEMCTL_BIN:-systemctl}"
  LLAMA_BIN="${LLAMA_SERVER_BIN:-llama-server}"; EVROOT="${LT_EVIDENCE_ROOT:-$EVROOT}"
  MEMINFO="${LT_MEMINFO:-/proc/meminfo}"; PSI="${LT_PSI:-/proc/pressure/memory}"; IOPSI="${LT_IOPSI:-/proc/pressure/io}"
fi

GATE_MIN_MEM_MB=12000; GATE_MIN_FREE_VRAM_MB=0; VRAM_NEED_MB=0; GATE_MAX_PSI_SOME=5; GATE_MAX_PSI_FULL=1; GATE_MAX_GPU_MB=6000; GATE_MAX_IO_SOME=10; GATE_MAX_IO_FULL=2
WD_RAW_MARGIN_MB=1024; RESTORE_UNKNOWN_FLOOR_MB=6144   # raw MemAvailable must exceed the watchdog floor by this; restore floor when a profile's reserved RAM is unknown
RESTORE_HEADROOM_MB=2048; RESTORE_BOUND=300; RESTORE_READY_MAX=120      # restore: RAM left free after a restart; bound of one `llmctl start`; health deadline
READY_INTERVAL=3; READY_MAX=180; PORT_DEFAULT=8082; VRAM_SLACK_MB=500
VALIDATE_GRACE=30; START_MAX=120; START_WAIT=60; POST_SAMPLE=20; PLAN_BOUND=60; VERIFY_BOUND=1800
WD_MIN_MEM_MB=5000; WD_MAX_GPU_MB=11500   # the watchdog's absolute floors/defaults (watchdog.sh); derived per profile after the gate
if [ "${LT_HERMETIC:-0}" = "1" ]; then
  READY_INTERVAL="${LT_READY_INTERVAL:-$READY_INTERVAL}"; READY_MAX="${LT_READY_MAX:-$READY_MAX}"
  VALIDATE_GRACE="${LT_VALIDATE_GRACE:-$VALIDATE_GRACE}"; START_MAX="${LT_START_MAX:-$START_MAX}"; START_WAIT="${LT_START_WAIT:-$START_WAIT}"; POST_SAMPLE="${LT_POST_SAMPLE:-$POST_SAMPLE}"
  PLAN_BOUND="${LT_PLAN_BOUND:-$PLAN_BOUND}"; VERIFY_BOUND="${LT_VERIFY_BOUND:-$VERIFY_BOUND}"
  RESTORE_BOUND="${LT_RESTORE_BOUND:-$RESTORE_BOUND}"; RESTORE_READY_MAX="${LT_RESTORE_READY_MAX:-$RESTORE_READY_MAX}"
fi

# ---- arguments ----
ALLOW_LARGE=0; [ "${LT_ALLOW_LARGE:-0}" = "1" ] && ALLOW_LARGE=1
GATE_ONLY=0; PLAN_ONLY=0; NO_RESTORE=0; RESTORE_ONLY=""; PROFILE=""
static_refuse() { echo "REFUSED: $*" >&2; exit 3; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-large) ALLOW_LARGE=1 ;;
    --gate-only)   GATE_ONLY=1 ;;
    --plan)        PLAN_ONLY=1 ;;
    --no-restore)  NO_RESTORE=1 ;;
    --restore-only) [ "$#" -ge 2 ] || static_refuse "--restore-only needs a set file"; RESTORE_ONLY="$2"; shift ;;
    -*)            static_refuse "unknown option '$1' (usage: vision_live_test.sh [--allow-large] [--gate-only|--plan] [--no-restore] [<profile>] | --restore-only <set-file>)" ;;
    *)             [ -z "$PROFILE" ] || static_refuse "exactly one profile per run (got '$PROFILE' and '$1'); use run_profiles.sh for a sequence"; PROFILE="$1" ;;
  esac
  shift
done
[ "$GATE_ONLY$PLAN_ONLY" != "11" ] || static_refuse "--gate-only and --plan are mutually exclusive"
if [ -n "$RESTORE_ONLY" ]; then
  [ -z "$PROFILE" ] || static_refuse "--restore-only takes no profile"
  [ -r "$RESTORE_ONLY" ] || static_refuse "--restore-only: cannot read the set file '$RESTORE_ONLY'"
  PROFILE="restore"; GATE_ONLY=0; PLAN_ONLY=0; NO_RESTORE=0
fi
PROFILE="${PROFILE:-vision}"

# ---- profile allow-list, part 1 (pure file reads; nothing is run, no evidence dir yet): catalog, engine, suites, large ----
# Part 2 (llmctl plan --json fits, llmctl models verify, not already running) runs after the evidence dir exists.
LTP="$HERE/lt_profiles.py"
CATALOG="$HERE/../../models/catalog.json"; SUITES_ROOT="$HERE/../../validation/suites"; LTP_OVERRIDES=()
if [ "${LT_HERMETIC:-0}" = "1" ]; then
  CATALOG="${LT_CATALOG:-$CATALOG}"; SUITES_ROOT="${LT_SUITES_ROOT:-$SUITES_ROOT}"
  [ -n "${LT_SUITE_DIR:-}" ] && LTP_OVERRIDES=(--override "vision-golden-v1=$LT_SUITE_DIR")   # legacy single-suite redirection
fi
ltp() { python3 -I "$LTP" "$@"; }
command -v python3 >/dev/null 2>&1 || { echo "missing tool: python3" >&2; exit 2; }
info_kv() { printf '%s\n' "$INFO" | sed -n "s/^$1=//p" | head -1; }
INFO=""; SUITES_CSV=""; NEEDS_MMPROJ=0; ALL_VISION=0; FOOTPRINT_MB=0
if [ -z "$RESTORE_ONLY" ]; then
INFO="$(ltp info --catalog "$CATALOG" --suites-root "$SUITES_ROOT" --profile "$PROFILE" ${LTP_OVERRIDES[@]+"${LTP_OVERRIDES[@]}"})" \
  || static_refuse "cannot evaluate profile '$PROFILE' against the catalog $CATALOG"
[ -z "$(info_kv refusal)" ] || static_refuse "$(info_kv refusal)"
FOOTPRINT_MB="$(info_kv footprint_mb)"; SUITES_CSV="$(info_kv suites)"; NEEDS_MMPROJ="$(info_kv mmproj)"; ALL_VISION="$(info_kv all_vision)"
if [ "$(info_kv large)" = "1" ] && [ "$ALLOW_LARGE" != "1" ]; then
  static_refuse "profile '$PROFILE' is large (min_tier $(info_kv min_tier), catalog footprint ${FOOTPRINT_MB} MiB): it needs the explicit --allow-large (or LT_ALLOW_LARGE=1) AND a plan that says it fits"
fi
fi
IFS=, read -r -a SUITES <<<"$SUITES_CSV"
[ -z "$(info_kv port)" ] || PORT_DEFAULT="$(info_kv port)"      # the catalog's port is the fallback when `llmctl status` has none
[ "${LT_HERMETIC:-0}" = "1" ] && PORT_DEFAULT="${LT_PORT_DEFAULT:-$PORT_DEFAULT}"

umask 077   # evidence (status, logs, outputs) is private: dirs 0700, files 0600
TS="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EVROOT" || { echo "cannot create evidence root $EVROOT" >&2; exit 2; }
EV="$EVROOT/$TS-$PROFILE"; _n=1
while ! mkdir "$EV" 2>/dev/null; do   # one directory per run and profile; a same-second rerun never shares one
  _n=$((_n + 1)); [ "$_n" -le 99 ] || { echo "cannot create evidence dir $EV" >&2; exit 2; }
  EV="$EVROOT/$TS-$PROFILE-$_n"
done
for _n in $OVERRIDE_NAMES; do
  if [ -n "${!_n:-}" ]; then
    if [ "${LT_HERMETIC:-0}" = 1 ]; then echo "HONOURED $_n=${!_n} (LT_HERMETIC=1: TEST RUN, NOT LIVE EVIDENCE)" >>"$EV/overrides.log"
    else echo "IGNORED $_n=${!_n} (LT_HERMETIC!=1)" >>"$EV/overrides.log"; fi
  fi
done
[ -n "${LT_LLMCTL_TREE:-}" ] && echo "HONOURED LT_LLMCTL_TREE=$LT_LLMCTL_TREE (explicit operator override of the llmctl-tree check)" >>"$EV/overrides.log"
[ "${LT_HERMETIC:-0}" = 1 ] && echo "HONOURED LT_HERMETIC=1: thresholds/timeouts may be overridden; this is NOT a live run" >>"$EV/overrides.log"
env | cut -d= -f1 | sort >"$EV/env_names.txt"   # NAMES only, never values (secrets)
CMDLOG="$EV/commands.log"; SIGLOG="$EV/signals.log"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$EV/run.log" >&2; }

WD_PID=""; START_SUB=""; START_PENDING=0; STOP_NEEDED=0; CLEANED=0; RESULT=2; VERDICT_REASON="not finished"
CG_PEAK=UNKNOWN; CG_HIGH=UNKNOWN; CG_MAX=UNKNOWN; GPU_PEAK=UNKNOWN
RESTORE_WORD=none; PRIOR_NAMES=(); PRIOR_RAM=0; PRIOR_VRAM=0; PRIOR_INSTANCES=(); RESTORE_NEEDED=0; RESTORE_DONE=0; RESTORE_RC=0; RESTORE_STATE="n/a (nothing was switched off)"; TARGET_STOP_OK=1
GPU_BASE_RAW=""; GPU_TOTAL=""; GATE_RES="NOT RUN"; READY=0; VRAM_NOTE=""; UNIT_STATE=""; PORT_SERVING=""; UNIT=""; FINAL_STOP_RC="NA"; GPU_BASE=""; GPU_FINAL=""; VALIDATE_RC="NA"; CLEAN_OK="NO"; MH="UNKNOWN"; PH="UNKNOWN"; LSV="UNKNOWN"

print_table() {
  printf '\n%-28s %s\n' "CHECK" "RESULT"
  printf '%-28s %s\n' "profile" "$PROFILE"
  printf '%-28s %s\n' "pre-gate" "$GATE_RES"
  printf '%-28s %s\n' "watchdog trigger" "$([ -s "$EV/trigger" ] && cat "$EV/trigger" || echo none)"
  local READY_TXT=no; [ "$READY" = 1 ] && READY_TXT=up
  printf '%-28s %s\n' "readiness" "$READY_TXT"
  printf '%-28s %s\n' "validate rc" "$VALIDATE_RC"
  printf '%-28s %s\n' "vram base/final MiB" "$GPU_BASE/$GPU_FINAL"
  printf '%-28s %s\n' "vram peak MiB" "$GPU_PEAK"
  printf '%-28s %s\n' "unit MemoryPeak MiB" "$CG_PEAK"
  printf '%-28s %s\n' "unit MemoryHigh MiB" "$CG_HIGH"
  printf '%-28s %s\n' "unit MemoryMax MiB" "$CG_MAX"
  printf '%-28s %s\n' "profile stopped+vram ok" "$CLEAN_OK${VRAM_NOTE:-}"
  printf '%-28s %s\n' "resident set switched off" "$([ "${#PRIOR_NAMES[@]}" -gt 0 ] && echo "${PRIOR_NAMES[*]}" || echo none)"
  printf '%-28s %s\n' "prior set restored" "$RESTORE_STATE"
  printf '%-28s %s\n' "model sha256" "$MH"
  printf '%-28s %s\n' "mmproj sha256" "$PH"
  printf '%-28s %s\n' "llama-server" "$LSV"
  printf '%-28s %s\n' "evidence" "$EV"
  local word=UNDETERMINED
  case "$RESULT" in 0) word=PASS; [ "$GATE_ONLY" = 1 ] && word=GATE-OK ;; 1) word=FAIL ;; 3) word=REFUSED ;; 4) word=ABORTED ;; 5) word=ABORTED-WATCHDOG-DEAD ;; 6) word=RESTORE-SKIPPED ;; 7) word=RESTORE-FAILED ;; *) ;; esac
  [ "$PLAN_ONLY" = 1 ] && [ "$RESULT" = 0 ] && word=PLAN
  printf '%-28s %s (exit %s) - %s\n' "VERDICT" "$word" "$RESULT" "$VERDICT_REASON"
  case "$RESTORE_STATE" in "left to the caller"*) [ "${LT_VIA_RUNNER:-0}" = 1 ] || echo "NOT RESTORED: ${PRIOR_NAMES[*]} stay switched off (--no-restore); run: nice -n 19 ionice -c 3 $LLMCTL start ${PRIOR_NAMES[*]}  (see $EV/RESTORE_MANUAL.txt)" ;; esac
  echo "RESTORE_STATE=${RESTORE_WORD:-none}"
}

# peaks.txt: the resource peaks of THIS profile's run (also for aborted runs): GPU peak from the watchdog's samples,
# the unit's cgroup MemoryPeak/High/Max captured before the stop (UNKNOWN when not captured, never 0).
write_peaks() {
  [ -s "$EV/samples.csv" ] && [ "$GPU_PEAK" = UNKNOWN ] && GPU_PEAK="$(gpu_peak_of "$EV/samples.csv")"
  { echo "profile=$PROFILE"; echo "gpu_peak_mb=$GPU_PEAK"; echo "gpu_baseline_mb=${GPU_BASE:-UNKNOWN}"; echo "gpu_final_mb=${GPU_FINAL:-UNKNOWN}"
    echo "unit_memory_peak_mb=$CG_PEAK"; echo "unit_memory_high_mb=$CG_HIGH"; echo "unit_memory_max_mb=$CG_MAX"; } >"$EV/peaks.txt"
}

# The ONLY place a signal is sent: to the watchdog PID this script started. Logged first.
safe_kill() {
  [ -n "$WD_PID" ] || return 0
  # identity check: only ever signal a live process whose cmdline is our watchdog (PID-reuse safe)
  if [ -r "/proc/$WD_PID/cmdline" ] && tr '\0' ' ' <"/proc/$WD_PID/cmdline" | grep -q 'livetest/watchdog\.sh\|watchdog\.sh .*'"$PROFILE"; then
    echo "$(date -u +%FT%TZ) SIGTERM -> watchdog pid $WD_PID" >>"$SIGLOG"
    kill -TERM "$WD_PID" 2>/dev/null
  else
    echo "$(date -u +%FT%TZ) NOT signalling pid $WD_PID: not (or no longer) our watchdog" >>"$SIGLOG"
  fi
}

wd_alive() {   # alive = exists, is our watchdog, and is not a zombie
  local st
  [ -n "$WD_PID" ] && [ -r "/proc/$WD_PID/cmdline" ] || return 1
  tr '\0' ' ' <"/proc/$WD_PID/cmdline" | grep -q 'watchdog\.sh' || return 1
  st="$(sed 's/^.*) //' "/proc/$WD_PID/stat" 2>/dev/null | cut -c1)"
  [ -n "$st" ] && [ "$st" != Z ] && [ "$st" != X ]
}

run_logged() { echo "$(date -u +%FT%TZ) \$ $*" >>"$CMDLOG"; "$@"; }

# shellcheck disable=SC2329  # invoked via trap
cleanup() {   # always: stop our profile via llmctl, then reap our own watchdog
  trap '' INT TERM HUP   # non-reentrant: further Ctrl-C/TERM while cleaning must not cut the remaining stops short
  [ "$CLEANED" = 1 ] && return; CLEANED=1
  if [ "$STOP_NEEDED" = 1 ]; then
    log "cleanup: llmctl stop $PROFILE"
    "$HERE/watchdog.sh" --stop "$PROFILE" "$EV" >>"$EV/stop.out" 2>&1; local crc=$?
    echo "cleanup stop rc=$crc (0 llmctl ok | 10 systemd fallback | 11 failed)" >>"$EV/stop.out"
    { [ "$crc" = 0 ] || [ "$crc" = 10 ]; } && TARGET_STOP_OK=1
    # a still-running background `llmctl start` may reach svc_start AFTER that stop: wait for it (never signalled), then stop again
    if [ -n "$START_SUB" ] && [ -d "/proc/$START_SUB" ] && [ ! -s "$EV/start.rc" ]; then
      local w=0
      log "cleanup: background start still running; waiting up to ${START_WAIT}s before a second stop"
      while [ -d "/proc/$START_SUB" ] && [ ! -s "$EV/start.rc" ] && [ "$w" -lt "$START_WAIT" ]; do sleep 1; w=$((w+1)); done
      "$HERE/watchdog.sh" --stop "$PROFILE" "$EV" >>"$EV/stop.out" 2>&1; crc=$?
      echo "second cleanup stop (after start ended) rc=$crc" >>"$EV/stop.out"
      { [ "$crc" = 0 ] || [ "$crc" = 10 ]; } && TARGET_STOP_OK=1
      if [ -d "/proc/$START_SUB" ] && [ ! -s "$EV/start.rc" ]; then START_PENDING=1; fi
    fi
  fi
  if [ "$START_PENDING" = 1 ]; then
    # The backgrounded `llmctl start` (queued behind the scheduler flock, which has no timeout) may still reach svc_start.
    # Do NOT reap the watchdog: it outlives us (own session), its parent-gone path stops a late unit and it keeps
    # re-checking while the start process is alive.
    VERDICT_REASON="$VERDICT_REASON | start still pending, watchdog left running (pid $WD_PID) - CHECK llmctl status / systemctl --user is-active $(unit_name)"
    log "$VERDICT_REASON"; echo "$VERDICT_REASON" >"$EV/WATCHDOG_LEFT_RUNNING.txt"
    WD_PID=""
    if [ "$RESTORE_NEEDED" = 1 ] && [ "$RESTORE_DONE" = 0 ]; then RESTORE_DONE=1; restore_skip_all "the start of '$PROFILE' is still pending (watchdog left running): the model may still appear" "${PRIOR_NAMES[@]}"; fi
    return 0
  fi
  safe_kill
  [ -n "$WD_PID" ] && wait "$WD_PID" 2>/dev/null
  restore_if_needed
  return 0
}
# shellcheck disable=SC2329
# machine-readable host-service state, for consumers that only see the exit code (the run's own 1-5 wins over 6/7): ok | manual | failed | none | deferred
restore_word() {
  case "$RESTORE_RC" in 6) echo manual; return ;; 7) echo failed; return ;; esac
  case "$RESTORE_STATE" in YES*) echo ok ;; "left to the caller"*) echo deferred ;; "not yet"*) echo manual ;; *) echo none ;; esac
}
on_exit() {
  local rc=$?; trap '' INT TERM HUP; cleanup; collect_evidence; [ -z "$RESTORE_ONLY" ] && write_peaks
  RESTORE_WORD="$(restore_word)"; echo "$RESTORE_WORD" >"$EV/restore_state"
  if [ "$RESTORE_RC" != 0 ]; then   # a run's own non-zero exit is never masked; a clean run with an unrestored set exits 6/7
    if [ "$rc" = 0 ]; then rc="$RESTORE_RC"; VERDICT_REASON="the run itself PASSed, but the prior set was NOT restored ($RESTORE_STATE) - see RESTORE_MANUAL.txt"
    else VERDICT_REASON="$VERDICT_REASON | PRIOR SET NOT RESTORED ($RESTORE_STATE) - see RESTORE_MANUAL.txt"; fi
  fi
  RESULT="$rc"; print_table | tee "$EV/verdict.txt"; exit "$rc"; }
# shellcheck disable=SC2329
on_sig()  { log "interrupted by signal"; RESULT=2; VERDICT_REASON="interrupted"; exit 2; }
trap on_exit EXIT
trap on_sig INT TERM HUP

refuse() { GATE_RES="REFUSED"; log "REFUSED (gate): $*"; echo "gate REFUSED: $*" >>"$EV/gate.log"; RESULT=3; VERDICT_REASON="gate: $*"; exit 3; }

need() { command -v "$1" >/dev/null 2>&1 || { log "missing tool: $1"; RESULT=2; VERDICT_REASON="missing tool $1"; exit 2; }; }
need python3; need curl; need awk; need "$LLMCTL"; need "$NVSMI"; need nice; need ionice

gpu_query() {   # gpu_query <memory.used|memory.total|memory.free> -> max over GPUs, empty when unreadable
  local o="$EV/.gpu.$BASHPID.$RANDOM"
  if bounded "$BOUND" "$o" "$NVSMI" --query-gpu="$1" --format=csv,noheader,nounits; then
    awk 'BEGIN{m=-1} /^[ \t]*[0-9]+[ \t]*$/{if($1+0>m)m=$1+0} END{if(m>=0)print m}' "$o"
  fi
  rm -f "$o" "$o.rc"
}
gpu_used() { gpu_query memory.used; }

# bounded <secs> <outfile> cmd... : detached with a deadline, never signalled; rc 124 = still running at the deadline.
BOUND=10; [ "${LT_HERMETIC:-0}" = 1 ] && BOUND="${LT_BOUND:-$BOUND}"
bounded() {
  local secs="$1" out="$2" i=0; shift 2
  rm -f "$out.rc"
  ( "$@" >"$out" 2>&1; echo $? >"$out.rc" ) >/dev/null 2>&1 &   # own stdout detached: safe inside $(...)
  while [ ! -s "$out.rc" ] && [ "$i" -lt $((secs * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$out.rc" ] || { echo "$(date -u +%FT%TZ) TIMEOUT ${secs}s: $*" >>"$EV/bounded.log"; return 124; }
  return "$(cat "$out.rc")"
}
# bounded_immune: like bounded, but the job ignores TERM/HUP/INT (ignored dispositions are inherited through exec), so a signal delivered to
# the whole process group (terminal or ssh close, `kill -TERM -PGID` by someone else) cannot kill a restore `llmctl start` half way and
# leave a half-started unit untracked. Nobody is signalled by us (CONST/§11.4.263); the job stays bounded by its deadline (rc 124, never
# killed). LIMIT: SIGKILL cannot be ignored, and the main-flow `llmctl switch` (background job of the driver) is NOT immune - a group
# signal there ends the switch and the cleanup path (stop + restore) takes over.
bounded_immune() {
  local secs="$1" out="$2" i=0; shift 2
  rm -f "$out.rc"
  ( trap '' TERM HUP INT; "$@" >"$out" 2>&1; echo $? >"$out.rc" ) >/dev/null 2>&1 &
  while [ ! -s "$out.rc" ] && [ "$i" -lt $((secs * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$out.rc" ] || { echo "$(date -u +%FT%TZ) TIMEOUT ${secs}s: $*" >>"$EV/bounded.log"; return 124; }
  return "$(cat "$out.rc")"
}
# gpu_peak_of <samples.csv>: max of the column NAMED gpu_used_mb (looked up in the header, never a hard-coded index:
# 3.2.0 read column 6 = io_some_avg10 (a float), so the peak was always reported as 0).
gpu_peak_of() {
  awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="gpu_used_mb") c=i; next} c && $c ~ /^[0-9]+$/ {if($c+0>m)m=$c+0} END{print m+0}' "$1" 2>/dev/null
}
# cg_mib <file> <key>: MiB of a numeric systemd property; infinity / [not set] / uint64-max / missing -> UNKNOWN (never 0)
cg_mib() {
  local v; v="$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1)"
  if [[ "$v" =~ ^[0-9]+$ ]] && [ "${#v}" -lt 19 ]; then echo $(( v / 1048576 )); else echo UNKNOWN; fi
}
status_json() {
  local o="$EV/.status.$BASHPID.$RANDOM"
  bounded "$BOUND" "$o" "$LLMCTL" status --json && cat "$o"
  local rc=$?; rm -f "$o" "$o.rc"; return "$rc"
}


# --- identity of what the unit ACTUALLY loaded: its env file's LLMCTL_ARGS (-m / --mmproj), never a default filename
services_env_file() {
  local inst="$PROFILE"
  [ -n "${LLMCTL_TENANT_ID:-}" ] && inst="${LLMCTL_TENANT_ID}--${PROFILE}"
  echo "${LLMCTL_SERVICES_DIR:-${LLMCTL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/llmctl}/services}/${inst}.env"
}
env_get() {   # env_get <profile> <KEY>: a value from the unit env file llmctl wrote for that profile (empty when absent)
  local inst="${1:-$PROFILE}"; [ -n "${LLMCTL_TENANT_ID:-}" ] && inst="${LLMCTL_TENANT_ID}--${inst}"
  sed -n "s/^$2=//p" "${LLMCTL_SERVICES_DIR:-${LLMCTL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/llmctl}/services}/${inst}.env" 2>/dev/null | tr -d "'" | head -1
}
engine_of() { env_get "${1:-$PROFILE}" LLMCTL_ENGINE; }
unit_name() {   # unit_name [profile]
  local p="${1:-$PROFILE}" inst engine
  inst="$p"; [ -n "${LLMCTL_TENANT_ID:-}" ] && inst="${LLMCTL_TENANT_ID}--${p}"
  engine="$(engine_of "$p")"
  echo "llmctl-${engine:-llama}@${inst}.service"
}
loaded_files() {   # prints two lines: model path, mmproj path (empty when unknown)
  python3 -I -c '
import shlex,sys
model=mm=""
try:
    for line in open(sys.argv[1]):
        if line.startswith("LLMCTL_ARGS="):
            t=shlex.split(line.split("=",1)[1].strip())
            for i,a in enumerate(t[:-1]):
                if a in ("-m","--model"): model=t[i+1]
                if a=="--mmproj": mm=t[i+1]
except Exception: pass
print(model); print(mm)' "$(services_env_file)"
}

# PASS evidence (lt_profiles.py check): the --json output of `llmctl validate` parses; there is exactly one report per suite of
# the profile; each has verdict PASS, no fail/undetermined, every probe PASS, and the probe/control/determinism counts equal what
# the SUITE FILE says the real judge emits (vision: probes + `discriminates` controls + determinism_repeat; chat/coder: cases +
# determinism_repeat; embedding: cases), with counts.pass equal to their sum. Prints OK or the reason.
check_validate_json() {   # check_validate_json <validate.out> -> prints OK or the reason
  local -a sa=(); local x
  for x in "${SUITES[@]}"; do sa+=(--suite "$x"); done
  ltp check --report "$1" --suites-root "$SUITES_ROOT" "${sa[@]}" ${LTP_OVERRIDES[@]+"${LTP_OVERRIDES[@]}"} || echo "validate output cannot be checked (lt_profiles.py failed)"
}

harness_info() {
  { echo "git_head=$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
    echo "git_dirty_files=$(git -C "$HERE" status --porcelain 2>/dev/null | wc -l)"
    bounded "$BOUND" "$EV/.ver" "$LLMCTL" version; echo "llmctl_version=$(head -1 "$EV/.ver" 2>/dev/null)"
    echo "llmctl_path=$(command -v "$LLMCTL")"
    echo "harness_utc=$(date -u +%FT%TZ)"; } >"$EV/harness.txt"
}
START_EPOCH=""
collect_evidence() {   # after the model ran: engine log + unit journal since start (bounded; never fails the run)
  [ -n "$START_EPOCH" ] || return 0
  bounded "$BOUND" "$EV/logs.txt" "$LLMCTL" logs "$PROFILE" 200
  if command -v journalctl >/dev/null 2>&1; then
    bounded "$BOUND" "$EV/journal.txt" journalctl --user -u "$(unit_name)" --since "@${START_EPOCH}" --no-pager -n 400
  else echo "journalctl not available" >"$EV/journal.txt"; fi
}


# ------------------------------------------------------------------ the resident set: record, plan, restore
# What llmctl runs NOW (status json + llmctl units) goes into the evidence before anything is stopped. Fail closed: if the set cannot
# be read, a switch would stop an unknown set, so the run is refused.
record_prior() {
  local st out
  st="$(status_json)" || refuse "llmctl status --json failed: cannot record the running set (a switch would stop it blind)"
  printf '%s\n' "$st" >"$EV/status_before.json"; cp "$EV/status_before.json" "$EV/prior_status.json"
  bounded "$BOUND" "$EV/prior_units.txt" "$SYSCTL" --user list-units --all --plain --no-legend 'llmctl-*@*.service' || echo "(llmctl unit list unavailable)" >>"$EV/prior_units.txt"
  out="$(ltp prior --status "$EV/prior_status.json" --exclude "$PROFILE")" || refuse "llmctl status --json is not parseable: cannot record the running set"
  mapfile -t PRIOR_NAMES < <(printf '%s\n' "$out" | sed -n 's/^profile=//p')
  mapfile -t PRIOR_INSTANCES < <(printf '%s\n' "$out" | sed -n 's/^instance=//p')
  PRIOR_RAM="$(printf '%s\n' "$out" | sed -n 's/^total_ram_mb=//p')"; PRIOR_VRAM="$(printf '%s\n' "$out" | sed -n 's/^total_vram_mb=//p')"
  : "${PRIOR_RAM:=0}" "${PRIOR_VRAM:=0}"
  : >"$EV/prior_set.txt"; local n; for n in ${PRIOR_NAMES[@]+"${PRIOR_NAMES[@]}"}; do echo "$n" >>"$EV/prior_set.txt"; done
  for n in ${PRIOR_INSTANCES[@]+"${PRIOR_INSTANCES[@]}"}; do echo "scaled instance $n (llmctl start brings back ONE instance of the base profile)" >>"$EV/prior_unrestorable.txt"; done
  if [ "${#PRIOR_NAMES[@]}" -gt 0 ]; then
    echo "nice -n 19 ionice -c 3 $LLMCTL start ${PRIOR_NAMES[*]}" >"$EV/RESTORE_MANUAL.txt"
  else RESTORE_STATE="NONE (no other llmctl profile was running)"; echo "nothing to restore (no other llmctl profile was running)" >"$EV/restore.txt"; fi
  log "recorded the running llmctl set: ${PRIOR_NAMES[*]:-<none>} (reserved RAM ${PRIOR_RAM} MiB, VRAM ${PRIOR_VRAM} MiB)"
}

plan_print() {   # --plan: what would happen; nothing is done
  {
    echo "PLAN (dry run: nothing is stopped, started or restored)"
    echo "profile under test: $PROFILE (catalog footprint ${FOOTPRINT_MB} MiB; suites: ${SUITES_CSV}; the plan says it fits)"
    echo "llmctl currently runs: ${PRIOR_NAMES[*]:-nothing}${PRIOR_INSTANCES[*]:+ (+ scaled instances: ${PRIOR_INSTANCES[*]})}"
    echo "would stop (by llmctl's own switch; this interrupts those services, enabled ones such as a decision gateway backend included, for the duration of the run): ${PRIOR_NAMES[*]:-nothing}"
    echo "would start: $PROFILE via: LLMCTL_VALIDATE_ON_START=0 LLMCTL_READY_TIMEOUT=0 nice -n 19 ionice -c 3 $LLMCTL switch $PROFILE (after the pre-gate, under the watchdog)"
    echo "would restore after the run (and after any abort/signal), one at a time, pressure-gated, health-checked: ${PRIOR_NAMES[*]:-nothing}"
    [ "${#PRIOR_NAMES[@]}" -eq 0 ] || echo "  via: nice -n 19 ionice -c 3 $LLMCTL start <profile>"
  } | tee "$EV/plan.txt"
}

read_pressure() {   # sets R_MEM R_PS R_PF R_IS R_IF (empty = unreadable)
  R_MEM=$(awk '/^MemAvailable:/{printf "%d",$2/1024}' "$MEMINFO" 2>/dev/null)
  R_PS=$(awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$PSI" 2>/dev/null)
  R_PF=$(awk '$1=="full"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$PSI" 2>/dev/null)
  R_IS=$(awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$IOPSI" 2>/dev/null)
  R_IF=$(awk '$1=="full"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$IOPSI" 2>/dev/null)
}
RESTORE_WHY=""
restore_gate() {   # restore_gate <ram_mb of the profile to restart>: 0 = the host may take it; else RESTORE_WHY says why not
  local need
  read_pressure
  if [ -z "$R_MEM" ] || [ -z "$R_PS" ] || [ -z "$R_PF" ] || [ -z "$R_IS" ] || [ -z "$R_IF" ]; then RESTORE_WHY="a pressure sensor is unreadable"; return 1; fi
  awk -v p="$R_PS" -v m="$GATE_MAX_PSI_SOME" 'BEGIN{exit !(p<m)}' || { RESTORE_WHY="memory PSI some avg10 ${R_PS} not < ${GATE_MAX_PSI_SOME} (host under pressure)"; return 1; }
  awk -v p="$R_PF" -v m="$GATE_MAX_PSI_FULL" 'BEGIN{exit !(p<m)}' || { RESTORE_WHY="memory PSI full avg10 ${R_PF} not < ${GATE_MAX_PSI_FULL} (host under pressure)"; return 1; }
  awk -v p="$R_IS" -v m="$GATE_MAX_IO_SOME" 'BEGIN{exit !(p<m)}' || { RESTORE_WHY="IO PSI some avg10 ${R_IS} not < ${GATE_MAX_IO_SOME} (host under pressure)"; return 1; }
  awk -v p="$R_IF" -v m="$GATE_MAX_IO_FULL" 'BEGIN{exit !(p<m)}' || { RESTORE_WHY="IO PSI full avg10 ${R_IF} not < ${GATE_MAX_IO_FULL} (host under pressure)"; return 1; }
  if [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; then
    need=$(( $1 + RESTORE_HEADROOM_MB )); [ "$R_MEM" -ge "$need" ] || { RESTORE_WHY="MemAvailable ${R_MEM} MiB < ${need} (the profile's reserved RAM ${1} + ${RESTORE_HEADROOM_MB} headroom; both are estimates)"; return 1; }
  else
    need="$RESTORE_UNKNOWN_FLOOR_MB"; [ "$R_MEM" -ge "$need" ] || { RESTORE_WHY="MemAvailable ${R_MEM} MiB < ${need} (reserved RAM unknown for this profile: conservative default floor)"; return 1; }
  fi
  return 0
}

restore_row_of() {   # restore_row_of <profile> -> "port" of its running row in `llmctl status --json`; rc 0 running (port may be empty), rc 1 not running
  local st; st="$(status_json)" || return 2
  printf '%s' "$st" | python3 -I -c '
import json,sys
try: rows=json.load(sys.stdin)
except Exception: sys.exit(2)
for r in rows:
    if r.get("profile")==sys.argv[1] and str(r.get("state","")).startswith("running"):
        print(r.get("port") or ""); sys.exit(0)
sys.exit(1)' "$1"
}
restore_healthy() {   # restore_healthy <profile> [row-port]: the profile's own health endpoint answers; no port known -> its llmctl unit is active
  local p="$1" port="${2:-}" path
  path="$(env_get "$p" LLMCTL_REG_HEALTH)"   # llmctl's registry health path, any engine (portreg_health_path)
  if [ -z "$path" ]; then path=/health; [ "$(engine_of "$p")" = onnx ] && path=/healthz; fi
  [ -n "$port" ] || port="$(env_get "$p" LLMCTL_PORT)"
  if [ -n "$port" ]; then curl -fsS --max-time 3 "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; return $?; fi
  bounded "$BOUND" "$EV/.ra.$p" "$SYSCTL" --user is-active "$(unit_name "$p")"; local rc=$?
  [ "$rc" = 0 ] && [ "$(head -1 "$EV/.ra.$p" 2>/dev/null)" = active ]
}
restore_manual_note() {   # restore_manual_note <names...>: loud, exact, in the evidence
  local cmd="nice -n 19 ionice -c 3 $LLMCTL start $*" i
  : >"$EV/RESTORE_MANUAL.txt"
  [ "$#" -eq 0 ] || { echo "$cmd" >>"$EV/RESTORE_MANUAL.txt"; log "RESTORE MANUALLY (the host is not touched any further by this tool): $cmd"; }
  for i in ${INST_OPEN[@]+"${INST_OPEN[@]}"}; do
    echo "scaled instance $i was running: nice -n 19 ionice -c 3 $LLMCTL decide scale ${i%%.*} $(inst_count "${i%%.*}")   # 'llmctl start' brings back ONE instance only" >>"$EV/RESTORE_MANUAL.txt"
    log "RESTORE MANUALLY: scaled instance $i: $LLMCTL decide scale ${i%%.*} $(inst_count "${i%%.*}")"
  done
}
restore_skip_all() {   # restore_skip_all <reason> <names...>
  local why="$1" n; shift
  : >"$EV/restore.txt"
  for n in "$@"; do printf '%-18s SKIPPED (%s)\n' "$n" "$why" >>"$EV/restore.txt"; done
  RESTORE_RC=6; RESTORE_STATE="NO (SKIPPED: $why)"
  log "RESTORE SKIPPED: $why - the prior set (${*}) is NOT running"
  restore_manual_note "$@"
}
# restore_set <names...>: llmctl start per profile, bounded, pressure-gated before EACH start, health-verified. Idempotent: a profile that
# already runs (and is healthy) is left alone. A profile whose reserved RAM is unknown/zero/non-numeric needs a conservative default floor.
# SIGNALS: the first INT/TERM/HUP finishes the start attempt in flight (llmctl runs it detached; abandoning it would leave an untracked
# half-started unit), then no further profile is started: the rest is SKIPPED (interrupted), the exact commands go to RESTORE_MANUAL.txt
# and the exit is 6. A second signal changes nothing (the in-flight start is still tracked). SIGKILL cannot be handled: documented gap.
# RESTORE_RC: 0 ok | 6 something skipped (pressure / interrupted) | 7 something failed.
RESTORE_INTR=0; INST_OPEN=()
inst_count() {   # inst_count <base>: how many instances of <base> were running (the base itself + its p.N rows)
  local c=0 n; for n in ${PRIOR_NAMES[@]+"${PRIOR_NAMES[@]}"}; do [ "$n" = "$1" ] && c=$((c + 1)); done
  for n in ${PRIOR_INSTANCES[@]+"${PRIOR_INSTANCES[@]}"}; do [ "${n%%.*}" = "$1" ] && c=$((c + 1)); done
  echo "$c"
}
restore_set() {
  local n ram port rc deadline failed=() skipped=() okc=0 ramfile="$EV/.ram.map" out
  RESTORE_INTR=0; trap 'RESTORE_INTR=$((RESTORE_INTR + 1))' INT TERM HUP
  : >"$EV/restore.txt"
  if [ "$#" -eq 0 ] && [ "${#PRIOR_INSTANCES[@]}" -eq 0 ]; then
    echo "nothing to restore (no other llmctl profile was running)" >"$EV/restore.txt"; RESTORE_STATE="NONE (no other llmctl profile was running)"; return 0
  fi
  if [ -s "$EV/prior_status.json" ]; then ltp prior --status "$EV/prior_status.json" --exclude "$PROFILE" | sed -n 's/^ram=//p' >"$ramfile"; else : >"$ramfile"; fi
  for n in "$@"; do
    if [ "$RESTORE_INTR" -gt 0 ]; then
      printf '%-18s SKIPPED (interrupted: restore stopped after the profile in flight)\n' "$n" >>"$EV/restore.txt"; skipped+=("$n"); RESTORE_WHY="interrupted by a signal"; continue
    fi
    ram="$(sed -n "s/^${n}://p" "$ramfile" | head -1)"; : "${ram:=0}"
    if port="$(restore_row_of "$n")"; then   # already running: idempotent, only verify
      deadline=$(( $(date +%s) + RESTORE_READY_MAX ))
      while ! restore_healthy "$n" "$port"; do [ "$(date +%s)" -lt "$deadline" ] && [ "$RESTORE_INTR" = 0 ] || break; sleep "$READY_INTERVAL"; done
      if restore_healthy "$n" "$port"; then printf '%-18s ALREADY RUNNING (healthy)\n' "$n" >>"$EV/restore.txt"; okc=$((okc+1))
      else printf '%-18s FAILED (running but not healthy within %ss)\n' "$n" "$RESTORE_READY_MAX" >>"$EV/restore.txt"; failed+=("$n"); fi
      continue
    fi
    if ! restore_gate "$ram"; then printf '%-18s SKIPPED (%s)\n' "$n" "$RESTORE_WHY" >>"$EV/restore.txt"; skipped+=("$n"); continue; fi
    echo "$(date -u +%FT%TZ) \$ LLMCTL_VALIDATE_ON_START=0 nice -n 19 ionice -c 3 $LLMCTL start $n" >>"$CMDLOG"
    rc=0; bounded_immune "$RESTORE_BOUND" "$EV/restore.$n.out" env LLMCTL_VALIDATE_ON_START=0 nice -n 19 ionice -c 3 "$LLMCTL" start "$n" || rc=$?
    if [ "$rc" = 124 ]; then printf '%-18s FAILED (llmctl start still running after %ss; never signalled)\n' "$n" "$RESTORE_BOUND" >>"$EV/restore.txt"; failed+=("$n"); continue; fi
    if [ "$rc" != 0 ]; then printf '%-18s FAILED (llmctl start rc=%s: %s)\n' "$n" "$rc" "$(tail -1 "$EV/restore.$n.out" 2>/dev/null | cut -c1-120)" >>"$EV/restore.txt"; failed+=("$n"); continue; fi
    port="$(restore_row_of "$n")"; : "${port:=}"
    deadline=$(( $(date +%s) + RESTORE_READY_MAX ))
    while ! restore_healthy "$n" "$port"; do [ "$(date +%s)" -lt "$deadline" ] && [ "$RESTORE_INTR" = 0 ] || break; sleep "$READY_INTERVAL"; done
    if restore_healthy "$n" "$port"; then printf '%-18s RESTORED (healthy)\n' "$n" >>"$EV/restore.txt"; okc=$((okc+1))
    elif [ "$RESTORE_INTR" -gt 0 ]; then printf '%-18s SKIPPED (interrupted: started, health NOT verified - check llmctl status)\n' "$n" >>"$EV/restore.txt"; skipped+=("$n"); RESTORE_WHY="interrupted by a signal"
    else printf '%-18s FAILED (started but not healthy within %ss)\n' "$n" "$RESTORE_READY_MAX" >>"$EV/restore.txt"; failed+=("$n"); fi
  done
  INST_OPEN=()
  for n in ${PRIOR_INSTANCES[@]+"${PRIOR_INSTANCES[@]}"}; do
    # llmctl's own switch rollback may already have brought the instance back: look at the CURRENT status before calling it lost
    if restore_row_of "$n" >/dev/null; then printf '%-18s ALREADY RUNNING (llmctl status lists the instance again)\n' "$n" >>"$EV/restore.txt"; okc=$((okc+1))
    else printf '%-18s FAILED (scaled instance not running; llmctl start restores ONE instance only; run: %s decide scale %s %s)\n' "$n" "$LLMCTL" "${n%%.*}" "$(inst_count "${n%%.*}")" >>"$EV/restore.txt"; failed+=("$n"); INST_OPEN+=("$n"); fi
  done
  status_json >"$EV/after_status.json" 2>/dev/null; bounded "$BOUND" "$EV/after_units.txt" "$SYSCTL" --user list-units --all --plain --no-legend 'llmctl-*@*.service' || true
  local manual=()
  if [ "${#failed[@]}" -gt 0 ]; then
    for n in "${failed[@]}" ${skipped[@]+"${skipped[@]}"}; do [[ "$n" == *.* ]] || manual+=("$n"); done
    RESTORE_RC=7; RESTORE_STATE="NO (FAILED: ${failed[*]}${skipped[*]:+; SKIPPED: ${skipped[*]}})"
    log "RESTORE FAILED for: ${failed[*]} - see $EV/restore.txt"; restore_manual_note ${manual[@]+"${manual[@]}"}
  elif [ "${#skipped[@]}" -gt 0 ]; then
    RESTORE_RC=6; RESTORE_STATE="NO (SKIPPED: ${skipped[*]}: $RESTORE_WHY)"
    log "RESTORE SKIPPED for: ${skipped[*]} ($RESTORE_WHY)"; restore_manual_note "${skipped[@]}"
  else RESTORE_RC=0; RESTORE_STATE="YES"; log "prior set restored: $okc profile(s), each verified healthy"; fi
  out="$(sed 's/^/  /' "$EV/restore.txt")"; log "restore result:"$'\n'"$out"
}
restore_if_needed() {   # called by cleanup, after the test model is stopped and our watchdog is reaped
  [ "$RESTORE_NEEDED" = 1 ] && [ "$RESTORE_DONE" = 0 ] || return 0
  RESTORE_DONE=1
  if [ "$TARGET_STOP_OK" != 1 ]; then restore_skip_all "the stop of '$PROFILE' is not confirmed: never bringing models back while it may still run" "${PRIOR_NAMES[@]}"; return 0; fi
  restore_set "${PRIOR_NAMES[@]}"
}
restore_only_main() {   # --restore-only <set-file>: used by the runner for the end of a sequence
  local -a names=(); local n
  while IFS= read -r n; do [[ "$n" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] && names+=("$n"); done <"$RESTORE_ONLY"
  PRIOR_NAMES=("${names[@]}")
  local d po; d="$(dirname "$RESTORE_ONLY")"
  if [ -s "$d/prior_status.json" ]; then   # the scaled instances (p.N) the set file cannot carry come from the recorded status
    cp "$d/prior_status.json" "$EV/prior_status.json"
    po="$(ltp prior --status "$EV/prior_status.json")" && mapfile -t PRIOR_INSTANCES < <(printf '%s\n' "$po" | sed -n 's/^instance=//p')
  fi
  restore_set "${names[@]}"
  VERDICT_REASON="restore of ${#names[@]} profile(s): $RESTORE_STATE"
  exit "$RESTORE_RC"
}

# ------------------------------------------------------------------ (a) pre-gate
gate() {
  local mem psi_s psi_f io_s io_f gpu st
  mem=$(awk '/^MemAvailable:/{printf "%d",$2/1024}' "$MEMINFO" 2>/dev/null)
  psi_s=$(awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$PSI" 2>/dev/null)
  psi_f=$(awk '$1=="full"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$PSI" 2>/dev/null)
  gpu=$(gpu_used)
  local mem_raw="$mem" gpu_raw="$gpu"
  # the switch stops the resident set, so the RAM/VRAM llmctl has reserved for it counts as free (an estimate: the status json reservations)
  [ -z "$mem" ] || mem=$(( mem + PRIOR_RAM ))
  [ -z "$gpu" ] || { gpu=$(( gpu - PRIOR_VRAM )); [ "$gpu" -ge 0 ] || gpu=0; }
  io_s=$(awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$IOPSI" 2>/dev/null)
  io_f=$(awk '$1=="full"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$IOPSI" 2>/dev/null)
  { echo "resident_set=${PRIOR_NAMES[*]:-none} reserved_ram_MiB=$PRIOR_RAM reserved_vram_MiB=$PRIOR_VRAM measured_mem_MiB=${mem_raw:-UNREADABLE} measured_gpu_used_MiB=${gpu_raw:-UNREADABLE} (effective values below add/subtract the reservations)"
    echo "MemAvailable_MiB=${mem:-UNREADABLE} psi_some=${psi_s:-UNREADABLE} psi_full=${psi_f:-UNREADABLE} gpu_used_MiB=${gpu:-UNREADABLE} io_some=${io_s:-UNREADABLE} io_full=${io_f:-UNREADABLE}"; } | tee "$EV/gate.log" >&2
  [ -n "$mem" ]   || refuse "cannot read MemAvailable"
  [ -n "$psi_s" ] && [ -n "$psi_f" ] || refuse "cannot read memory PSI"
  [ -n "$io_s" ] && [ -n "$io_f" ] || refuse "cannot read IO PSI"
  awk -v p="$io_s" -v m="$GATE_MAX_IO_SOME" 'BEGIN{exit !(p<m)}' || refuse "IO PSI some avg10 ${io_s} not < ${GATE_MAX_IO_SOME}"
  awk -v p="$io_f" -v m="$GATE_MAX_IO_FULL" 'BEGIN{exit !(p<m)}' || refuse "IO PSI full avg10 ${io_f} not < ${GATE_MAX_IO_FULL}"
  [ -n "$gpu" ]   || refuse "cannot read GPU memory (nvidia-smi)"
  # the reservation credit must never lower the watchdog's floor: the watchdog checks RAW MemAvailable while the resident set is still
  # loaded, so a run that passes only thanks to the credit would be aborted (exit 4) AFTER the switch had stopped the resident set
  [ "$mem_raw" -ge $(( WD_MIN_MEM_MB + WD_RAW_MARGIN_MB )) ] || refuse "RAW MemAvailable ${mem_raw} MiB < watchdog floor ${WD_MIN_MEM_MB} + ${WD_RAW_MARGIN_MB} margin (the resident set's reserved RAM is credited only above that floor; nothing was switched off)"
  [ "$mem" -ge "$GATE_MIN_MEM_MB" ] || refuse "MemAvailable ${mem} MiB < ${GATE_MIN_MEM_MB} (floor 12000 or catalog footprint ${FOOTPRINT_MB} + 4096 + 2048)"
  awk -v p="$psi_s" -v m="$GATE_MAX_PSI_SOME" 'BEGIN{exit !(p<m)}' || refuse "PSI some avg10 ${psi_s} not < ${GATE_MAX_PSI_SOME}"
  awk -v p="$psi_f" -v m="$GATE_MAX_PSI_FULL" 'BEGIN{exit !(p<m)}' || refuse "PSI full avg10 ${psi_f} not < ${GATE_MAX_PSI_FULL}"
  [ "$gpu" -lt "$GATE_MAX_GPU_MB" ] || refuse "GPU used ${gpu} MiB not < ${GATE_MAX_GPU_MB}"
  GPU_BASE="$gpu"; GPU_BASE_RAW="${gpu_raw:-$gpu}"
  # free VRAM must cover the plan's VRAM for the profile + margin (only when the profile uses the GPU); the absolute GPU-used gate above stays
  GPU_TOTAL=""
  if [ "$VRAM_NEED_MB" -gt 0 ]; then
    local gfree; gfree="$(gpu_query memory.free)"; GPU_TOTAL="$(gpu_query memory.total)"
    [ -z "$gfree" ] || gfree=$(( gfree + PRIOR_VRAM ))
    [ -n "$gfree" ] || refuse "cannot read free GPU memory (nvidia-smi memory.free) while '$PROFILE' needs ${VRAM_NEED_MB} MiB of VRAM"
    [ "$gfree" -ge "$GATE_MIN_FREE_VRAM_MB" ] || refuse "free VRAM ${gfree} MiB < ${GATE_MIN_FREE_VRAM_MB} (plan VRAM ${VRAM_NEED_MB} + 1024 margin)"
  else GPU_TOTAL="$(gpu_query memory.total)"; fi

  # --- preconditions that must fail BEFORE any model is started ---
  local tree real
  tree="${LT_LLMCTL_TREE:-}"; [ -n "$tree" ] || { [ "${LT_HERMETIC:-0}" = 1 ] || tree="$(readlink -f "$HERE/../..")"; }
  if [ -n "$tree" ]; then
    real="$(readlink -f "$(command -v "$LLMCTL")" 2>/dev/null)"
    case "$real" in "$(readlink -f "$tree")"/*) ;; *) refuse "llmctl ($real) not inside this tree ($tree): the installed llmctl may lack vision validate/--host (set LT_LLMCTL_TREE to override explicitly)" ;; esac
    echo "llmctl tree check: $real inside $tree" >>"$EV/gate.log"
  fi
  # The scheduler flock (lib/scheduler.sh scheduler::with_lock) has NO timeout: if someone holds it, our start and our
  # stops would queue behind it. Non-blocking shared probe, released immediately; never held past the check.
  local rt lock holder
  if [ -n "${LLMCTL_RUNTIME_DIR:-}" ]; then rt="$LLMCTL_RUNTIME_DIR"
  elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then rt="$XDG_RUNTIME_DIR/llmctl"
  else rt="${LLMCTL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/llmctl}/run"; fi
  lock="$rt/.scheduler.lock"
  if [ -e "$lock" ] && command -v flock >/dev/null 2>&1 && ! flock -n -s "$lock" true; then
    holder="$(fuser "$lock" 2>&1 | tr '\n' ' ')"; [ -n "$holder" ] || holder="holder unknown (fuser unavailable)"
    refuse "scheduler lock $lock is held by someone else ($holder): another llmctl operation is running; wait for it"
  fi
  echo "scheduler lock $lock: free" >>"$EV/gate.log"

  # the status read happened in record_prior (status_before.json): the profile itself must not run; a profile in a failed state is a refusal.
  # Other RUNNING profiles are not a refusal any more: llmctl's switch stops them and we restore them afterwards.
  local verdict
  verdict="$(python3 -I -c '
import json,sys
prof=sys.argv[2]
try: rows=json.load(open(sys.argv[1]))
except Exception as e: print("BAD status json: %s"%e); sys.exit(0)
for r in rows:
    if r.get("profile","").split(".")[0]==prof: print("profile %s already running/reserved"%prof); sys.exit(0)
    if not str(r.get("state","")).startswith("running"): print("profile %s state=%s"%(r.get("profile"),r.get("state"))); sys.exit(0)
print("OK")' "$EV/status_before.json" "$PROFILE")"
  echo "status check: $verdict" >>"$EV/gate.log"
  [ "$verdict" = "OK" ] || refuse "$verdict"

  command -v "$SYSCTL" >/dev/null 2>&1 || refuse "systemctl unavailable: cannot verify unit state"
  local units
  units="$("$SYSCTL" --user list-units --all --plain --no-legend "llmctl-*@${PROFILE}*.service" 2>&1)" || refuse "systemctl list-units failed"
  printf '%s\n' "$units" >"$EV/units_before.txt"
  if printf '%s\n' "$units" | grep -Eiq '(failed|activating|auto-restart)'; then
    refuse "llmctl unit for $PROFILE is failed/restarting: $(printf '%s' "$units" | grep -Ei '(failed|activating|auto-restart)' | head -1)"
  fi
  GATE_RES="PASS"; echo "gate: PASS" >>"$EV/gate.log"; log "gate PASS (mem=${mem}MiB psi=${psi_s}/${psi_f} gpu=${gpu}MiB)"
}
# ------------------------------------------------------------------ (a0) eligibility, part 2: plan fits + checksum verified
# `llmctl plan --json` is read-only (hardware probe + catalog); only stdout is the JSON (stderr kept apart).
eligibility() {
  local rc=0 fits_out why
  bounded "$PLAN_BOUND" "$EV/plan.json" bash -c '"$@" 2>"$0"' "$EV/plan.err" "$LLMCTL" plan --json || rc=$?
  [ "$rc" = 0 ] || refuse "llmctl plan --json failed or timed out (rc=$rc): cannot tell whether '$PROFILE' fits this host"
  fits_out="$(ltp fits --plan "$EV/plan.json" --profile "$PROFILE" --footprint-mb "$FOOTPRINT_MB")" || refuse "llmctl plan --json output is not usable"
  why="$(printf '%s\n' "$fits_out" | sed -n 's/^refusal=//p' | head -1)"
  [ -z "$why" ] || refuse "$why"
  printf '%s\n' "$fits_out" >"$EV/plan_fits.txt"
  GATE_MIN_MEM_MB="$(printf '%s\n' "$fits_out" | sed -n 's/^gate_min_mem_mb=//p')"
  GATE_MIN_FREE_VRAM_MB="$(printf '%s\n' "$fits_out" | sed -n 's/^gate_min_free_vram_mb=//p')"
  VRAM_NEED_MB="$(printf '%s\n' "$fits_out" | sed -n 's/^vram_need_mb=//p')"
  case "$GATE_MIN_MEM_MB$GATE_MIN_FREE_VRAM_MB$VRAM_NEED_MB" in ''|*[!0-9]*) refuse "plan-derived gate thresholds are not numbers" ;; esac
  # the checksum of what is on disk must verify (hashes GBs: niced, bounded, never signalled; a timeout is a refusal, never a pass).
  # --gate-only (the runner's between-runs re-check) leaves it to the real run: it re-checks the HOST, and must not re-hash GBs.
  { [ "$GATE_ONLY" = 1 ] || [ "$PLAN_ONLY" = 1 ]; } && return 0
  rc=0
  bounded "$VERIFY_BOUND" "$EV/verify.out" nice -n 19 ionice -c 3 "$LLMCTL" models verify "$PROFILE" || rc=$?
  echo "$(date -u +%FT%TZ) \$ nice -n 19 ionice -c 3 $LLMCTL models verify $PROFILE -> rc=$rc" >>"$CMDLOG"
  if [ "$rc" = 124 ]; then refuse "checksum verification of '$PROFILE' did not finish within ${VERIFY_BOUND}s (not verified)"
  elif [ "$rc" != 0 ]; then refuse "checksum NOT verified: 'llmctl models verify $PROFILE' rc=$rc (profile not downloaded or files do not match the catalog sha256; see verify.out)"; fi
}
if [ -n "$RESTORE_ONLY" ]; then restore_only_main; fi
harness_info
eligibility
record_prior
if [ "$PLAN_ONLY" = 1 ]; then plan_print; RESULT=0; VERDICT_REASON="plan only: nothing was stopped, started or restored"; exit 0; fi
gate

# watchdog limits derived from the footprint with the absolute floors: memory abort floor 5000 MiB is never lowered (the gate already
# guarantees >= footprint + 6 GiB before the start, so a legitimate load stays above it); the GPU ceiling is max(11500, baseline + plan
# VRAM + 1024), capped at (card total - 256) when the total is readable (a small card lowers it: lower is safer).
WD_MAX_GPU_MB=$(( GPU_BASE + VRAM_NEED_MB + 1024 )); [ "$WD_MAX_GPU_MB" -ge 11500 ] || WD_MAX_GPU_MB=11500
if [ -n "$GPU_TOTAL" ] && [ "$GPU_TOTAL" -gt 256 ] && [ "$WD_MAX_GPU_MB" -gt $(( GPU_TOTAL - 256 )) ]; then WD_MAX_GPU_MB=$(( GPU_TOTAL - 256 )); fi
{ echo "profile=$PROFILE"; echo "suites=$SUITES_CSV"; echo "allow_large=$ALLOW_LARGE"; echo "footprint_mb=$FOOTPRINT_MB"; echo "vram_need_mb=$VRAM_NEED_MB"
  echo "gate_min_mem_mb=$GATE_MIN_MEM_MB"; echo "gate_min_free_vram_mb=$GATE_MIN_FREE_VRAM_MB"; echo "gpu_total_mb=${GPU_TOTAL:-UNKNOWN}"
  echo "wd_min_mem_mb=$WD_MIN_MEM_MB"; echo "wd_max_gpu_mb=$WD_MAX_GPU_MB"; echo "catalog=$CATALOG"; } >"$EV/thresholds.txt"
if [ "$GATE_ONLY" = 1 ]; then
  RESULT=0; VERDICT_REASON="gate only: every refusal check and the pre-gate passed; NOTHING was started (this is not a test result)"; log "$VERDICT_REASON"; exit 0
fi

# ------------------------------------------------------------------ (b) watchdog BEFORE the model
# own session/process group (setsid execs in place for a background job, so $! is still the watchdog PID): a
# group-directed signal aimed at the driver (e.g. Ctrl-C / kill -- -PGID) does not also take out the guard.
if command -v setsid >/dev/null 2>&1; then setsid "$HERE/watchdog.sh" "$PROFILE" "$EV" "$$" --min-mem-mb "$WD_MIN_MEM_MB" --max-gpu-mb "$WD_MAX_GPU_MB" >>"$EV/watchdog.out" 2>&1 &
else "$HERE/watchdog.sh" "$PROFILE" "$EV" "$$" --min-mem-mb "$WD_MIN_MEM_MB" --max-gpu-mb "$WD_MAX_GPU_MB" >>"$EV/watchdog.out" 2>&1 & echo "setsid unavailable: watchdog shares the driver process group" >>"$EV/overrides.log"; fi
WD_PID=$!
echo "$(date -u +%FT%TZ) started watchdog pid $WD_PID" >>"$SIGLOG"
for _ in $(seq 1 20); do [ "$(wc -l 2>/dev/null <"$EV/samples.csv" || echo 0)" -ge 2 ] && break; sleep 0.5; done
[ "$(wc -l 2>/dev/null <"$EV/samples.csv" || echo 0)" -ge 2 ] || { log "watchdog produced no sample; not starting the model"; RESULT=2; VERDICT_REASON="watchdog not sampling"; exit 2; }
log "watchdog running (pid $WD_PID)"

triggered() { [ -s "$EV/trigger" ]; }
guard() {   # watchdog fired -> 4; watchdog dead without a trigger -> 5 (model must never run unguarded)
  abort_if_triggered
  if ! wd_alive; then
    sleep 0.5; abort_if_triggered   # it may have just fired and exited
    RESULT=5; VERDICT_REASON="watchdog died/is not alive: model would run unguarded -> aborted and stopped"
    log "$VERDICT_REASON"; exit 5
  fi
}
abort_if_triggered() {
  if triggered; then RESULT=4; VERDICT_REASON="watchdog: $(cat "$EV/trigger")"; log "ABORTED by watchdog: $(cat "$EV/trigger")"; exit 4; fi
}

# ------------------------------------------------------------------ (c) start + readiness
guard   # last look at the watchdog (trigger / death) BEFORE the resident set is switched off
STOP_NEEDED=1; TARGET_STOP_OK=0; START_EPOCH=$(date +%s)
if [ "${#PRIOR_NAMES[@]}" -gt 0 ] || [ "${#PRIOR_INSTANCES[@]}" -gt 0 ]; then
  if [ "$NO_RESTORE" = 1 ]; then
    RESTORE_STATE="left to the caller (--no-restore): ${PRIOR_NAMES[*]}"
    if [ "${LT_VIA_RUNNER:-0}" != 1 ]; then
      echo "WARNING: --no-restore: the running llmctl set (${PRIOR_NAMES[*]}${PRIOR_INSTANCES[*]:+ + instances ${PRIOR_INSTANCES[*]}}) will be switched off and NOT restored by this run; restore it yourself (exact command in $EV/RESTORE_MANUAL.txt): nice -n 19 ionice -c 3 $LLMCTL start ${PRIOR_NAMES[*]}" >&2
    fi
  else RESTORE_NEEDED=1; RESTORE_STATE="not yet (pending)"; fi
fi
log "starting: LLMCTL_VALIDATE_ON_START=0 nice -n 19 ionice -c 3 $LLMCTL switch $PROFILE (llmctl stops the resident set: ${PRIOR_NAMES[*]:-none})"
echo "$(date -u +%FT%TZ) \$ LLMCTL_VALIDATE_ON_START=0 LLMCTL_READY_TIMEOUT=0 nice -n 19 ionice -c 3 $LLMCTL switch $PROFILE (background; stops: ${PRIOR_NAMES[*]:-none})" >>"$CMDLOG"
# `llmctl start` holds the scheduler flock across svc_start (+ its own readiness wait). LLMCTL_READY_TIMEOUT=0
# (verified in lib/scheduler.sh _sched_wait_ready: <=0 disables the wait) makes it return right after svc_start,
# releasing the lock so a watchdog stop is never queued behind the model load; WE poll readiness below, with
# watchdog checks, under our own deadline. The start runs in the background so a breach during it is seen at once.
rm -f "$EV/start.rc"
( LLMCTL_VALIDATE_ON_START=0 LLMCTL_READY_TIMEOUT=0 nice -n 19 ionice -c 3 "$LLMCTL" switch "$PROFILE" >"$EV/start.out" 2>&1; echo $? >"$EV/start.rc" ) &
START_SUB=$!; echo "$START_SUB" >"$EV/start.pid"
t0=$(date +%s)
while [ ! -s "$EV/start.rc" ]; do
  guard
  [ $(( $(date +%s) - t0 )) -lt "$START_MAX" ] || { RESULT=2; VERDICT_REASON="llmctl start did not return within ${START_MAX}s"; exit 2; }
  sleep 0.3
done
START_RC="$(cat "$EV/start.rc")"
echo "start rc=$START_RC" >>"$EV/start.out"
abort_if_triggered
[ "$START_RC" = 0 ] || { RESULT=2; VERDICT_REASON="llmctl start rc=$START_RC"; exit 2; }

PORT="$(status_json | python3 -I -c '
import json,sys
try:
    for r in json.load(sys.stdin):
        if r.get("profile")==sys.argv[1] and r.get("port"): print(int(r["port"])); break
except Exception: pass' "$PROFILE" 2>/dev/null)"
[ -n "$PORT" ] || PORT="$PORT_DEFAULT"
URL="http://127.0.0.1:${PORT}"
log "waiting for $URL/health (every ${READY_INTERVAL}s, max ${READY_MAX}s)"
READY=0; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$READY_MAX" ]; do
  guard
  if curl -fsS --max-time 3 "$URL/health" >"$EV/health.out" 2>>"$EV/health.err"; then READY=1; break; fi
  sleep "$READY_INTERVAL"
done
abort_if_triggered
[ "$READY" = 1 ] || { RESULT=2; VERDICT_REASON="not ready within ${READY_MAX}s"; exit 2; }
log "ready: $(head -c 200 "$EV/health.out")"
{ read -r LOADED_MODEL; read -r LOADED_MMPROJ; } < <(loaded_files)
echo "unit_env=$(services_env_file) model=${LOADED_MODEL:-UNKNOWN} mmproj=${LOADED_MMPROJ:-UNKNOWN}" >"$EV/loaded_files.txt"

# ------------------------------------------------------------------ (d) known-answer probes
HAVE_VV=0
if [ "$ALL_VISION" = 1 ]; then
  if bounded "$BOUND" "$EV/.vhelp" "$LLMCTL" vision help && grep -q 'vision validate' "$EV/.vhelp" && grep -q -- '--host' "$EV/.vhelp"; then HAVE_VV=1; fi
  VV_NAME="'vision validate --host'"
else
  if bounded "$BOUND" "$EV/.vhelp" "$LLMCTL" help && grep -Eq 'validate <profile> \[--host' "$EV/.vhelp"; then HAVE_VV=1; fi
  VV_NAME="'validate <profile> --host'"
fi
[ "$HAVE_VV" = 1 ] || { RESULT=2; VERDICT_REASON="installed llmctl has no $VV_NAME (without --host validate could restart the model); scratch harness not used live"; exit 2; }
# Immediately before validate: the profile must be up (health answers). validate gets --host so it validates an
# explicit endpoint and can NEVER start the profile itself (without --host, lib/validate.sh calls sched_start when
# there is no .run file, which a stop removes - an un-niced, un-gated restart). --host also means the verdict is
# evidence only and is not recorded as local validation state (fine: our evidence is the captured output).
guard
curl -fsS --max-time 3 "$URL/health" >/dev/null 2>&1 || { RESULT=2; VERDICT_REASON="profile not up immediately before validate"; exit 2; }
if [ "$ALL_VISION" = 1 ]; then VCMD=(nice -n 19 ionice -c 3 "$LLMCTL" vision validate --profile "$PROFILE" --host "$URL" --json --keep)
else VCMD=(nice -n 19 ionice -c 3 "$LLMCTL" validate "$PROFILE" --host "$URL" --json --keep); fi
echo "$(date -u +%FT%TZ) \$ ${VCMD[*]}" >>"$CMDLOG"
"${VCMD[@]}" >"$EV/validate.out" 2>"$EV/validate.err" &
VPID=$!
while [ -d "/proc/$VPID" ]; do
  if triggered || ! wd_alive; then
    log "watchdog fired/died during validation; giving the client ${VALIDATE_GRACE}s to fail by itself (never signalled)"
    g=0; while [ -d "/proc/$VPID" ] && [ "$g" -lt "$VALIDATE_GRACE" ]; do sleep 1; g=$((g+1)); done
    break
  fi
  sleep 1
done
if [ -d "/proc/$VPID" ]; then VALIDATE_RC="HUNG"; else wait "$VPID"; VALIDATE_RC=$?; fi
echo "$VALIDATE_RC" >"$EV/validate.rc"
guard

# ------------------------------------------------------------------ (e) finalize: stop, confirm, identity
# cgroup peak of the running unit, captured BEFORE the stop destroys it (calibration datum; bounded, never signalled)
bounded "$BOUND" "$EV/cgroup_peak.txt" "$SYSCTL" --user show -p MemoryPeak -p MemoryHigh -p MemoryMax "$(unit_name)" || true
CG_PEAK="$(cg_mib "$EV/cgroup_peak.txt" MemoryPeak)"; CG_HIGH="$(cg_mib "$EV/cgroup_peak.txt" MemoryHigh)"; CG_MAX="$(cg_mib "$EV/cgroup_peak.txt" MemoryMax)"
log "final: llmctl stop $PROFILE"
"$HERE/watchdog.sh" --stop "$PROFILE" "$EV" >>"$EV/stop.out" 2>&1; FINAL_STOP_RC=$?; echo "final stop rc=$FINAL_STOP_RC (0 llmctl ok | 10 systemd fallback | 11 failed)" >>"$EV/stop.out"
if [ "$FINAL_STOP_RC" != 0 ] && [ "$FINAL_STOP_RC" != 10 ]; then
  # neither llmctl nor systemd stopped it: the model may still be running. Keep STOP_NEEDED and the watchdog;
  # the EXIT trap retries the stop (and only then reaps the watchdog).
  RESULT=2; VERDICT_REASON="stop failed (rc=$FINAL_STOP_RC: llmctl stop and systemd stop both failed); retrying in cleanup, MODEL MAY STILL BE RUNNING - check manually"
  log "$VERDICT_REASON"; exit 2
fi
STOP_NEEDED=0; TARGET_STOP_OK=1
safe_kill; wait "$WD_PID" 2>/dev/null; WD_PID=""
abort_if_triggered   # a trigger recorded just before we reaped the watchdog still counts

# keep sampling VRAM after the stop so recovery (or a leak) is on record; last sample is the final value
echo "utc,gpu_used_mb" >"$EV/post_stop_samples.csv"
for _ in $(seq 1 "$POST_SAMPLE"); do
  GPU_FINAL="$(gpu_used)"; echo "$(date -u +%FT%TZ),${GPU_FINAL:-NA}" >>"$EV/post_stop_samples.csv"; sleep 1
done
status_json >"$EV/status_after.json" 2>&1
STILL="$(python3 -I -c '
import json,sys
try: print("yes" if any(r.get("profile","").split(".")[0]==sys.argv[1] for r in json.load(open(sys.argv[2]))) else "no")
except Exception: print("unknown")' "$PROFILE" "$EV/status_after.json")"
UNIT="$(unit_name)"
bounded "$BOUND" "$EV/.unit_active" "$SYSCTL" --user is-active "$UNIT"; echo "unit=$UNIT is-active: $(tr '\n' ' ' <"$EV/.unit_active" 2>/dev/null)" >"$EV/post_stop_state.txt"
UNIT_STATE="$(head -1 "$EV/.unit_active" 2>/dev/null)"
PORT_SERVING=no; curl -fsS --max-time 3 "$URL/health" >/dev/null 2>&1 && PORT_SERVING=yes
echo "port $PORT health still answering: $PORT_SERVING" >>"$EV/post_stop_state.txt"
GPU_PEAK="$(gpu_peak_of "$EV/samples.csv")"
VRAM_NOTE=""; [ $(( ${GPU_PEAK:-0} - ${GPU_BASE:-0} )) -lt 200 ] && VRAM_NOTE=" (VRAM check informational: no GPU use observed, peak ${GPU_PEAK}MiB)"
# VRAM must be back to the baseline; with a resident set switched off the baseline is the MEASURED pre-switch value (the status-json
# reservations used to lower it for the gate are estimates, so they must not make a clean stop look like a leak)
CLEAN_BASE="$GPU_BASE"; [ "$PRIOR_VRAM" -gt 0 ] && CLEAN_BASE="${GPU_BASE_RAW:-$GPU_BASE}"
if [ "$STILL" = "no" ] && [ -n "$GPU_FINAL" ] && [ "$GPU_FINAL" -le $((CLEAN_BASE + VRAM_SLACK_MB)) ]; then CLEAN_OK="YES"; fi

hash_of() { if [ -n "$1" ] && [ -f "$1" ]; then nice -n 19 ionice -c 3 sha256sum "$1" | awk '{print $1}'; else echo "MISSING"; fi; }
MH="$(hash_of "${LOADED_MODEL:-}")"
if [ "$NEEDS_MMPROJ" = 1 ]; then PH="$(hash_of "${LOADED_MMPROJ:-}")"; else PH="N/A"; fi   # only profiles whose catalog has an mmproj file need one
JSON_VERDICT="$(check_validate_json "$EV/validate.out")"; echo "$JSON_VERDICT" >"$EV/validate_check.txt"
bounded "$BOUND" "$EV/.lsv" "$LLAMA_BIN" --version; LSV="$(tr '\n' ' ' <"$EV/.lsv" 2>/dev/null | cut -c1-300)"; [ -n "$LSV" ] || LSV="UNKNOWN"
{ echo "model_sha256=$MH"; echo "mmproj_sha256=$PH"; echo "llama_server_version=$LSV"; echo "gpu_baseline_mb=$GPU_BASE gpu_final_mb=$GPU_FINAL"; } >"$EV/identity.txt"

if [ "$VALIDATE_RC" = 1 ]; then RESULT=1; VERDICT_REASON="wrong answer(s): validate rc=1"
elif [ "$VALIDATE_RC" != 0 ]; then RESULT=2; VERDICT_REASON="validate rc=$VALIDATE_RC (could not determine)"
elif [ "$JSON_VERDICT" != OK ]; then RESULT=2; VERDICT_REASON="$JSON_VERDICT"
elif [ "$MH" = MISSING ] || [ "$PH" = MISSING ]; then RESULT=2; VERDICT_REASON="hash of the model$([ "$NEEDS_MMPROJ" = 1 ] && echo "/mmproj") the unit loaded not capturable"
elif [ "$FINAL_STOP_RC" != 0 ]; then RESULT=2; VERDICT_REASON="final stop was not a clean llmctl stop (rc=$FINAL_STOP_RC; 10 = only the systemd fallback worked, 11 = failed)"
elif [ "$UNIT_STATE" != inactive ] && [ "$UNIT_STATE" != failed ]; then RESULT=2; VERDICT_REASON="unit $UNIT state '${UNIT_STATE:-<empty/timeout>}' is not inactive/failed after stop"
elif [ "$PORT_SERVING" = yes ]; then RESULT=2; VERDICT_REASON="port $PORT still answering /health after stop"
elif [ "$CLEAN_OK" != YES ]; then RESULT=2; VERDICT_REASON="cleanup not confirmed (vram base=$GPU_BASE final=$GPU_FINAL still_running=$STILL)"
else RESULT=0; VERDICT_REASON="all known-answer probes matched; evidence captured; VRAM back to baseline"; fi

exit "$RESULT"
