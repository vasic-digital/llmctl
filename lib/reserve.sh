#!/usr/bin/env bash
# reserve.sh - host reserve for locally run models (CPU + RAM), computed from the live host.
#
# Why (root cause, measured 2026-10-28 on a 16-CPU / 31 GiB host, docs/host-safety.md "Host reserve"):
#   * llama-server was started without --threads, so it used one thread per physical core for generation AND batch;
#   * no unit had CPUQuota=/CPUAffinity=, so one decision model under 4 parallel requests used 5-6.5 CPUs and two
#     models could take every CPU of the host;
#   * a unit's MemoryMax could reach 90% of RAM, the start gate kept a fixed 4 GiB regardless of host size, and nothing
#     summed the limits of the units already running.
#
# Policy (every number comes from the live host; nothing is hard-coded per machine):
#   N  = online CPUs (/sys/devices/system/cpu/online; never nproc, which follows the CALLER's affinity)
#   Rc = max(LLMCTL_RESERVE_CPU_MIN (>= 2), ceil(N * LLMCTL_RESERVE_CPU_PCT / 100) (>= 25%)), rounded UP to whole
#        physical cores (SMT siblings are reserved together), never more than N-1
#   Bc = N - Rc                                   the CPUs every llmctl model together may use
#   chat cap   = max(1, floor(Bc * LLMCTL_CHAT_CPU_PCT / 100))    (default 50%)
#   decide cap = max(1, floor(Bc * LLMCTL_DECIDE_CPU_PCT / 100))  (default 25%; never above the chat cap)
#   T  = MemTotal (MiB)
#   Rm = max(LLMCTL_RESERVE_MEM_MIN_MB (>= 4096), T * LLMCTL_RESERVE_MEM_PCT / 100 (>= 20%))
#   Bm = T - Rm                                   the RAM every llmctl model together may be limited to
# Stricter values are accepted; looser values are raised to the floor (reported by `llmctl reserve`).
#
# LLMCTL_HOST_RESERVE=0 is a DIAGNOSTICS switch only: it restores the pre-3.4.0 behaviour (no thread cap, no CPU
# quota, fixed 4 GiB gate reserve, no combined check) so the old failure can be reproduced. It is reported loudly.
#
# Test inputs: LLMCTL_HOST_CPUS, LLMCTL_CPU_ONLINE_FILE, LLMCTL_CPU_SYSFS, LLMCTL_HOST_MEM_MB, LLMCTL_MEMINFO_FILE,
# LLMCTL_CGROUP_ROOT, LLMCTL_SELF_CGROUP, LLMCTL_LOADAVG_FILE, LLMCTL_CPU_PSI_FILE.

set -euo pipefail

[[ -n "${_LLMCTL_RESERVE_SH:-}" ]] && return 0
_LLMCTL_RESERVE_SH=1

reserve_enabled() { [[ "${LLMCTL_HOST_RESERVE:-1}" != 0 ]]; }

# _rsv_int <value> <default> <floor> <ceiling> -> an integer clamped to [floor, ceiling]; a non-integer is the default.
_rsv_int() {
  local v="$1" d="$2" lo="$3" hi="$4"
  [[ "${v}" =~ ^[0-9]+$ ]] || v="${d}"
  v=$(( 10#${v} ))
  (( v < lo )) && v="${lo}"
  (( v > hi )) && v="${hi}"
  echo "${v}"
}

# _rsv_expand <list> -> one CPU number per line from a kernel CPU list such as "0-3,8,10-11".
_rsv_expand() {
  local part a b
  local IFS=,
  for part in $1; do
    part="${part//[[:space:]]/}"
    if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
      while (( a <= b )); do echo "${a}"; a=$(( a + 1 )); done
    elif [[ "${part}" =~ ^[0-9]+$ ]]; then
      echo "${part}"
    fi
  done
}

# _rsv_compress <cpu...> -> "2-7,10-15" (input sorted numerically, unique).
_rsv_compress() {
  local out="" start="" prev="" c
  for c in "$@"; do
    if [[ -z "${start}" ]]; then start="${c}"; prev="${c}"; continue; fi
    if (( c == prev + 1 )); then prev="${c}"; continue; fi
    out+="${out:+,}$([[ "${start}" == "${prev}" ]] && echo "${start}" || echo "${start}-${prev}")"
    start="${c}"; prev="${c}"
  done
  [[ -n "${start}" ]] && out+="${out:+,}$([[ "${start}" == "${prev}" ]] && echo "${start}" || echo "${start}-${prev}")"
  echo "${out}"
}

# _rsv_online_cpus -> the online CPU numbers, one per line.
_rsv_online_cpus() {
  local n="${LLMCTL_HOST_CPUS:-}" f="${LLMCTL_CPU_ONLINE_FILE:-/sys/devices/system/cpu/online}" i
  if [[ "${n}" =~ ^[1-9][0-9]*$ ]]; then
    for (( i = 0; i < n; i++ )); do echo "${i}"; done
    return 0
  fi
  if [[ -r "${f}" ]]; then
    _rsv_expand "$(head -1 "${f}")"
    return 0
  fi
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  [[ "${n}" =~ ^[1-9][0-9]*$ ]] || n=1
  for (( i = 0; i < n; i++ )); do echo "${i}"; done
}

# _rsv_siblings <cpu> -> the CPUs of the same physical core (itself when the topology is not readable).
_rsv_siblings() {
  local d="${LLMCTL_CPU_SYSFS:-/sys/devices/system/cpu}/cpu$1/topology" f
  for f in "${d}/core_cpus_list" "${d}/thread_siblings_list"; do
    if [[ -r "${f}" ]]; then _rsv_expand "$(head -1 "${f}")"; return 0; fi
  done
  echo "$1"
}

# reserve_compute fills the RSV_* globals. It is memoised on EVERY input it reads (the knobs, the online-CPU list,
# the sibling and meminfo sources, MemTotal): `start` asks for the reserve several times, mostly from $(...) subshells,
# which inherit the parent's RSV_* values, so `start` primes it once in the parent (reserve_prime). A changed input
# changes the key and recomputes - the memo can never return a stale reserve.
_rsv_memo_key() {
  local on="" mtl="" line f="${LLMCTL_CPU_ONLINE_FILE:-/sys/devices/system/cpu/online}" mi="${LLMCTL_MEMINFO_FILE:-/proc/meminfo}"
  [[ -r "${f}" ]] && read -r on < "${f}"
  if [[ -r "${mi}" ]]; then
    while read -r line; do [[ "${line}" == MemTotal:* ]] && { mtl="${line}"; break; }; done < "${mi}"
  fi
  # the SMT topology _rsv_siblings reads (builtin reads only, no process per CPU)
  local topo="" t
  for t in "${LLMCTL_CPU_SYSFS:-/sys/devices/system/cpu}"/cpu[0-9]*/topology/{core_cpus_list,thread_siblings_list}; do
    [[ -r "${t}" ]] || continue
    read -r line < "${t}" || true
    topo+="${t##*/cpu}=${line};"
  done
  printf '%s|' "${topo}" "${LLMCTL_HOST_CPUS:-}" "${f}" "${on}" "${LLMCTL_CPU_SYSFS:-}" "${LLMCTL_HOST_MEM_MB:-}" "${mi}" "${mtl}" \
    "${LLMCTL_RESERVE_CPU_PCT:-}" "${LLMCTL_RESERVE_CPU_MIN:-}" "${LLMCTL_CHAT_CPU_PCT:-}" "${LLMCTL_DECIDE_CPU_PCT:-}" \
    "${LLMCTL_RESERVE_MEM_PCT:-}" "${LLMCTL_RESERVE_MEM_MIN_MB:-}" "${LLMCTL_GATE_CPU_SOME_MAX:-}" "${LLMCTL_GATE_LOAD_PER_CPU:-}"
}
reserve_compute() {
  local key; key="$(_rsv_memo_key)"
  [[ -n "${_RSV_MEMO_KEY:-}" && "${_RSV_MEMO_KEY}" == "${key}" ]] && return 0
  _reserve_compute_now
  _RSV_MEMO_KEY="${key}"
}

_reserve_compute_now() {
  local -a online=()
  mapfile -t online < <(_rsv_online_cpus | sort -n -u)
  (( ${#online[@]} > 0 )) || online=(0)
  RSV_N="${#online[@]}"
  # Every knob may only make the reserve STRICTER: a reserve below the floor is raised back to it, a per-model cap above
  # its default is lowered back to it, and a stricter value is honoured as written (a reserve up to 100 %, which leaves
  # one CPU / no model memory; review round 1 S6: the old 90 % ceiling and 100 % cap ceilings could loosen the policy).
  RSV_CPU_PCT="$(_rsv_int "${LLMCTL_RESERVE_CPU_PCT:-25}" 25 25 100)"
  RSV_CPU_MIN="$(_rsv_int "${LLMCTL_RESERVE_CPU_MIN:-2}" 2 2 4096)"
  RSV_CHAT_PCT="$(_rsv_int "${LLMCTL_CHAT_CPU_PCT:-50}" 50 1 50)"
  RSV_DECIDE_PCT="$(_rsv_int "${LLMCTL_DECIDE_CPU_PCT:-25}" 25 1 25)"
  local want=$(( (RSV_N * RSV_CPU_PCT + 99) / 100 ))
  (( want < RSV_CPU_MIN )) && want="${RSV_CPU_MIN}"
  RSV_CPU_SHORT=0
  if (( want > RSV_N - 1 )); then want=$(( RSV_N - 1 )); RSV_CPU_SHORT=1; fi
  # Reserve whole physical cores, lowest numbers first (CPU 0 also carries most interrupts on common hosts).
  local -A reserved=() online_set=()
  local c s count=0
  for c in "${online[@]}"; do online_set["${c}"]=1; done
  for c in "${online[@]}"; do
    (( count >= want )) && break
    [[ -n "${reserved[${c}]:-}" ]] && continue
    for s in $(_rsv_siblings "${c}"); do
      [[ -n "${online_set[${s}]:-}" && -z "${reserved[${s}]:-}" ]] || continue
      reserved["${s}"]=1; count=$(( count + 1 ))
    done
  done
  # a core-rounding that would leave no model CPU falls back to single CPUs
  if (( count > RSV_N - 1 )); then
    reserved=(); count=0
    for c in "${online[@]}"; do (( count >= want )) && break; reserved["${c}"]=1; count=$(( count + 1 )); done
  fi
  local -a model=() rsv=()
  for c in "${online[@]}"; do
    if [[ -n "${reserved[${c}]:-}" ]]; then rsv+=("${c}"); else model+=("${c}"); fi
  done
  RSV_RC="${#rsv[@]}"
  RSV_BC="${#model[@]}"
  RSV_RESERVED_SET="$(_rsv_compress "${rsv[@]}")"
  RSV_CPUSET="$(_rsv_compress "${model[@]}")"
  if (( RSV_BC < 1 )); then RSV_BC=1; RSV_CPUSET="${online[$(( RSV_N - 1 ))]}"; RSV_CPU_SHORT=1; fi
  RSV_CHAT_CPUS=$(( RSV_BC * RSV_CHAT_PCT / 100 )); (( RSV_CHAT_CPUS < 1 )) && RSV_CHAT_CPUS=1
  RSV_DECIDE_CPUS=$(( RSV_BC * RSV_DECIDE_PCT / 100 )); (( RSV_DECIDE_CPUS < 1 )) && RSV_DECIDE_CPUS=1
  (( RSV_DECIDE_CPUS > RSV_CHAT_CPUS )) && RSV_DECIDE_CPUS="${RSV_CHAT_CPUS}"

  local mt="${LLMCTL_HOST_MEM_MB:-}" mi="${LLMCTL_MEMINFO_FILE:-/proc/meminfo}"
  if [[ ! "${mt}" =~ ^[1-9][0-9]*$ ]]; then
    mt="$(awk '/^MemTotal:/{print int($2/1024); exit}' "${mi}" 2>/dev/null || true)"
  fi
  [[ "${mt}" =~ ^[1-9][0-9]*$ ]] || mt=0
  RSV_MT="${mt}"
  RSV_MEM_PCT="$(_rsv_int "${LLMCTL_RESERVE_MEM_PCT:-20}" 20 20 100)"
  RSV_MEM_MIN="$(_rsv_int "${LLMCTL_RESERVE_MEM_MIN_MB:-4096}" 4096 4096 4194304)"
  RSV_RM=$(( mt * RSV_MEM_PCT / 100 )); (( RSV_RM < RSV_MEM_MIN )) && RSV_RM="${RSV_MEM_MIN}"
  # The model budget is what is LEFT after the reserve, never more: a small host (or a huge reserve) whose budget is
  # below 512 MiB (smaller than any engine's memory limit) is "short", and every start is refused
  # (capacity does_not_fit, combined check 75) instead of handing models a 512 MiB budget carved out of the reserve
  # (review round 1 S6 / M06: the old floor did exactly that).
  RSV_MEM_SHORT=0
  RSV_BM=$(( mt - RSV_RM )); (( RSV_BM < 0 )) && RSV_BM=0
  (( RSV_BM < 512 )) && RSV_MEM_SHORT=1
  # gate thresholds: stricter (lower) is allowed, looser is clamped back (CPU PSI some <= 80 %, load <= 3 x CPUs)
  RSV_GATE_CPU_SOME_MAX="$(_rsv_int "${LLMCTL_GATE_CPU_SOME_MAX:-80}" 80 0 80)"
  RSV_GATE_LOAD_PER_CPU="$(_rsv_int "${LLMCTL_GATE_LOAD_PER_CPU:-3}" 3 1 3)"
}

# reserve_profile_class <profile> -> "decide" or "chat". Decision engines (catalog capability "decide", onnx encoders)
# get the strictest budget.
# One catalog read (reserve_decide_profiles) instead of two or three per call: `start` asks this several times for the
# same profile. An unknown profile, or no catalog, is "chat" (the looser of the two caps is still bounded by Bc).
# A unit/instance name maps to its catalog profile by reserve_base_profile: a "<tenant>--" prefix is dropped, and a
# ".<N>" instance suffix (N >= 2, lib/scheduler.sh _sched_scale_key) is dropped ONLY when the full name is not itself in
# the set and the base is (review round 1 S7: the old "${1%.[0-9]*}" turned "qwen2.5-coder" into "qwen2").
reserve_profile_class() {
  local set; set=" $(reserve_decide_profiles 2>/dev/null || true) "
  case "${set}" in
    *" $(reserve_base_profile "$1" "${set}") "*) echo decide ;;
    *) echo chat ;;
  esac
}

# reserve_base_profile <name> <space-separated known profiles> -> the known profile the name stands for (or the name).
reserve_base_profile() {
  local n="$1" set=" ${2:-} "
  [[ "${n}" == *--* ]] && n="${n##*--}"
  [[ "${set}" == *" ${n} "* ]] && { echo "${n}"; return 0; }
  if [[ "${n}" =~ ^(.+)\.([2-9]|[1-9][0-9]+)$ && "${set}" == *" ${BASH_REMATCH[1]} "* ]]; then
    echo "${BASH_REMATCH[1]}"; return 0
  fi
  echo "${n}"
}

# reserve_decide_profiles -> the space-separated names of every catalog profile reserve_profile_class calls "decide",
# computed in ONE catalog read (capability "decide" or engine "onnx"). capacity_json needs the whole set on every
# start; asking reserve_profile_class per profile spawned two or three catalog reads per profile and tripled the
# latency of `llmctl start` (2.7 s -> 8.5 s measured), which made llmctld's forwarded starts time out.
reserve_decide_profiles() {
  declare -F catalog_check >/dev/null 2>&1 || return 0
  # memoised on the catalog path AND its content (catalog_check ran when the memo was filled, on that same content) (a subshell inherits the parent's value; see reserve_prime)
  local cat=""; [[ -r "${LLMCTL_CATALOG}" ]] && cat="$(<"${LLMCTL_CATALOG}")"
  if [[ -n "${_RSV_DECIDE_MEMO_KEY:-}" && "${_RSV_DECIDE_MEMO_KEY}" == "${LLMCTL_CATALOG}:${cat}" ]]; then
    echo "${_RSV_DECIDE_MEMO}"; return 0
  fi
  _reserve_decide_profiles_now
}
_reserve_decide_profiles_now() {
  catalog_check
  python3 - "${LLMCTL_CATALOG}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
out = []
for name, v in sorted(d.get("profiles", {}).items()):
    cap = v.get("capability") or []
    if isinstance(cap, str):
        cap = [cap]
    if "decide" in cap or v.get("engine") == "onnx":
        out.append(name)
print(" ".join(out))
PYEOF
}

# reserve_prime - compute the reserve and the decision-profile set ONCE in the calling shell, so the $(...) subshells
# `start` runs afterwards (launch argv, unit drop-in, capacity check) reuse them instead of re-reading /proc, /sys
# and the catalog each time. Purely a cache: every value is still keyed on its inputs.
reserve_prime() {
  reserve_compute
  declare -F catalog_check >/dev/null 2>&1 || return 0
  local cat=""; [[ -r "${LLMCTL_CATALOG}" ]] && cat="$(<"${LLMCTL_CATALOG}")"
  _RSV_DECIDE_MEMO="$(_reserve_decide_profiles_now 2>/dev/null || true)"
  _RSV_DECIDE_MEMO_KEY="${LLMCTL_CATALOG}:${cat}"
}

# reserve_cpu_cap <profile> -> the number of CPUs (and llama.cpp threads) the profile may use.
# _RSV_CAP_OVERRIDE (a non-exported global set only by `start` for one profile, from lib/capacity.sh
# capacity_admit's fits_with_reduced_threads verdict) LOWERS the cap - it can never raise it.
reserve_cpu_cap() {
  reserve_compute
  local cap
  if [[ "$(reserve_profile_class "$1")" == decide ]]; then cap="${RSV_DECIDE_CPUS}"; else cap="${RSV_CHAT_CPUS}"; fi
  if [[ "${_RSV_CAP_OVERRIDE:-}" =~ ^[1-9][0-9]*$ ]] && (( _RSV_CAP_OVERRIDE < cap )); then cap="${_RSV_CAP_OVERRIDE}"; fi
  echo "${cap}"
}

# reserve_dropin_body <profile> -> the [Service] drop-in (06-reserve.conf) that bounds one profile's unit.
reserve_dropin_body() {
  reserve_compute
  local cap cls; cls="$(reserve_profile_class "$1")"
  cap="$(reserve_cpu_cap "$1")"
  printf '# written by llmctl host reserve (profile %s, class %s): %s of %s CPUs kept for the host (%s); models may use %s (%s); this profile: %s CPU(s)\n' \
    "$1" "${cls}" "${RSV_RC}" "${RSV_N}" "${RSV_RESERVED_SET}" "${RSV_BC}" "${RSV_CPUSET}" "${cap}"
  printf '[Service]\nCPUQuota=%s%%\nCPUAffinity=%s\nAllowedCPUs=%s\nEnvironment=OMP_NUM_THREADS=%s\nEnvironment=LLMCTL_RESERVE_CPU_PCT_UNIT=%s\n' \
    "$(( cap * 100 ))" "${RSV_CPUSET//,/ }" "${RSV_CPUSET}" "${cap}" "$(( cap * 100 ))"
}

# --- reading the live cgroup tree -----------------------------------------------------------------------------------
# _rsv_cgroup_root -> the cgroup v2 directory of this user's service manager. LLMCTL_CGROUP_FS (default /sys/fs/cgroup) is
# the cgroup mount point; LLMCTL_CGROUP_ROOT replaces the whole path (tests, and hosts with a non-standard layout).
_rsv_cgroup_root() {
  if [[ -n "${LLMCTL_CGROUP_ROOT:-}" ]]; then echo "${LLMCTL_CGROUP_ROOT}"; return; fi
  local uid; uid="$(id -u)"
  echo "$(_rsv_cgroup_fs)/user.slice/user-${uid}.slice/user@${uid}.service"
}

# _rsv_cgroup_fs -> the cgroup mount point without trailing slashes (review round 6, F4): "/x/" and "/x" must classify
# the same, because find prints "/x/user.slice/..." and every prefix test below compares against that.
_rsv_cgroup_fs() {
  local fs="${LLMCTL_CGROUP_FS:-/sys/fs/cgroup}"
  while [[ "${fs}" == */ && "${fs}" != / ]]; do fs="${fs%/}"; done
  echo "${fs}"
}

# _rsv_find <root> <maxdepth> [find-args...] -> rc 0 when the walk is trustworthy (find's stdout is then in
# _RSV_FIND_OUT), rc 1 otherwise (the reason is in _RSV_FIND_WHY). Both are globals: call it in the current shell, not
# in a command substitution.
# GNU find exits 1 when a directory vanished between readdir and descent ("No such file or directory"). In a cgroup
# tree that is a unit stopping during the scan, i.e. an absent unit, not an unreadable tree (review round 6, F1:
# measured 4/277 false "unmeasurable" on the reference host). Only that exact cause is tolerated: any other message
# (Permission denied, I/O error ...), a non-zero status without a message, or a status above 1 fails closed. The error
# text is read in the C locale so the ENOENT wording is stable.
_RSV_FIND_WHY=""; _RSV_FIND_OUT=""
_rsv_find() {
  local root="$1" depth="$2"; shift 2
  local errf rc=0 line first="" other=0 n=0
  _RSV_FIND_WHY=""; _RSV_FIND_OUT=""
  errf="$(mktemp)" || { _RSV_FIND_WHY="no temporary file for the scan"; return 1; }
  _RSV_FIND_OUT="$(LC_ALL=C find "${root}" -maxdepth "${depth}" "$@" 2>"${errf}")" || rc=$?
  if (( rc != 0 )); then
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      n=$(( n + 1 ))
      if [[ "${line}" == "find: "*": No such file or directory" && "${line}" != "find: ‘${root}’: "* && "${line}" != "find: '${root}': "* ]]; then
        continue
      fi
      other=1; [[ -n "${first}" ]] || first="${line}"
    done < "${errf}"
    if (( rc > 1 )) || (( n == 0 )) || (( other )); then
      _RSV_FIND_WHY="${first:-find exited ${rc} without saying why}"
      rm -f "${errf:?}"
      return 1
    fi
  fi
  rm -f "${errf:?}"
  return 0
}

# _rsv_units_unmeasurable -> empty when the running llmctl engine units CAN be counted; otherwise one line saying why
# (review round 5, R5-1/R5-2). Counting zero units in a tree that could not be read is not "no units": it admitted a
# start on a full budget. A cgroup v1 or hybrid host has no per-user cgroup v2 tree at the default root, so the units
# cannot be counted there at all (the reserve refuses on such a host; docs/capacity.md "Limits"). The default root is
# only used when the cgroup mount carries cgroup.controllers (the cgroup v2 unified hierarchy).
_rsv_units_unmeasurable() {
  local root depth fs
  read -r root depth < <(_rsv_units_scan)
  if [[ -z "${LLMCTL_CGROUP_ROOT:-}" ]]; then
    fs="$(_rsv_cgroup_fs)"
    if [[ ! -f "${fs}/cgroup.controllers" ]]; then
      echo "no cgroup v2 unified hierarchy at ${fs} (cgroup v1 and hybrid hosts are not supported by the host reserve)"
      return 0
    fi
  fi
  if [[ ! -d "${root}" ]]; then echo "the cgroup root ${root} does not exist"; return 0; fi
  if [[ ! -r "${root}" || ! -x "${root}" ]]; then echo "the cgroup root ${root} is not readable"; return 0; fi
  if ! _rsv_find "${root}" "${depth}" -type d; then
    echo "a directory under ${root} could not be read (${_RSV_FIND_WHY})"
    return 0
  fi
  # anything one level below the scan depth would hold units that are not counted: say so, never skip silently (F2)
  local deeper
  if ! _rsv_find "${root}" $(( depth + 1 )) -mindepth $(( depth + 1 )) -type d -print -quit; then
    echo "a directory under ${root} could not be read (${_RSV_FIND_WHY})"
    return 0
  fi
  deeper="${_RSV_FIND_OUT}"
  if [[ -n "${deeper}" ]]; then
    echo "the cgroup tree under ${root} is deeper than the ${depth} levels the unit scan covers (${deeper}); units below that depth would not be counted"
    return 0
  fi
  return 0
}

# _rsv_units_scan -> "<scan-root> <max-depth>": where the running llmctl engine units are counted (review round 5, F3).
# Default: the WHOLE cgroup v2 mount (LLMCTL_CGROUP_FS), so the units of this user's manager, of every other user's
# manager (user.slice/user-<uid>.slice/user@<uid>.service/app.slice/app-llmctl\x2dllama.slice/<unit>, depth 6) and of
# system.slice all count against the one host model budget. Depth 8 leaves room for two more slice levels. Measured on
# the reference host: 310 cgroups, every one readable, about 25 ms. LLMCTL_CGROUP_ROOT (tests, non-standard layouts)
# narrows the scan to that one manager root (depth 3, the layout of a single user manager).
_rsv_units_scan() {
  if [[ -n "${LLMCTL_CGROUP_ROOT:-}" ]]; then echo "${LLMCTL_CGROUP_ROOT} 3"; return; fi
  echo "$(_rsv_cgroup_fs) 8"
}

# _rsv_unit_owner <unit-cgroup-dir> -> "self" (this user's manager), "user-<uid>" (another user's manager), "system"
# (system.slice) or "other". Only "self" units are this user's instances (restart replacement, "running"); every owner
# counts as consumption.
_rsv_unit_owner() {
  local d="$1" mine; mine="$(_rsv_cgroup_root)"
  if [[ -n "${LLMCTL_CGROUP_ROOT:-}" ]]; then echo self; return; fi
  if [[ "${d}" == "${mine}/"* ]]; then
    # an llmctl unit inside a container scope (libpod-*.scope, docker-*.scope ...) is not one of this manager's own
    # units: it counts as consumption but is never a restart replacement (review round 6, F3)
    local rel="${d#"${mine}"/}"; rel="${rel%/*}"
    if [[ "/${rel}/" == */*.scope/* ]]; then echo container; else echo self; fi
    return
  fi
  if [[ "${d}" =~ /user\.slice/user-([0-9]+)\.slice/user@([0-9]+)\.service/ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then
    echo "user-${BASH_REMATCH[1]}"; return
  fi
  [[ "${d}" == "$(_rsv_cgroup_fs)/system.slice/"* ]] && { echo system; return; }
  echo other
}

# _rsv_self_cgroup -> the absolute cgroup directory of THIS process (empty when unknown).
_rsv_self_cgroup() {
  if [[ -n "${LLMCTL_SELF_CGROUP:-}" ]]; then echo "${LLMCTL_SELF_CGROUP}"; return; fi
  local rel; rel="$(awk -F: '$1=="0"{print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
  [[ -n "${rel}" ]] && echo "/sys/fs/cgroup${rel}"
}

# _rsv_cpu_pct <cgroup-dir> -> the cgroup's CPU limit in percent of one CPU ("max" -> empty).
_rsv_cpu_pct() {
  local q p
  read -r q p < "$1/cpu.max" 2>/dev/null || return 0
  [[ "${q}" =~ ^[0-9]+$ && "${p}" =~ ^[1-9][0-9]*$ ]] && echo $(( (q * 100 + p - 1) / p ))
  return 0
}

# _rsv_mem_mb <cgroup-dir> -> memory.max in MiB ("max" -> empty).
_rsv_mem_mb() {
  local m; m="$(head -1 "$1/memory.max" 2>/dev/null || true)"
  [[ "${m}" =~ ^[0-9]+$ ]] && echo $(( (m + 1048575) / 1048576 ))
  return 0
}

# reserve_running_units -> "<name> <cpu-pct|max> <mem-mb|max> <owner> <cgroup-dir>" for every POPULATED llmctl engine
# unit cgroup on the host (_rsv_units_scan: every user's manager and system.slice; owner from _rsv_unit_owner), except
# the caller's own cgroup (a unit's ExecStartPre runs inside it). The decision gateway is not an engine and not counted.
# LLMCTL_RESERVE_EXTRA_UNIT_GLOB (QA only): one more unit-name pattern counted as an llmctl engine unit. The live
# evidence harness (scripts/qa/host_reserve_live.sh) runs its engines as transient units named llmctl-qa-reserve-*,
# because an instance of the operator's installed llmctl-llama@ template cannot be created as a transient unit.
reserve_running_units() {
  local root depth self d name cpu mem
  read -r root depth < <(_rsv_units_scan); self="$(_rsv_self_cgroup)"
  # rc 1 (and no line) when the tree cannot be read: a caller must not read "no output" as "no units" (round 5, R5-1).
  # find exits non-zero on any directory it cannot enter, so a partly unreadable tree is a failure too.
  [[ -d "${root}" && -r "${root}" && -x "${root}" ]] || return 1
  local list
  _rsv_find "${root}" "${depth}" -type d \( -name 'llmctl-llama@*.service' -o -name 'llmctl-onnx@*.service' -o -name 'llmctl-colibri@*.service' \
             -o -name "${LLMCTL_RESERVE_EXTRA_UNIT_GLOB:-llmctl-llama@*.service}" \) || return 1
  list="${_RSV_FIND_OUT}"
  while IFS= read -r d; do
    [[ -n "${d}" ]] || continue
    [[ -n "${self}" && "${d}" == "${self}" ]] && continue
    grep -qx 'populated 1' "${d}/cgroup.events" 2>/dev/null || continue
    name="${d##*/}"
    cpu="$(_rsv_cpu_pct "${d}")"; mem="$(_rsv_mem_mb "${d}")"
    echo "${name} ${cpu:-max} ${mem:-max} $(_rsv_unit_owner "${d}") ${d}"
  done < <(printf '%s\n' "${list}" | LC_ALL=C sort)
}

# reserve_combined_check <new-cpu-pct> <new-mem-mb> [label] - rc 75 (message on stderr) when the limits of the running
# engine units plus the new one would exceed the model budget (Bc CPUs, Bm MiB). A unit without a CPU or memory limit
# ("max", e.g. one started by an older llmctl) counts as the whole budget: it can take everything.
reserve_combined_check() {
  reserve_enabled || return 0
  reserve_compute
  local ncpu="${1:-}" nmem="${2:-}" label="${3:-service}" act="${LLMCTL_GATE_ACTION:-start}"
  local bcpu=$(( RSV_BC * 100 )) ucpu=0 umem=0 name cpu mem list=""
  [[ "${ncpu}" =~ ^[0-9]+$ ]] || ncpu="${bcpu}"
  [[ "${nmem}" =~ ^[0-9]+$ ]] || nmem="${RSV_BM}"
  # a host whose model budget is under 512 MiB is too small for any engine: refuse every start (review round 1 S6/M06)
  if (( RSV_MEM_SHORT == 1 )); then
    printf 'refusing to %s %s: the host RAM reserve (%s MiB of %s MiB) leaves only %s MiB for models (< 512 MiB); this host is too small for a local model.\n' \
      "${act}" "${label}" "${RSV_RM}" "${RSV_MT}" "${RSV_BM}" >&2
    return 75
  fi
  # the running units must be countable: an unreadable or missing tree counted as "no units" admitted a start on a full
  # budget (review round 5, R5-2; this check runs in hk_gate, the ExecStartPre of every start, restart and boot)
  local why census
  why="$(_rsv_units_unmeasurable)"
  if [[ -z "${why}" ]] && ! census="$(reserve_running_units)"; then why="the unit census under $(_rsv_units_scan) failed"; fi
  if [[ -n "${why}" ]]; then
    printf 'refusing to %s %s: cannot count the running llmctl units (%s), so the model budget cannot be checked.\n' \
      "${act}" "${label}" "${why}" >&2
    return 75
  fi
  local owner ucg
  while read -r name cpu mem owner ucg; do
    [[ -n "${name}" ]] || continue
    [[ "${cpu}" =~ ^[0-9]+$ ]] || cpu="${bcpu}"
    [[ "${mem}" =~ ^[0-9]+$ ]] || mem="${RSV_BM}"
    ucpu=$(( ucpu + cpu )); umem=$(( umem + mem )); list+=" ${name}"; [[ "${owner}" == self ]] || list+="(${owner})"
  done <<< "${census}"
  if (( ucpu + ncpu > bcpu )); then
    printf 'refusing to %s %s: host CPU reserve would be breached (running llmctl units%s hold %s%% CPU, this one needs %s%%, the model budget is %s%% = %s of %s CPUs; %s CPUs stay reserved for the host). Stop a model first.\n' \
      "${act}" "${label}" "${list:- (none)}" "${ucpu}" "${ncpu}" "${bcpu}" "${RSV_BC}" "${RSV_N}" "${RSV_RC}" >&2
    return 75
  fi
  if (( umem + nmem > RSV_BM )); then
    printf 'refusing to %s %s: host RAM reserve would be breached (running llmctl units%s are limited to %s MiB, this one to %s MiB, the model budget is %s MiB of %s MiB; %s MiB stay reserved for the host). Stop a model first.\n' \
      "${act}" "${label}" "${list:- (none)}" "${umem}" "${nmem}" "${RSV_BM}" "${RSV_MT}" "${RSV_RM}" >&2
    return 75
  fi
  return 0
}

# _rsv_inputs_strict - rc 0 where the gate's /proc inputs are part of the platform (Linux): there an unreadable or
# unparseable input REFUSES the start (review round 4, F1: the gate failed open). On other platforms (macOS has no
# /proc/pressure and no /proc/loadavg) the PSI/load tests are skipped, as documented in docs/capacity.md.
_rsv_inputs_strict() { [[ "$(uname -s 2>/dev/null)" == Linux ]]; }

# _rsv_avg10 <psi file> <some|full> - prints the avg10 value; rc 1 when the file is unreadable or the value is not a
# plain non-negative decimal number (garbage is never read as "no pressure").
_rsv_avg10() {
  local v
  [[ -r "$1" ]] || return 1
  v="$(awk -v k="$2" '$1==k{for(i=2;i<=NF;i++) if($i ~ /^avg10=/){sub(/avg10=/,"",$i); print $i; exit}}' "$1" 2>/dev/null)" || return 1
  [[ "${v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  printf '%s' "${v}"
}

# _rsv_load1 <loadavg file> - prints the 1-minute load; rc 1 when unreadable or not a plain decimal number.
_rsv_load1() {
  local v
  [[ -r "$1" ]] || return 1
  v="$(awk '{print $1; exit}' "$1" 2>/dev/null)" || return 1
  [[ "${v}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  printf '%s' "${v}"
}

# reserve_cpu_gate [label] - rc 75 when the host CPU is already saturated: PSI cpu "some" avg10 above
# LLMCTL_GATE_CPU_SOME_MAX (default 80 %) or the 1-minute load above LLMCTL_GATE_LOAD_PER_CPU (default 3) x CPUs.
# On Linux an unreadable or unparseable CPU PSI or loadavg input refuses too (rc 75, fail closed - review round 4, F1);
# elsewhere a missing file skips that test only.
reserve_cpu_gate() {
  reserve_enabled || return 0
  [[ "${LLMCTL_GATE_CPU_CHECKS:-1}" == 0 ]] && return 0
  reserve_compute
  local label="${1:-service}" act="${LLMCTL_GATE_ACTION:-start}"
  local psi="${LLMCTL_CPU_PSI_FILE:-/proc/pressure/cpu}" la="${LLMCTL_LOADAVG_FILE:-/proc/loadavg}" some="" l1="" strict=0
  _rsv_inputs_strict && strict=1
  if ! some="$(_rsv_avg10 "${psi}" some)"; then
    some=""
    if (( strict )); then
      printf 'refusing to %s %s: the CPU pressure input %s is unreadable or unparseable; the gate cannot judge the host and fails closed.\n' \
        "${act}" "${label}" "${psi}" >&2
      return 75
    fi
  fi
  if [[ -n "${some}" ]] && awk -v v="${some}" -v m="${RSV_GATE_CPU_SOME_MAX}" 'BEGIN{exit !(v>m)}'; then
    printf 'refusing to %s %s: CPU pressure is too high (PSI cpu some avg10=%s > %s). Wait for it to drop; this gate keeps the host responsive.\n' \
      "${act}" "${label}" "${some}" "${RSV_GATE_CPU_SOME_MAX}" >&2
    return 75
  fi
  if ! l1="$(_rsv_load1 "${la}")"; then
    l1=""
    if (( strict )); then
      printf 'refusing to %s %s: the load input %s is unreadable or unparseable; the gate cannot judge the host and fails closed.\n' \
        "${act}" "${label}" "${la}" >&2
      return 75
    fi
  fi
  if [[ -n "${l1}" ]] && awk -v v="${l1}" -v k="${RSV_GATE_LOAD_PER_CPU}" -v n="${RSV_N}" 'BEGIN{exit !(v>k*n)}'; then
    printf 'refusing to %s %s: host load is too high (1-minute load %s > %s x %s CPUs). Wait for it to drop; this gate keeps the host responsive.\n' \
      "${act}" "${label}" "${l1}" "${RSV_GATE_LOAD_PER_CPU}" "${RSV_N}" >&2
    return 75
  fi
  return 0
}

# _rsv_json_str <string> -> the string escaped for use inside a JSON string literal (review round 6, F5): backslash,
# double quote and every control character.
_rsv_json_str() {
  local s="$1" out="" c i
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"
  if [[ "${s}" =~ [[:cntrl:]] ]]; then
    for (( i = 0; i < ${#s}; i++ )); do
      c="${s:i:1}"
      if [[ "${c}" == [[:cntrl:]] ]]; then printf -v c '\\u%04x' "'${c}"; fi
      out+="${c}"
    done
    s="${out}"
  fi
  printf '%s' "${s}"
}

# reserve_report [--json] - the effective budget, the reserve and every running engine unit's applied limits, read
# back from the live cgroup and /proc (never from what llmctl intended to write).
reserve_report() {
  reserve_compute
  local json=0; [[ "${1:-}" == --json ]] && json=1
  local name cpu mem d pid aff thr units=() root uerr census="" owner
  root="$(_rsv_units_scan)"; root="${root% *}"
  # an unreadable unit tree is reported, never shown as "no unit is running" (review round 5, R5-1)
  uerr="$(_rsv_units_unmeasurable)"
  if [[ -z "${uerr}" ]] && ! census="$(reserve_running_units)"; then uerr="the unit census under ${root} failed"; fi
  while read -r name cpu mem owner d; do
    [[ -n "${name}" ]] || continue
    pid="$(head -1 "${d}/cgroup.procs" 2>/dev/null || true)"
    aff=""; thr=""
    if [[ "${pid}" =~ ^[0-9]+$ ]]; then
      aff="$(awk '/^Cpus_allowed_list:/{print $2; exit}' "/proc/${pid}/status" 2>/dev/null || true)"
      thr="$(awk '/^Threads:/{print $2; exit}' "/proc/${pid}/status" 2>/dev/null || true)"
    fi
    units+=("${name}|${cpu}|${mem}|${aff}|${thr}|$(head -1 "${d}/cpu.weight" 2>/dev/null || true)|$(head -1 "${d}/memory.swap.max" 2>/dev/null || true)|${owner}|${d}")
  done <<< "${census}"
  if (( json )); then
    local u first=1
    printf '{"enabled":%s,"cpus":{"online":%s,"reserved":%s,"reserved_set":"%s","model_budget":%s,"model_set":"%s","chat_cap":%s,"decide_cap":%s,"reserve_pct":%s,"reserve_min":%s,"short":%s},' \
      "$(reserve_enabled && echo true || echo false)" "${RSV_N}" "${RSV_RC}" "${RSV_RESERVED_SET}" "${RSV_BC}" "${RSV_CPUSET}" \
      "${RSV_CHAT_CPUS}" "${RSV_DECIDE_CPUS}" "${RSV_CPU_PCT}" "${RSV_CPU_MIN}" "$( ((RSV_CPU_SHORT)) && echo true || echo false)"
    printf '"memory":{"total_mb":%s,"reserved_mb":%s,"model_budget_mb":%s,"reserve_pct":%s,"reserve_min_mb":%s,"short":%s},' \
      "${RSV_MT}" "${RSV_RM}" "${RSV_BM}" "${RSV_MEM_PCT}" "${RSV_MEM_MIN}" "$( ((RSV_MEM_SHORT)) && echo true || echo false)"
    printf '"gate":{"cpu_psi_some_max":%s,"load_per_cpu_max":%s},"units_scope":"%s","units_readable":%s,"units_error":"%s","units":[' \
      "${RSV_GATE_CPU_SOME_MAX}" "${RSV_GATE_LOAD_PER_CPU}" "$([[ -n "${LLMCTL_CGROUP_ROOT:-}" ]] && echo manager || echo host)" "$([[ -z "${uerr}" ]] && echo true || echo false)" "$(_rsv_json_str "${uerr}")"
    for u in "${units[@]}"; do
      IFS='|' read -r name cpu mem aff thr d pid owner ucg <<<"${u}"
      (( first )) || printf ','; first=0
      printf '{"unit":"%s","cpu_quota_pct":"%s","memory_max_mb":"%s","cpus_allowed":"%s","threads":"%s","cpu_weight":"%s","swap_max":"%s","owner":"%s","cgroup":"%s"}' \
        "$(_rsv_json_str "${name}")" "${cpu}" "${mem}" "${aff}" "${thr}" "${d}" "${pid}" "${owner}" "$(_rsv_json_str "${ucg}")"
    done
    printf ']}\n'
    return 0
  fi
  if reserve_enabled; then echo "Host reserve: ON"; else echo "Host reserve: OFF (LLMCTL_HOST_RESERVE=0 - diagnostics only, models may take the whole host)"; fi
  printf '  CPUs:   %s online; %s reserved for the host (%s); models may use %s (%s)%s\n' \
    "${RSV_N}" "${RSV_RC}" "${RSV_RESERVED_SET:-none}" "${RSV_BC}" "${RSV_CPUSET}" "$( ((RSV_CPU_SHORT)) && echo ' [host too small for the full reserve]')"
  printf '          per model: chat %s CPU(s), decision %s CPU(s); rule max(%s CPUs, %s%%) rounded to whole cores\n' \
    "${RSV_CHAT_CPUS}" "${RSV_DECIDE_CPUS}" "${RSV_CPU_MIN}" "${RSV_CPU_PCT}"
  printf '  RAM:    %s MiB total; %s MiB reserved for the host; models may be limited to %s MiB together; rule max(%s MiB, %s%%)%s\n' \
    "${RSV_MT}" "${RSV_RM}" "${RSV_BM}" "${RSV_MEM_MIN}" "${RSV_MEM_PCT}" "$( ((RSV_MEM_SHORT)) && echo ' [host too small for the full reserve]')"
  printf '  Gate:   refuse a start at PSI cpu some avg10 > %s or 1-minute load > %s x %s CPUs (plus the memory gate)\n' \
    "${RSV_GATE_CPU_SOME_MAX}" "${RSV_GATE_LOAD_PER_CPU}" "${RSV_N}"
  if [[ -n "${uerr}" ]]; then echo "  Units:  UNKNOWN - cannot count the running llmctl units (${uerr}); starts are refused"; return 0; fi
  if (( ${#units[@]} == 0 )); then echo "  Units:  no llmctl engine unit is running"; return 0; fi
  echo "  Units (applied limits, read from the cgroup and /proc):"
  local u
  for u in "${units[@]}"; do
    IFS='|' read -r name cpu mem aff thr d pid owner ucg <<<"${u}"
    printf '    %s [%s]: CPUQuota %s%%, MemoryMax %s MiB, CPUs %s, threads %s, CPUWeight %s, swap.max %s\n' \
      "${name}" "${owner}" "${cpu}" "${mem}" "${aff:-?}" "${thr:-?}" "${d:-?}" "${pid:-?}"
  done
}
