#!/usr/bin/env bash
# host_reserve_live.sh - LIVE evidence for the 3.4.0 host reserve and capacity gate (§11.4.289: real engine, real model,
# real systemd units and cgroups, readings taken from /sys/fs/cgroup and /proc; no stub answers anything).
#
# usage: scripts/qa/host_reserve_live.sh <llmctl-root> <out-dir> <label> [runs]
#   <llmctl-root>  the llmctl tree whose code renders the unit (the fixed tree, or a worktree of the pre-fix commit)
#   <label>        fixed        - the tree as it is (host reserve on)
#                  reserve-off  - the same tree with LLMCTL_HOST_RESERVE=0 (negative control)
#                  prefix       - a pre-3.4.0 tree (negative control; has no reserve code at all)
#   [runs]         repetitions (default 3)
# Required env: LLMCTL_LLAMA_SERVER (a built llama-server), LLMCTL_MODELS_DIR (holds models/<profile>/), optional
# QA_PROFILE (default decide-tiny, the smallest decision profile).
#
# What each run does:
#   1. renders the engine launch (sched_build_launch) and the unit properties (_svc_resource_directives, the reserve
#      drop-in, _svc_profile_caps) with the tree's own code, and starts that exact command as a transient user unit
#      llmctl-qa-reserve-<label>-r<i>.service (an instance of the operator's installed llmctl-llama@ template cannot be a
#      transient unit; nothing of the operator's units, state or models is written);
#   2. reads the limits back from the unit's cgroup (cpu.max, memory.max/high/swap.max, cpu.weight) and from /proc
#      (threads, Cpus_allowed_list of every thread, nice, oom_score_adj);
#   3. fixed only: loads the model with 4 concurrent completion loops for STRESS_SECONDS and measures the unit's CPU use
#      from cpu.stat usage_usec, throttling from nr_throttled and the CPU every engine thread last ran on (/proc/<tid>/stat
#      field 39). The negative controls are NOT loaded: an unlimited engine would take the host the agents are using;
#      their RED is the read-back (no quota, all CPUs, no thread cap);
#   4. starts a filler unit that holds a 1000% CPU limit (real cgroup, sleeps) and runs `llmctl start <profile>` with
#      LLMCTL_DRY_RUN=1 (a gate that wrongly admits still cannot start a real model): fixed must refuse with 75, print
#      the "llmctl-fallback:" line and leave no new unit or engine process;
#   5. fixed only: a pressure case against the REAL /proc/pressure/cpu reading - the threshold is made stricter than the
#      live value (allowed: only looser is clamped) and `llmctl capacity --json` must report pressure, mark the running
#      QA unit degraded with a stop suggestion and exit 3;
#   6. stops every unit it started and checks that no engine process of this run is left.
# Every run writes run-<i>/ files; summary.json carries the verdicts and the determinism check.
set -euo pipefail

ROOT="$(cd "${1:?usage: host_reserve_live.sh <llmctl-root> <out-dir> <label> [runs]}" && pwd)"
OUT="${2:?out-dir}"
LABEL="${3:?label: fixed|reserve-off|prefix}"
RUNS="${4:-3}"
case "${LABEL}" in fixed|reserve-off|prefix) ;; *) echo "bad label ${LABEL}" >&2; exit 64 ;; esac
PROFILE="${QA_PROFILE:-decide-tiny}"
ENGINE="${LLMCTL_LLAMA_SERVER:?set LLMCTL_LLAMA_SERVER to a built llama-server}"
MODELS="${LLMCTL_MODELS_DIR:?set LLMCTL_MODELS_DIR}"
STRESS_SECONDS="${STRESS_SECONDS:-20}"
[[ -x "${ENGINE}" ]] || { echo "engine not executable: ${ENGINE}" >&2; exit 2; }
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
SCR="$(mktemp -d)"
UNITS=()
export LLMCTL_RESERVE_EXTRA_UNIT_GLOB='llmctl-qa-reserve-*.service'

cleanup() {
  local u
  for u in ${UNITS[@]+"${UNITS[@]}"}; do
    systemctl --user stop "${u}" >/dev/null 2>&1 || true
    systemctl --user reset-failed "${u}" >/dev/null 2>&1 || true
  done
  rm -rf -- "${SCR:?}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${OUT}/harness.log" >&2; }

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# engine_pids <model-path> -> pids whose real executable is the engine and whose argv carries this model (§11.4.196(D):
# the real /proc/<pid>/exe and cmdline, never a substring match on a command line that merely mentions the model).
engine_pids() {
  local p exe
  for p in /proc/[0-9]*; do
    exe="$(readlink "${p}/exe" 2>/dev/null || true)"
    [[ "${exe}" == "$(readlink -f "${ENGINE}")" ]] || continue
    tr '\0' '\n' < "${p}/cmdline" 2>/dev/null | grep -qxF -- "$1" && echo "${p#/proc/}"
  done
  return 0
}

# llmctl_env - the environment every call of the tree's code gets: scratch state and unit dirs, the real models.
llmctl_env() {
  # LLMCTL_RUNTIME_DIR must be isolated too: it defaults to ${XDG_RUNTIME_DIR}/llmctl, the operator's real one, and an
  # admitted dry-run start writes a <profile>.run reservation there (found 2026-10-28: a negative-control run left one, and
  # every later start of that profile short-circuited as "already running" instead of reaching admission).
  local -a e=(LLMCTL_ROOT="${ROOT}" LLMCTL_STATE_DIR="${SCR}/state" LLMCTL_RUNTIME_DIR="${SCR}/run" LLMCTL_UNIT_DIR="${SCR}/units"
              LLMCTL_DATA_DIR="${SCR}/data" LLMCTL_MODELS_DIR="${MODELS}" LLMCTL_LLAMA_SERVER="${ENGINE}"
              LLMCTL_RESERVE_EXTRA_UNIT_GLOB="${LLMCTL_RESERVE_EXTRA_UNIT_GLOB}")
  [[ "${LABEL}" == reserve-off ]] && e+=(LLMCTL_HOST_RESERVE=0)
  printf '%s\n' "${e[@]}"
}

model_file() { local f; for f in "${MODELS}/${PROFILE}"/*.gguf; do [[ "${f}" == *mmproj* ]] && continue; echo "${f}"; return; done; }

# render <dir> <port> -> <dir>/argv (NUL separated), <dir>/props (one systemd property per line), <dir>/key.
render() {
  local d="$1" port="$2"
  mkdir -p "${d}"
  env "${ENVV[@]}" RENDER_DIR="${d}" RENDER_PORT="${port}" RENDER_PROFILE="${PROFILE}" bash -c '
    set -euo pipefail
    for l in common os_detect hardware catalog scheduler service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
    plan="$(hw_probe_json | catalog_plan_json)"
    read -r ctx ram < <(python3 -c "import json,sys; p=json.loads(sys.argv[1])[\"profiles\"][sys.argv[2]]; print(p.get(\"ctx\") or 2048, p.get(\"ram_mb\") or 1024)" "${plan}" "${RENDER_PROFILE}")
    sched_build_launch "${RENDER_PROFILE}" cpu "${RENDER_PORT}" "${ctx}" 0 1 off f16
    printf "%s\0" "${SCHED_EXEC}" "${SCHED_ARGS[@]}" > "${RENDER_DIR}/argv"
    total="$(awk "/^MemTotal:/{print int(\$2/1024)}" /proc/meminfo)"
    _svc_resource_directives | grep -E "^(MemorySwapMax|Nice|IOWeight|CPUWeight|OOMScoreAdjust|CPUQuota|CPUAffinity|KillMode)=" > "${RENDER_DIR}/props"
    if declare -F reserve_dropin_body >/dev/null && reserve_enabled; then
      reserve_dropin_body "${RENDER_PROFILE}" | grep -E "^(CPUQuota|CPUAffinity|AllowedCPUs|Environment)=" >> "${RENDER_DIR}/props"
    fi
    read -r mh mm < <(_svc_profile_caps "${ram}" "${total}" cpu measured)
    printf "MemoryHigh=%sM\nMemoryMax=%sM\n" "${mh}" "${mm}" >> "${RENDER_DIR}/props"
    k="$(ls "${LLMCTL_STATE_DIR}"/keys/llama-*.key 2>/dev/null | head -1 || true)"
    [[ -n "${k}" ]] && cp "${k}" "${RENDER_DIR}/key" && chmod 600 "${RENDER_DIR}/key"
    printf "ctx=%s ram_mb=%s total_mb=%s\n" "${ctx}" "${ram}" "${total}" > "${RENDER_DIR}/render.txt"
  '
}

start_unit() { # <unit> <render-dir>
  local u="$1" d="$2"
  local -a props=() argv=()
  mapfile -t props < "${d}/props"
  mapfile -d '' -t argv < "${d}/argv"
  local -a pargs=()
  local p; for p in "${props[@]}"; do pargs+=(-p "${p}"); done
  UNITS+=("${u}")
  systemd-run --user --quiet --unit="${u}" -p Type=exec "${pargs[@]}" -- "${argv[@]}"
}

wait_health() { # <port> <unit> <seconds>
  local i
  for (( i = 0; i < $3; i++ )); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$1/health" || true)" == 200 ]] && return 0
    systemctl --user is-active --quiet "$2" || return 1
    sleep 1
  done
  return 1
}

readback() { # <unit> <file>
  local u="$1" f="$2" cg pid t
  cg="/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value "${u}")"
  pid="$(systemctl --user show -p MainPID --value "${u}")"
  {
    echo "unit=${u}"
    echo "cgroup=${cg}"
    echo "cpu.max=$(cat "${cg}/cpu.max")"
    echo "cpu.weight=$(cat "${cg}/cpu.weight" 2>/dev/null || echo n/a)"
    echo "memory.max=$(cat "${cg}/memory.max")"
    echo "memory.high=$(cat "${cg}/memory.high")"
    echo "memory.swap.max=$(cat "${cg}/memory.swap.max")"
    echo "pid=${pid}"
    # the real target (review round 3 item 2): what actually runs is identified by the executable the kernel mapped
    echo "exe=$(readlink "/proc/${pid}/exe" 2>/dev/null || echo unreadable)"
    echo "exe_sha256=$(sha256sum "/proc/${pid}/exe" 2>/dev/null | awk '{print $1}' || echo unreadable)"
    echo "model_arg=$(tr '\0' '\n' < "/proc/${pid}/cmdline" | awk 'p{print; exit} $0=="-m"||$0=="--model"{p=1}')"
    echo "threads=$(awk '/^Threads:/{print $2}' "/proc/${pid}/status")"
    echo "nice=$(awk '{print $19}' "/proc/${pid}/stat")"
    echo "oom_score_adj=$(cat "/proc/${pid}/oom_score_adj")"
    echo "cpus_allowed_main=$(awk '/^Cpus_allowed_list:/{print $2}' "/proc/${pid}/status")"
    echo "cpus_allowed_all_threads=$(for t in /proc/"${pid}"/task/*; do awk '/^Cpus_allowed_list:/{print $2}' "${t}/status"; done | sort -u | paste -sd'|' -)"
    echo "argv_threads=$(tr '\0' ' ' < "/proc/${pid}/cmdline" | grep -o -- '--threads [0-9]*' || echo none)"
    echo "env_omp=$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep '^OMP_NUM_THREADS=' || echo none)"
  } > "${f}"
}

stress() { # <unit> <port> <render-dir> <file>
  local u="$1" port="$2" d="$3" f="$4" cg pid u0 u1 t0 t1 end i
  cg="/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value "${u}")"
  pid="$(systemctl --user show -p MainPID --value "${u}")"
  local cfg="${d}/curl.cfg"
  ( umask 077; { printf 'header = "Content-Type: application/json"\n'
    [[ -f "${d}/key" ]] && printf 'header = "Authorization: Bearer %s"\n' "$(cat "${d}/key")"; } > "${cfg}" )
  u0="$(awk '/^usage_usec/{print $2}' "${cg}/cpu.stat")"; t0="$(awk '/^nr_throttled/{print $2}' "${cg}/cpu.stat")"
  local start; start="$(date +%s%N)"; end=$(( $(date +%s) + STRESS_SECONDS ))
  local -a bg=()
  for i in 1 2 3 4; do
    ( while (( $(date +%s) < end )); do
        curl -s -o /dev/null --max-time 30 -K "${cfg}" -d '{"prompt":"Count from one to one hundred in words:","n_predict":96,"cache_prompt":false}' \
          "http://127.0.0.1:${port}/completion" || true
      done ) &
    bg+=("$!")
  done
  : > "${d}/cpus_seen"
  while (( $(date +%s) < end )); do
    for t in /proc/"${pid}"/task/*; do awk '{print $39}' "${t}/stat" 2>/dev/null >> "${d}/cpus_seen" || true; done
    sleep 1
  done
  wait "${bg[@]}" 2>/dev/null || true
  local stop; stop="$(date +%s%N)"
  u1="$(awk '/^usage_usec/{print $2}' "${cg}/cpu.stat")"; t1="$(awk '/^nr_throttled/{print $2}' "${cg}/cpu.stat")"
  python3 - "$u0" "$u1" "$t0" "$t1" "$start" "$stop" "${d}/cpus_seen" > "${f}" <<'PY'
import sys
u0, u1, t0, t1, s, e = map(int, sys.argv[1:7])
seen = sorted({int(x) for x in open(sys.argv[7]).read().split() if x.isdigit()})
wall = (e - s) / 1e9
print("window_s=%.2f" % wall)
print("cpu_pct=%.1f" % ((u1 - u0) / 1e6 / wall * 100))
print("nr_throttled_delta=%d" % (t1 - t0))
print("cpus_seen=%s" % ",".join(map(str, seen)))
PY
}

host_ctx() { # <file>
  { echo "time=$(date -u +%FT%TZ)"; echo "nproc=$(nproc)"; echo "loadavg=$(cat /proc/loadavg)"
    echo "psi_cpu=$(head -1 /proc/pressure/cpu)"; echo "psi_mem=$(head -1 /proc/pressure/memory)"
    echo "memavailable_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"; } > "$1"
}

over_budget_start() { # <run-dir> <i>
  local d="$1" i="$2" filler="llmctl-qa-reserve-${LABEL}-filler-r${2}.service" before after rc
  UNITS+=("${filler}")
  systemd-run --user --quiet --unit="${filler}" -p CPUQuota=1000% -p MemoryMax=64M -- sleep 600
  sleep 1
  before="$(systemctl --user list-units --all --no-legend --plain 'llmctl-*' | awk '{print $1}' | sort | paste -sd' ' -)"
  local b_pids; b_pids="$(engine_pids "$(model_file)" | sort | paste -sd' ' -)"
  set +e
  env "${ENVV[@]}" LLMCTL_DRY_RUN=1 "${ROOT}/bin/llmctl" start "${PROFILE}" > "${d}/second_start.out" 2> "${d}/second_start.err"
  rc=$?
  set -e
  after="$(systemctl --user list-units --all --no-legend --plain 'llmctl-*' | awk '{print $1}' | sort | paste -sd' ' -)"
  local a_pids; a_pids="$(engine_pids "$(model_file)" | sort | paste -sd' ' -)"
  {
    echo "rc=${rc}"
    # precondition: the start must reach admission; "already running" short-circuits before it and proves nothing
    echo "reached_admission=$(grep -qh 'is already running' "${d}/second_start.out" "${d}/second_start.err" && echo no || echo yes)"
    echo "fallback_line=$(grep -o 'llmctl-fallback: [a-z]*' "${d}/second_start.err" | head -1 || echo none)"
    echo "units_before=${before}"
    echo "units_after=${after}"
    echo "engine_pids_before=${b_pids}"
    echo "engine_pids_after=${a_pids}"
    echo "env_record_written=$([[ -e "${SCR}/state/services/${PROFILE}.env" ]] && echo yes || echo no)"
  } > "${d}/second_start.txt"
  # an ADMITTED dry run (the negative controls) leaves its reservation and env record in this harness's scratch state;
  # clear them so the next run's second start reaches admission again instead of short-circuiting as "already running"
  rm -f -- "${SCR:?}/run/${PROFILE}.run" "${SCR:?}/state/services/${PROFILE}.env"
  systemctl --user stop "${filler}" >/dev/null 2>&1 || true
}

pressure_case() { # <run-dir>
  local d="$1" some thr rc
  some="$(awk '/^some/{split($2,a,"="); print a[2]}' /proc/pressure/cpu)"
  # a quarter of the live value: PSI avg10 moves between this read and the tool's own read (measured: 19.6 -> 13.9 within
  # seconds after a load stops), so a threshold just under the live value is a race; the oracle below compares against
  # the value the TOOL itself read, which it reports in its JSON.
  thr="$(awk -v v="${some}" 'BEGIN{t=int(v/4); if (v < 4) t=-1; print t}')"
  if (( thr < 0 )); then
    printf 'skipped=live CPU PSI some avg10 is %s, no stricter threshold below it exists\n' "${some}" > "${d}/pressure.txt"; return 0
  fi
  set +e
  env "${ENVV[@]}" LLMCTL_GATE_CPU_SOME_MAX="${thr}" "${ROOT}/bin/llmctl" capacity --json "${PROFILE}" > "${d}/pressure_capacity.json" 2> "${d}/pressure_capacity.err"
  rc=$?
  set -e
  python3 - "${d}/pressure_capacity.json" "${rc}" "${some}" "${thr}" > "${d}/pressure.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
qa = [u for u in d["llmctl"]["units"] if u["unit"].startswith("llmctl-qa-reserve-")]
print("live_cpu_some_avg10=%s threshold=%s" % (sys.argv[3], sys.argv[4]))
seen = d["host"]["psi"]["cpu"]["some"]
print("tool_cpu_some_avg10=%s" % seen)
print("tool_saw_above_threshold=%s" % (seen is not None and seen > float(sys.argv[4])))
print("rc=%s" % sys.argv[2])
print("pressure_ok=%s" % d["pressure"]["ok"])
print("pressure_reasons=%s" % "; ".join(d["pressure"]["reasons"]))
print("qa_unit_status=%s" % ",".join(u["status"] for u in qa))
print("qa_unit_suggest=%s" % ",".join(u.get("suggest") or "" for u in qa))
print("profile_verdict=%s" % next(iter(d["profiles"].values()))["verdict"])
print("fallback=%s" % d["fallback"]["recommended"])
PY
}

mapfile -t ENVV < <(llmctl_env)
log "label=${LABEL} root=${ROOT} profile=${PROFILE} runs=${RUNS}"
# the code under test (review round 3 item 2): HEAD, its tree, and a hash of any uncommitted diff, so the evidence is tied
# to exact content and a dirty run is visible as dirty. Review round 4, F5: the WHOLE tree is checked (tracked changes and
# untracked files, tests and docs included), except this run's own output directory when it lies inside the checkout.
DIRTY_SPEC=(.)
case "${OUT}/" in "${ROOT}/"*) DIRTY_SPEC+=(":(exclude)${OUT#"${ROOT}"/}") ;; esac
{
  echo "head=$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo none)"
  echo "head_tree=$(git -C "${ROOT}" rev-parse 'HEAD^{tree}' 2>/dev/null || echo none)"
  if git -C "${ROOT}" rev-parse --git-dir > /dev/null 2>&1; then
    if [[ -z "$(git -C "${ROOT}" status --porcelain -- "${DIRTY_SPEC[@]}" 2>/dev/null)" ]]; then
      echo "dirty=no"
    else
      echo "dirty=yes"
      echo "dirty_paths=$(git -C "${ROOT}" status --porcelain -- "${DIRTY_SPEC[@]}" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
      echo "dirty_diff_sha256=$( { git -C "${ROOT}" diff HEAD -- "${DIRTY_SPEC[@]}"; git -C "${ROOT}" status --porcelain -- "${DIRTY_SPEC[@]}"; } | sha256sum | awk '{print $1}')"
    fi
  else
    echo "dirty=unknown (not a git checkout)"
  fi
  echo "llama_server=${LLMCTL_LLAMA_SERVER:-unset}"
  echo "llama_server_sha256=$(sha256sum "${LLMCTL_LLAMA_SERVER:-/nonexistent}" 2>/dev/null | awk '{print $1}' || echo unreadable)"
} > "${OUT}/artifact_commit.txt"
for (( i = 1; i <= RUNS; i++ )); do
  D="${OUT}/run-${i}"; mkdir -p "${D}"
  host_ctx "${D}/host_before.txt"
  PORT="$(free_port)"; U="llmctl-qa-reserve-${LABEL}-r${i}.service"
  render "${D}" "${PORT}"
  log "run ${i}: starting ${U} on 127.0.0.1:${PORT}"
  start_unit "${U}" "${D}"
  if ! wait_health "${PORT}" "${U}" 240; then
    log "run ${i}: engine did not become healthy"; journalctl --user -u "${U}" -n 40 --no-pager > "${D}/journal.txt" 2>&1 || true
    echo "healthy=no" > "${D}/verdict.txt"; systemctl --user stop "${U}" || true; continue
  fi
  readback "${U}" "${D}/limits.txt"
  if [[ "${LABEL}" == fixed ]]; then
    stress "${U}" "${PORT}" "${D}" "${D}/stress.txt"
  else
    echo "skipped=negative control is not loaded (an unlimited engine would take the shared host)" > "${D}/stress.txt"
  fi
  over_budget_start "${D}" "${i}"
  [[ "${LABEL}" == fixed ]] && pressure_case "${D}"
  systemctl --user stop "${U}"
  sleep 1
  model_file="$(model_file)"
  {
    echo "unit_state=$(systemctl --user is-active "${U}" 2>/dev/null || true)"
    echo "leftover_engine_pids_with_port=$(for p in $(engine_pids "${model_file}"); do tr '\0' ' ' < "/proc/${p}/cmdline" | grep -q -- "--port ${PORT} " && echo "${p}"; done | paste -sd' ' -)"
  } > "${D}/post_stop.txt"
  host_ctx "${D}/host_after.txt"
  rm -f -- "${D:?}/curl.cfg" "${D:?}/key"
  log "run ${i}: done"
done

python3 - "${OUT}" "${LABEL}" "${RUNS}" > "${OUT}/summary.json" <<'PY'
import json, os, sys
out, label, runs = sys.argv[1], sys.argv[2], int(sys.argv[3])
def kv(path):
    d = {}
    if os.path.exists(path):
        for line in open(path):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1); d[k] = v
    return d
def cpuset(s):
    r = set()
    for part in s.replace(" ", ",").split(","):
        if not part: continue
        a, _, b = part.partition("-"); r.update(range(int(a), int(b or a) + 1))
    return r
art = kv(os.path.join(out, "artifact_commit.txt"))
res = []
for i in range(1, runs + 1):
    d = os.path.join(out, "run-%d" % i)
    lim, st, ss, pr, ps = (kv(os.path.join(d, f)) for f in ("limits.txt", "stress.txt", "second_start.txt", "pressure.txt", "post_stop.txt"))
    checks = {}
    cpumax = lim.get("cpu.max", "")
    q = cpumax.split()
    quota_pct = int(q[0]) * 100 // int(q[1]) if q and q[0] != "max" else None
    checks["cpu_quota_set"] = quota_pct is not None
    # the process in the unit runs the engine binary named in artifact_commit.txt (by content, not by path)
    checks["engine_exe_is_the_named_binary"] = lim.get("exe_sha256", "x") == art.get("llama_server_sha256", "y") and len(lim.get("exe_sha256", "")) == 64
    allowed = lim.get("cpus_allowed_all_threads", "")
    checks["affinity_excludes_reserved_cpus"] = bool(allowed) and "|" not in allowed and not ({0, 1, 8, 9} & cpuset(allowed)) if os.cpu_count() == 16 else None
    checks["thread_cap_in_argv"] = lim.get("argv_threads", "none") != "none"
    checks["swap_off"] = lim.get("memory.swap.max") == "0"
    checks["memory_max_bounded"] = lim.get("memory.max", "max") != "max"
    checks["oom_score_adj_800"] = lim.get("oom_score_adj") == "800"
    checks["nice_15"] = lim.get("nice") == "15"
    if "cpu_pct" in st and quota_pct:
        checks["stress_cpu_within_quota"] = float(st["cpu_pct"]) <= quota_pct * 1.10
        seen = cpuset(st.get("cpus_seen", ""))
        checks["stress_never_on_reserved_cpus"] = not (seen & {0, 1, 8, 9}) if os.cpu_count() == 16 else None
    checks["second_start_reached_admission"] = ss.get("reached_admission") == "yes"
    checks["second_start_refused_75"] = ss.get("rc") == "75"
    checks["second_start_fallback_line"] = ss.get("fallback_line", "none") != "none"
    checks["second_start_no_new_unit"] = ss.get("units_before") == ss.get("units_after")
    checks["second_start_no_new_engine_process"] = ss.get("engine_pids_before") == ss.get("engine_pids_after")
    checks["second_start_no_env_record"] = ss.get("env_record_written") == "no"
    if pr and "skipped" not in pr and pr.get("tool_saw_above_threshold") == "True":
        checks["pressure_reported"] = pr.get("pressure_ok") == "False"
        checks["pressure_unit_degraded"] = pr.get("qa_unit_status", "").startswith("degraded")
        checks["pressure_exit_3_or_75"] = pr.get("rc") in ("3", "75")
    checks["no_process_left"] = ps.get("leftover_engine_pids_with_port", "x") == ""
    res.append({"run": i, "limits": lim, "stress": st, "second_start": ss, "pressure": pr, "checks": checks})
keys = ["cpu.max", "memory.max", "memory.high", "memory.swap.max", "cpus_allowed_all_threads", "argv_threads", "nice", "oom_score_adj"]
det = all(r["limits"].get(k) == res[0]["limits"].get(k) for r in res for k in keys)
verdict_keys = sorted({k for r in res for k in r["checks"]})
det_checks = all(r["checks"].get(k) == res[0]["checks"].get(k) for r in res for k in verdict_keys)
print(json.dumps({"label": label, "runs": runs, "artifact": art, "deterministic_limits": det, "deterministic_verdicts": det_checks,
                  "all_checks_true": all(v in (True, None) for r in res for v in r["checks"].values()),
                  "results": res}, indent=1))
PY
log "summary: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("deterministic_limits=%s deterministic_verdicts=%s all_checks_true=%s" % (d["deterministic_limits"], d["deterministic_verdicts"], d["all_checks_true"]))' "${OUT}/summary.json")"
