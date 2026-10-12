#!/usr/bin/env bash
# test_portguard_condition.sh - RED-first (review MEDIUM-3). systemd tests RestartPreventExitStatus only against the MAIN
# process, so a failing ExecStartPre (exit 98) IS retried (proved below with a transient unit: NRestarts>0). The
# "port already in use" refusal therefore must not be an ExecStartPre failure: it is an ExecCondition= (exit 1-254 skips the
# unit cleanly - not failed, not restarted). Contract: `svc_hook.sh portcheck <inst>` exits 98 when the profile's port is
# listening (0 otherwise, key untouched) and every engine unit has ExecCondition=... portcheck %i ahead of the gate.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
HOOK="${LLMCTL_ROOT}/lib/svc_hook.sh"; INST="llmctl-test-$$"
LP=""
cleanup() { # only units carrying THIS run's unique prefix (the transient helper runs in a subshell, so no array bookkeeping)
  systemctl --user stop "${INST}-*" >/dev/null 2>&1 || true; systemctl --user reset-failed "${INST}-*" >/dev/null 2>&1 || true
  [[ -z "${LP}" ]] || kill "${LP}" 2>/dev/null || true; test_teardown_env; }
trap cleanup EXIT
export LLMCTL_LOG_DIR="${TEST_TMP}/logs"; mkdir -p "${LLMCTL_LOG_DIR}" "${LLMCTL_SERVICES_DIR}" "${LLMCTL_STATE_DIR}/keys"
KEY="${LLMCTL_STATE_DIR}/keys/${INST}.key"; printf 'oldkey\n' > "${KEY}"
mkenv() { printf 'LLMCTL_PROFILE=%s\nLLMCTL_ENGINE=llama\nLLMCTL_PORT=%s\nLLMCTL_KEY_FILE=%s\n' "${INST}" "$1" "${KEY}" > "${LLMCTL_SERVICES_DIR}/${INST}.env"; }

echo "== hook: portcheck =="
FREE="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"; mkenv "${FREE}"
rc=0; timeout 10 bash "${HOOK}" portcheck "${INST}" >/dev/null 2>&1 || rc=$?; assert_eq "0" "${rc}" "free port: portcheck exits 0"
python3 -c 'import socket,time
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("127.0.0.1",0));s.listen(5)
print(s.getsockname()[1],flush=True);time.sleep(60)' > "${TEST_TMP}/port" & LP=$!
for _ in $(seq 1 20); do [[ -s "${TEST_TMP}/port" ]] && break; sleep 0.1; done
mkenv "$(head -1 "${TEST_TMP}/port")"; before="$(stat -c %Y.%y "${KEY}")"
rc=0; timeout 10 bash "${HOOK}" portcheck "${INST}" >/dev/null 2>&1 || rc=$?; assert_eq "98" "${rc}" "busy port: portcheck exits 98"
assert_eq "${before}" "$(stat -c %Y.%y "${KEY}")" "portcheck never touches the key file"

echo "== generated units carry the ExecCondition =="
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
( svc_install ) >/dev/null 2>&1
for eng in llama colibri onnx; do
  U="${LLMCTL_UNIT_DIR}/llmctl-${eng}@.service"
  c="$(grep -nE '^ExecCondition=.*portcheck.*svc_hook\.sh' "${U}" | head -1 | cut -d: -f1 || true)"
  g="$(grep -nE '^ExecStartPre=.*svc_hook\.sh.* gate' "${U}" | head -1 | cut -d: -f1 || true)"
  if [[ -n "${c}" && -n "${g}" ]]; then echo "  ok: ${eng}: ExecCondition portcheck present (line ${c}); gate at ${g}"
  else printf '  FAIL: %s: no ExecCondition=... portcheck line (cond=%s gate=%s)\n' "${eng}" "${c:-none}" "${g:-none}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
done

echo "== a crashing hook must not be a silent skip (ExecCondition exit 1-254 = skipped; only 255 or a signal fails the unit) =="
cond_line="$(sed -n 's/^ExecCondition=//p' "${LLMCTL_UNIT_DIR}/llmctl-llama@.service" | head -1)"
if ! systemctl --user show-environment >/dev/null 2>&1 || ! command -v systemd-run >/dev/null 2>&1; then
  assert_skip "no reachable systemd --user manager" "broken-hook ExecCondition semantics"
else
  hookpath="${LLMCTL_ROOT}/lib/svc_hook.sh"
  run_cond() { # <label> <hook path to substitute> -> "ActiveState|Result" after 2 s (real hook env: services dir with a free port)
    local u="${INST}-$1" line="${cond_line//%i/${INST}}"
    line="${line//${hookpath}/$2}"; line="${line//%%/%}"
    systemd-run --user --quiet --on-active=60s --unit="${u}-reaper" systemctl --user stop "${u}.service" >/dev/null 2>&1 || true
    systemd-run --user --quiet --unit="${u}" -p "ExecCondition=${line}" -p "Environment=LLMCTL_SERVICES_DIR=${LLMCTL_SERVICES_DIR}" -p "Environment=LLMCTL_STATE_DIR=${LLMCTL_STATE_DIR}" -p "Environment=LLMCTL_LOG_DIR=${LLMCTL_LOG_DIR}" /bin/sleep 3 >/dev/null 2>&1 || true
    sleep 2
    printf '%s|%s' "$(systemctl --user show -p ActiveState --value "${u}.service")" "$(systemctl --user show -p Result --value "${u}.service")"
    systemctl --user stop "${u}.service" >/dev/null 2>&1 || true; systemctl --user reset-failed "${u}.service" >/dev/null 2>&1 || true
  }
  mkenv "${FREE}"
  r="$(run_cond ok "${hookpath}")"
  [[ "${r%%|*}" == active || "${r%%|*}" == activating ]] && echo "  ok: real hook, free port: the unit starts (${r})" || { printf '  FAIL: real hook, free port: unit did not start (%s)\n' "${r}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
  mkenv "$(head -1 "${TEST_TMP}/port")"
  r="$(run_cond busy "${hookpath}")"
  [[ "${r%%|*}" == inactive ]] && echo "  ok: real hook, busy port: skipped (${r})" || { printf '  FAIL: real hook, busy port: expected a clean skip, got %s\n' "${r}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
  printf '#!/bin/bash\nexit 1\n' > "${TEST_TMP}/broken-hook.sh"
  r="$(run_cond broken "${TEST_TMP}/broken-hook.sh")"
  [[ "${r%%|*}" == failed ]] && echo "  ok: a hook that crashes with exit 1 FAILS the unit, it is not a silent skip (${r})" || { printf '  FAIL: a crashing hook (exit 1) was treated as a skip: %s\n' "${r}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
  r="$(run_cond missing "${TEST_TMP}/no-such-hook.sh")"
  [[ "${r%%|*}" == failed ]] && echo "  ok: a missing hook FAILS the unit (${r})" || { printf '  FAIL: a missing hook (exit 127) was treated as a skip: %s\n' "${r}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
fi

echo "== systemd semantics (real transient units) =="
if ! systemctl --user show-environment >/dev/null 2>&1 || ! command -v systemd-run >/dev/null 2>&1; then
  assert_skip "no reachable systemd --user manager" "ExecStartPre-vs-ExecCondition retry semantics"
else
  run() { # <label> <prop-key=value> ; prints NRestarts|ActiveState|Result after 6 s
    local u="${INST}-$1"
    systemd-run --user --quiet --on-active=120s --unit="${u}-reaper" systemctl --user stop "${u}.service" >/dev/null 2>&1 || true   # reaper: no loop outlives the test
    systemd-run --user --quiet --unit="${u}" -p Restart=on-failure -p RestartSec=1 -p StartLimitBurst=3 -p StartLimitIntervalSec=30 \
      -p RestartPreventExitStatus=98 -p "$2" /bin/sleep 5 >/dev/null 2>&1 || true
    sleep 6
    printf '%s|%s|%s' "$(systemctl --user show -p NRestarts --value "${u}.service")" "$(systemctl --user show -p ActiveState --value "${u}.service")" "$(systemctl --user show -p Result --value "${u}.service")"
    systemctl --user stop "${u}.service" >/dev/null 2>&1 || true; systemctl --user reset-failed "${u}.service" >/dev/null 2>&1 || true
  }
  r="$(run pre "ExecStartPre=/bin/sh -c 'exit 98'")"
  if [[ "${r%%|*}" =~ ^[0-9]+$ && "${r%%|*}" -gt 0 ]]; then echo "  ok: control: a failing ExecStartPre (exit 98) IS retried by systemd (${r}) - RestartPreventExitStatus does not cover it"
  else printf '  FAIL: control: expected the ExecStartPre failure to be retried, got %s\n' "${r}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  r="$(run cond "ExecCondition=/bin/sh -c 'exit 98'")"
  if [[ "${r%%|*}" == 0 && "${r#*|}" != failed* ]]; then echo "  ok: ExecCondition exit 98 skips the unit without a restart or a failure (${r})"
  else printf '  FAIL: ExecCondition exit 98 was retried or failed: %s\n' "${r}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
fi
test_finish
