#!/usr/bin/env bash
# test_doctor_stray_scope.sh - RED-first (review MEDIUM-4). The doctor's "live engine without a registry row" FAIL must not
# fire (i) for a process younger than LLMCTL_REGISTER_WAIT (it is still loading; the registration waiter has not had its
# time) or (ii) whose port is not listening yet, and (iii) with an EMPTY scope set (no install dir known) the check is
# skipped with a WARN, never judging other projects' llama-servers. Positive control: old + listening + no row -> FAIL.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
PIDS=()
trap 'for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "${p}" 2>/dev/null || true; done; test_teardown_env' EXIT
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" LLMCTL_PORTREG=1
export HOME="${TEST_TMP}/home"; mkdir -p "${HOME}"
FD="${TEST_TMP}/fake-decide"
printf '#!/bin/sh\ncase "$1 $2" in\n  "registry diff") echo ok; exit 0;;\n  "registry list") echo "{\\"services\\":[]}"; exit 0;;\nesac\nexit 0\n' > "${FD}"; chmod +x "${FD}"
export LLMCTL_DECIDE_BIN="${FD}" LLMCTL_DOCTOR_PROC_ROOTS="${TEST_TMP}"
mkdir -p "${LLMCTL_UNIT_DIR}"
doc() { timeout 150 bash -c 'source "$1/lib/doctor.sh"; doctor_run' _ "${LLMCTL_ROOT}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true; }
# a fake engine named like llama-server that LISTENS on its --port (or not, when told not to)
cat > "${TEST_TMP}/llama-server" <<'P'
#!/usr/bin/env python3
import socket, sys, time
port = int(sys.argv[sys.argv.index("--port") + 1])
if "--nolisten" not in sys.argv:
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", port)); s.listen(5)
time.sleep(120)
P
chmod +x "${TEST_TMP}/llama-server"
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
stray_fail() { grep -E '^FAIL' <<<"$1" | grep -qE 'no registry row'; }

P1="$(free_port)"; "${TEST_TMP}/llama-server" --port "${P1}" & PIDS+=("$!"); sleep 1
echo "== (i) young process (LLMCTL_REGISTER_WAIT=600) =="
out="$(LLMCTL_REGISTER_WAIT=600 doc)"
if stray_fail "${out}"; then printf '  FAIL: (i) a process younger than LLMCTL_REGISTER_WAIT was judged\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: (i) young process not judged"; fi
echo "== positive control: LLMCTL_REGISTER_WAIT=0, listening, no row =="
out="$(LLMCTL_REGISTER_WAIT=0 doc)"
if stray_fail "${out}"; then echo "  ok: control: old + listening + no row is a FAIL"; else printf '  FAIL: control: the real stray was not reported\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
kill "${PIDS[0]}" 2>/dev/null || true; PIDS=()

echo "== (ii) port not listening yet =="
P2="$(free_port)"; "${TEST_TMP}/llama-server" --port "${P2}" --nolisten & PIDS+=("$!"); sleep 1
out="$(LLMCTL_REGISTER_WAIT=0 doc)"
if stray_fail "${out}"; then printf '  FAIL: (ii) a process whose port is not listening was judged\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: (ii) not-yet-listening process not judged"; fi

echo "== (iii) empty scope set =="
out="$(LLMCTL_REGISTER_WAIT=0 LLMCTL_DOCTOR_PROC_ROOTS="" doc)"
if grep -E '^WARN' <<<"${out}" | grep -qi 'skipp.*stray\|stray.*skipp\|scope'; then echo "  ok: (iii) empty scope: WARN, check skipped"
else printf '  FAIL: (iii) no WARN about the skipped stray-process check with an empty scope\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if stray_fail "${out}"; then printf '  FAIL: (iii) empty scope still judged a process\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
test_finish
