#!/usr/bin/env bash
# test_registry_discovery.sh - service discovery through the registry, driven
# through the REAL scheduler and the REAL llmctl-decide binary (spec 009
# FR-089/FR-090, SC-015; T077/T080).
#
# Checks: a service is published only once it answers (never before), is
# removed on stop, a kill -9'd service is removed by reconcile (liveness from
# the real process identity), `registry diff` / the doctor report registry ==
# live set in both directions, and the decision gateway - started through the
# unit hook lib/svc_hook.sh run-gateway - allocates its own port (fixed or
# dynamic), registers itself (kind=gateway), is pointed at the live decision
# instances found in the registry, and has its peak memory recorded (FR-083).
#
# Stand-ins (on purpose): the engine is tests/fixtures/fake_engine.py and the
# service manager is tests/fixtures/svc_backend_direct.sh (see
# test_dynamic_ports.sh). Gateway, TLS, registry, allocator, scheduler: real.
# All ports/paths derive from this host at run time.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP-SUITE: curl not installed"; exit 0; }

BIN="${TEST_TMP}/bin/llmctl-decide"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide )
cp "${LLMCTL_ROOT}/tests/fixtures/fake_engine.py" "${TEST_TMP}/bin/llama-server"
chmod +x "${TEST_TMP}/bin/llama-server"

GW_PID=""
cleanup() {
  [[ -n "${GW_PID}" ]] && kill "${GW_PID}" 2>/dev/null || true
  "${LLMCTL_ROOT}/bin/llmctl" stop all >/dev/null 2>&1 || true
  # last resort: any fake engine of THIS test run that a failed stop left behind
  # (identity proven from /proc: the argv must contain this run's own temp dir)
  local pf pid
  for pf in "${TEST_TMP}"/state/direct/*.pid "${TEST_TMP}"/user2/state/direct/*.pid; do
    [[ -f "${pf}" ]] || continue
    pid="$(cat "${pf}" 2>/dev/null || true)"
    if [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] && tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -qF "${TEST_TMP}/bin/llama-server"; then
      kill "${pid}" 2>/dev/null || true
    fi
  done
  test_teardown_env
}
trap cleanup EXIT

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
reg_json() { "${BIN}" registry list --json; }
reg_has() { reg_json | python3 -c 'import json,sys;sys.exit(0 if any(s["name"]==sys.argv[1] for s in json.load(sys.stdin)["services"]) else 1)' "$1"; }
reg_field() {
  reg_json | python3 -c '
import json,sys
n,f=sys.argv[1:3]
for s in json.load(sys.stdin)["services"]:
    if s["name"]==n:
        print(s.get("labels",{}).get("kind") if f=="kind" else s.get(f)); break
' "$1" "$2"
}
pid_of() { cat "${LLMCTL_STATE_DIR}/direct/$1.pid"; }
run_port() { sed -n 's/^port=//p' "${LLMCTL_RUNTIME_DIR}/$1.run" 2>/dev/null | head -1; }

P_SMALL="$(free_port)"; P_FAST="$(free_port)"; P_DEC="$(free_port)"
while [[ "${P_FAST}" == "${P_SMALL}" ]]; do P_FAST="$(free_port)"; done
while [[ "${P_DEC}" == "${P_SMALL}" || "${P_DEC}" == "${P_FAST}" ]]; do P_DEC="$(free_port)"; done
export LLMCTL_CATALOG="${TEST_TMP}/catalog.json"
python3 - "${LLMCTL_ROOT}/models/catalog.json" "${LLMCTL_CATALOG}" "${P_SMALL}" "${P_FAST}" "${P_DEC}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for name, port in zip(("small", "fast", "decide-2b"), sys.argv[3:6]):
    d["profiles"][name]["port"] = int(port)
    if "ports" in d:
        d["ports"][name] = int(port)
json.dump(d, open(sys.argv[2], "w"), indent=1)
PY
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
for prof in small fast decide-2b; do
  while IFS='|' read -r fname _ _ _; do
    mkdir -p "$(dirname "${LLMCTL_MODELS_DIR}/${prof}/${fname}")"; : > "${LLMCTL_MODELS_DIR}/${prof}/${fname}"
  done < <(catalog_files "${prof}")
done

BASE="$(( ($(free_port) / 100) * 100 + 100 ))"
export LLMCTL_PORTREG=1 LLMCTL_DECIDE_BIN="${BIN}"
export LLMCTL_SERVICE_BACKEND_FILE="${LLMCTL_ROOT}/tests/fixtures/svc_backend_direct.sh"
export LLMCTL_LLAMA_SERVER="${TEST_TMP}/bin/llama-server"
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
export LLMCTL_READY_TIMEOUT=20
export LLMCTL_DECIDE_REGISTRY_INTERVAL=500ms
export LLMCTL_BIND_HOST=127.0.0.1
export LLMCTL_PORT_RANGE="${BASE}-$(( BASE + 59 ))"
export LLMCTL_CTX_SMALL=8192 LLMCTL_KVTYPE_SMALL=f16
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"

echo "== 1. a service is published when it becomes READY, never before =="
( export FAKE_ENGINE_DELAY=3; "${LLMCTL}" start small >/dev/null 2>&1 ) &
START_PID=$!
early_row=0; saw_not_ready=0; saw_ready_row=0
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:${P_SMALL}/health" 2>/dev/null || true)"
  if reg_has small; then
    [[ "${code}" == "200" ]] && saw_ready_row=1 || early_row=1
  else
    [[ "${code}" != "200" ]] && saw_not_ready=1
  fi
  kill -0 "${START_PID}" 2>/dev/null || break
  sleep 0.1
done
wait "${START_PID}" || true
assert_eq 1 "${saw_not_ready}" "observed the window where the engine was alive but not yet answering (and unpublished)"
assert_eq 0 "${early_row}" "the registry row never appeared before the engine answered"
reg_has small && saw_ready_row=1
assert_eq 1 "${saw_ready_row}" "the row is present once the engine answers"
assert_eq "$(pid_of small)" "$(reg_field small pid)" "the row carries the engine's real pid"
assert_eq "/health" "$(reg_field small health_path)" "the row carries the health path"
assert_eq "http://127.0.0.1:${P_SMALL}" "$("${BIN}" discover --json | python3 -c 'import json,sys;print([s["url"] for s in json.load(sys.stdin)["services"] if s["name"]=="small"][0])')" "discover returns the URL clients should use"

echo "== 2. unregistered on stop =="
"${LLMCTL}" stop small >/dev/null 2>&1
if reg_has small; then printf '  FAIL: row survived stop\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: stop removed the row\n'; fi

echo "== 3. kill -9, then reconcile removes the dead service (real process identity) =="
"${LLMCTL}" start small fast >/dev/null 2>&1
KILLED_PID="$(pid_of fast)"
kill -9 "${KILLED_PID}"
for _ in $(seq 1 50); do kill -0 "${KILLED_PID}" 2>/dev/null || break; sleep 0.1; done
reg_has fast && printf '  ok: before reconcile the dead service still has a (stale) row\n' || printf '  ok: row already gone\n'
out="$("${BIN}" registry reconcile --grace 0s --port-grace 0s)"
assert_contains "${out}" "removed fast" "reconcile reports the dead service removed"
if reg_has fast; then printf '  FAIL: dead service still registered after reconcile\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: dead service no longer registered\n'; fi
reg_has small && printf '  ok: the live service is untouched by reconcile\n' || { printf '  FAIL: reconcile removed a live service\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }
assert_eq "" "$("${BIN}" discover --json | python3 -c 'import json,sys;print([s["name"] for s in json.load(sys.stdin)["services"] if s["name"]=="fast"])' | tr -d '[]')" "discover no longer lists it"

echo "== 4. registry == live set, both directions (doctor + diff) =="
source "${LLMCTL_ROOT}/lib/scheduler.sh"
sched_load_backend
"${LLMCTL}" stop all >/dev/null 2>&1
"${LLMCTL}" start small fast >/dev/null 2>&1
rc=0; out="$(portreg_diff_report)" || rc=$?
assert_eq 0 "${rc}" "running set equals the registry"
assert_contains "${out}" "registry == live set" "diff says so"
doc="$("${LLMCTL}" doctor 2>&1 || true)"
assert_contains "${doc}" "service registry == live service set" "llmctl doctor reports PASS for the in-sync registry"
"${BIN}" registry unregister small >/dev/null
rc=0; out="$(portreg_diff_report)" || rc=$?
assert_eq 1 "${rc}" "a live service without a row is reported (rc 1)"
assert_contains "${out}" "live service without a registry row: small" "…naming the service"
doc="$("${LLMCTL}" doctor 2>&1 || true)"
assert_contains "${doc}" "FAIL" "doctor FAILs on the discrepancy"
assert_contains "${doc}" "service registry differs from the live service set" "…with the registry message"
kill -9 "$(pid_of fast)"; for _ in $(seq 1 50); do kill -0 "$(pid_of fast)" 2>/dev/null || break; sleep 0.1; done
rc=0; out="$(portreg_diff_report)" || rc=$?
assert_eq 1 "${rc}" "a registry row without a live service is reported (rc 1)"
assert_contains "${out}" "registry row without a live service: fast" "…naming the service"
"${BIN}" registry reconcile --grace 0s --port-grace 0s >/dev/null
"${LLMCTL}" stop all >/dev/null 2>&1
rc=0; out="$(portreg_diff_report)" || rc=$?
assert_eq 0 "${rc}" "after stop all: registry empty == live set empty"

echo "== 5. 20 random start/stop/kill sequences keep registry == live set (SC-015) =="
export LLMCTL_PORT_STRATEGY=dynamic
bad=0
RANDOM=7
profs=(small fast decide-2b)
for step in $(seq 1 20); do
  p="${profs[$(( RANDOM % 3 ))]}"
  case $(( RANDOM % 3 )) in
    0) "${LLMCTL}" start "${p}" >/dev/null 2>&1 || true ;;
    1) "${LLMCTL}" stop "${p}" >/dev/null 2>&1 || true ;;
    2) if [[ -f "${LLMCTL_STATE_DIR}/direct/${p}.pid" ]]; then
         kp="$(cat "${LLMCTL_STATE_DIR}/direct/${p}.pid")"; kill -9 "${kp}" 2>/dev/null || true
         for _ in $(seq 1 30); do kill -0 "${kp}" 2>/dev/null || break; sleep 0.1; done
         "${BIN}" registry reconcile --grace 0s --port-grace 0s >/dev/null
       fi ;;
  esac
  rc=0; portreg_diff_report >/dev/null 2>&1 || rc=$?
  [[ "${rc}" == 0 ]] || { bad=$((bad+1)); echo "  step ${step}: diff differs after '${p}'" >&2; }
done
assert_eq 0 "${bad}" "registry == live set after each of 20 random steps"
"${LLMCTL}" stop all >/dev/null 2>&1
unset LLMCTL_PORT_STRATEGY

echo "== 6. the gateway: own port (fixed, then dynamic), self-registration, registry-resolved backends =="
export LLMCTL_HOME="${TEST_TMP}/home/llmctl"
export LLMCTL_ENV_FILE="${TEST_TMP}/root/.env"
export LLMCTL_TLS_SAN="ip:127.0.0.1"
export LLMCTL_DECIDE_BIND="127.0.0.1"
mkdir -p "${TEST_TMP}/root"
unset LLMCTL_API_KEY LLMCTL_DECIDE_PORT LLMCTL_TLS_MODE LLMCTL_DECIDE_MODE
"${LLMCTL}" start decide-2b >/dev/null 2>&1
assert_eq "$(run_port decide-2b)" "$(reg_field decide-2b port)" "the decision engine is registered at its assigned port before the gateway starts"
GWN=decide-gateway   # the name the gateway publishes itself under
start_gw() { # start_gw [VAR=VAL...] -> GW_PID
  env "$@" bash "${LLMCTL_ROOT}/lib/svc_hook.sh" run-gateway > "${TEST_TMP}/gw.out" 2>&1 &
  GW_PID=$!
  for _ in $(seq 1 100); do reg_has "${GWN}" && return 0; kill -0 "${GW_PID}" 2>/dev/null || break; sleep 0.2; done
  return 1
}
stop_gw() {
  [[ -n "${GW_PID}" ]] && kill "${GW_PID}" 2>/dev/null || true
  for _ in $(seq 1 150); do reg_has "${GWN}" || break; sleep 0.1; done
  wait "${GW_PID}" 2>/dev/null || true; GW_PID=""
}
model_status() { # model_status <port> <model> -> the gateway's own status for the model ("absent" if unlisted, "?" if unparsable)
  curl -s --cacert "${LLMCTL_HOME}/cert/ca/ca.crt" -H "Authorization: Bearer ${GWKEY}" "https://127.0.0.1:$1/v1/models" \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); sys.exit(0)
m = [x.get("status", "?") for x in d.get("data", []) if x.get("id") == sys.argv[1]]
print(m[0] if m else "absent")' "$2"
}
GW_FIXED="$(free_port)"
rc=0; start_gw LLMCTL_DECIDE_PORT="${GW_FIXED}" || rc=$?
assert_eq 0 "${rc}" "gateway started through the unit wrapper and registered itself"
GWKEY="$(sed -n 's/^LLMCTL_API_KEY=//p' "${LLMCTL_ENV_FILE}" | tr -d "'\"")"
assert_eq "${GW_FIXED}" "$(reg_field "${GWN}" port)" "fixed strategy: the gateway listens on its configured port"
assert_eq "gateway" "$(reg_field "${GWN}" kind)" "registry kind label = gateway"
assert_eq "$(tr '\0' ' ' < "/proc/${GW_PID}/cmdline")" "$(printf '%s ' "${BIN}" serve --foreground)" "the wrapper exec'd exactly: llmctl-decide serve --foreground"
assert_eq "${GW_PID}" "$(reg_field "${GWN}" pid)" "the row carries the gateway's pid"
assert_eq "200" "$(curl -s -o /dev/null -w '%{http_code}' --cacert "${LLMCTL_HOME}/cert/ca/ca.crt" "https://127.0.0.1:${GW_FIXED}/healthz")" "the gateway answers HTTPS on the registered port"
assert_contains "$(tr '\0' '\n' < "/proc/${GW_PID}/environ")" "LLMCTL_DECIDE_RESOLVER=registry" "the gateway resolves backends from the registry, not from a static port table"
# routing follows the registry within a health interval, without a gateway restart
st_up="?"; for _ in $(seq 1 30); do st_up="$(model_status "${GW_FIXED}" decide-2b)"; [[ "${st_up}" == "ready" || "${st_up}" == "available" ]] && break; sleep 0.5; done
echo "    gateway status of decide-2b with its engine registered: ${st_up}"
"${LLMCTL}" stop decide-2b >/dev/null 2>&1
st_down="${st_up}"; for _ in $(seq 1 30); do st_down="$(model_status "${GW_FIXED}" decide-2b)"; [[ "${st_down}" != "${st_up}" ]] && break; sleep 0.5; done
echo "    gateway status of decide-2b after its engine stopped and left the registry: ${st_down}"
if [[ "${st_up}" == "ready" && "${st_down}" != "ready" && "${st_down}" != "?" ]]; then printf '  ok: the gateway stopped routing to the removed engine without a restart (%s -> %s)\n' "${st_up}" "${st_down}"; else printf '  FAIL: gateway view of decide-2b did not change after the engine left the registry (%s)\n' "${st_up}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
# FR-083: measured peak memory of the decision component (policy: no cap, OD-14)
PEAK_KB="$(sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\) kB.*/\1/p' "/proc/${GW_PID}/status")"
if [[ "${PEAK_KB}" =~ ^[0-9]+$ && "${PEAK_KB}" -gt 0 ]]; then printf '  ok: measured gateway peak RSS %s KiB (VmHWM, FR-083)\n' "${PEAK_KB}"; else printf '  FAIL: no peak memory reading\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
stop_gw
if reg_has "${GWN}"; then printf '  FAIL: gateway row survived the gateway process\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: the gateway row is removed when the gateway process ends\n'; fi

rc=0; start_gw LLMCTL_PORT_STRATEGY=dynamic || rc=$?
assert_eq 0 "${rc}" "gateway started under the dynamic strategy and registered itself"
GW_DYN="$(reg_field "${GWN}" port)"
if [[ "${GW_DYN}" -ge "${BASE}" && "${GW_DYN}" -le "$(( BASE + 59 ))" ]]; then printf '  ok: dynamic gateway port %s is inside LLMCTL_PORT_RANGE\n' "${GW_DYN}"; else printf '  FAIL: gateway port %s outside the range\n' "${GW_DYN}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_eq "200" "$(curl -s -o /dev/null -w '%{http_code}' --cacert "${LLMCTL_HOME}/cert/ca/ca.crt" "https://127.0.0.1:${GW_DYN}/healthz")" "the dynamically-ported gateway answers HTTPS"
assert_eq "https" "$(reg_json | python3 -c 'import json,sys;print([s["protocol"] for s in json.load(sys.stdin)["services"] if s["name"]=="decide-gateway"][0])')" "the entry says https"
stop_gw
"${LLMCTL}" stop all >/dev/null 2>&1

# QA evidence, written ONLY on request and derived from this run (never hardcoded)
if [[ "${LLMCTL_QA_EVIDENCE:-0}" == "1" ]]; then
  ev="${LLMCTL_ROOT}/docs/qa/dynamic-ports-validation"
  mkdir -p "${ev}"
  {
    printf 'host_kernel: %s\nhost_cpus: %s\nhost_mem_total_kib: %s\n' "$(uname -sr)" "$(nproc)" "$(awk '/MemTotal/{print $2}' /proc/meminfo)"
    printf 'systemd: %s\n' "$(systemd-analyze --version 2>/dev/null | head -1 || echo none)"
    printf 'gateway_peak_rss_kib: %s\n' "${PEAK_KB}"
    printf 'gateway_dynamic_port_range: %s-%s (chosen from a free port on this host)\n' "${BASE}" "$(( BASE + 59 ))"
    printf 'memory_policy: OD-14 (2026-09-15) no cap below physical RAM; peak recorded regardless (FR-083)\n'
    printf 'recorded_at_utc: %s\n' "$(date -u +%FT%TZ)"
  } > "${ev}/registry-discovery-run.txt"
fi

test_finish
