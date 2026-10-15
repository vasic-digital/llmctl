#!/usr/bin/env bash
# test_enforcement_marker.sh - review 2026-10-15 finding 1: installed units run lib/svc_hook.sh straight from the working
# tree, so the unit-level validation gates (ExecCondition `validated`, the launchd run-engine gate, the waiter that
# validates BEFORE it registers and stops the unit on any non-PASS) must reach ONLY units installed by an llmctl that
# has them. They are switched on by a versioned marker that `llmctl install` (svc_install) writes into the state dir.
#   * marker ABSENT  -> exactly the c23c2e6 behaviour: the waiter registers first; only a kind=llm profile is then
#                       validated, FAIL stops it, UNDETERMINED keeps it running (not validated); kind=decide is
#                       registered and never validated; `validated` and run-engine pass everything through;
#   * marker PRESENT -> the gates of the 2026-10-14 round (decide kinds validated before registration, UNDETERMINED
#                       stopped, ExecCondition exit 77, run-engine exit 77).
# Plus a fixture of a unit installed BEFORE the change (tests/fixtures/units/llmctl-onnx@.service.c23c2e6, written by
# c23c2e6's svc_install): its hook commands, run in unit order against the CURRENT tree, keep registering decide-nli
# without validating it. Harness: tests/gate_wiring_lib.sh (recording validate_profile, fake systemctl, a fake
# llmctl-decide that records registry calls, a real HTTP fixture as the engine's health endpoint, `sleep` as its pid).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
cleanup() {
  local p
  for p in $(pgrep -f "${TEST_TMP}/tree/lib/svc_hook.sh" 2>/dev/null || true); do kill "${p}" 2>/dev/null || true; done
  gw_cleanup_bg
  test_teardown_env
}
trap cleanup EXIT
gw_init
# mutation hook (tests/test_validation_mutants.sh group "marker"): MARK_MUT_FILE/OLD/NEW re-introduce ONE defect into
# this run's throw-away tree (never the repository)
if [[ -n "${MARK_MUT_FILE:-}" ]]; then
  _mf="${GW_TREE}/lib/${MARK_MUT_FILE}"; rm -f -- "${_mf:?}"; cp "${LLMCTL_ROOT}/lib/${MARK_MUT_FILE}" "${_mf}"
  python3 -I - "${_mf}" "${MARK_MUT_OLD}" "${MARK_MUT_NEW}" <<'PY2'
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1: sys.exit("mutation anchor found %d times" % s.count(old))
open(f, "w").write(s.replace(old, new))
PY2
  echo "MUTANT applied to ${MARK_MUT_FILE}"
fi
unset LLMCTL_SERVICE_BACKEND_FILE
export LLMCTL_ROOT="${GW_TREE}"
export LLMCTL_REGISTER_WAIT=15 LLMCTL_REGISTER_POLL=1 LLMCTL_REGISTER_IDENTITY_WAIT=1 LLMCTL_VALIDATE_SETTLE=0
HK="${GW_TREE}/lib/svc_hook.sh"
MARKER="${LLMCTL_STATE_DIR}/unit-enforcement"

FAKEBIN="${TEST_TMP}/fakebin"; mkdir -p "${FAKEBIN}"
cat > "${FAKEBIN}/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${GW_CALLS:?}"
case " $* " in *" is-failed "*) exit 1 ;; *) exit 0 ;; esac
FAKE
# a registry binary that only RECORDS (so a real registration is observable without the Go build)
cat > "${FAKEBIN}/llmctl-decide" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "registry list") printf '[]\n' ;;
  "registry register") printf 'registry_register %s\n' "$3" >> "${GW_CALLS:?}" ;;
esac
exit 0
FAKE
chmod +x "${FAKEBIN}/systemctl" "${FAKEBIN}/llmctl-decide"
export PATH="${FAKEBIN}:${PATH}" LLMCTL_PORTREG=1 LLMCTL_DECIDE_BIN="${FAKEBIN}/llmctl-decide"

b2i() { if "$@"; then echo 1; else echo 0; fi; }
ENGINE_PID=""
new_engine_pid() { sleep 300 >/dev/null 2>&1 & ENGINE_PID=$!; GW_BG_PIDS+=("${ENGINE_PID}"); }
write_env() { # write_env <instance> <engine> <kind> <port>
  mkdir -p "${LLMCTL_SERVICES_DIR}"
  { printf 'LLMCTL_PROFILE=%s\nLLMCTL_ENGINE=%s\nLLMCTL_PORT=%s\nLLMCTL_REG_TOKEN=tok\nLLMCTL_REG_PROTOCOL=http\n' "$1" "$2" "$4"
    printf 'LLMCTL_REG_HEALTH=/health\nLLMCTL_REG_KIND=%s\nLLMCTL_REG_PROFILE=%s\nLLMCTL_REG_LOOPBACK=1\n' "$3" "$1"; } > "${LLMCTL_SERVICES_DIR}/$1.env"
}
reset_world() {
  gw_calls_reset
  rm -rf "${LLMCTL_STATE_DIR:?}/validation"
  mkdir -p "${LLMCTL_LOG_DIR}"; : > "${LLMCTL_LOG_DIR}/svc_hook.log"
  unset GW_VALIDATE_RC
  export LLMCTL_VALIDATE_ON_START=1
  new_engine_pid
}
run_waiter() { local rc=0; env "${@:2}" timeout 60 bash "${HK}" _wait_register "$1" "${ENGINE_PID}" >"${TEST_TMP}/last.out" 2>&1 || rc=$?; echo "${rc}"; }
line_of() { { grep -nE "$1" "${GW_CALLS}" || true; } | head -1 | cut -d: -f1; }

READY_REQ="${TEST_TMP}/ready.req"
GW_HTTP_FIXED_PORT=0 gw_http_server "${READY_REQ}"
P="${GW_HTTP_PORT}"
write_env decide-nli onnx decide "${P}"
write_env small llama llm "${P}"

echo "== llmctl install writes the versioned marker (0600)"
rm -f -- "${MARKER:?}"     # helpers.sh models an installed llmctl; this test starts from a pre-gate install
assert_file_absent "${MARKER}" "fresh state dir: no marker"
( export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/os_detect.sh"
  source "${LLMCTL_ROOT}/lib/hardware.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_install ) > "${TEST_TMP}/install.out" 2>&1
assert_file_contains "${MARKER}" "validation-gate=1" "svc_install (llmctl install) wrote validation-gate=1"
assert_eq 600 "$(stat -c '%a' "${MARKER}" 2>/dev/null || echo missing)" "the marker is owner-only"
assert_file_contains "${LLMCTL_UNIT_DIR}/llmctl-onnx@.service" "svc_hook.sh\" validated %i" "the regenerated unit carries ExecCondition validated"
assert_eq 0 "$(b2i grep -q 'command not found' "${TEST_TMP}/install.out")" "install executes nothing from the unit comment (no backtick command substitution)"
( export LLMCTL_DRY_RUN=1; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_macos.sh"; rm -f -- "${MARKER:?}"; svc_install ) >/dev/null 2>&1
assert_file_contains "${MARKER}" "validation-gate=1" "the launchd backend's svc_install writes it too"
rm -f -- "${MARKER:?}"

echo "== marker ABSENT (unit installed before the gate): decide kind is registered, NEVER validated, NEVER stopped"
reset_world
rc="$(run_waiter decide-nli GW_VALIDATE_RC=1)"
assert_eq 0 "${rc}" "legacy decide waiter: exits 0"
assert_eq 1 "$(gw_count '^registry_register decide-nli$')" "legacy decide waiter: registered"
assert_eq 0 "$(gw_count '^validate_profile ')" "legacy decide waiter: not validated (c23c2e6: kind decide is not its business)"
assert_eq 0 "$(gw_count '^systemctl --user stop')" "legacy decide waiter: nothing stopped"

echo "== marker ABSENT: kind llm keeps the c23c2e6 order and verdict policy"
reset_world
rc="$(run_waiter small GW_VALIDATE_RC=2)"
assert_eq 1 "$(gw_count '^registry_register small$')" "legacy llm UNDETERMINED: registered"
assert_eq 1 "$(gw_count '^validate_profile small ')" "legacy llm UNDETERMINED: validated once"
s_reg="$(line_of '^registry_register small$')"; s_val="$(line_of '^validate_profile small ')"
assert_eq 1 "$(( ${s_reg:-0} > 0 && ${s_val:-0} > ${s_reg:-0} ? 1 : 0 ))" "legacy llm: registration BEFORE validation (c23c2e6 order; reg ${s_reg}, val ${s_val})"
assert_eq 0 "$(gw_count '^systemctl --user stop')" "legacy llm UNDETERMINED: keeps running (c23c2e6: only LLMCTL_VALIDATE_STRICT=1 stopped it)"
reset_world
rc="$(run_waiter small GW_VALIDATE_RC=1)"
assert_eq 1 "$(gw_count '^systemctl --user stop llmctl-llama@small.service$')" "legacy llm FAIL: stopped (as at c23c2e6)"
reset_world
rc="$(run_waiter small GW_VALIDATE_RC=1 LLMCTL_VALIDATE_ON_START=0)"
assert_eq 0 "$(gw_count '^validate_profile ')" "legacy llm ON_START=0: not validated (c23c2e6)"
assert_eq 1 "$(gw_count '^registry_register small$')" "legacy llm ON_START=0: registered (c23c2e6)"

echo "== marker ABSENT: ExecCondition validated and the launchd run-engine wrapper pass through"
reset_world
rc=0; bash "${HK}" validated small >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "legacy: 'validated' passes a profile without a record"
write_env small llama llm "$(gw_free_port)"     # run-engine's prestart refuses a port in use (98): give it a free one
rc=0; out="$(bash "${HK}" run-engine small -- bash -c 'echo engine-ran' 2>/dev/null)" || rc=$?
assert_eq "0 engine-ran" "${rc} ${out}" "legacy: run-engine execs the engine"
write_env small llama llm "${P}"

echo "== marker PRESENT: the 2026-10-14 gates apply"
( source "${LLMCTL_ROOT}/lib/common.sh"; enforcement_mark_installed )
assert_file_contains "${MARKER}" "validation-gate=1" "marker written"
reset_world
rc="$(run_waiter decide-nli GW_VALIDATE_RC=1)"
assert_eq 1 "$(gw_count '^validate_profile decide-nli ')" "enforced decide waiter: validated once"
assert_eq 0 "$(gw_count '^registry_register decide-nli$')" "enforced decide waiter FAIL: never registered"
assert_eq 1 "$(gw_count '^systemctl --user stop llmctl-onnx@decide-nli.service$')" "enforced decide waiter FAIL: stopped"
reset_world
rc="$(run_waiter small GW_VALIDATE_RC=2)"
assert_eq 1 "$(gw_count '^systemctl --user stop llmctl-llama@small.service$')" "enforced llm UNDETERMINED: stopped (strict)"
assert_eq 0 "$(gw_count '^registry_register small$')" "enforced llm UNDETERMINED: never registered"
rc=0; bash "${HK}" validated small >/dev/null 2>&1 || rc=$?
assert_eq 77 "${rc}" "enforced: 'validated' refuses a profile without a record (exit 77)"
write_env small llama llm "$(gw_free_port)"
rc=0; out="$(bash "${HK}" run-engine small -- bash -c 'echo engine-ran' 2>/dev/null)" || rc=$?
# exit 0 (not 77) since review 2026-10-15 finding 11: the agent's KeepAlive restarts only an unsuccessful exit
assert_eq "0 " "${rc} ${out}" "enforced: run-engine refuses before exec (the engine never ran; exit 0: not respawned)"
write_env small llama llm "${P}"
printf 'validation-gate=banana\n' > "${MARKER}"
rc=0; bash "${HK}" validated small >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "an unknown marker format is NOT treated as installed (legacy)"
rm -f -- "${MARKER:?}"

echo "== fixture: a unit installed BEFORE the change (c23c2e6 body), its hooks run in unit order against THIS tree"
FIX="${LLMCTL_ROOT}/tests/fixtures/units/llmctl-onnx@.service.c23c2e6"
assert_file_exists "${FIX}" "fixture present"
assert_eq 0 "$(b2i grep -q 'svc_hook.sh" validated' "${FIX}")" "fixture: the pre-change unit has no ExecCondition validated"
reset_world
UPORT="$(gw_free_port)"
write_env decide-nli onnx decide "${UPORT}"
hooks="$(sed -n -e 's#@ROOT@#'"${GW_TREE}"'#g' -e 's/^Exec\(Condition\|StartPre\|StartPost\)=-\{0,1\}//p' "${FIX}" | grep 'svc_hook.sh')"
assert_eq 4 "$(printf '%s\n' "${hooks}" | grep -c .)" "fixture: four start-side hook commands (portcheck, gate, prestart, register)"
GW_HTTP_FIXED_PORT="${UPORT}" GW_HTTP_DELAY=2 GW_HTTP_NOWAIT=1 gw_http_server "${TEST_TMP}/u.req"   # the engine comes up
allrc=""
while IFS= read -r cmd; do
  cmd="${cmd//\$\$/\$}"; cmd="${cmd//%i/decide-nli}"
  r=0; MAINPID="${ENGINE_PID}" eval "${cmd}" >/dev/null 2>&1 || r=$?; allrc+="${r} "
done <<< "${hooks}"
assert_eq "0 0 0 0 " "${allrc}" "fixture: every start-side hook of the old unit succeeds (none refuses)"
for _ in $(seq 1 30); do [[ "$(gw_count '^registry_register decide-nli$')" -ge 1 ]] && break; sleep 0.5; done
assert_eq 1 "$(gw_count '^registry_register decide-nli$')" "fixture: the old unit's detached waiter REGISTERS decide-nli"
sleep 1
assert_eq 0 "$(gw_count '^validate_profile ')" "fixture: decide-nli is NOT validated by the old unit's hooks"
assert_eq 0 "$(gw_count '^systemctl --user stop')" "fixture: decide-nli is NOT stopped"

test_finish
