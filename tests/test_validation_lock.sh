#!/usr/bin/env bash
# test_validation_lock.sh - RED-first (wiring review #4). `llmctl enable|restart` validated the profile in the CLI hook AND the
# systemd waiter validated it again, concurrently: two probe loops hammering one model. A per-profile validation lock (flock on
# <runtime>/.validate-<profile>.lock - NOT the scheduler lock) serialises them: the second waits for the first and then re-checks
# freshness (a real validation leaves a fresh PASS record; the stub validator used here records none, so it simply runs second).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
cleanup() { local p; for p in $(pgrep -f "${TEST_TMP}/tree/" 2>/dev/null || true); do kill "${p}" 2>/dev/null || true; done; gw_cleanup_bg; test_teardown_env; }
trap cleanup EXIT
gw_init
L="${GW_LLMCTL}"
FAKEBIN="${TEST_TMP}/fakebin"; mkdir -p "${FAKEBIN}"
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >> "${GW_CALLS:?}"\nexit 0\n' > "${FAKEBIN}/systemctl"; chmod +x "${FAKEBIN}/systemctl"
export PATH="${FAKEBIN}:${PATH}"
GW_HTTP_FIXED_PORT=0 gw_http_server "${TEST_TMP}/ready.req"; PORT="${GW_HTTP_PORT}"
gw_mark_running small "${PORT}"
mkdir -p "${LLMCTL_SERVICES_DIR}" "${LLMCTL_LOG_DIR}"
{ printf 'LLMCTL_ENGINE=llama\nLLMCTL_PORT=%s\nLLMCTL_REG_TOKEN=tok\nLLMCTL_REG_PROTOCOL=http\n' "${PORT}"
  printf 'LLMCTL_REG_HEALTH=/health\nLLMCTL_REG_KIND=llm\nLLMCTL_REG_PROFILE=small\nLLMCTL_REG_LOOPBACK=1\n'; } > "${LLMCTL_SERVICES_DIR}/small.env"
sleep 300 >/dev/null 2>&1 & ENGINE_PID=$!; GW_BG_PIDS+=("${ENGINE_PID}")
export LLMCTL_ROOT="${GW_TREE}" LLMCTL_REGISTER_WAIT=15 LLMCTL_REGISTER_POLL=1 LLMCTL_REGISTER_IDENTITY_WAIT=1 LLMCTL_VALIDATE_ON_START=1
export GW_VALIDATE_SLEEP=3 GW_VALIDATE_RC=0

gw_calls_reset
( "${L}" validate-after-start small >"${TEST_TMP}/cli.out" 2>&1 || true ) &
P1=$!
sleep 1
( timeout 60 bash "${GW_TREE}/lib/svc_hook.sh" _wait_register small "${ENGINE_PID}" >"${TEST_TMP}/waiter.out" 2>&1 || true ) &
P2=$!
wait "${P1}" "${P2}"
n="$(gw_count '^validate_profile_begin small ')"
assert_eq 2 "${n}" "both entry points validated (the stub records no PASS, so the second still runs): ${n} begin lines"
e1="$(awk '$1=="validate_profile_end"{print $4}' "${GW_CALLS}" | sed -n 1p)"
b2="$(awk '$1=="validate_profile_begin"{print $3}' "${GW_CALLS}" | sed -n 2p)"
assert_eq 1 "$(python3 -I -c 'import sys; e1,b2=float(sys.argv[1] or 0),float(sys.argv[2] or 0); print(1 if e1>0 and b2>=e1 else 0)' "${e1:-0}" "${b2:-0}")" "the second validation began (${b2:-none}) only after the first ended (${e1:-none}): no concurrent probe loops"
test_finish
