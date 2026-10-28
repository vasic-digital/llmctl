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
# plus the largest decision profile that fits, every running unit's state (ok | degraded, with a suggestion to stop it),
# and a machine-readable fallback recommendation: "cloud" when no local decision model fits and a hosted-key VARIABLE is
# set (detected by name only, the value is never read into the output), "local" when one fits, "none" otherwise.
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

# capacity_json [profile...] - prints the capacity document (one JSON object).
capacity_json() {
  reserve_compute
  local mi="${LLMCTL_MEMINFO_FILE:-/proc/meminfo}" la="${LLMCTL_LOADAVG_FILE:-/proc/loadavg}"
  local pdir="${LLMCTL_PSI_DIR:-/proc/pressure}"
  local mpsi="${LLMCTL_PSI_FILE:-${pdir}/memory}" cpsi="${LLMCTL_CPU_PSI_FILE:-${pdir}/cpu}" ipsi="${LLMCTL_IO_PSI_FILE:-${pdir}/io}"
  local root; root="$(_rsv_cgroup_root)"
  local plan_file; plan_file="$(mktemp)"
  hw_probe_json | catalog_plan_json > "${plan_file}" 2>/dev/null || echo '{}' > "${plan_file}"
  local units="" name cpu mem d cur
  while read -r name cpu mem; do
    [[ -n "${name}" ]] || continue
    d="$(find "${root}" -maxdepth 3 -type d -name "${name}" 2>/dev/null | head -1)"
    cur="$(head -1 "${d}/memory.current" 2>/dev/null || true)"
    [[ "${cur}" =~ ^[0-9]+$ ]] && cur=$(( cur / 1048576 )) || cur=""
    units+="${name} $(_cap_unit_profile "${name}") ${cpu} ${mem} ${cur:-?}"$'\n'
  done < <(reserve_running_units)
  local decide
  decide="$(reserve_decide_profiles 2>/dev/null || true)"
  local keyvar="" v
  for v in ${LLMCTL_HOSTED_KEY_VARS}; do
    [[ "${v}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ -n "${!v:-}" ]]; then keyvar="${v}"; break; fi
  done
  local cg_mmax cg_mcur cg_cmax
  cg_mmax="$(head -1 "${root}/memory.max" 2>/dev/null || true)"
  cg_mcur="$(head -1 "${root}/memory.current" 2>/dev/null || true)"
  cg_cmax="$(_rsv_cpu_pct "${root}" 2>/dev/null || true)"
  CAP_ENABLED="$(reserve_enabled && echo 1 || echo 0)" \
  CAP_N="${RSV_N}" CAP_RC="${RSV_RC}" CAP_BC="${RSV_BC}" CAP_RSET="${RSV_RESERVED_SET}" CAP_MSET="${RSV_CPUSET}" \
  CAP_CHAT="${RSV_CHAT_CPUS}" CAP_DECIDE="${RSV_DECIDE_CPUS}" CAP_MT="${RSV_MT}" CAP_RM="${RSV_RM}" CAP_BM="${RSV_BM}" \
  CAP_CPU_SOME_MAX="${RSV_GATE_CPU_SOME_MAX}" CAP_LOAD_K="${RSV_GATE_LOAD_PER_CPU}" \
  CAP_MEM_FULL_MAX="${LLMCTL_GATE_FULL_MAX:-2}" CAP_MEM_SOME_MAX="${LLMCTL_GATE_SOME_MAX:-10}" \
  CAP_MSOME="$(_cap_psi "${mpsi}" some)" CAP_MFULL="$(_cap_psi "${mpsi}" full)" CAP_CSOME="$(_cap_psi "${cpsi}" some)" \
  CAP_ISOME="$(_cap_psi "${ipsi}" some)" CAP_IFULL="$(_cap_psi "${ipsi}" full)" \
  CAP_LOAD="$(head -1 "${la}" 2>/dev/null || true)" CAP_MEMINFO="$(cat "${mi}" 2>/dev/null || true)" \
  CAP_UNITS="${units}" CAP_DECIDE_SET="${decide}" CAP_KEYVAR="${keyvar}" CAP_KEYVARS="${LLMCTL_HOSTED_KEY_VARS}" \
  CAP_CG_ROOT="${root}" CAP_CG_MMAX="${cg_mmax}" CAP_CG_MCUR="${cg_mcur}" CAP_CG_CMAX="${cg_cmax}" \
  CAP_CHECK_PRESSURE="${LLMCTL_GATE_CPU_CHECKS:-1}" \
    python3 - "${plan_file}" "$@" <<'PYEOF'
import json, os, sys, time
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
load = [float(x) for x in la[:3]] if len(la) >= 3 else None
psi = {"memory": {"some": num("CAP_MSOME"), "full": num("CAP_MFULL")}, "cpu": {"some": num("CAP_CSOME")},
       "io": {"some": num("CAP_ISOME"), "full": num("CAP_IFULL")}}
def mb_or_none(v):
    v = (v or "").strip()
    return int(v) // 1048576 if v.isdigit() else None
cg = {"path": E.get("CAP_CG_ROOT"), "memory_max_mb": mb_or_none(E.get("CAP_CG_MMAX")),
      "memory_current_mb": mb_or_none(E.get("CAP_CG_MCUR")),
      "cpu_max_pct": int(E["CAP_CG_CMAX"]) if E.get("CAP_CG_CMAX", "").isdigit() else None}
# usable memory right now: MemAvailable, and the user manager's own memory.max when it is finite
live_avail = avail
if cg["memory_max_mb"] is not None and cg["memory_current_mb"] is not None:
    cg_room = cg["memory_max_mb"] - cg["memory_current_mb"]
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
# --- running llmctl engine units ---
units, used_cpu, used_mem = [], 0, 0
for line in E.get("CAP_UNITS", "").splitlines():
    f = line.split()
    if len(f) < 5: continue
    name, prof, cpu, mem, cur = f[:5]
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
                  "status": "degraded" if reasons else "ok", "reasons": reasons,
                  "suggest": ("llmctl stop %s" % prof.rsplit(".", 1)[0] if "." in prof and prof.rsplit(".", 1)[1].isdigit() else "llmctl stop %s" % prof) if reasons else None})
running = {u["profile"] for u in units}
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
profiles = {}
for p, info in sorted((plan.get("profiles") or {}).items()):
    if wanted and p not in wanted: continue
    cls = "decide" if p in decide_set else "chat"
    cap = decide if cls == "decide" else chat
    fp = int(info.get("ram_mb") or 0)
    need_mem = mem_limit(fp, info.get("mode"), str(info.get("vram_provenance")))
    reasons, verdict, threads = [], "fits", cap
    if p in running:
        reasons.append("already running")
    if info.get("fits") is not True:
        reasons.append("planner: does not fit this host's RAM/VRAM budget (llmctl plan)")
    if enabled and need_mem > mem_free:
        reasons.append("memory limit %s MiB > %s MiB left of the %s MiB model budget" % (need_mem, max(mem_free, 0), Bm))
    if live_avail is not None and live_avail - fp < (Rm if enabled else 4096):
        reasons.append("MemAvailable %s MiB - footprint %s MiB would leave less than the %s MiB host reserve" % (live_avail, fp, Rm if enabled else 4096))
    reasons += pressure
    if enabled and not reasons:
        if cpu_free < 100:
            reasons.append("no CPU left in the %s-CPU model budget (%s%% in use)" % (Bc, used_cpu))
        elif cpu_free < cap * 100:
            threads = cpu_free // 100
            verdict = "fits_with_reduced_threads"
    if reasons and p not in running: verdict = "does_not_fit"
    elif p in running: verdict = "running"
    profiles[p] = {"class": cls, "verdict": verdict, "reasons": reasons,
                   "threads": threads if verdict in ("fits", "fits_with_reduced_threads") else 0,
                   "headroom": {"cpu_pct_free": cpu_free, "cpu_pct_need": cap * 100,
                                "mem_budget_free_mb": mem_free, "mem_limit_need_mb": need_mem,
                                "footprint_mb": fp,
                                "mem_available_after_mb": (live_avail - fp) if live_avail is not None else None}}
fit_dec = [(profiles[p]["headroom"]["footprint_mb"], p) for p in profiles
           if profiles[p]["class"] == "decide" and profiles[p]["verdict"] in ("fits", "fits_with_reduced_threads")]
largest = max(fit_dec)[1] if fit_dec else None
if wanted:
    blocked = any(profiles.get(p, {}).get("verdict") == "does_not_fit" for p in wanted) or any(p not in profiles for p in wanted)
else:
    blocked = largest is None and not any(u["profile"] in decide_set for u in units)
keyvar = E.get("CAP_KEYVAR") or None
if not blocked:
    fb = {"recommended": "local", "reason": "a local model fits", "key_variable": None}
elif keyvar:
    fb = {"recommended": "cloud", "reason": "no local model fits now; a hosted decision key is set", "key_variable": keyvar}
else:
    fb = {"recommended": "none", "reason": "no local model fits now and none of %s is set" % E.get("CAP_KEYVARS"), "key_variable": None}
doc = {
    "schema": "llmctl.capacity/1", "time": int(time.time()),
    "host": {"cpus_online": N, "mem_total_mb": T, "mem_available_mb": avail, "usable_mem_mb": live_avail,
             "swap_total_mb": swap_t, "swap_free_mb": swap_f,
             "load": {"1": load[0], "5": load[1], "15": load[2]} if load else None, "psi": psi, "cgroup": cg},
    "reserve": {"enabled": enabled, "cpus_reserved": Rc, "cpus_reserved_set": E.get("CAP_RSET"),
                "cpus_model_budget": Bc, "cpus_model_set": E.get("CAP_MSET"), "chat_cpu_cap": chat,
                "decide_cpu_cap": decide, "mem_reserved_mb": Rm, "mem_model_budget_mb": Bm},
    "llmctl": {"units": units, "cpu_pct_used": used_cpu, "mem_limits_used_mb": used_mem,
               "cpu_pct_free": cpu_free, "mem_budget_free_mb": mem_free},
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
# 75 a named profile does not fit (or is unknown), 3 nothing named and a running model is degraded.
capacity_exit_code() {
  python3 -c '
import json, sys
d = json.loads(sys.argv[1]); w = sys.argv[2:]
if w:
    bad = [p for p in w if d["profiles"].get(p, {}).get("verdict", "does_not_fit") == "does_not_fit"]
    sys.exit(75 if bad else 0)
sys.exit(3 if d["degraded"] else 0)' "$@"
}

# capacity_human <json> - a short human summary.
capacity_human() {
  python3 -c '
import json, sys
d = json.loads(sys.argv[1]); h = d["host"]; r = d["reserve"]
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
    print("  %-22s %-7s %-26s%s %s" % (p, v["class"], v["verdict"], extra, "; ".join(v["reasons"])))
print("Largest decision model that fits: %s" % (d["largest_decision_fit"] or "none"))
print("Fallback: %s (%s)%s" % (d["fallback"]["recommended"], d["fallback"]["reason"],
      (" via $" + d["fallback"]["key_variable"]) if d["fallback"]["key_variable"] else ""))' "$1"
}

# capacity_admit <profile> - the start/switch admission: rc 0 and sets CAP_THREADS (the CPU cap to use) when the
# profile fits; rc 75 with the reasons and a machine-readable "llmctl-fallback: <cloud|none>" line on stderr when it
# does not. No-op (rc 0) with the host reserve off.
capacity_admit() {
  CAP_THREADS=""
  reserve_enabled || return 0
  local p="$1" doc verdict
  doc="$(capacity_json "${p}")" || return 0          # a broken measurement never blocks a start; the unit gate still runs
  verdict="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); v=d["profiles"].get(sys.argv[2]); print("%s %s" % (v["verdict"], v["threads"]) if v else "unknown 0")' "${doc}" "${p}")"
  case "${verdict%% *}" in
    fits|fits_with_reduced_threads|running) CAP_THREADS="${verdict##* }"; [[ "${CAP_THREADS}" == 0 ]] && CAP_THREADS=""; return 0 ;;
    unknown) return 0 ;;
  esac
  # When the ONLY reason is the planner's RAM/VRAM verdict, defer to the planner path in start, which refuses with
  # exit 1 and the exact MiB numbers ("cannot start '<p>': needs ..."); the capacity gate owns the reserve/CPU/PSI cases.
  if python3 -c 'import json,sys; v=json.loads(sys.argv[1])["profiles"][sys.argv[2]]; sys.exit(0 if v["reasons"] and all(r.startswith("planner:") for r in v["reasons"]) else 1)' "${doc}" "${p}"; then
    return 0
  fi
  python3 -c '
import json, sys
d = json.loads(sys.argv[1]); v = d["profiles"][sys.argv[2]]
sys.stderr.write("refusing to %s %s: the host cannot run it next to its current workload: %s\n" % (sys.argv[3], sys.argv[2], "; ".join(v["reasons"])))
sys.stderr.write("llmctl-fallback: %s\n" % d["fallback"]["recommended"])
if d["fallback"]["key_variable"]: sys.stderr.write("route decisions to the hosted endpoint (key variable %s is set)\n" % d["fallback"]["key_variable"])' \
    "${doc}" "${p}" "${LLMCTL_GATE_ACTION:-start}"
  return 75
}
