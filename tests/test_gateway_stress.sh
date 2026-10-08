#!/usr/bin/env bash
# test_gateway_stress.sh - T083 (FR-078): bounded load scenario against the REAL gateway process.
# Starts `llmctl-decide serve` (loopback only, isolated HOME/state) in front of the in-repo fake engine
# (no model, no real inference), then checks over real HTTPS:
#   1. backpressure: with concurrency=1 and queue=1, a fixed burst of 6 slow requests is answered
#      200 (in-flight + queued) or 529 + Retry-After (saturated) - never anything else, never a hang;
#      /healthz stays answerable while saturated;
#   2. graceful stop: `serve --stop` during an in-flight request flips /readyz to not-ready FIRST, lets
#      the in-flight request finish with 200 inside the grace period, and the process then exits;
#   3. the gateway's resident memory stays small (bounded host impact).
# Fixed request count (6 + 1), nothing is downloaded, nothing outside loopback is touched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP-SUITE: curl not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }

BIN="${TEST_TMP}/bin/llmctl-decide"
FAKE="${TEST_TMP}/bin/fakebackends"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide && go build -o "${FAKE}" ./internal/gateway/internal/fakebackends )

PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done
  if [[ -f "${TEST_TMP}/state/decide/gateway.pid" ]]; then "${BIN}" serve --stop >/dev/null 2>&1 || true; fi
  test_teardown_env
}
trap cleanup EXIT

export LLMCTL_HOME="${TEST_TMP}/home/llmctl"
export LLMCTL_ENV_FILE="${TEST_TMP}/root/.env"
export LLMCTL_TLS_SAN="ip:127.0.0.1"
export LLMCTL_DECIDE_BIND="127.0.0.1"
export LLMCTL_CATALOG="${TEST_TMP}/catalog.json"
mkdir -p "${TEST_TMP}/root"
unset LLMCTL_API_KEY LLMCTL_BIND_HOST LLMCTL_DECIDE_PORT LLMCTL_TLS_MODE LLMCTL_DECIDE_MODE
cat > "${LLMCTL_CATALOG}" <<'JSON'
{"version":3,"profiles":{
 "fast":{"capability":["chat"],"port":8080},
 "decide-tiny":{"engine":"llama","port":8092,"capability":["decide"],
   "decision":{"protocol":"letter-logit","max_options":20,"score_levels":[2,10],
     "readout":{"n_probs":32,"mass_threshold":0.5,"spellings":["A"," A"],"cache_prompt":false}}}
}}
JSON

IKEY="internal-test-key-$(date +%s)-0123456789abcdef"
"${FAKE}" -key "${IKEY}" -ports-file "${TEST_TMP}/ports" >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do [[ -s "${TEST_TMP}/ports" ]] && break; sleep 0.1; done
read -r LP _ < <(sed -E 's/llama=([0-9]+) encoder=([0-9]+)/\1 \2/' "${TEST_TMP}/ports")
IKF="${TEST_TMP}/internal.key"; ( umask 077; printf '%s\n' "${IKEY}" > "${IKF}" ); chmod 600 "${IKF}"
export LLMCTL_DECIDE_INTERNAL_KEY_FILE="${IKF}"
export LLMCTL_DECIDE_ENDPOINT_DECIDE_TINY="http://127.0.0.1:${LP}"

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
export LLMCTL_STATE_DIR="${TEST_TMP}/state" LLMCTL_LOG_DIR="${TEST_TMP}/state/logs"
mkdir -p "${LLMCTL_STATE_DIR}"
LLMCTL_DECIDE_CONCURRENCY=1 LLMCTL_DECIDE_QUEUE=1 LLMCTL_DECIDE_DRAIN_GRACE=10 \
  "${BIN}" serve --port "${PORT}" > "${TEST_TMP}/banner" 2>&1
CA="${LLMCTL_HOME}/cert/ca/ca.crt"
KEY="$(sed -n 's/^LLMCTL_API_KEY=//p' "${LLMCTL_ENV_FILE}" | tr -d "'\"")"
[[ -n "${KEY}" ]] || { echo "FAIL: no key generated" >&2; exit 1; }
GWPID="$(awk '{print $1}' "${LLMCTL_STATE_DIR}/decide/gateway.pid")"

SLOWBODY='{"model":"decide-tiny","state":"SLOW load","questions":{"q":{"type":"noul","instructions":"Is it urgent?"}}}'
# post_slow <n>: one authenticated slow request; writes "<status> <retry-after>" to out.<n>
post_slow() {
  local n="$1" st
  st="$(curl -sS --cacert "${CA}" --max-time 30 -o /dev/null -D "${TEST_TMP}/hdr.${n}" -w '%{http_code}' \
    -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' --data-binary "${SLOWBODY}" \
    "https://127.0.0.1:${PORT}/v1/systemone" 2>/dev/null)" || st="000"
  printf '%s %s\n' "${st}" "$(tr -d '\r' < "${TEST_TMP}/hdr.${n}" 2>/dev/null | awk 'tolower($1)=="retry-after:"{print $2}')" > "${TEST_TMP}/out.${n}"
}
plain() { curl -sS --cacert "${CA}" --max-time 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${PORT}$1" 2>/dev/null || true; }

echo "== readiness before load =="
assert_eq "200" "$(plain /readyz)" "readyz is 200 when idle"

echo "== backpressure: burst of 6 slow requests, concurrency 1, queue 1 =="
BURST=()
for i in 1 2 3 4 5 6; do post_slow "${i}" & BURST+=($!); done
sleep 0.7
assert_eq "200" "$(plain /healthz)" "healthz stays answerable while saturated"
wait "${BURST[@]}" || true
ok=0; shed=0; other=0; noretry=0
for i in 1 2 3 4 5 6; do
  read -r st ra < "${TEST_TMP}/out.${i}"
  case "${st}" in
    200) ok=$((ok+1)) ;;
    529) shed=$((shed+1)); [[ -n "${ra}" ]] || noretry=$((noretry+1)) ;;
    *)   other=$((other+1)); echo "  unexpected status ${st} for request ${i}" >&2 ;;
  esac
done
printf '  burst result: 200=%d 529=%d other=%d\n' "${ok}" "${shed}" "${other}"
assert_eq "0" "${other}" "every burst answer is 200 or 529 (no hang, no 5xx)"
assert_eq "0" "${noretry}" "every 529 carries a Retry-After hint"
if [[ "${shed}" -ge 1 ]]; then printf '  ok: saturation was shed with 529\n'; else printf '  FAIL: no request was shed (backpressure not exercised)\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if [[ "${ok}" -ge 2 ]]; then printf '  ok: in-flight + queued requests completed\n'; else printf '  FAIL: fewer than 2 requests completed (%d)\n' "${ok}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_eq "200" "$(plain /readyz)" "readyz recovers to 200 after the burst"

echo "== bounded memory =="
rss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/${GWPID}/status" 2>/dev/null || echo 0)"
printf '  gateway RSS: %s kB\n' "${rss_kb}"
if [[ "${rss_kb:-0}" -gt 0 && "${rss_kb}" -lt 204800 ]]; then printf '  ok: gateway RSS below 200 MB\n'; else printf '  FAIL: gateway RSS %s kB (want 1..204799)\n' "${rss_kb}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

echo "== graceful stop with a request in flight =="
post_slow 9 & INFLIGHT=$!
sleep 0.5
"${BIN}" serve --stop > "${TEST_TMP}/stop.out" 2>&1 &
STOPPID=$!
rdy="200"
for _ in $(seq 1 20); do rdy="$(plain /readyz)"; [[ "${rdy}" != "200" ]] && break; sleep 0.1; done
# 000 alone could be a crash, so also require the process still alive at the flip (it is draining the
# in-flight request); the 503 body itself is asserted in-process by Go TestGracefulDrain (the listener
# closes first, so it is not observable over HTTPS).
if [[ "${rdy}" == "503" || ( "${rdy}" == "000" && -d "/proc/${GWPID}" ) ]]; then printf '  ok: readiness flipped (%s) while the process is still alive and draining\n' "${rdy}"; else printf '  FAIL: readyz stayed %s during the stop\n' "${rdy}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
wait "${INFLIGHT}" || true
read -r st _ < "${TEST_TMP}/out.9"
assert_eq "200" "${st}" "in-flight request completed with 200 during the grace period"
wait "${STOPPID}" || true
gone=0
for _ in $(seq 1 100); do kill -0 "${GWPID}" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
assert_eq "1" "${gone}" "gateway process exited after the drain"
assert_eq "000" "$(plain /readyz)" "listener is closed after the stop"

test_finish
