#!/usr/bin/env bash
# test_doctor_profile_exclusivity.sh - RED-first. Defect: `llmctl doctor` reported PASS for "registry == live set" while
# (a) one profile had two enabled engine units and (b) a live engine process had no registry row. Contract: doctor
# prints a FAIL line naming the profile / the process when (a) or (b) holds. Fixture only: fake decide binary
# (registry diff -> ok, registry list -> no rows), temp unit dir with symlinks, a fake `llama-server` process.
# Negative control: with neither condition present the doctor prints no such FAIL.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
command -v python3 >/dev/null || { echo "SKIP-SUITE: python3 missing"; exit 0; }
FAKEPID=""; trap '[[ -z "${FAKEPID}" ]] || kill "${FAKEPID}" 2>/dev/null || true; test_teardown_env' EXIT
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" LLMCTL_PORTREG=1
export HOME="${TEST_TMP}/home"; mkdir -p "${HOME}"
FD="${TEST_TMP}/fake-decide"
cat > "${FD}" <<'F'
#!/bin/sh
case "$1 $2" in
  "registry diff") echo "registry == live (fixture)"; exit 0;;
  "registry list") echo '{"services":[]}'; exit 0;;
esac
exit 0
F
chmod +x "${FD}"; export LLMCTL_DECIDE_BIN="${FD}"
# scope the stray-process scan to this test (a real llama-server/onnx_server of the host must not decide the result)
export LLMCTL_DOCTOR_PROC_ROOTS="${TEST_TMP}"
W="${LLMCTL_UNIT_DIR:?}/default.target.wants"; mkdir -p "${W}" "${LLMCTL_SERVICES_DIR}"
touch "${LLMCTL_UNIT_DIR}/llmctl-llama@.service" "${LLMCTL_UNIT_DIR}/llmctl-onnx@.service"
doc() { timeout 150 bash -c 'source "$1/lib/doctor.sh"; doctor_run' _ "${LLMCTL_ROOT}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true; }

echo "== negative control: one enabled unit, no stray process =="
ln -s ../llmctl-onnx@.service "${W}/llmctl-onnx@decide-nli.service"
out="$(doc)"
if grep -E '^FAIL' <<<"${out}" | grep -qE 'decide-nli|llama-server|no registry row|more than one|duplicate'; then printf '  FAIL: control: doctor raised the exclusivity FAIL on a clean fixture\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: control: no exclusivity FAIL on a clean fixture"; fi

echo "== (a) two enabled engine units for one profile =="
ln -s ../llmctl-llama@.service "${W}/llmctl-llama@decide-nli.service"
out="$(doc)"
if grep -E '^FAIL' <<<"${out}" | grep -q 'decide-nli'; then echo "  ok: doctor FAILs and names decide-nli (two enabled units)"
else printf '  FAIL: (a) doctor did not FAIL for two enabled units of decide-nli. registry line: %s\n' "$(grep -m1 -i 'registry' <<<"${out}")" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
rm -f "${W}/llmctl-llama@decide-nli.service"

echo "== (b) a live engine process with no registry row =="
cat > "${TEST_TMP}/llama-server" <<'P'
#!/usr/bin/env python3
import socket, sys, time
port = int(sys.argv[sys.argv.index("--port") + 1])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(5)   # serving: the scan only judges listening engines
time.sleep(120)
P
chmod +x "${TEST_TMP}/llama-server"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
LLMCTL_REGISTER_WAIT=0; export LLMCTL_REGISTER_WAIT   # the scan skips processes younger than the registration wait
"${TEST_TMP}/llama-server" --port "${PORT}" --alias llmctl-test-stray & FAKEPID=$!
sleep 0.5
out="$(doc)"
if grep -E '^FAIL' <<<"${out}" | grep -qE "llama-server|${PORT}|${FAKEPID}|no registry row"; then echo "  ok: doctor FAILs for the live engine (pid ${FAKEPID}, port ${PORT}) without a registry row"
else printf '  FAIL: (b) doctor did not FAIL for live engine pid %s port %s with no registry row. registry line: %s\n' "${FAKEPID}" "${PORT}" "$(grep -m1 -i 'registry' <<<"${out}")" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
test_finish
