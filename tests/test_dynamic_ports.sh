#!/usr/bin/env bash
# test_dynamic_ports.sh - dynamic port assignment through the REAL scheduler
# start path (spec 009 FR-088, OD-18, SC-015; T077).
#
# What is real here: bin/llmctl (start/stop/switch/enable/disable/plan/status),
# lib/scheduler.sh, lib/portreg.sh, the production env-record writer, and the
# llmctl-decide binary (built from this tree into a temp dir; nothing lands in
# the repo). What is a stand-in, on purpose: the ENGINE is tests/fixtures/
# fake_engine.py (harmless: binds the given host:port, answers /health and
# /v1/models) standing in for llama-server, and the service MANAGER is
# tests/fixtures/svc_backend_direct.sh (spawns the engine from the env record
# and tracks its pid) so the developer's systemd user manager is never touched.
# Every port, range and process is derived from THIS host at run time - no
# hardcoded host name, path or port number.
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

OCCUPIERS=()
cleanup() {
  local p
  "${LLMCTL_ROOT}/bin/llmctl" stop all >/dev/null 2>&1 || true
  LLMCTL_STATE_DIR="${TEST_TMP}/user2/state" LLMCTL_RUNTIME_DIR="${TEST_TMP}/user2/run" \
    LLMCTL_SERVICES_DIR="${TEST_TMP}/user2/services" LLMCTL_LOG_DIR="${TEST_TMP}/user2/logs" \
    "${LLMCTL_ROOT}/bin/llmctl" stop all >/dev/null 2>&1 || true
  for p in "${OCCUPIERS[@]:-}"; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done
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
occupy() { # occupy <port> -> background listener, pid in OCC_PID
  python3 -c "import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',$1));s.listen();time.sleep(600)" &
  OCC_PID=$!; OCCUPIERS+=("${OCC_PID}")
  for _ in $(seq 1 50); do python3 -c "import socket;socket.create_connection(('127.0.0.1',$1),0.2)" 2>/dev/null && return 0; sleep 0.1; done
  echo "occupier on $1 never came up" >&2; return 1
}
reg_ports() { "${BIN}" registry list --json | python3 -c 'import json,sys;print(" ".join("%s=%s"%(s["name"],s["port"]) for s in json.load(sys.stdin)["services"]))'; }
reg_field() { # reg_field <name> <port|kind|loopback_only|url>
  "${BIN}" registry list --json | python3 -c '
import json,sys
n,f=sys.argv[1:3]
for s in json.load(sys.stdin)["services"]:
    if s["name"]==n:
        v = s.get("labels",{}).get("kind") if f=="kind" else s.get(f)
        print(v); break
' "$1" "$2"
}
run_port() { sed -n 's/^port=//p' "${LLMCTL_RUNTIME_DIR}/$1.run" 2>/dev/null | head -1; }
cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline"; }
pid_of() { cat "${LLMCTL_STATE_DIR}/direct/$1.pid"; }

# ---- a catalog derived from the real one, with free ports found on THIS host ----
P_SMALL="$(free_port)"; P_FAST="$(free_port)"; P_DEC="$(free_port)"
while [[ "${P_FAST}" == "${P_SMALL}" ]]; do P_FAST="$(free_port)"; done
while [[ "${P_DEC}" == "${P_SMALL}" || "${P_DEC}" == "${P_FAST}" ]]; do P_DEC="$(free_port)"; done
export LLMCTL_CATALOG="${TEST_TMP}/catalog.json"
python3 - "${LLMCTL_ROOT}/models/catalog.json" "${LLMCTL_CATALOG}" "${P_SMALL}" "${P_FAST}" "${P_DEC}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for name, port in zip(("small", "fast", "decide-tiny"), sys.argv[3:6]):
    d["profiles"][name]["port"] = int(port)
    if "ports" in d:
        d["ports"][name] = int(port)
json.dump(d, open(sys.argv[2], "w"), indent=1)
PY
# model files (the scheduler checks they exist; the fake engine never reads them)
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
for prof in small fast decide-tiny; do
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
export LLMCTL_BIND_HOST=127.0.0.1
export LLMCTL_PORT_RANGE="${BASE}-$(( BASE + 59 ))"
export LLMCTL_CTX_SMALL=8192 LLMCTL_KVTYPE_SMALL=f16
unset LLMCTL_PORT_STRATEGY
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"

echo "== 1. fixed strategy (default, OD-18): the documented port, recorded everywhere =="
rc=0; out="$("${LLMCTL}" start small 2>&1)" || rc=$?
assert_eq 0 "${rc}" "start small (fixed) succeeds"
assert_contains "${out}" "port=${P_SMALL}" "start output records the assigned port"
assert_eq "${P_SMALL}" "$(run_port small)" "reservation record holds the documented port"
assert_file_contains "${LLMCTL_SERVICES_DIR}/small.env" "--port ${P_SMALL}" "env record / launch arguments carry the port"
assert_file_contains "${LLMCTL_SERVICES_DIR}/small.env" "LLMCTL_PORT=${P_SMALL}" "env record names the port for the registration hook"
assert_eq "600" "$(stat -c %a "${LLMCTL_SERVICES_DIR}/small.env")" "env record is mode 0600"
assert_contains "$(cmdline_of "$(pid_of small)")" "--port ${P_SMALL}" "the live process was started on that port (/proc cmdline)"
assert_eq "${P_SMALL}" "$(reg_field small port)" "registry row published at ready with the same port"
assert_eq "chat" "$(reg_field small kind)" "registry kind label = chat"
assert_contains "$("${LLMCTL}" status)" "${P_SMALL}" "status shows the assigned port"
assert_eq "${P_SMALL}" "$("${LLMCTL}" plan --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["profiles"]["small"]["assigned_port"])')" "plan --json records the assigned port of a running service"
assert_eq "http://127.0.0.1:${P_SMALL}" "$("${BIN}" discover --json --kind chat | python3 -c 'import json,sys;print(json.load(sys.stdin)["services"][0]["url"])')" "discover resolves the service by kind label"

echo "== 2. fixed + the default port occupied by another program: fails naming port and variable =="
occupy "${P_FAST}"
rc=0; err="$("${LLMCTL}" start fast 2>&1 >/dev/null)" || rc=$?
assert_eq "1" "${rc}" "taken documented port: start exits non-zero"
assert_contains "${err}" "${P_FAST}" "message names the port"
assert_contains "${err}" "LLMCTL_PORT_FAST" "message names the override variable"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/fast.run" "no reservation was written for the refused start"
assert_eq "" "$(reg_field fast port)" "no registry row for the refused start"
assert_eq "" "$("${BIN}" port list | awk '$1=="fast"{print $2}')" "no port hold left behind by the refused start"

echo "== 3. dynamic per profile (=auto) with that same port occupied: starts on a free range port =="
rc=0; LLMCTL_PORT_FAST=auto "${LLMCTL}" start fast >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "start fast with LLMCTL_PORT_FAST=auto succeeds although ${P_FAST} is occupied"
DYN_FAST="$(run_port fast)"
if [[ "${DYN_FAST}" != "${P_FAST}" && "${DYN_FAST}" -ge "${BASE}" && "${DYN_FAST}" -le "$(( BASE + 59 ))" ]]; then
  printf '  ok: dynamic port %s is inside LLMCTL_PORT_RANGE and differs from the occupied %s\n' "${DYN_FAST}" "${P_FAST}"
else
  printf '  FAIL: dynamic port %s not in range %s-%s or equal to occupied %s\n' "${DYN_FAST}" "${BASE}" "$(( BASE + 59 ))" "${P_FAST}" >&2; TEST_FAILS=$((TEST_FAILS+1))
fi
assert_eq "${DYN_FAST}" "$(reg_field fast port)" "registry row carries the dynamic port"
assert_contains "$(cmdline_of "$(pid_of fast)")" "--port ${DYN_FAST}" "process listens where the registry says"
assert_eq "${DYN_FAST}" "$("${LLMCTL}" plan --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["profiles"]["fast"]["assigned_port"])')" "plan --json shows the dynamic assignment"
assert_eq "200" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DYN_FAST}/health")" "the service answers on the assigned port"

echo "== 4. restart reuses the port when still free; stop releases hold and registry row =="
"${LLMCTL}" stop fast >/dev/null 2>&1
assert_eq "" "$(reg_field fast port)" "stop removed the registry row"
assert_eq "" "$("${BIN}" port list | awk '$1=="fast"{print $2}')" "stop released the port hold"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/fast.run" "stop removed the reservation"
LLMCTL_PORT_FAST=auto "${LLMCTL}" start fast >/dev/null 2>&1
assert_eq "${DYN_FAST}" "$(run_port fast)" "restart of the same service reuses its previous dynamic port (sticky)"
"${LLMCTL}" stop fast >/dev/null 2>&1

echo "== 5. global dynamic strategy: three services, distinct free ports, all registered =="
"${LLMCTL}" stop all >/dev/null 2>&1
export LLMCTL_PORT_STRATEGY=dynamic
rc=0; "${LLMCTL}" start small fast decide-tiny >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "three services start under LLMCTL_PORT_STRATEGY=dynamic"
PS="$(run_port small) $(run_port fast) $(run_port decide-tiny)"
assert_eq "3" "$(printf '%s\n' ${PS} | sort -u | wc -l | tr -d ' ')" "three distinct ports: ${PS}"
for pr in small fast decide-tiny; do
  prt="$(run_port "${pr}")"
  if [[ "${prt}" -ge "${BASE}" && "${prt}" -le "$(( BASE + 59 ))" ]]; then printf '  ok: %s port %s inside the range\n' "${pr}" "${prt}"; else printf '  FAIL: %s port %s outside range\n' "${pr}" "${prt}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  assert_eq "${prt}" "$(reg_field "${pr}" port)" "${pr}: registry port equals the live assignment"
  assert_eq "200" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${prt}/health")" "${pr}: answers on its assigned port"
done
assert_eq "decide" "$(reg_field decide-tiny kind)" "decision profile is published with kind=decide"
assert_eq "True" "$(reg_field decide-tiny loopback_only)" "decision engine entry says loopback-only (FR-090)"

echo "== 6. decision engine launch (FR-073/FR-074, G-030): loopback, key FILE, one slot =="
DCMD="$(cmdline_of "$(pid_of decide-tiny)")"
assert_contains "${DCMD}" "--host 127.0.0.1" "decision engine binds loopback only"
assert_contains "${DCMD}" "--parallel 1" "deterministic mode (default) launches exactly one slot (-np 1)"
assert_contains "${DCMD}" "--ctx-size 4096" "context per slot preserved (catalog ctx, one slot)"
assert_contains "${DCMD}" "--no-webui" "web UI disabled"
KEYF="${LLMCTL_STATE_DIR}/keys/llama-decide-tiny.key"
assert_contains "${DCMD}" "--api-key-file ${KEYF}" "key passed as a FILE path"
assert_eq "600" "$(stat -c %a "${KEYF}")" "key file mode 0600"
assert_eq "700" "$(stat -c %a "$(dirname "${KEYF}")")" "key directory mode 0700"
KEYVAL="$(head -1 "${KEYF}")"
if [[ -n "${KEYVAL}" && "${DCMD}" != *"${KEYVAL}"* ]] && ! grep -q "${KEYVAL}" "/proc/$(pid_of decide-tiny)/environ" 2>/dev/null; then
  printf '  ok: the key value is in neither /proc/<pid>/cmdline nor /proc/<pid>/environ\n'
else
  printf '  FAIL: key value visible in cmdline or environ (or empty)\n' >&2; TEST_FAILS=$((TEST_FAILS+1))
fi
CHAT_CMD="$(cmdline_of "$(pid_of small)")"
assert_contains "${CHAT_CMD}" "--parallel" "chat engine still launches with its catalog parallel"
if [[ "${CHAT_CMD}" == *"--api-key-file"* || "${CHAT_CMD}" == *"--no-webui"* ]]; then printf '  FAIL: chat engine must not get decision-only flags\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: chat engine launch is unchanged (no key file, UI untouched)\n'; fi
# throughput mode: catalog parallel, ctx per slot preserved (llama-server divides --ctx-size across slots)
tp="$( ( export LLMCTL_DRY_RUN=1 LLMCTL_DECIDE_MODE=throughput; source "${LLMCTL_ROOT}/lib/scheduler.sh"; sched_build_launch decide-tiny gpu 9 4096 99 4 auto q8_0; printf '%s ' "${SCHED_ARGS[@]}" ) )"
assert_contains "${tp}" "--parallel 4" "throughput mode (opt-in) uses the catalog parallel"
assert_contains "${tp}" "--ctx-size 16384" "throughput mode scales --ctx-size so each slot keeps 4096"
rc=0; ( export LLMCTL_DRY_RUN=1 LLMCTL_DECIDE_MODE=bogus; source "${LLMCTL_ROOT}/lib/scheduler.sh"; sched_build_launch decide-tiny gpu 9 4096 99 4 auto q8_0 ) >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "an invalid LLMCTL_DECIDE_MODE is refused"
# the capacity report states the mode its slot figures assume
rep="$("${LLMCTL}" plan --json | python3 -c 'import json,sys;d=json.load(sys.stdin);e=d["decision_instances"]["decide-tiny"];print(d["decision_mode"],e["mode"],e["slots_assume_mode"],e["effective_slots_per_instance"])')"
assert_eq "deterministic deterministic throughput 1" "${rep}" "capacity report: mode=deterministic, catalog-parallel figures labelled as throughput-mode, effective slots = 1"
rep="$(LLMCTL_DECIDE_MODE=throughput "${LLMCTL}" plan --json | python3 -c 'import json,sys;d=json.load(sys.stdin);e=d["decision_instances"]["decide-tiny"];print(d["decision_mode"],e["effective_slots_per_instance"])')"
assert_eq "throughput 4" "${rep}" "capacity report under throughput mode: effective slots = catalog parallel"

echo "== 7. explicit numeric port always wins, even under the dynamic strategy =="
"${LLMCTL}" stop small >/dev/null 2>&1
EXPL="$(free_port)"
LLMCTL_PORT_SMALL="${EXPL}" "${LLMCTL}" start small >/dev/null 2>&1
assert_eq "${EXPL}" "$(run_port small)" "LLMCTL_PORT_SMALL=<n> beats LLMCTL_PORT_STRATEGY=dynamic"
assert_eq "${EXPL}" "$(reg_field small port)" "registry carries the explicit port"

echo "== 8. per-user isolation: a second user gets a disjoint port set =="
U2="${TEST_TMP}/user2"
u2() { env LLMCTL_STATE_DIR="${U2}/state" LLMCTL_RUNTIME_DIR="${U2}/run" LLMCTL_SERVICES_DIR="${U2}/services" LLMCTL_LOG_DIR="${U2}/logs" "$@"; }
mkdir -p "${U2}"
u2 "${LLMCTL}" start small fast >/dev/null 2>&1
U1_SET="$(for p in small fast decide-tiny; do run_port "${p}"; done | sort -n | tr '\n' ' ')"
U2_SET="$(for p in small fast; do sed -n 's/^port=//p' "${U2}/run/${p}.run"; done | sort -n | tr '\n' ' ')"
OVERLAP="$(comm -12 <(tr ' ' '\n' <<<"${U1_SET}" | sort) <(tr ' ' '\n' <<<"${U2_SET}" | sort) | grep -c . || true)"
assert_eq "0" "${OVERLAP}" "user 1 ports {${U1_SET}} and user 2 ports {${U2_SET}} are disjoint (same range, bind test)"
U2BASE=$(( BASE + 60 ))
u2 "${LLMCTL}" stop all >/dev/null 2>&1
U2_PORT="$(u2 env LLMCTL_PORT_RANGE="${U2BASE}-$(( U2BASE + 29 ))" "${LLMCTL}" start small >/dev/null 2>&1; sed -n 's/^port=//p' "${U2}/run/small.run")"
if [[ -n "${U2_PORT}" && "${U2_PORT}" -ge "${U2BASE}" && "${U2_PORT}" -le "$(( U2BASE + 29 ))" ]]; then printf '  ok: a per-user LLMCTL_PORT_RANGE confines user 2 to %s-%s (got %s)\n' "${U2BASE}" "$(( U2BASE + 29 ))" "${U2_PORT}"; else printf '  FAIL: per-user range not honoured (got %q)\n' "${U2_PORT}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
u2 "${LLMCTL}" stop all >/dev/null 2>&1

echo "== 9. switch and enable/disable keep ports + registry consistent =="
"${LLMCTL}" stop all >/dev/null 2>&1
"${LLMCTL}" start fast >/dev/null 2>&1
"${LLMCTL}" switch small >/dev/null 2>&1
assert_eq "" "$(reg_field fast port)" "switch unregistered the stopped profile"
assert_eq "$(run_port small)" "$(reg_field small port)" "switch registered the new profile at its assigned port"
"${LLMCTL}" stop all >/dev/null 2>&1
"${LLMCTL}" enable small >/dev/null 2>&1
EN_PORT="$(run_port small)"
assert_eq "${EN_PORT}" "$(reg_field small port)" "enable publishes the service in the registry"
assert_eq "${EN_PORT}" "$("${BIN}" port list | awk '$1=="small"{print $2}')" "enable holds the port"
"${LLMCTL}" enable small >/dev/null 2>&1
assert_eq "${EN_PORT}" "$(run_port small)" "re-enabling a running service keeps the port it holds"
"${LLMCTL}" disable small >/dev/null 2>&1
assert_eq "" "$(reg_field small port)" "disable removed the registry row"
assert_eq "" "$("${BIN}" port list | awk '$1=="small"{print $2}')" "disable released the port hold"

echo "== 10. stop all: registry and port holds are empty =="
"${LLMCTL}" start small decide-tiny >/dev/null 2>&1
"${LLMCTL}" stop all >/dev/null 2>&1
assert_eq "" "$(reg_ports)" "registry is empty after stop all"
assert_eq "" "$("${BIN}" port list)" "no port holds remain after stop all"

echo "== 10b. after a reboot the reservation is rebuilt with the REAL (dynamic) port =="
export LLMCTL_PORT_STRATEGY=dynamic
"${LLMCTL}" enable small >/dev/null 2>&1
REAL_PORT="$(run_port small)"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run"          # the runtime dir is a tmpfs wiped by a reboot
"${LLMCTL}" status >/dev/null 2>&1                # status reconciles enabled+active services
assert_eq "${REAL_PORT}" "$(run_port small)" "reconciled reservation carries the dynamic port from the env record, not the documented one"
"${LLMCTL}" disable small >/dev/null 2>&1
unset LLMCTL_PORT_STRATEGY

echo "== 11. dynamic requested without the registry binary is refused, never silently ignored =="
rc=0; out="$(env -u LLMCTL_PORT_STRATEGY LLMCTL_DECIDE_BIN="${TEST_TMP}/does-not-exist" LLMCTL_PORT_SMALL=auto "${LLMCTL}" start small 2>&1)" || rc=$?
assert_eq 1 "${rc}" "dynamic request with no usable binary exits non-zero"
assert_contains "${out}" "dynamic port assignment was requested" "message explains why"
"${LLMCTL}" stop all >/dev/null 2>&1 || true
rc=0; out="$(env -u LLMCTL_PORT_STRATEGY LLMCTL_PORTREG=0 "${LLMCTL}" start small 2>&1)" || rc=$?
assert_eq 0 "${rc}" "registry off + fixed strategy: the previous behaviour (documented port, no registry) is unchanged"
assert_eq "${P_SMALL}" "$(run_port small)" "inactive adapter uses the catalog port as before"
assert_eq "" "$(reg_ports)" "inactive adapter publishes nothing"
env -u LLMCTL_PORT_STRATEGY LLMCTL_PORTREG=0 "${LLMCTL}" stop all >/dev/null 2>&1 || true

test_finish
