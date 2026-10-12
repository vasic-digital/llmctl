#!/usr/bin/env bash
# test_start_not_active.sh - RED-first (review N2 + N5), against a FAKE `systemctl` (no real unit is touched).
#  N2: an ExecCondition skip makes `systemctl start` return 0 while the unit stays inactive; if a FOREIGN process listens on
#      the profile's port, the readiness poll used to succeed and a reservation + registry row was written for a dead unit.
#      Contract: after svc_start succeeds the unit must be active/activating, else "unit not active after start ...", the port
#      reservation is released, no .run record is written, rc 1.
#  N5: the scheduler flock is held across svc_start; a unit whose ExecStartPre gate waits up to 120 s blocked every other llmctl
#      call. Contract: svc_start is bounded (LLMCTL_START_WAIT, default 20 s; timeout => the unit is "still starting" and the
#      readiness poll decides), so `llmctl start` returns in bounded time and releases the lock.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
FAKEBIN="${TEST_TMP}/fakebin"; mkdir -p "${FAKEBIN}"
export FAKE_STATE="${TEST_TMP}/fake_state"; mkdir -p "${FAKE_STATE}"
cat > "${FAKEBIN}/systemctl" <<'F'
#!/usr/bin/env bash
[[ "${1:-}" == "--user" ]] || exit 1; shift
verb="${1:-}"; shift || true; unit=""; for a in "$@"; do unit="${a}"; done
case "${verb}" in
  is-active) s="$(cat "${FAKE_STATE}/${unit}" 2>/dev/null || echo inactive)"; echo "${s}"; [[ "${s}" == active ]]; exit $? ;;
  is-failed) exit 1 ;;
  start)
    case "${FAKE_START_MODE:-ok}" in
      skip) exit 0 ;;                                   # ExecCondition skip: rc 0, unit stays inactive
      slow) echo activating > "${FAKE_STATE}/${unit}"; sleep 60; echo active > "${FAKE_STATE}/${unit}"; exit 0 ;;   # gate waiting
      *)    echo active > "${FAKE_STATE}/${unit}"; exit 0 ;;
    esac ;;
  stop) rm -f "${FAKE_STATE}/${unit}"; exit 0 ;;
  *) exit 0 ;;
esac
F
chmod +x "${FAKEBIN}/systemctl"; export PATH="${FAKEBIN}:${PATH}"
mkdir -p "${LLMCTL_MODELS_DIR}/fast"; : > "${LLMCTL_MODELS_DIR}/fast/Llama-3.1-8B-Instruct-Q4_K_M.gguf"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
export LLMCTL_PORT_FAST="${PORT}"
python3 - "${PORT}" >/dev/null 2>&1 <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = b'{"data":[{"id":"foreign"}]}'
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
LISTENER=$!; trap 'kill "${LISTENER}" 2>/dev/null || true; test_teardown_env' EXIT
for _ in $(seq 1 30); do (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null && break; sleep 0.1; done
export LLMCTL_READY_TIMEOUT=2

echo "== N2: unit skipped (inactive) while a foreign listener holds the port =="
rc=0; out="$(FAKE_START_MODE=skip timeout 60 "${LLMCTL}" start fast 2>&1)" || rc=$?
assert_eq "1" "${rc}" "N2: start refuses when the unit is not active after start"
assert_contains "${out}" "unit not active after start" "N2: clear message"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/fast.run" "N2: no reservation written for a dead unit"

echo "== control: unit becomes active, port answers -> start succeeds =="
rm -rf "${FAKE_STATE:?}"/*
rc=0; out="$(FAKE_START_MODE=ok timeout 60 "${LLMCTL}" start fast 2>&1)" || rc=$?
assert_eq "0" "${rc}" "control: start succeeds with an active unit"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "control: reservation written"
"${LLMCTL}" stop fast >/dev/null 2>&1 || true; rm -rf "${FAKE_STATE:?}"/*

echo "== N5: a unit that is still gating/starting must not hold the lock for the whole gate wait =="
t0=$(date +%s); rc=0; out="$(FAKE_START_MODE=slow LLMCTL_START_WAIT=3 timeout 45 "${LLMCTL}" start fast 2>&1)" || rc=$?
el=$(( $(date +%s) - t0 ))
if [[ "${rc}" != 124 && "${el}" -lt 30 ]]; then echo "  ok: N5: start returned after ${el}s (bounded by LLMCTL_START_WAIT, rc=${rc})"
else printf '  FAIL: N5: start blocked for %ss (rc=%s): the blocking `systemctl start` holds the scheduler lock for the unit gate wait\n' "${el}" "${rc}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
rm -rf "${FAKE_STATE:?}"/*
if flock -n "${LLMCTL_RUNTIME_DIR}/.scheduler.lock" true; then echo "  ok: N5: the scheduler lock is free afterwards"; else printf '  FAIL: N5: scheduler lock still held\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
test_finish
