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
# LIVE = a process that looks like one of our engines (a script named llama-server); RECYCLED = an unrelated live pid
printf '#!/bin/sh\nsleep 120\n' > "${TEST_TMP}/llama-server"; chmod +x "${TEST_TMP}/llama-server"
"${TEST_TMP}/llama-server" --port 1 & LIVE=$!
sleep 120 & RECYCLED=$!
trap '[[ -z "${LIVE}" ]] || kill "${LIVE}" 2>/dev/null || true; kill "${RECYCLED}" 2>/dev/null || true; test_teardown_env' EXIT
sleep 0.3
sleep 0.1 & DEAD=$!; wait "${DEAD}" 2>/dev/null || true       # a pid that has exited
CALLS="${TEST_TMP}/calls"
mkfake() { # mkfake <row-pid> [cmd_token]
  cat > "${TEST_TMP}/fake-decide" <<F
#!/bin/sh
echo "\$*" >> "${CALLS}"
if [ "\$1 \$2" = "registry list" ]; then printf '{"services":[{"name":"decide-nli","pid":$1,"port":8096,"cmd_token":"${2:-llama-server}"}]}\n'; fi
exit 0
F
  chmod +x "${TEST_TMP}/fake-decide"; : > "${CALLS}"
}
unreg_calls() { grep -c '^registry unregister decide-nli' "${CALLS}" || true; }
run_unreg() { MAINPID="$1" LLMCTL_DECIDE_BIN="${TEST_TMP}/fake-decide" timeout 20 bash "${HOOK}" unregister decide-nli >/dev/null 2>&1 || true; }

mkfake "${LIVE}"; run_unreg "${DEAD}"
assert_eq "0" "$(unreg_calls)" "row pid ${LIVE} is ALIVE and != stopping pid ${DEAD}: the row is kept (no 'registry unregister')"
mkfake "${RECYCLED}"; run_unreg "${DEAD}"
assert_eq "1" "$(unreg_calls)" "LOW-2: row pid ${RECYCLED} is alive but NOT an engine (recycled pid): the row IS dropped"
mkfake "${DEAD}"; run_unreg "${DEAD}"
assert_eq "1" "$(unreg_calls)" "control: row pid == stopping pid: the row IS dropped"
mkfake "${DEAD}"; run_unreg "$(( DEAD + 100000 ))"
assert_eq "1" "$(unreg_calls)" "control: row pid is dead (stale row): the row IS dropped"
# --- LOW-2 (re-review): wrapper forms and custom engine names must not look like a recycled pid
printf '#!/bin/sh\nsleep 120\n' > "${TEST_TMP}/my-engine-bin"; chmod +x "${TEST_TMP}/my-engine-bin"
W1=""; W2=""; W3=""; W4=""
nice -n 19 "${TEST_TMP}/llama-server" --port 2 & W1=$!                 # nice -n 19 llama-server
"${TEST_TMP}/my-engine-bin" --port 3 & W2=$!                           # custom LLMCTL_LLAMA_SERVER name (registry cmd_token)
taskset -c 0 "${TEST_TMP}/llama-server" --port 4 & W3=$!               # taskset wrapper
printf '#!/bin/sh\nsleep 120\n' > "${TEST_TMP}/onnx_server.py"; chmod +x "${TEST_TMP}/onnx_server.py"
env FOO=1 "${TEST_TMP}/onnx_server.py" --port 5 & W4=$!                # env wrapper + onnx_server.py
sleep 0.4
trap 'kill "${LIVE}" "${RECYCLED}" "${W1}" "${W2}" "${W3}" "${W4}" 2>/dev/null || true; test_teardown_env' EXIT
mkfake "${W1}"; run_unreg "${DEAD}"; assert_eq "0" "$(unreg_calls)" "LOW-2: 'nice -n 19 llama-server' (pid ${W1}) keeps its row"
mkfake "${W2}" my-engine-bin; run_unreg "${DEAD}"; assert_eq "0" "$(unreg_calls)" "LOW-2: custom-named engine matched by the row's cmd_token keeps its row"
mkfake "${W3}"; run_unreg "${DEAD}"; assert_eq "0" "$(unreg_calls)" "LOW-2: 'taskset ... llama-server' keeps its row"
mkfake "${W4}" onnx_server.py; run_unreg "${DEAD}"; assert_eq "0" "$(unreg_calls)" "LOW-2: 'env FOO=1 onnx_server.py' keeps its row"
mkfake "${RECYCLED}" my-engine-bin; run_unreg "${DEAD}"; assert_eq "1" "$(unreg_calls)" "control: an unrelated live pid is still dropped even with a custom cmd_token"
test_finish
