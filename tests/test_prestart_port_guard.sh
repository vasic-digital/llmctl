#!/usr/bin/env bash
# test_prestart_port_guard.sh - RED-first. Defect: a second unit for the SAME profile loads 3-4 GB, then dies with
# EADDRINUSE and loops until StartLimit; its prestart also rotates the SHARED key file under the live server
# (lib/svc_hook.sh hk_prestart ~125). Contract: when LLMCTL_PORT already listens, `svc_hook.sh prestart` exits fast
# (<1.5 s) with a DISTINCT 'port in use' code (not 0/1/2/75), does NOT rotate the key file (mtime unchanged, twice),
# and the generated units carry RestartPreventExitStatus listing that code. Control: port free -> exit 0 and key rotated.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
HOOK="${LLMCTL_ROOT}/lib/svc_hook.sh"; INST="llmctl-test-$$"
LP=""; trap '[[ -z "${LP}" ]] || kill "${LP}" 2>/dev/null || true; test_teardown_env' EXIT
export LLMCTL_LOG_DIR="${TEST_TMP}/logs"; mkdir -p "${LLMCTL_LOG_DIR}" "${LLMCTL_SERVICES_DIR}" "${LLMCTL_STATE_DIR}/keys"
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
KEY="${LLMCTL_STATE_DIR}/keys/${INST}.key"; printf 'oldkey\n' > "${KEY}"; chmod 600 "${KEY}"
mkenv() { printf 'LLMCTL_PROFILE=%s\nLLMCTL_ENGINE=onnx\nLLMCTL_PORT=%s\nLLMCTL_KEY_FILE=%s\n' "${INST}" "$1" "${KEY}" > "${LLMCTL_SERVICES_DIR}/${INST}.env"; }
mt() { stat -c %Y.%y "${KEY}"; }

echo "== control: port free -> prestart succeeds and rotates the key =="
FREE="$(free_port)"; mkenv "${FREE}"; before="$(mt)"; sleep 1.1
rc=0; bash "${HOOK}" prestart "${INST}" >/dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "free port: prestart exit 0"
[[ "$(mt)" != "${before}" ]] && echo "  ok: free port: key rotated" || { printf '  FAIL: free port: key was not rotated\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }

echo "== port already listening =="
python3 -c 'import socket,sys,time
s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("127.0.0.1",0));s.listen(5)
print(s.getsockname()[1],flush=True);time.sleep(120)' > "${TEST_TMP}/port" & LP=$!
for _ in $(seq 1 20); do [[ -s "${TEST_TMP}/port" ]] && break; sleep 0.1; done
BUSY="$(head -1 "${TEST_TMP}/port")"; mkenv "${BUSY}"
before="$(mt)"; sleep 1.1
t0=$(date +%s.%N); rc=0; timeout 10 bash "${HOOK}" prestart "${INST}" >/dev/null 2>&1 || rc=$?
el="$(awk -v a="${t0}" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}')"
if [[ "${rc}" =~ ^[0-9]+$ && "${rc}" -ge 3 && "${rc}" -le 254 && "${rc}" != 75 ]]; then echo "  ok: busy port: distinct exit code ${rc}"
else printf '  FAIL: busy port (%s): prestart exit %s (need a distinct code: not 0/1/2/75)\n' "${BUSY}" "${rc}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
awk -v e="${el}" 'BEGIN{exit !(e<1.5)}' && echo "  ok: busy port: returned in ${el}s" || { printf '  FAIL: busy port: took %ss (>=1.5)\n' "${el}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
timeout 10 bash "${HOOK}" prestart "${INST}" >/dev/null 2>&1 || true
[[ "$(mt)" == "${before}" ]] && echo "  ok: busy port: key file mtime unchanged after two prestarts" \
  || { printf '  FAIL: busy port: key file was rotated under the live server (mtime changed)\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }

echo "== generated units prevent restart on that code =="
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
for l in common os_detect hardware service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
( svc_install ) >/dev/null 2>&1
for eng in llama colibri onnx; do
  p="$(sed -n 's/^RestartPreventExitStatus=//p' "${LLMCTL_UNIT_DIR}/llmctl-${eng}@.service" | tail -1)"
  if [[ "${rc}" -ge 3 && " ${p} " == *" ${rc} "* ]]; then echo "  ok: ${eng}: RestartPreventExitStatus lists ${rc}"
  else printf '  FAIL: %s: RestartPreventExitStatus=%s does not list the distinct port-in-use code (prestart rc=%s)\n' "${eng}" "${p:-unset}" "${rc}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
done
test_finish
