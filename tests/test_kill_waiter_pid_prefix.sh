#!/usr/bin/env bash
# test_kill_waiter_pid_prefix.sh - RED-first: _hk_kill_waiter's cmdline match must delimit the pid. A stopping unit with MAINPID 123
# must NOT kill (or untrack) the waiter of the same instance's unit with MAINPID 1234 (123 is a textual prefix of 1234).
# The "waiter" is a REAL process whose /proc cmdline is `... _wait_register <inst> <pid>` (bash -c args), no mocks.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
W=""
cleanup() { if [[ -n "${W}" ]]; then pkill -P "${W}" 2>/dev/null || true; kill "${W}" 2>/dev/null || true; fi; test_teardown_env; }
trap cleanup EXIT
export LLMCTL_RUNTIME_DIR="${TEST_TMP}/run"; mkdir -p "${LLMCTL_RUNTIME_DIR}"
# shellcheck disable=SC1091
source "${LLMCTL_ROOT}/lib/svc_hook.sh"
# a killed-but-unreaped child is a zombie (state Z): not alive
alive() { local st; st="$(awk '/^State:/{print $2}' "/proc/$1/status" 2>/dev/null || true)"; if [[ -n "${st}" && "${st}" != Z ]]; then echo 1; else echo 0; fi; }
bash -c "sleep 300; :" _wait_register inst 1234 >/dev/null 2>&1 & W=$!
sleep 0.3
_hk_track_waiter inst "${W}"
echo "== stopping unit pid 123 must not kill the waiter of pid 1234"
_hk_kill_waiter inst 123
assert_eq 1 "$(alive "${W}")" "waiter of pid 1234 survives a stop of pid 123"
assert_eq 1 "$([[ -f "$(_hk_waiter_file inst)" ]] && echo 1 || echo 0)" "waiter of pid 1234 stays tracked"
echo "== the exact pid does kill it"
_hk_kill_waiter inst 1234
sleep 0.3
assert_eq 0 "$(alive "${W}")" "waiter of pid 1234 is killed by a stop of pid 1234"
test_finish
