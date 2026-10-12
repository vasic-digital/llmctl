#!/usr/bin/env bash
# test_unregister_pid_guard.sh - RED-first. Defect: two units (llmctl-llama@decide-nli, llmctl-onnx@decide-nli) ran one
# profile; the loser's ExecStopPost `svc_hook.sh unregister` -> portreg_unregister (lib/portreg.sh:144-146) dropped the
# registry row BY NAME, so the LIVE winner had no row. Contract: unregister must NOT drop a row whose pid is alive and
# differs from the stopping unit's pid ($MAINPID, the dead main pid systemd exposes to ExecStopPost). Fake decide
# binary; only our own sleep pids are touched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
HOOK="${LLMCTL_ROOT}/lib/svc_hook.sh"
LIVE=""; trap '[[ -z "${LIVE}" ]] || kill "${LIVE}" 2>/dev/null || true; test_teardown_env' EXIT
export LLMCTL_PORTREG=1 LLMCTL_LOG_DIR="${TEST_TMP}/logs"; mkdir -p "${LLMCTL_LOG_DIR}"
sleep 120 & LIVE=$!
sleep 0.1 & DEAD=$!; wait "${DEAD}" 2>/dev/null || true       # a pid that has exited
CALLS="${TEST_TMP}/calls"
mkfake() { # mkfake <row-pid>
  cat > "${TEST_TMP}/fake-decide" <<F
#!/bin/sh
echo "\$*" >> "${CALLS}"
if [ "\$1 \$2" = "registry list" ]; then printf '{"services":[{"name":"decide-nli","pid":$1,"port":8096}]}\n'; fi
exit 0
F
  chmod +x "${TEST_TMP}/fake-decide"; : > "${CALLS}"
}
unreg_calls() { grep -c '^registry unregister decide-nli' "${CALLS}" || true; }
run_unreg() { MAINPID="$1" LLMCTL_DECIDE_BIN="${TEST_TMP}/fake-decide" timeout 20 bash "${HOOK}" unregister decide-nli >/dev/null 2>&1 || true; }

mkfake "${LIVE}"; run_unreg "${DEAD}"
assert_eq "0" "$(unreg_calls)" "row pid ${LIVE} is ALIVE and != stopping pid ${DEAD}: the row is kept (no 'registry unregister')"
mkfake "${DEAD}"; run_unreg "${DEAD}"
assert_eq "1" "$(unreg_calls)" "control: row pid == stopping pid: the row IS dropped"
mkfake "${DEAD}"; run_unreg "$(( DEAD + 100000 ))"
assert_eq "1" "$(unreg_calls)" "control: row pid is dead (stale row): the row IS dropped"
test_finish
