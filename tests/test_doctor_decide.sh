#!/usr/bin/env bash
# test_doctor_decide.sh - T082 (FR-032): `llmctl doctor` reports the decision-gateway prerequisites:
# API key file (presence + mode, never the value), certificate (expiry / SAN drift / key match, via the
# real `llmctl-decide cert doctor`), private venv, engine HTTPS support, gateway port, firewall/bind note.
# The Go binary and the certificate are REAL; the llama-server is a tiny stub that only answers --help.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }

BIN="${TEST_TMP}/bin/llmctl-decide"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide )

LISTENER=""
cleanup() { [[ -n "${LISTENER}" ]] && kill "${LISTENER}" 2>/dev/null || true; test_teardown_env; }
trap cleanup EXIT

export HOME="${TEST_TMP}/home"
export LLMCTL_HOME="${TEST_TMP}/home/llmctl"
export LLMCTL_ENV_FILE="${TEST_TMP}/root/.env"
export LLMCTL_DECIDE_BIN="${BIN}"
export LLMCTL_DATA_DIR="${TEST_TMP}/data"
export LLMCTL_STATE_DIR="${TEST_TMP}/state"
export LLMCTL_PORTREG=0
export LLMCTL_TLS_SAN="ip:127.0.0.1"
export LLMCTL_DECIDE_BIND="127.0.0.1"
export NO_COLOR=1
unset LLMCTL_API_KEY LLMCTL_DECIDE_PORT LLMCTL_BIND_HOST LLMCTL_TLS_MODE
mkdir -p "${TEST_TMP}/root" "${HOME}"

SECRET="doctor-test-secret-key-0123456789abcdef0123456789"
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
export LLMCTL_DECIDE_PORT; LLMCTL_DECIDE_PORT="$(free_port)"

mkstub() { # mkstub <path> <with-ssl: 1|0>
  { echo '#!/usr/bin/env bash'
    if [[ "$2" == 1 ]]; then echo 'echo "  --ssl-key-file FNAME   path to a PEM private key"'; else echo 'echo "  --port N"'; fi
  } > "$1"; chmod +x "$1"
}
mkstub "${TEST_TMP}/llama-ssl" 1
mkstub "${TEST_TMP}/llama-nossl" 0
export LLMCTL_LLAMA_SERVER_BIN="${TEST_TMP}/llama-ssl"
{ echo '#!/usr/bin/env bash'
  echo "REAL='${BIN}'"
  echo 'if [[ "${1:-}" == cert && "${STUB_CERT_ERR:-0}" == 1 && "${*: -1}" == doctor ]]; then echo "cert doctor: boom" >&2; exit 5; fi'
  echo 'if [[ "${1:-}" == cert && "${STUB_CERT_SILENT:-0}" == 1 && "${*: -1}" == doctor ]]; then exit 0; fi'
  echo 'if [[ "${1:-}" == serve && "${2:-}" == --status && -n "${STUB_STATUS_PID:-}" ]]; then echo "llmctl decide gateway: running pid ${STUB_STATUS_PID}, up 1s"; exit 0; fi'
  echo 'exec "$REAL" "$@"'
} > "${TEST_TMP}/bin/stub-decide"; chmod +x "${TEST_TMP}/bin/stub-decide"

doctor_out() { bash -c 'source "$1/lib/doctor.sh"; doctor_run' _ "${LLMCTL_ROOT}" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true; }

echo "== key + cert healthy =="
( umask 077; printf "LLMCTL_API_KEY='%s'\n" "${SECRET}" > "${LLMCTL_ENV_FILE}" ); chmod 600 "${LLMCTL_ENV_FILE}"
"${BIN}" cert --home "${LLMCTL_HOME}" ensure >/dev/null
out="$(doctor_out)"
assert_contains "${out}" "PASS decide: API key present in ${LLMCTL_ENV_FILE} (mode 600)" "key present + 0600"
case "${out}" in *"${SECRET}"*) printf '  FAIL: doctor leaked the key\n' >&2; TEST_FAILS=$((TEST_FAILS+1));; *) printf '  ok: doctor never prints the key\n';; esac
assert_contains "${out}" "PASS decide: certificate key_matches_cert" "cert key matches"
assert_contains "${out}" "PASS decide: certificate expiry" "cert expiry reported"
assert_contains "${out}" "PASS decide: certificate san_drift" "no SAN drift"
assert_contains "${out}" "PASS decide: engine HTTPS" "engine supports --ssl-key-file"
assert_contains "${out}" "PASS decide: gateway port ${LLMCTL_DECIDE_PORT} is free" "port free"
assert_contains "${out}" "PASS decide: gateway binds loopback only" "loopback bind note"

echo "== key file too open =="
chmod 644 "${LLMCTL_ENV_FILE}"
out="$(doctor_out)"
assert_contains "${out}" "FAIL decide: API key file ${LLMCTL_ENV_FILE} is mode 644" "loose key file is a FAIL"
for m in 640 604 660; do
  chmod "${m}" "${LLMCTL_ENV_FILE}"
  out="$(doctor_out)"
  assert_contains "${out}" "FAIL decide: API key file ${LLMCTL_ENV_FILE} is mode ${m}" "mode ${m} key file is a FAIL"
done
chmod 600 "${LLMCTL_ENV_FILE}"

echo "== no key yet =="
mv "${LLMCTL_ENV_FILE}" "${LLMCTL_ENV_FILE}.bak"
out="$(doctor_out)"
assert_contains "${out}" "WARN decide: no API key" "missing key is a WARN"
mv "${LLMCTL_ENV_FILE}.bak" "${LLMCTL_ENV_FILE}"

echo "== certificate drift =="
out="$(LLMCTL_TLS_SAN='ip:10.9.8.7' doctor_out)"
assert_contains "${out}" "WARN decide: certificate san_drift" "SAN drift reported"

echo "== no certificate =="
mv "${LLMCTL_HOME}/cert" "${LLMCTL_HOME}/cert.bak"
out="$(doctor_out)"
assert_contains "${out}" "WARN decide: no gateway certificate" "missing cert is a WARN"
mv "${LLMCTL_HOME}/cert.bak" "${LLMCTL_HOME}/cert"

echo "== engine without HTTPS support =="
out="$(LLMCTL_LLAMA_SERVER_BIN="${TEST_TMP}/llama-nossl" doctor_out)"
assert_contains "${out}" "WARN decide: engine HTTPS" "engine without --ssl-key-file is a WARN"

echo "== port in use =="
python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(60)' "${LLMCTL_DECIDE_PORT}" &
LISTENER=$!
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/${LLMCTL_DECIDE_PORT}") 2>/dev/null && break; sleep 0.1; done
out="$(doctor_out)"
assert_contains "${out}" "WARN decide: gateway port ${LLMCTL_DECIDE_PORT} is in use" "occupied port is a WARN"
kill "${LISTENER}" 2>/dev/null || true; LISTENER=""

echo "== non-loopback bind: firewall note =="
out="$(LLMCTL_DECIDE_BIND=0.0.0.0 doctor_out)"
assert_contains "${out}" "WARN decide: gateway binds 0.0.0.0" "wide bind warns"
assert_contains "${out}" "firewall" "firewall note present"

echo "== cert doctor failures are never silent =="
out="$(LLMCTL_DECIDE_BIN="${TEST_TMP}/bin/stub-decide" STUB_CERT_ERR=1 doctor_out)"
assert_contains "${out}" "FAIL decide: certificate doctor failed" "cert doctor exit 5 + stderr -> FAIL"
out="$(LLMCTL_DECIDE_BIN="${TEST_TMP}/bin/stub-decide" STUB_CERT_SILENT=1 doctor_out)"
assert_contains "${out}" "FAIL decide: certificate doctor failed" "cert doctor with no verdict lines -> FAIL"
chmod 644 "${LLMCTL_HOME}/cert/current/leaf.key"
out="$(doctor_out)"
assert_contains "${out}" "FAIL decide: certificate permissions" "a cert FAIL line stays a FAIL"
chmod 600 "${LLMCTL_HOME}/cert/current/leaf.key"

echo "== empty API key is not a PASS =="
for v in "LLMCTL_API_KEY=" "LLMCTL_API_KEY=''" 'LLMCTL_API_KEY=""'; do
  ( umask 077; printf '%s\n' "${v}" > "${LLMCTL_ENV_FILE}" )
  out="$(doctor_out)"
  assert_contains "${out}" "WARN decide: no API key" "empty key (${v}) -> WARN"
  case "${out}" in *"PASS decide: API key"*) printf '  FAIL: empty key (%s) reported PASS\n' "${v}" >&2; TEST_FAILS=$((TEST_FAILS+1));; *) printf '  ok: no PASS for %s\n' "${v}";; esac
done
( umask 077; printf "LLMCTL_API_KEY='%s'\n" "${SECRET}" > "${LLMCTL_ENV_FILE}" )

echo "== engine help larger than the pipe buffer, match first =="
{ echo '#!/usr/bin/env bash'; echo 'echo "  --ssl-key-file FNAME"'; echo 'head -c 200000 /dev/zero | tr "\\0" "x"; echo'; } > "${TEST_TMP}/llama-big"; chmod +x "${TEST_TMP}/llama-big"
out="$(LLMCTL_LLAMA_SERVER_BIN="${TEST_TMP}/llama-big" doctor_out)"
assert_contains "${out}" "PASS decide: engine HTTPS" "large --help with an early match still PASSes (no SIGPIPE)"

echo "== running gateway must be on the configured port =="
if command -v ss >/dev/null 2>&1; then
  OTHER="$(free_port)"
  python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(60)' "${OTHER}" &
  LISTENER=$!
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/${OTHER}") 2>/dev/null && break; sleep 0.1; done
  out="$(LLMCTL_DECIDE_BIN="${TEST_TMP}/bin/stub-decide" STUB_STATUS_PID="${LISTENER}" doctor_out)"
  assert_contains "${out}" "WARN decide: gateway pid ${LISTENER} is not listening on port ${LLMCTL_DECIDE_PORT}" "pid alive but on another port -> WARN naming the port"
  out="$(LLMCTL_DECIDE_PORT="${OTHER}" LLMCTL_DECIDE_BIND=127.0.0.1 LLMCTL_DECIDE_BIN="${TEST_TMP}/bin/stub-decide" STUB_STATUS_PID="${LISTENER}" doctor_out)"
  assert_contains "${out}" "PASS decide: gateway port ${OTHER} served by the running llmctl gateway (pid ${LISTENER})" "pid listens on the configured port -> PASS"
  # foreign process listens on the configured port; the gateway pid is alive but elsewhere
  python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(60)' "${LLMCTL_DECIDE_PORT}" &
  FOREIGN=$!
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/${LLMCTL_DECIDE_PORT}") 2>/dev/null && break; sleep 0.1; done
  out="$(LLMCTL_DECIDE_BIN="${TEST_TMP}/bin/stub-decide" STUB_STATUS_PID="${LISTENER}" doctor_out)"
  assert_contains "${out}" "WARN decide: gateway pid ${LISTENER} is not listening on port ${LLMCTL_DECIDE_PORT}" "foreign listener on the configured port -> WARN"
  case "${out}" in *"PASS decide: gateway port ${LLMCTL_DECIDE_PORT} served"*) printf '  FAIL: foreign listener reported as the gateway\n' >&2; TEST_FAILS=$((TEST_FAILS+1));; *) printf '  ok: no PASS for a foreign listener\n';; esac
  kill "${FOREIGN}" 2>/dev/null || true
  kill "${LISTENER}" 2>/dev/null || true; LISTENER=""
else
  echo "  SKIP: ss not installed"
fi

echo "== venv =="
out="$(doctor_out)"
assert_contains "${out}" "WARN decide: private venv" "absent venv -> WARN"
mkdir -p "${LLMCTL_DATA_DIR}/venv-onnx/bin"; printf '#!/bin/sh\nexit 1\n' > "${LLMCTL_DATA_DIR}/venv-onnx/bin/python"; chmod +x "${LLMCTL_DATA_DIR}/venv-onnx/bin/python"
out="$(doctor_out)"
assert_contains "${out}" "PASS decide: private venv" "present venv -> PASS"

test_finish
