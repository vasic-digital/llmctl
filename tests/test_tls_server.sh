#!/usr/bin/env bash
# test_tls_server.sh - transport tier for internal/server (T023, spec FR-019, FR-022, FR-066, FR-070):
#   1. the in-process end-to-end Go test (real sockets, real TLS) must pass;
#   2. a real server process (test-only helper, throw-away CA) is driven by the REAL curl binary and
#      judged on status, headers, certificate chain and the plain-HTTP refusal.
# Nothing is written into the repository tree (the helper binary and its CA/key live in a temp dir).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then kill "${SERVER_PID}" 2>/dev/null || true; wait "${SERVER_PID}" 2>/dev/null || true; fi
  test_teardown_env
}
trap cleanup EXIT

command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP-SUITE: curl not installed"; exit 0; }
export GOFLAGS="-mod=readonly"
cd "${LLMCTL_ROOT}"

echo "== in-process end-to-end (real sockets, real TLS) =="
if go test -run TestServerEndToEnd -count=1 ./internal/server/ >"${TEST_TMP}/e2e.out" 2>&1; then
  assert_eq "0" "0" "go test -run TestServerEndToEnd passes"
else
  cat "${TEST_TMP}/e2e.out" >&2
  assert_eq "0" "1" "go test -run TestServerEndToEnd passes"
fi

echo "== real server process driven by curl =="
BIN="${TEST_TMP}/servetest"
go build -o "${BIN}" ./internal/server/internal/servetest
D="${TEST_TMP}/srv"; mkdir -p "${D}"
mkfifo "${TEST_TMP}/stdin"
"${BIN}" -dir "${D}" <"${TEST_TMP}/stdin" >"${TEST_TMP}/stdout" 2>"${TEST_TMP}/stderr" &
SERVER_PID=$!
exec 7>"${TEST_TMP}/stdin"   # holding the fifo open keeps the server alive; closing it drains it
for _ in $(seq 1 100); do grep -q '^READY ' "${TEST_TMP}/stdout" 2>/dev/null && break; sleep 0.1; done
URL="$(sed -n 's/^READY //p' "${TEST_TMP}/stdout")"
assert_contains "${URL}" "https://127.0.0.1:" "server announced an https address"
HOSTPORT="${URL#https://}"; PORT="${HOSTPORT##*:}"
KEY="$(cat "${D}/key")"
CA="${D}/ca.pem"
H="${TEST_TMP}/hdr"

echo "-- TLS trust and probes --"
code="$(curl -sS --cacert "${CA}" -o "${TEST_TMP}/body" -D "${H}" -w '%{http_code}' "${URL}/healthz")"
assert_eq "200" "${code}" "healthz over HTTPS with the CA trusted"
assert_eq '{"status":"ok"}' "$(cat "${TEST_TMP}/body")" "healthz body is minimal"
assert_contains "$(tr 'A-Z' 'a-z' <"${H}")" "cache-control: no-store" "Cache-Control: no-store"
assert_contains "$(tr 'A-Z' 'a-z' <"${H}")" "x-content-type-options: nosniff" "nosniff"
assert_contains "$(tr 'A-Z' 'a-z' <"${H}")" "x-request-id: " "x-request-id present"
if grep -qi '^server:' "${H}"; then assert_eq "no Server header" "Server header present" "no Server header"; else assert_eq "0" "0" "no Server header"; fi
if grep -qi '^access-control-' "${H}"; then assert_eq "no CORS" "CORS present" "no CORS headers"; else assert_eq "0" "0" "no CORS headers"; fi

rc=0; curl -sS -o /dev/null --max-time 5 "${URL}/healthz" 2>/dev/null || rc=$?
assert_eq "60" "${rc}" "without the CA, curl refuses the certificate (exit 60)"
rc=0; curl -sS -o /dev/null --max-time 5 --cacert "${CA}" --resolve "wrong.example:${PORT}:127.0.0.1" "https://wrong.example:${PORT}/healthz" 2>/dev/null || rc=$?
assert_eq "60" "${rc}" "a host name not in the certificate is refused (exit 60)"

if command -v openssl >/dev/null 2>&1; then
  out="$(echo | openssl s_client -connect "${HOSTPORT}" -CAfile "${CA}" -servername localhost -verify_return_error -verify_hostname localhost 2>&1 || true)"
  assert_contains "${out}" "Verify return code: 0 (ok)" "certificate chain verifies against the CA (openssl)"
  assert_contains "${out}" "New, TLSv1." "TLS 1.2+ negotiated"
  out="$(echo | openssl s_client -connect "${HOSTPORT}" -CAfile "${CA}" -tls1_1 2>&1 || true)"
  if [[ "${out}" == *"BEGIN CERTIFICATE"* && "${out}" == *"Verify return code: 0"* ]]; then assert_eq "refused" "accepted" "a TLS 1.1 handshake does not complete (the Go test proves the server side)"; else assert_eq "0" "0" "a TLS 1.1 handshake does not complete (the Go test proves the server side)"; fi
else
  assert_skip "openssl not installed" "certificate chain / old-protocol checks"
fi

echo "-- plain HTTP to the TLS port --"
rc=0; plain="$(curl -sS --max-time 5 -o - "http://${HOSTPORT}/healthz" 2>&1)" || rc=$?
assert_eq "1" "$([[ "${rc}" != 0 ]] && echo 1 || echo 0)" "plain HTTP request fails (curl exit ${rc})"
assert_eq "0" "$([[ "${plain}" == *'"status"'* ]] && echo 1 || echo 0)" "plain HTTP never receives an answer body"

echo "-- authentication and routing order --"
code="$(curl -sS --cacert "${CA}" -o "${TEST_TMP}/body" -D "${H}" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "${URL}/v1/systemone")"
assert_eq "401" "${code}" "no key => 401"
assert_contains "$(tr 'A-Z' 'a-z' <"${H}")" "www-authenticate: bearer" "401 carries WWW-Authenticate"
code="$(curl -sS --cacert "${CA}" -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' "${URL}/no/such")"
assert_eq "401" "${code}" "unknown path without a valid key => 401, not 404"
code="$(curl -sS --cacert "${CA}" -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${KEY}" "${URL}/no/such")"
assert_eq "404" "${code}" "unknown path with the key => 404"
code="$(curl -sS --cacert "${CA}" -o /dev/null -D "${H}" -w '%{http_code}' -H "Authorization: Bearer ${KEY}" "${URL}/v1/systemone")"
assert_eq "405" "${code}" "GET on the POST endpoint => 405"
assert_contains "$(tr 'A-Z' 'a-z' <"${H}")" "allow: post" "405 carries Allow"

echo "-- decision, models, metrics --"
body='{"state":"the printer is on fire","questions":{"q":{"type":"noul","instructions":"Is it urgent?"}}}'
code="$(curl -sS --cacert "${CA}" -o "${TEST_TMP}/body" -w '%{http_code}' -X POST -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' -d "${body}" "${URL}/v1/systemone")"
assert_eq "200" "${code}" "valid decision => 200"
assert_contains "$(cat "${TEST_TMP}/body")" '"answers"' "decision body has answers"
code="$(curl -sS --cacert "${CA}" -o "${TEST_TMP}/body" -w '%{http_code}' -H "Authorization: Bearer ${KEY}" "${URL}/v1/models")"
assert_eq "200" "${code}" "models => 200"
assert_contains "$(cat "${TEST_TMP}/body")" '"decide-tiny"' "models lists the profile"
code="$(curl -sS --cacert "${CA}" -o "${TEST_TMP}/body" -w '%{http_code}' -H "Authorization: Bearer ${KEY}" "${URL}/metrics")"
assert_eq "200" "${code}" "metrics => 200"
assert_eq "0" "$(grep -c "${KEY}" "${TEST_TMP}/body" || true)" "metrics never contain the key"

echo "-- keep-alive survives an error response (N-12), one curl invocation, one connection --"
out="$(curl -sS --cacert "${CA}" -w ' conn=%{num_connects}\n' -o /dev/null -X POST -H 'Authorization: Bearer wrong' -H 'Content-Type: application/json' -d "${body}" "${URL}/v1/systemone" --next --cacert "${CA}" -w ' code=%{http_code} conn=%{num_connects}\n' -o /dev/null "${URL}/healthz" 2>&1)"
assert_contains "${out}" "code=200 conn=0" "second request after a 401 succeeds on the SAME connection (no new connect)"

echo "-- graceful stop --"
exec 7>&-
rc=0; wait "${SERVER_PID}" || rc=$?
SERVER_PID=""
assert_eq "0" "${rc}" "server drained and exited 0 when stdin closed"

test_finish
