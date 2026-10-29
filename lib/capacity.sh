#!/usr/bin/env bash
# capacity.sh - "can this host run a local model NOW, next to its current workload?" (3.4.0)
#
# capacity_json [profile...] measures the live host every time it runs (nothing is cached): MemAvailable, swap, PSI
# (memory / cpu / io), load, the user service manager's cgroup limits, the limits and memory of every running llmctl
# engine unit, and the host-reserve policy (lib/reserve.sh). For every catalog profile (or the ones named) it returns
# a verdict:
#   fits                        the profile's full CPU cap and memory limit fit the remaining model budget
#   fits_with_reduced_threads   memory fits, but only fewer CPUs than the profile's cap are left (>= 1); `start` then
#                               runs it with that many threads and that CPU quota
#   does_not_fit                memory, CPU, the planner or the current pressure say no; `start` refuses with 75
#   undetermined                the measurement did not finish in its time budget or a probe failed (3.4.0 review r2);
#                               `start` refuses with 75, the fallback is never "local"
#   running                     not a candidate verdict: THIS host's own unit instance of the profile (tenant key +
#                               primary name) is already up; other instances/tenants of the profile only count as usage
# Each verdict also carries the anchor vocabulary in "verdict_class" (fits | fits_reduced | does_not_fit | undetermined,
# null for running) and the fallback a "route" (local | hosted | none) next to llmctl's "recommended" name.
# plus the largest decision profile that fits, every running unit's state (ok | degraded, with a suggestion to stop it),
# and a machine-readable fallback recommendation: "cloud" when no local decision model fits and a hosted-key VARIABLE is
# set (detected by name only, the value is never read into the output), "local" when one fits, "none" otherwise.
# Every probe and the whole measurement are time-bounded (LLMCTL_CAPACITY_PROBE_TIMEOUT, LLMCTL_CAPACITY_TIMEOUT).
# Schema: docs/capacity.md (llmctl.capacity/1).

set -euo pipefail

[[ -n "${_LLMCTL_CAPACITY_SH:-}" ]] && return 0
_LLMCTL_CAPACITY_SH=1

# Names of the variables that carry a hosted decision (Jev) key. Only their PRESENCE is checked.
LLMCTL_HOSTED_KEY_VARS="${LLMCTL_HOSTED_KEY_VARS:-TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_API_KEY}"

# _cap_psi <file> <some|full> -> avg10 (empty when unreadable)
_cap_psi() {
  [[ -r "$1" ]] || return 0
  awk -v k="$2" '$1==k{for(i=2;i<=NF;i++) if($i ~ /^avg10=/){sub(/avg10=/,"",$i); print $i; exit}}' "$1" 2>/dev/null || true
}

# _cap_unit_profile <unit-name> -> the profile instance of an engine unit name (llmctl-llama@decide-tiny.service).
_cap_unit_profile() { local n="${1#*@}"; echo "${n%.service}"; }

# --- time bounds (3.4.0 review round 2, F2) -------------------------------------------------------------------------
# A hung probe (an nvidia-smi stuck on a wedged driver, measured: the CLI hung until killed) must never hang `start`,
# `llmctl capacity` or llmctld. Every probe gets LLMCTL_CAPACITY_PROBE_TIMEOUT seconds (default 3, 1..30, never more than
# the whole) and the whole measurement LLMCTL_CAPACITY_TIMEOUT seconds (default 5, 2..30); a measurement that does not
# finish is "undetermined": refused with 75 and a cloud|none fallback, never "local". (A healthy measurement takes
# about 0.8 s on the reference host.)

# _cap_budgets -> sets CAP_T (whole measurement) and CAP_PT (one probe), clamped.
_cap_budgets() {
  CAP_T="$(_rsv_int "${LLMCTL_CAPACITY_TIMEOUT:-}" 5 2 30)"
  CAP_PT="$(_rsv_int "${LLMCTL_CAPACITY_PROBE_TIMEOUT:-}" 3 1 30)"
  (( CAP_PT > CAP_T )) && CAP_PT="${CAP_T}"
  return 0
}

# _cap_pid_start <pid> -> the process start time (field 22 of /proc/<pid>/stat); fails when the process is gone.
_cap_pid_start() {
  local s f; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*) }"; read -r -a f <<<"${s}"; [[ -n "${f[19]:-}" ]] || return 1; printf '%s' "${f[19]}"
}

# _cap_ppid_table -> "pid ppid" lines for every process, in ONE scan of the process table (no command-line match).
_cap_ppid_table() {
  if command -v ps >/dev/null 2>&1 && ps -e -o pid=,ppid= 2>/dev/null; then return 0; fi
  local d s f
  for d in /proc/[0-9]*; do
    read -r s < "${d}/stat" 2>/dev/null || continue; s="${s##*) }"; read -r -a f <<<"${s}"
    [[ -n "${f[1]:-}" ]] && printf '%s %s\n' "${d#/proc/}" "${f[1]}"
  done
  return 0
}

# _cap_tree_collect <pid> - collect a background measurement subshell this shell started and everything below it into
# _CAP_KT_ALL (pids, parent first) and _CAP_KT_ST (their start times), STOPping each pid so it cannot fork while the
# tree is walked. Only that tree is touched (§11.4.174): the root is our own `$!`, the rest is found by parent pid; every
# pid is checked to be > 1 and not this shell. The start time is read again AFTER the STOP: a pid that changed between
# the read and the STOP (it exited and the number was reused by an unrelated process) is CONTinued and skipped, so a
# reused pid is never left stopped and never collected (review round 3, item 7). One process-table snapshot per pass;
# passes repeat until one adds nothing (a child forked between a snapshot and its parent's STOP is caught by the next).
_CAP_KT_ALL=(); _CAP_KT_ST=()
_cap_tree_collect() {
  local root="$1" p k k2 pass added c pp
  _CAP_KT_ALL=(); _CAP_KT_ST=()
  [[ "${root}" =~ ^[0-9]+$ ]] && (( root > 1 )) || return 0
  local -a all=() st=() q=()
  local -A seen=() kids=()
  for pass in 1 2 3 4 5; do
    kids=(); added=0
    while read -r c pp; do [[ -n "${pp}" ]] && kids[${pp}]+=" ${c}"; done < <(_cap_ppid_table)
    q=("${root}")
    while (( ${#q[@]} )); do
      p="${q[0]}"; q=("${q[@]:1}")
      [[ "${p}" =~ ^[0-9]+$ ]] && (( p > 1 && p != $$ && p != BASHPID )) || continue
      if [[ -z "${seen[${p}]:-}" ]]; then
      k="$(_cap_pid_start "${p}")" || continue
      kill -STOP "${p}" 2>/dev/null || true   # no new children while the tree is collected
      k2="$(_cap_pid_start "${p}" 2>/dev/null || true)"
      if [[ "${k2}" != "${k}" ]]; then kill -CONT "${p}" 2>/dev/null || true; continue; fi
      all+=("${p}"); st+=("${k}"); seen[${p}]=1; added=1
      fi
      for c in ${kids[${p}]:-}; do q+=("${c}"); done
    done
    (( added )) || break
  done
  _CAP_KT_ALL=("${all[@]}"); _CAP_KT_ST=("${st[@]}")
  return 0
}

# _cap_tree_kill - SIGKILL every pid _cap_tree_collect recorded, each only while its recorded start time still matches.
_cap_tree_kill() {
  local i
  local -a all=("${_CAP_KT_ALL[@]}") st=("${_CAP_KT_ST[@]}")
  for i in "${!all[@]}"; do
    [[ "$(_cap_pid_start "${all[i]}" 2>/dev/null || true)" == "${st[i]}" ]] && kill -KILL "${all[i]}" 2>/dev/null
  done
  return 0
}

# _cap_kill_tree <pid> - collect the measurement subshell tree, then SIGKILL it.
_cap_kill_tree() { _cap_tree_collect "$1"; _cap_tree_kill; }

# _cap_bounded <seconds> <outfile> <cmd...> - run cmd (a shell function is fine) in a background subshell with stdout to
# outfile; rc 124 and the whole subshell tree killed when it is still running after <seconds>, else cmd's rc. The
# subshell writes to a FILE, never to a pipe of a command substitution, so a stuck grandchild cannot hold `$(...)` open.
# The bound is wall-clock elapsed time (review round 3, item 6).
_cap_bounded() {
  local secs="$1" out="$2" pid deadline
  shift 2
  deadline=$(( $(_cap_now_ms) + secs * 1000 ))
  ( "$@" ) > "${out}" 2>/dev/null < /dev/null &
  pid=$!
  while [[ -d "/proc/${pid}" && "$(awk '{print $3}' "/proc/${pid}/stat" 2>/dev/null)" != Z ]]; do
    if (( $(_cap_now_ms) >= deadline )); then
      _cap_kill_tree "${pid}"
      wait "${pid}" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
  done
  wait "${pid}"
}

# _cap_now_ms -> wall-clock milliseconds (bash EPOCHREALTIME; `date +%s%N` where bash is older than 5.0). The bound is
# elapsed time, never a count of 0.1 s polls: a loaded host stretches each poll, an iteration count would not notice.
_cap_now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then local t="${EPOCHREALTIME/[.,]/}"; echo "${t:0:${#t}-3}"
  else local t; t="$(date +%s%N)"; echo "${t:0:${#t}-6}"; fi
}

# _cap_key_real <VAR> - rc 0 when the variable holds a real-looking key: non-empty and not a placeholder. The rule is
# the constitution's key_state (§11.4.279(E), scripts/jev/lib_keys.sh): a known dummy value, fewer than 16 characters,
# one repeated character or a control character is a placeholder (treated as absent). The value is only compared here;
# it is never printed, logged or put on a command line (§11.4.10).
_cap_key_real() {
  local v="$1" k lk
  [[ "${v}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  k="${!v:-}"
  [[ -n "${k}" ]] || return 1
  lk="${k,,}"
  case "${lk}" in
    x|xx|xxx|changeme|change-me|replace-me|replaceme|your-key-here|your_api_key|placeholder|dummy|test|none|null|todo|empty|"<"*">") return 1 ;;
  esac
  (( ${#k} >= 16 )) || return 1
  [[ -n "${k//"${k:0:1}"/}" ]] || return 1
  case "${k}" in *[[:cntrl:]]*) return 1 ;; esac
  return 0
}

# _cap_key_var -> the NAME of the first hosted-key variable that holds a real key (never its value); empty if none.
_cap_key_var() {
  local v
  for v in ${LLMCTL_HOSTED_KEY_VARS}; do
    if _cap_key_real "${v}"; then echo "${v}"; return 0; fi
  done
  return 0
}

# _cap_undetermined_doc <reason> [profile...] - the llmctl.capacity/1 document of a measurement that could not finish:
# every named profile "undetermined", measurement.ok false, fallback cloud|none (route hosted|none), never local.
_cap_undetermined_doc() {
  local reason="$1"; shift
  # no reserve_compute here: it reads /proc and could be the very read that hung; RSV_* are reported when already known
  CAP_REASON="${reason}" CAP_KEYVAR="$(_cap_key_var)" CAP_KEYVARS="${LLMCTL_HOSTED_KEY_VARS}" \
  CAP_T="${CAP_T:-}" CAP_PT="${CAP_PT:-}" CAP_ENABLED="$(reserve_enabled && echo 1 || echo 0)" \
  CAP_N="${RSV_N:-}" CAP_RC="${RSV_RC:-}" CAP_BC="${RSV_BC:-}" CAP_RSET="${RSV_RESERVED_SET:-}" CAP_MSET="${RSV_CPUSET:-}" \
  CAP_CHAT="${RSV_CHAT_CPUS:-}" CAP_DECIDE="${RSV_DECIDE_CPUS:-}" CAP_RM="${RSV_RM:-}" CAP_BM="${RSV_BM:-}" \
    python3 - "$@" <<'PYEOF'
import json, os, sys, time
E = os.environ
def i(k):
    v = E.get(k, "")
    return int(v) if v.isdigit() else None
reason = E.get("CAP_REASON") or "the host capacity could not be determined"
keyvar = E.get("CAP_KEYVAR") or None
fb = {"recommended": "cloud" if keyvar else "none", "route": "hosted" if keyvar else "none",
      "reason": "the host capacity could not be determined (%s); %s" % (
          reason, "a hosted decision key is set" if keyvar else "none of %s is set" % E.get("CAP_KEYVARS")),
      "key_variable": keyvar}
profiles = {p: {"class": None, "verdict": "undetermined", "verdict_class": "undetermined", "running": False,
                "reasons": [reason], "threads": 0, "headroom": None} for p in sys.argv[1:]}
doc = {
    "schema": "llmctl.capacity/1", "time": int(time.time()),
    "measurement": {"ok": False, "reason": reason, "timeout_s": i("CAP_T"), "probe_timeout_s": i("CAP_PT")},
    "host": {"cpus_online": i("CAP_N"), "mem_total_mb": None, "mem_available_mb": None, "usable_mem_mb": None,
             "swap_total_mb": None, "swap_free_mb": None, "load": None,
             "psi": {"memory": {"some": None, "full": None}, "cpu": {"some": None}, "io": {"some": None, "full": None}},
             "cgroup": None, "nproc": None},
    "inputs": {},
    "reserve": {"enabled": E.get("CAP_ENABLED") == "1", "cpus_reserved": i("CAP_RC"), "cpus_reserved_set": E.get("CAP_RSET"),
                "cpus_model_budget": i("CAP_BC"), "cpus_model_set": E.get("CAP_MSET"), "chat_cpu_cap": i("CAP_CHAT"),
                "decide_cpu_cap": i("CAP_DECIDE"), "mem_reserved_mb": i("CAP_RM"), "mem_model_budget_mb": i("CAP_BM")},
    "llmctl": {"units": [], "cpu_pct_used": None, "mem_limits_used_mb": None, "cpu_pct_free": None, "mem_budget_free_mb": None},
    "pressure": {"ok": False, "reasons": [reason]},
    "profiles": profiles, "unknown_profiles": [], "largest_decision_fit": None, "degraded": False, "fallback": fb,
}
print(json.dumps(doc, sort_keys=True))
PYEOF
}

# capacity_json [profile...] - prints the capacity document (one JSON object), within LLMCTL_CAPACITY_TIMEOUT seconds.
# rc 0 with an "undetermined" document when the measurement times out or fails (the caller gets a verdict either way).
capacity_json() {
  _cap_budgets
  local tdir out rc=0
  if ! tdir="$(mktemp -d)"; then
    _cap_undetermined_doc "no scratch directory for the measurement" "$@"; return 0
  fi
  out="${tdir}/doc.json"
  _CAP_TMPDIR="${tdir}" _cap_bounded "${CAP_T}" "${out}" _cap_measure "$@" || rc=$?
  if (( rc == 0 )) && [[ -s "${out}" ]]; then
    cat -- "${out}"
  elif (( rc == 124 )); then
    _cap_undetermined_doc "the capacity measurement did not finish within ${CAP_T} s (LLMCTL_CAPACITY_TIMEOUT)" "$@"
  else
    _cap_undetermined_doc "the capacity measurement failed (rc ${rc})" "$@"
  fi
  rm -rf -- "${tdir:?}"
  return 0
}

# _cap_plan_probe - the hardware probe and the planner (the step that runs nvidia-smi / rocm-smi).
_cap_plan_probe() { set -o pipefail; hw_probe_json | catalog_plan_json; }

# _cap_in <name> <source> <0|1> - record one input of the §11.4.291(C) contract: where it was read, when, whether it
# could be read. An unreadable input is recorded as unreadable (its value is null), never defaulted.
_cap_in() { _CAP_INPUTS+="$1"$'\t'"$3"$'\t'"$(_cap_now_ms)"$'\t'"$2"$'\n'; }

# _cap_cpu_stat <cpu.stat file> -> "nr_periods nr_throttled throttled_usec" ("? ? ?" when unreadable)
_cap_cpu_stat() {
  awk '$1=="nr_periods"{p=$2} $1=="nr_throttled"{t=$2} $1=="throttled_usec"{u=$2}
       END{printf "%s %s %s", (p==""?"?":p), (t==""?"?":t), (u==""?"?":u)}' "$1" 2>/dev/null || printf '? ? ?'
}

# _cap_measure [profile...] - the measurement itself; runs inside _cap_bounded (capacity_json).
_cap_measure() {
  _CAP_INPUTS=""
  reserve_compute
  local mi="${LLMCTL_MEMINFO_FILE:-/proc/meminfo}" la="${LLMCTL_LOADAVG_FILE:-/proc/loadavg}"
  local pdir="${LLMCTL_PSI_DIR:-/proc/pressure}"
  local mpsi="${LLMCTL_PSI_FILE:-${pdir}/memory}" cpsi="${LLMCTL_CPU_PSI_FILE:-${pdir}/cpu}" ipsi="${LLMCTL_IO_PSI_FILE:-${pdir}/io}"
  local root; root="$(_rsv_cgroup_root)"
  local plan_file="${_CAP_TMPDIR:?}/plan.json" prc=0
  _cap_bounded "${CAP_PT}" "${plan_file}" _cap_plan_probe || prc=$?
  if (( prc == 124 )); then
    _cap_undetermined_doc "the hardware/plan probe did not finish within ${CAP_PT} s (LLMCTL_CAPACITY_PROBE_TIMEOUT)" "$@"
    return 0
  fi
  if (( prc != 0 )) || ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("profiles"), dict) else 1)' "${plan_file}" 2>/dev/null; then
    _cap_undetermined_doc "the hardware/plan probe failed (llmctl plan --json); the capacity cannot be judged without it" "$@"
    return 0
  fi
  _cap_in plan "llmctl plan --json (hw_probe_json | catalog_plan_json)" 1
  local units="" name cpu mem d cur cg_err census="" owner scan; scan="$(_rsv_units_scan)"; scan="${scan% *}"
  # the unit census must be readable (review round 5, R5-1): an unreadable tree is a critical input, never "0 units"
  cg_err="$(_rsv_units_unmeasurable)"
  if [[ -z "${cg_err}" ]] && ! census="$(reserve_running_units)"; then cg_err="the unit census under ${scan} failed"; fi
  while read -r name cpu mem owner d; do
    [[ -n "${name}" ]] || continue
    cur="$(head -1 "${d}/memory.current" 2>/dev/null || true)"
    [[ "${cur}" =~ ^[0-9]+$ ]] && cur=$(( cur / 1048576 )) || cur=""
    units+="${name} $(_cap_unit_profile "${name}") ${cpu} ${mem} ${cur:-?} $(_cap_cpu_stat "${d}/cpu.stat") ${owner} ${d}"$'\n'
  done <<< "${census}"
  if [[ -z "${cg_err}" ]]; then _cap_in units "${scan} (llmctl engine unit cgroups, every owner)" 1; else _cap_in units "${scan} (llmctl engine unit cgroups, every owner)" 0; fi
  local decide
  decide="$(reserve_decide_profiles 2>/dev/null || true)"
  local keyvar; keyvar="$(_cap_key_var)"
  local cg_mmax="" cg_mcur="" cg_cmax="" cg_cstat="" in_mi="" in_la="" in_ms="" in_mf="" in_cs="" in_is="" in_if=""
  if cg_mmax="$(head -1 "${root}/memory.max" 2>/dev/null)"; then _cap_in cgroup_memory_max "${root}/memory.max" 1; else cg_mmax=""; _cap_in cgroup_memory_max "${root}/memory.max" 0; fi
  if cg_mcur="$(head -1 "${root}/memory.current" 2>/dev/null)"; then _cap_in cgroup_memory_current "${root}/memory.current" 1; else cg_mcur=""; _cap_in cgroup_memory_current "${root}/memory.current" 0; fi
  if [[ -r "${root}/cpu.max" ]]; then _cap_in cgroup_cpu_max "${root}/cpu.max" 1; else _cap_in cgroup_cpu_max "${root}/cpu.max" 0; fi
  cg_cmax="$(_rsv_cpu_pct "${root}" 2>/dev/null || true)"
  if [[ -r "${root}/cpu.stat" ]]; then _cap_in cgroup_cpu_stat "${root}/cpu.stat" 1; else _cap_in cgroup_cpu_stat "${root}/cpu.stat" 0; fi
  cg_cstat="$(_cap_cpu_stat "${root}/cpu.stat")"
  if in_mi="$(cat "${mi}" 2>/dev/null)"; then _cap_in meminfo "${mi}" 1; else in_mi=""; _cap_in meminfo "${mi}" 0; fi
  if in_la="$(head -1 "${la}" 2>/dev/null)"; then _cap_in loadavg "${la}" 1; else in_la=""; _cap_in loadavg "${la}" 0; fi
  in_ms="$(_cap_psi "${mpsi}" some)"; in_mf="$(_cap_psi "${mpsi}" full)"
  if [[ -n "${in_ms}" ]]; then _cap_in psi_memory "${mpsi}" 1; else _cap_in psi_memory "${mpsi}" 0; fi
  in_cs="$(_cap_psi "${cpsi}" some)"
  if [[ -n "${in_cs}" ]]; then _cap_in psi_cpu "${cpsi}" 1; else _cap_in psi_cpu "${cpsi}" 0; fi
  in_is="$(_cap_psi "${ipsi}" some)"; in_if="$(_cap_psi "${ipsi}" full)"
  if [[ -n "${in_is}" ]]; then _cap_in psi_io "${ipsi}" 1; else _cap_in psi_io "${ipsi}" 0; fi
  CAP_ENABLED="$(reserve_enabled && echo 1 || echo 0)" \
  CAP_N="${RSV_N}" CAP_RC="${RSV_RC}" CAP_BC="${RSV_BC}" CAP_RSET="${RSV_RESERVED_SET}" CAP_MSET="${RSV_CPUSET}" CAP_CPUSHORT="${RSV_CPU_SHORT:-0}" \
  CAP_CHAT="${RSV_CHAT_CPUS}" CAP_DECIDE="${RSV_DECIDE_CPUS}" CAP_MT="${RSV_MT}" CAP_RM="${RSV_RM}" CAP_BM="${RSV_BM}" \
  CAP_CPU_SOME_MAX="${RSV_GATE_CPU_SOME_MAX}" CAP_LOAD_K="${RSV_GATE_LOAD_PER_CPU}" \
  CAP_MEM_FULL_MAX="${LLMCTL_GATE_FULL_MAX:-2}" CAP_MEM_SOME_MAX="${LLMCTL_GATE_SOME_MAX:-10}" \
  CAP_MSOME="${in_ms}" CAP_MFULL="${in_mf}" CAP_CSOME="${in_cs}" CAP_ISOME="${in_is}" CAP_IFULL="${in_if}" \
  CAP_LOAD="${in_la}" CAP_MEMINFO="${in_mi}" CAP_INPUTS="${_CAP_INPUTS}" CAP_CG_CSTAT="${cg_cstat}" \
  CAP_PROC_DIR="${LLMCTL_PROC_DIR:-/proc}" CAP_NPROC_LIMIT="${LLMCTL_NPROC_LIMIT:-}" \
  CAP_UNITS="${units}" CAP_DECIDE_SET="${decide}" CAP_KEYVAR="${keyvar}" CAP_KEYVARS="${LLMCTL_HOSTED_KEY_VARS}" \
  CAP_CG_ROOT="${root}" CAP_UNITS_SCAN="$(_rsv_units_scan)" CAP_SCOPE_MANAGER="$([[ -n "${LLMCTL_CGROUP_ROOT:-}" ]] && echo 1 || echo 0)" CAP_CG_ERR="${cg_err}" CAP_PROC_SELF_PID="${LLMCTL_PROC_SELF_PID:-}" CAP_CG_MMAX="${cg_mmax}" CAP_CG_MCUR="${cg_mcur}" CAP_CG_CMAX="${cg_cmax}" \
  CAP_CHECK_PRESSURE="${LLMCTL_GATE_CPU_CHECKS:-1}" CAP_MEM_SHORT="${RSV_MEM_SHORT}" \
  CAP_NEW_INSTANCES="${_CAP_NEW_INSTANCES:-}" CAP_REPLACE="${_CAP_REPLACE:-}" CAP_TENANT="${LLMCTL_TENANT_ID:-}" \
  CAP_T="${CAP_T:-}" CAP_PT="${CAP_PT:-}" CAP_STRICT="$(_rsv_inputs_strict && echo 1 || echo 0)" \
    python3 - "${plan_file}" "$@" <<'PYEOF'
import json, os, re, sys, time
E = os.environ
def num(k, d=None):
    try: return float(E.get(k, ""))
    except ValueError: return d
def inum(k, d=0):
    v = num(k)
    return int(v) if v is not None else d
plan = {}
try: plan = json.load(open(sys.argv[1]))
except Exception: plan = {}
wanted = sys.argv[2:]
enabled = E.get("CAP_ENABLED") == "1"
N, Rc, Bc = inum("CAP_N", 1), inum("CAP_RC"), inum("CAP_BC", 1)
T, Rm, Bm = inum("CAP_MT"), inum("CAP_RM"), inum("CAP_BM")
chat, decide = inum("CAP_CHAT", 1), inum("CAP_DECIDE", 1)
mi = {}
for line in E.get("CAP_MEMINFO", "").splitlines():
    k, _, rest = line.partition(":")
    parts = rest.split()
    if parts and parts[0].isdigit(): mi[k.strip()] = int(parts[0]) // 1024
avail = mi.get("MemAvailable"); swap_t = mi.get("SwapTotal"); swap_f = mi.get("SwapFree")
la = E.get("CAP_LOAD", "").split()
def _dec(x):
    # a plain non-negative decimal only (review round 4, F1: garbage is unreadable, never a number and never "no load")
    return float(x) if re.fullmatch(r"[0-9]+(\.[0-9]+)?", x or "") else None
load = [_dec(x) for x in la[:3]] if len(la) >= 3 else None
if load is not None and None in load: load = None
psi = {"memory": {"some": _dec(E.get("CAP_MSOME")), "full": _dec(E.get("CAP_MFULL"))}, "cpu": {"some": _dec(E.get("CAP_CSOME"))},
       "io": {"some": _dec(E.get("CAP_ISOME")), "full": _dec(E.get("CAP_IFULL"))}}
def mb_or_none(v):
    v = (v or "").strip()
    return int(v) // 1048576 if v.isdigit() else None
def cpu_stat(txt):
    # cgroup v2 cpu.stat throttle counters (cumulative since the cgroup was created; §11.4.225 diagnoses on DELTAS of two
    # readings over a window, which a caller takes from two documents); None when the file could not be read
    f = (txt or "").split()
    if len(f) != 3 or not all(x.isdigit() for x in f): return None
    return {"nr_periods": int(f[0]), "nr_throttled": int(f[1]), "throttled_usec": int(f[2])}
cg = {"path": E.get("CAP_CG_ROOT"), "memory_max_mb": mb_or_none(E.get("CAP_CG_MMAX")),
      "memory_current_mb": mb_or_none(E.get("CAP_CG_MCUR")),
      "cpu_max_pct": int(E["CAP_CG_CMAX"]) if E.get("CAP_CG_CMAX", "").isdigit() else None,
      "cpu_stat": cpu_stat(E.get("CAP_CG_CSTAT"))}
# --- the §11.4.291(C) input record: source, read time and readability per input ---
inputs = {}
for _line in E.get("CAP_INPUTS", "").splitlines():
    _f = _line.split("\t", 3)
    if len(_f) == 4 and _f[2].isdigit():
        inputs[_f[0]] = {"source": _f[3], "readable": _f[1] == "1", "read_at": int(_f[2]) / 1000.0}
# --- RLIMIT_NPROC headroom (§12.12): the soft limit minus the threads of this real uid. LLMCTL_NPROC_LIMIT can only
# LOWER the limit (a stricter knob, also the test seam); the count reads /proc/<pid>/status (Uid, Threads) and sees only
# this pid namespace, so it is a lower bound of what the kernel counts ---
import resource
_soft, _hard = resource.getrlimit(resource.RLIMIT_NPROC)
nproc_soft = None if _soft == resource.RLIM_INFINITY else _soft
nproc_hard = None if _hard == resource.RLIM_INFINITY else _hard
_lim = E.get("CAP_NPROC_LIMIT", "")
if _lim.isdigit(): nproc_soft = int(_lim) if nproc_soft is None else min(nproc_soft, int(_lim))
_pdir = E.get("CAP_PROC_DIR") or "/proc"
_uid, user_threads, nproc_ok = os.getuid(), 0, True
try:
    _ents = os.listdir(_pdir)
except OSError:
    _ents, nproc_ok = [], False
# control needle (review round 5, R5-6): the census must see the process doing the counting, with this uid. An empty or
# foreign directory, or a /proc that hides other processes' entries, otherwise reads as "0 threads" and passes.
# LLMCTL_PROC_SELF_PID (tests only, with LLMCTL_PROC_DIR) names the fixture entry that stands for this process.
_self = (E.get("CAP_PROC_SELF_PID") or "").strip() or str(os.getpid())
_self_seen = False
for _e in _ents:
    if not _e.isdigit(): continue
    try:
        _uidl = _thr = None
        for _l in open(os.path.join(_pdir, _e, "status")):
            if _l.startswith("Uid:"): _uidl = _l.split()[1]
            elif _l.startswith("Threads:"): _thr = _l.split()[1]
        if _uidl == str(_uid) and _thr and _thr.isdigit():
            user_threads += int(_thr)
            if _e == _self: _self_seen = True
    except (OSError, IndexError):
        continue
if not _self_seen: nproc_ok = False
nproc_headroom = (nproc_soft - user_threads) if (nproc_soft is not None and nproc_ok) else None
inputs["rlimit_nproc"] = {"source": "getrlimit(RLIMIT_NPROC) + %s/<pid>/status Threads of uid %s" % (_pdir, _uid),
                          "readable": nproc_ok, "read_at": time.time()}
nproc = {"rlimit_soft": nproc_soft, "rlimit_hard": nproc_hard, "user_threads": user_threads if nproc_ok else None,
         "headroom": nproc_headroom, "limit_override": int(_lim) if _lim.isdigit() else None,
         "source": inputs["rlimit_nproc"]["source"]}
# usable memory right now: MemAvailable, and the user manager's own memory.max when it is finite
live_avail = avail
# restart: the replaced unit's resident memory comes back when it stops (CAP_REPLACE, see below)
_rep, rep_cur = E.get("CAP_REPLACE", ""), 0
if _rep:
    for _line in E.get("CAP_UNITS", "").splitlines():
        _f = _line.split()
        if len(_f) >= 5 and _f[1] == _rep and _f[4].isdigit() and (_f[8] if len(_f) > 8 else "self") == "self": rep_cur += int(_f[4])
if live_avail is not None: live_avail += rep_cur
if cg["memory_max_mb"] is not None and cg["memory_current_mb"] is not None:
    cg_room = cg["memory_max_mb"] - cg["memory_current_mb"] + rep_cur
    live_avail = cg_room if live_avail is None else min(live_avail, cg_room)
# --- host pressure (the same thresholds as the start gate) ---
pressure = []
if psi["memory"]["full"] is not None and psi["memory"]["full"] > num("CAP_MEM_FULL_MAX", 2):
    pressure.append("memory PSI full avg10=%s > %s" % (psi["memory"]["full"], E.get("CAP_MEM_FULL_MAX")))
if psi["memory"]["some"] is not None and psi["memory"]["some"] > num("CAP_MEM_SOME_MAX", 10):
    pressure.append("memory PSI some avg10=%s > %s" % (psi["memory"]["some"], E.get("CAP_MEM_SOME_MAX")))
if enabled and E.get("CAP_CHECK_PRESSURE", "1") != "0":
    if psi["cpu"]["some"] is not None and psi["cpu"]["some"] > num("CAP_CPU_SOME_MAX", 80):
        pressure.append("cpu PSI some avg10=%s > %s" % (psi["cpu"]["some"], E.get("CAP_CPU_SOME_MAX")))
    if load is not None and load[0] > num("CAP_LOAD_K", 3) * N:
        pressure.append("1-minute load %s > %s x %s CPUs" % (load[0], E.get("CAP_LOAD_K"), N))
if enabled and live_avail is not None and live_avail < Rm:
    pressure.append("only %s MiB available, below the %s MiB host reserve" % (live_avail, Rm))
known = set((plan.get("profiles") or {}).keys())
def base_profile(n):
    # mirrors reserve_base_profile (lib/reserve.sh): "<tenant>--" prefix dropped; ".<N>" (N >= 2) instance suffix dropped
    # only when the full name is not a profile and the base is (review round 1 S4/S7)
    if "--" in n: n = n.rsplit("--", 1)[1]
    if n in known: return n
    m = re.fullmatch(r"(.+)\.([2-9]|[1-9][0-9]+)", n)
    return m.group(1) if m and m.group(1) in known else n
# CAP_NEW_INSTANCES (decide scale): the named profiles are judged as that many NEW instances next to the running ones.
# CAP_REPLACE (restart): the named unit instance is about to be replaced, so its own limits are not counted as used.
new_inst = int(E["CAP_NEW_INSTANCES"]) if E.get("CAP_NEW_INSTANCES", "").isdigit() else 0
replace = E.get("CAP_REPLACE", "")
# --- running llmctl engine units ---
units, used_cpu, used_mem = [], 0, 0
for line in E.get("CAP_UNITS", "").splitlines():
    f = line.split()
    if len(f) < 5: continue
    name, prof, cpu, mem, cur = f[:5]
    ustat = cpu_stat(" ".join(f[5:8]))
    # owner (review round 5, F3): "self" = this user's manager; "user-<uid>" / "system" / "other" units count as
    # consumption but are never this user's instance (not replaced by a restart, never "running", never local)
    owner = f[8] if len(f) > 8 else "self"
    ucg = " ".join(f[9:]) if len(f) > 9 else None
    if replace and prof == replace and owner == "self": continue
    cpu_v = int(cpu) if cpu.isdigit() else Bc * 100
    mem_v = int(mem) if mem.isdigit() else Bm
    used_cpu += cpu_v; used_mem += mem_v
    reasons = list(pressure)
    if cpu == "max": reasons.append("no CPU limit (started by an older llmctl or with LLMCTL_HOST_RESERVE=0)")
    if cur.isdigit() and mem.isdigit() and int(cur) >= int(mem) * 9 // 10:
        reasons.append("memory %s MiB is at >= 90%% of its %s MiB limit" % (cur, mem))
    units.append({"unit": name, "profile": prof, "cpu_quota_pct": cpu_v if cpu.isdigit() else None,
                  "memory_max_mb": mem_v if mem.isdigit() else None,
                  "memory_current_mb": int(cur) if cur.isdigit() else None,
                  "memory_current_provenance": "measured" if cur.isdigit() else None, "cpu_stat": ustat,
                  "status": "degraded" if reasons else "ok", "reasons": reasons,
                  "base_profile": base_profile(prof), "owner": owner, "cgroup": ucg,
                  "suggest": ("llmctl stop %s" % base_profile(prof)) if reasons else None})
# "running" means THIS host's own unit instance of the profile is up: the tenant key + the primary name, exactly as
# _svc_instance_key builds it. Another instance (decide-tiny.2) or another tenant's unit (t1--decide-tiny) of the same
# profile is only consumption, never "already running" (review round 2 F1).
tenant = E.get("CAP_TENANT", "")
unit_keys = {u["profile"] for u in units if u["owner"] == "self"}
def inst_key(p): return ("%s--%s" % (tenant, p)) if tenant else p
cpu_free = Bc * 100 - used_cpu
mem_free = Bm - used_mem
decide_set = set(E.get("CAP_DECIDE_SET", "").split())
lim_one = T * 90 // 100
if enabled and Bm < lim_one: lim_one = Bm
def mem_limit(fp, mode, prov):
    # mirrors _svc_profile_caps (lib/service_linux.sh) - parity is tested
    h = fp * 125 // 100; m = fp * 150 // 100
    if h < 1024: h = 1024
    if m < 1280: m = 1280
    if mode == "gpu" and prov != "measured":
        if h < 5120: h = 5120
        if m < 6144: m = 6144
    if m > lim_one: m = lim_one
    return m
# the anchor vocabulary next to llmctl's own verdict names (review round 2 F4); "running" is a unit state, not a verdict
VCLASS = {"fits": "fits", "fits_with_reduced_threads": "fits_reduced", "does_not_fit": "does_not_fit",
          "undetermined": "undetermined", "running": None}
profiles = {}
for p, info in sorted((plan.get("profiles") or {}).items()):
    if wanted and p not in wanted: continue
    cls = "decide" if p in decide_set else "chat"
    cap = decide if cls == "decide" else chat
    k = new_inst if (new_inst and p in wanted) else 1
    # a named profile being scaled (new instances) or restarted (replace) is judged as a NEW start, never as "running"
    is_running = inst_key(p) in unit_keys and not ((new_inst or replace) and p in wanted)
    fp = int(info.get("ram_mb") or 0) * k
    need_mem = mem_limit(int(info.get("ram_mb") or 0), info.get("mode"), str(info.get("vram_provenance"))) * k
    reasons, verdict, threads = [], "fits", cap
    if is_running:
        reasons.append("already running")
    if enabled and E.get("CAP_MEM_SHORT") == "1":
        reasons.append("the host reserve leaves only %s MiB of model memory (< 512 MiB): this host is too small for a local model" % Bm)
    if info.get("fits") is not True:
        reasons.append("planner: does not fit this host's RAM/VRAM budget (llmctl plan)")
    if enabled and need_mem > mem_free:
        reasons.append("memory limit %s MiB > %s MiB left of the %s MiB model budget" % (need_mem, max(mem_free, 0), Bm))
    if live_avail is not None and live_avail - fp < (Rm if enabled else 4096):
        reasons.append("MemAvailable %s MiB - footprint %s MiB would leave less than the %s MiB host reserve" % (live_avail, fp, Rm if enabled else 4096))
    if enabled and nproc_headroom is not None and nproc_headroom < cap:
        reasons.append("RLIMIT_NPROC headroom %s threads < the %s-thread cap (limit %s, %s threads of this user)" % (nproc_headroom, cap, nproc_soft, user_threads))
    reasons += pressure
    if enabled and not reasons:
        if cpu_free < 100:
            reasons.append("no CPU left in the %s-CPU model budget (%s%% in use)" % (Bc, used_cpu))
        elif k > 1 or (new_inst and p in wanted):
            # new instances start with the full cap (decide scale has no reduced-thread launch)
            if cpu_free < cap * 100 * k:
                reasons.append("%s new instance(s) need %s%% CPU, only %s%% left of the %s-CPU model budget" % (k, cap * 100 * k, cpu_free, Bc))
        elif cpu_free < cap * 100:
            threads = cpu_free // 100
            verdict = "fits_with_reduced_threads"
    if reasons and not is_running: verdict = "does_not_fit"
    elif is_running: verdict = "running"
    profiles[p] = {"class": cls, "verdict": verdict, "reasons": reasons,
                   "verdict_class": VCLASS.get(verdict), "running": verdict == "running",
                   "threads": threads if verdict in ("fits", "fits_with_reduced_threads") else 0,
                   "headroom": {"cpu_pct_free": cpu_free, "cpu_pct_need": cap * 100,
                                "mem_budget_free_mb": mem_free, "mem_limit_need_mb": need_mem,
                                "footprint_mb": fp, "footprint_provenance": "declared",
                                "footprint_source": "llmctl plan --json profiles.%s.ram_mb (the catalog's declared RAM, not a measured run)%s" % (p, " x %s instances" % k if k > 1 else ""),
                                "vram_provenance": info.get("vram_provenance"),
                                "mem_available_after_mb": (live_avail - fp) if live_avail is not None else None}}
fit_dec = [(profiles[p]["headroom"]["footprint_mb"], p) for p in profiles
           if profiles[p]["class"] == "decide" and profiles[p]["verdict"] in ("fits", "fits_with_reduced_threads")]
largest = max(fit_dec)[1] if fit_dec else None
# The fallback is about where DECISIONS go: "local" only while a local decision model fits now or one is running and
# healthy, and never for a refused start (review round 1 S5: a fitting chat profile used to yield "local").
def own_unit(u):
    # this host's / this tenant's own instance (the primary or .N); another tenant's unit is consumption, never a local
    # decision endpoint for this tenant (review round 3, item 1; §11.4.291(E): no fit -> cloud or none, never local)
    if u["owner"] != "self": return False
    return u["profile"].startswith(tenant + "--") if tenant else "--" not in u["profile"]
decision_local = largest is not None or any(own_unit(u) and u["base_profile"] in decide_set and u["status"] == "ok" for u in units)
named_refused = bool(wanted) and (any(profiles.get(p, {}).get("verdict") == "does_not_fit" for p in wanted)
                                  or any(p not in profiles for p in wanted))
blocked = named_refused or not decision_local
keyvar = E.get("CAP_KEYVAR") or None
if not blocked:
    fb = {"recommended": "local", "route": "local", "reason": "a local decision model fits or is running", "key_variable": None}
elif keyvar:
    fb = {"recommended": "cloud", "route": "hosted", "reason": "%s; a hosted decision key is set" % ("the requested start does not fit" if named_refused else "no local decision model can run now"), "key_variable": keyvar}
else:
    fb = {"recommended": "none", "route": "none", "reason": "%s and none of %s is set" % ("the requested start does not fit" if named_refused else "no local decision model can run now", E.get("CAP_KEYVARS")), "key_variable": None}
# --- verdict-critical inputs (review round 4, F1): an input the verdict depends on that is unreadable or unparseable
# makes the whole measurement undetermined (exit 75, fallback cloud|none, never local), instead of silently skipping
# the check it feeds. Critical: meminfo MemAvailable, memory PSI some+full (always); with the host reserve on, also
# CPU PSI some and loadavg (when the CPU checks are on), the cgroup root the llmctl units are counted under, and the
# /proc thread census for RLIMIT_NPROC. Informational only (never critical): io PSI, the cgroup memory.max/current,
# cpu.max and cpu.stat. Linux only: elsewhere these /proc inputs do not exist (docs/capacity.md, "Limits").
def _src(k, d):
    return (inputs.get(k) or {}).get("source") or d
critical = []
if avail is None: critical.append("meminfo MemAvailable (%s)" % _src("meminfo", "/proc/meminfo"))
if psi["memory"]["some"] is None or psi["memory"]["full"] is None:
    critical.append("memory PSI some/full avg10 (%s)" % _src("psi_memory", "/proc/pressure/memory"))
if enabled and E.get("CAP_CHECK_PRESSURE", "1") != "0":
    if psi["cpu"]["some"] is None: critical.append("CPU PSI some avg10 (%s)" % _src("psi_cpu", "/proc/pressure/cpu"))
    if load is None: critical.append("loadavg (%s)" % _src("loadavg", "/proc/loadavg"))
if enabled and E.get("CAP_CG_ERR"):
    critical.append("the cgroup tree the llmctl units are counted under (%s: %s)" % (E.get("CAP_CG_ROOT"), E.get("CAP_CG_ERR")))
if enabled and not nproc_ok:
    critical.append("the thread census for RLIMIT_NPROC (%s%s)" % (_pdir, "" if _self_seen else ": it did not see this process, pid %s" % _self))
strict = E.get("CAP_STRICT") == "1"
measurement = {"ok": True, "timeout_s": inum("CAP_T", None), "probe_timeout_s": inum("CAP_PT", None),
               "critical_inputs_unreadable": critical}
if critical and strict:
    why = "unreadable or unparseable verdict-critical input(s): %s" % "; ".join(critical)
    measurement.update({"ok": False, "reason": why})
    for _p, _v in profiles.items():
        _v.update({"verdict": "undetermined", "verdict_class": "undetermined", "running": False, "threads": 0,
                   "reasons": [why] + _v["reasons"]})
    largest = None
    if keyvar:
        fb = {"recommended": "cloud", "route": "hosted", "reason": "the host capacity could not be determined (%s); a hosted decision key is set" % why, "key_variable": keyvar}
    else:
        fb = {"recommended": "none", "route": "none", "reason": "the host capacity could not be determined (%s); none of %s is set" % (why, E.get("CAP_KEYVARS")), "key_variable": None}
doc = {
    "schema": "llmctl.capacity/1", "time": int(time.time()),
    "measurement": measurement,
    "host": {"cpus_online": N, "mem_total_mb": T, "mem_available_mb": avail, "usable_mem_mb": live_avail,
             "swap_total_mb": swap_t, "swap_free_mb": swap_f,
             "load": {"1": load[0], "5": load[1], "15": load[2]} if load else None, "psi": psi, "cgroup": cg,
             "nproc": nproc},
    "inputs": inputs,
    "reserve": {"enabled": enabled, "cpus_reserved": Rc, "cpus_reserved_set": E.get("CAP_RSET"),
                # F1 (round 7): true when the host has too few CPUs to keep the configured reserve (a 1-CPU host reserves 0)
                "cpu_short": E.get("CAP_CPUSHORT") == "1",
                "cpus_model_budget": Bc, "cpus_model_set": E.get("CAP_MSET"), "chat_cpu_cap": chat,
                "decide_cpu_cap": decide, "mem_reserved_mb": Rm, "mem_model_budget_mb": Bm},
    "llmctl": {"units": units, "cpu_pct_used": used_cpu, "mem_limits_used_mb": used_mem,
               "cpu_pct_free": cpu_free, "mem_budget_free_mb": mem_free,
               # review round 4, F3: what "used" counts. Only llmctl engine units under this cgroup root (by default this
               # user's systemd manager, user@UID.service); llmctl units of another user or system units are NOT seen.
               "consumption_scope": {"cgroup_root": (E.get("CAP_UNITS_SCAN") or " ").rsplit(" ", 1)[0],
                                     "max_depth": int((E.get("CAP_UNITS_SCAN") or "x 3").rsplit(" ", 1)[1]),
                                     "scope": "manager" if E.get("CAP_SCOPE_MANAGER") == "1" else "host",
                                     "owners": sorted({u["owner"] for u in units}),
                                     "units": "llmctl-llama@*, llmctl-onnx@*, llmctl-colibri@* (+ LLMCTL_RESERVE_EXTRA_UNIT_GLOB)",
                                     "not_counted": ("llmctl units outside LLMCTL_CGROUP_ROOT (other users' managers, system.slice), and " if E.get("CAP_SCOPE_MANAGER") == "1" else "") + "every non-llmctl workload"}},
    "pressure": {"ok": not pressure, "reasons": pressure},
    "profiles": profiles,
    "unknown_profiles": [p for p in wanted if p not in profiles],
    "largest_decision_fit": largest,
    "degraded": any(u["status"] == "degraded" for u in units),
    "fallback": fb,
}
print(json.dumps(doc, sort_keys=True))
PYEOF
  local rc=$?
  rm -f -- "${plan_file:?}"
  return "${rc}"
}

# capacity_exit_code <json> [profile...] -> 0 every named profile fits (or none named and nothing is degraded),
# 75 a named profile does not fit (or is unknown) or the measurement is undetermined, 3 nothing named and a running model is degraded.
capacity_exit_code() {
  python3 -c '
import json, sys
d = json.loads(sys.argv[1]); w = sys.argv[2:]
if not (d.get("measurement") or {}).get("ok", True): sys.exit(75)
if w:
    bad = [p for p in w if d["profiles"].get(p, {}).get("verdict", "does_not_fit") in ("does_not_fit", "undetermined")]
    sys.exit(75 if bad else 0)
sys.exit(3 if d["degraded"] else 0)' "$@"
}

# capacity_human <json> - a short human summary.
capacity_human() {
  python3 -c '
import json, sys
d = json.loads(sys.argv[1]); h = d["host"]; r = d["reserve"]
m = d.get("measurement") or {}
if not m.get("ok", True):
    print("Capacity: UNDETERMINED (%s)" % m.get("reason"))
    for p in sorted(d["profiles"]): print("  %-22s undetermined" % p)
    print("Fallback: %s (%s)%s" % (d["fallback"]["recommended"], d["fallback"]["reason"],
          (" via $" + d["fallback"]["key_variable"]) if d["fallback"]["key_variable"] else ""))
    sys.exit(0)
print("Host:     %s CPUs, %s MiB RAM (%s MiB usable now), load %s, PSI cpu %s / mem some %s full %s" % (
    h["cpus_online"], h["mem_total_mb"], h["usable_mem_mb"], (h["load"] or {}).get("1"),
    h["psi"]["cpu"]["some"], h["psi"]["memory"]["some"], h["psi"]["memory"]["full"]))
print("Reserve:  %s; host keeps %s CPUs (%s) and %s MiB; models: %s CPUs (%s), %s MiB" % (
    "ON" if r["enabled"] else "OFF (diagnostics)", r["cpus_reserved"], r["cpus_reserved_set"], r["mem_reserved_mb"],
    r["cpus_model_budget"], r["cpus_model_set"], r["mem_model_budget_mb"]))
l = d["llmctl"]
print("llmctl:   %s%% CPU and %s MiB of limits in use; free: %s%% CPU, %s MiB" % (l["cpu_pct_used"], l["mem_limits_used_mb"], l["cpu_pct_free"], l["mem_budget_free_mb"]))
for u in l["units"]:
    print("  %-40s %-8s %s" % (u["unit"], u["status"], "; ".join(u["reasons"]) + ((" -> " + u["suggest"]) if u["suggest"] else "")))
if not d["pressure"]["ok"]: print("Pressure: " + "; ".join(d["pressure"]["reasons"]))
for p, v in sorted(d["profiles"].items()):
    extra = (" threads=%s" % v["threads"]) if v["threads"] else ""
    print("  %-22s %-7s %-26s%s %s" % (p, v["class"] or "-", v["verdict"], extra, "; ".join(v["reasons"])))
print("Largest decision model that fits: %s" % (d["largest_decision_fit"] or "none"))
print("Fallback: %s (%s)%s" % (d["fallback"]["recommended"], d["fallback"]["reason"],
      (" via $" + d["fallback"]["key_variable"]) if d["fallback"]["key_variable"] else ""))' "$1"
}

# _cap_fallback_name -> "cloud" when a hosted-key VARIABLE holds a real key (by name; the value is never read out, and
# a placeholder counts as absent), else "none".
_cap_fallback_name() {
  if [[ -n "$(_cap_key_var)" ]]; then echo cloud; else echo none; fi
}

# _cap_refuse <profile> <why> - the fail-closed refusal: message + machine-readable fallback line, rc 75.
_cap_refuse() {
  printf 'refusing to %s %s: %s\n' "${LLMCTL_GATE_ACTION:-start}" "$1" "$2" >&2
  printf 'llmctl-fallback: %s\n' "$(_cap_fallback_name)" >&2
  return 75
}

# capacity_admit <profile> [new-instances] [replaced-unit-instance] - the admission used by start, switch, restart and
# decide scale: rc 0 and sets CAP_THREADS (the CPU cap to use) when the profile fits; rc 75, a reason and a
# machine-readable "llmctl-fallback: cloud|none" line on stderr when it does not. A host with too few CPUs to keep the CPU
# reserve (reserve.cpu_short, e.g. a 1-CPU host) is admitted with a loud warning; LLMCTL_HOST_RESERVE_STRICT=1 refuses it.
# This function does not decide RAM/VRAM: that verdict is deferred to the planner path in start (see below). It FAILS CLOSED: a capacity measurement
# that errors, or a verdict it cannot read, refuses exactly like does_not_fit (review round 1 S2).
#   new-instances  (decide scale) judge the profile as that many NEW instances next to the running ones
#   replaced-unit  (restart) the running instance being replaced: its own limits are not counted as used
capacity_admit() {
  CAP_THREADS=""
  reserve_enabled || return 0
  local p="$1" doc verdict
  local _CAP_NEW_INSTANCES="${2:-}" _CAP_REPLACE="${3:-}"
  if ! doc="$(capacity_json "${p}" 2>/dev/null)" || [[ -z "${doc}" ]]; then
    _cap_refuse "${p}" "the host capacity could not be measured (llmctl capacity --json ${p}); refusing rather than guessing"
    return 75
  fi
  verdict="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); v=d["profiles"].get(sys.argv[2]); m=d.get("measurement") or {}; print("undetermined 0" if not m.get("ok", True) else ("%s %s" % (v["verdict"], v["threads"]) if v else "unknown 0"))' "${doc}" "${p}" 2>/dev/null)" || verdict=""
  case "${verdict%% *}" in
    fits|fits_with_reduced_threads|running)
      if python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1])["reserve"].get("cpu_short") else 1)' "${doc}" 2>/dev/null; then
        printf 'WARNING: this host has too few CPUs to keep a CPU reserve (reserved 0): %s %s can use every CPU. Route decisions to a hosted endpoint, or set LLMCTL_HOST_RESERVE_STRICT=1 to refuse.\n' "${LLMCTL_GATE_ACTION:-start}" "${p}" >&2
        if [[ "${LLMCTL_HOST_RESERVE_STRICT:-0}" == 1 ]]; then
          _cap_refuse "${p}" "the host has too few CPUs to keep a CPU reserve and LLMCTL_HOST_RESERVE_STRICT=1"; return 75
        fi
      fi
      CAP_THREADS="${verdict##* }"; [[ "${CAP_THREADS}" =~ ^[1-9][0-9]*$ ]] || CAP_THREADS=""; return 0 ;;
    does_not_fit) ;;
    undetermined)
      local why
      why="$(python3 -c 'import json,sys; print((json.loads(sys.argv[1]).get("measurement") or {}).get("reason") or "unknown reason")' "${doc}" 2>/dev/null)" || why="unknown reason"
      _cap_refuse "${p}" "the host capacity could not be determined: ${why}; refusing rather than guessing"; return 75 ;;
    unknown) _cap_refuse "${p}" "it is not a catalog profile the capacity check knows; refusing rather than guessing"; return 75 ;;
    *) _cap_refuse "${p}" "the capacity verdict could not be read; refusing rather than guessing"; return 75 ;;
  esac
  # When the ONLY reason is the planner's RAM/VRAM verdict, defer to the planner path in start, which refuses with
  # exit 1 and the exact MiB numbers ("cannot start '<p>': needs ..."); the capacity gate owns the reserve/CPU/PSI cases.
  if python3 -c 'import json,sys; v=json.loads(sys.argv[1])["profiles"][sys.argv[2]]; sys.exit(0 if v["reasons"] and all(r.startswith("planner:") for r in v["reasons"]) else 1)' "${doc}" "${p}" 2>/dev/null; then
    return 0
  fi
  python3 -c '
import json, sys
d = json.loads(sys.argv[1]); v = d["profiles"][sys.argv[2]]
sys.stderr.write("refusing to %s %s: the host cannot run it next to its current workload: %s\n" % (sys.argv[3], sys.argv[2], "; ".join(v["reasons"])))
sys.stderr.write("llmctl-fallback: %s\n" % d["fallback"]["recommended"])
if d["fallback"]["key_variable"]: sys.stderr.write("route decisions to the hosted endpoint (key variable %s is set)\n" % d["fallback"]["key_variable"])' \
    "${doc}" "${p}" "${LLMCTL_GATE_ACTION:-start}" || _cap_refuse "${p}" "the host cannot run it next to its current workload"
  return 75
}
