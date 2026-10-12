#!/usr/bin/env bash
# test_stop_post_bounded.sh - RED-first (fix/bounded-restart-and-pressure-gates).
# Root cause (4): ExecStopPost `svc_hook.sh unregister` runs portreg_unregister (llmctl-decide) WITHOUT a bound, so under
# pressure it exceeded TimeoutStopSec=90; the ExecStartPost waiter (setsid ... _wait_register, up to 600 s) also stayed
# alive in the unit's cgroup. Contract: hk_unregister finishes within 5 s even when the portreg binary hangs, and the
# registration waiter for that instance is killed on stop. Only fake binaries / our own sleep pids are touched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
HOOK="${LLMCTL_ROOT}/lib/svc_hook.sh"
INST="llmctl-test-$$"
KILL=()
cleanup() { local p; for p in ${KILL[@]+"${KILL[@]}"}; do kill "${p}" 2>/dev/null || true; done
  pkill -f "svc_hook.sh _wait_register ${INST}" 2>/dev/null || true; test_teardown_env; }
trap cleanup EXIT
export LLMCTL_PORTREG=1
export LLMCTL_LOG_DIR="${TEST_TMP}/logs"; mkdir -p "${LLMCTL_LOG_DIR}"

echo "== unregister is bounded when the portreg binary hangs =="
HANG="${TEST_TMP}/hang-decide"; printf '#!/bin/sh\nsleep 30\n' > "${HANG}"; chmod +x "${HANG}"
t0=$(date +%s.%N); rc=0
LLMCTL_DECIDE_BIN="${HANG}" timeout 12 bash "${HOOK}" unregister "${INST}" >/dev/null 2>&1 || rc=$?
el="$(awk -v a="${t0}" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')"
if awk -v e="${el}" 'BEGIN{exit !(e<5)}'; then echo "  ok: unregister with a hanging binary returned in ${el}s (<5s)"
else printf '  FAIL: unregister with a hanging portreg binary took %ss (rc=%s; must finish within 5s; killed by the 12s harness timeout when unbounded)\n' "${el}" "${rc}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_eq "0" "${rc}" "unregister exits 0 even when the binary hangs (ExecStopPost must never fail the unit)"

echo "== negative control: a fast fake binary returns immediately (harness measures time correctly) =="
FAST="${TEST_TMP}/fast-decide"; printf '#!/bin/sh\nexit 0\n' > "${FAST}"; chmod +x "${FAST}"
t0=$(date +%s.%N); LLMCTL_DECIDE_BIN="${FAST}" timeout 12 bash "${HOOK}" unregister "${INST}" >/dev/null 2>&1 || true
el2="$(awk -v a="${t0}" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')"
if awk -v e="${el2}" 'BEGIN{exit !(e<3)}'; then echo "  ok: fast binary: ${el2}s"; else printf '  FAIL: fast fake binary took %ss\n' "${el2}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

echo "== the registration waiter is killed on stop =="
mkdir -p "${LLMCTL_SERVICES_DIR}"
printf 'LLMCTL_PORT=1\nLLMCTL_REG_PROTOCOL=http\nLLMCTL_REG_HEALTH=/health\nLLMCTL_REG_KIND=llm\nLLMCTL_REG_PROFILE=x\nLLMCTL_REG_TOKEN=t\nLLMCTL_REG_LOOPBACK=1\n' > "${LLMCTL_SERVICES_DIR}/${INST}.env"
sleep 120 & ENGINE=$!; KILL+=("${ENGINE}")
LLMCTL_DECIDE_BIN="${FAST}" LLMCTL_REGISTER_WAIT=300 MAINPID="${ENGINE}" bash "${HOOK}" register "${INST}" >/dev/null 2>&1 || true
sleep 1
alive() { pgrep -f "svc_hook.sh _wait_register ${INST}" >/dev/null 2>&1; }
if alive; then echo "  ok: precondition: the waiter for ${INST} is running"; else printf '  FAIL: precondition: no waiter was started for %s\n' "${INST}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
LLMCTL_DECIDE_BIN="${FAST}" timeout 12 bash "${HOOK}" unregister "${INST}" >/dev/null 2>&1 || true
gone=0; for _ in 1 2 3 4; do alive || { gone=1; break; }; sleep 1; done
if [[ "${gone}" == 1 ]]; then echo "  ok: waiter gone within 4s of unregister"; else printf '  FAIL: the _wait_register waiter for %s is still alive after unregister (stays in the unit cgroup for up to 600s)\n' "${INST}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
test_finish
