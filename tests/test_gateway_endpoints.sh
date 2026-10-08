#!/usr/bin/env bash
# test_gateway_endpoints.sh - T042: builds the REAL llmctl-decide binary and a tiny fake-engine helper
# (both into a temp dir; nothing lands in the repo tree), starts `serve` in an isolated HOME against the
# fake llama-server / encoder runtime and drives every reachable row of
# specs/009-jev-decision-models/contracts/endpoint-inventory.tsv over real HTTPS (curl --cacert), then
# checks `serve --status` / `--stop` safety (Helix 11.4.263: only a verified process is ever signalled).
# The engines are fakes by design (they stand in for a model); gateway, TLS, auth, limits, key and
# certificate handling are the real implementations.
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
  for s in A B C E; do
    if [[ -f "${TEST_TMP}/state-${s}/decide/gateway.pid" ]]; then
      LLMCTL_STATE_DIR="${TEST_TMP}/state-${s}" "${BIN}" serve --stop >/dev/null 2>&1 || true
    fi
  done
  test_teardown_env
}
trap cleanup EXIT

# ---- isolated installation: home, key file, catalog -------------------------------------------------
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
     "readout":{"n_probs":32,"mass_threshold":0.5,"spellings":["A"," A"],"cache_prompt":false}}},
 "decide-small":{"engine":"llama","port":8101,"capability":["decide"],"defaults":{"ctx":512,"parallel":1},
   "decision":{"protocol":"letter-logit","max_options":20,"score_levels":[2,10],
     "readout":{"n_probs":32,"mass_threshold":0.5,"spellings":["A"," A"],"cache_prompt":false}}},
 "decide-nli":{"engine":"onnx","port":8096,"capability":["decide"],
   "decision":{"protocol":"nli-onnx","max_options":20,"score_levels":[2,10],"experimental":["choice","score"]}}
}}
JSON

# ---- fake engines ------------------------------------------------------------------------------------
IKEY="internal-test-key-$(date +%s)-0123456789abcdef"
"${FAKE}" -key "${IKEY}" -ports-file "${TEST_TMP}/ports" >/dev/null 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do [[ -s "${TEST_TMP}/ports" ]] && break; sleep 0.1; done
read -r LP EP < <(sed -E 's/llama=([0-9]+) encoder=([0-9]+)/\1 \2/' "${TEST_TMP}/ports")
# G-040: the internal engine key travels in a 0600 FILE, never in the environment
IKF="${TEST_TMP}/internal.key"; ( umask 077; printf '%s\n' "${IKEY}" > "${IKF}" ); chmod 600 "${IKF}"
export LLMCTL_DECIDE_INTERNAL_KEY_FILE="${IKF}"
export LLMCTL_DECIDE_ENDPOINT_DECIDE_TINY="http://127.0.0.1:${LP}"
export LLMCTL_DECIDE_ENDPOINT_DECIDE_NLI="http://127.0.0.1:${EP}"
export LLMCTL_DECIDE_ENDPOINT_DECIDE_SMALL="http://127.0.0.1:${LP}"
hits() { curl -sS --max-time 5 "http://127.0.0.1:${LP}/_hits"; }

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

# start_gateway <label> [VAR=VAL ...]: detached `serve` with its own state dir; prints the banner.
start_gateway() {
  local label="$1"; shift
  local port; port="$(free_port)"
  eval "PORT_${label}=${port}"
  mkdir -p "${TEST_TMP}/state-${label}"
  env LLMCTL_STATE_DIR="${TEST_TMP}/state-${label}" LLMCTL_LOG_DIR="${TEST_TMP}/state-${label}/logs" "$@" \
    "${BIN}" serve --port "${port}" > "${TEST_TMP}/banner-${label}" 2>&1
}

CA="${LLMCTL_HOME}/cert/ca/ca.crt"
req() { # req <port> <METHOD> <path> <auth: key|none|wrong> [body] [extra curl args...]
  local port="$1" method="$2" path="$3" auth="$4" body="${5:-}"; shift 5 2>/dev/null || shift $#
  local args=(-sS --cacert "${CA}" --max-time 20 -o "${TEST_TMP}/resp" -w '%{http_code}' -X "${method}")
  case "${auth}" in
    key)   args+=(-H "Authorization: Bearer ${KEY}") ;;
    wrong) args+=(-H "Authorization: Bearer not-the-key-not-the-key-not-the-key-0000") ;;
  esac
  if [[ -n "${body}" ]]; then args+=(-H "Content-Type:${CT-application/json}" --data-binary "${body}"); fi
  local code=""
  code="$(curl "${args[@]}" "$@" "https://127.0.0.1:${port}${path}" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}
body() { cat "${TEST_TMP}/resp"; }
errtype() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("error_type",""))' "${TEST_TMP}/resp" 2>/dev/null || echo "?"; }
# row <id> <expected-status> <expected-error-type or -> <actual-status>
row() {
  local id="$1" want="$2" et="$3" got="$4"
  assert_eq "${want}" "${got}" "${id}: status"
  if [[ "${et}" != "-" ]]; then assert_eq "${et}" "$(errtype)" "${id}: error_type"; fi
}

NOUL='{"model":"decide-tiny","state":"the printer is on fire","questions":{"q":{"type":"noul","instructions":"Is it urgent?"}}}'
mkchoice() { # mkchoice <model> <n> [state]
  python3 - "$1" "$2" "${3:-invoice overdue}" <<'PY'
import json,sys
m,n,st=sys.argv[1],int(sys.argv[2]),sys.argv[3]
print(json.dumps({"model":m,"state":st,"questions":{"c":{"type":"choice","instructions":"Which team?","criteria":{"opt%d"%i:"d%d"%i for i in range(n)}}}}))
PY
}
mkscore() { python3 -c 'import json,sys;n=int(sys.argv[1]);print(json.dumps({"model":"decide-tiny","state":"great","questions":{"s":{"type":"score","instructions":"Rate","criteria":["l%d"%i for i in range(n)]}}}))' "$1"; }

echo "== start gateway A (defaults, detached) =="
start_gateway A LLMCTL_DECIDE_AUTH_FAIL_LIMIT=12
assert_eq "0" "$(LLMCTL_STATE_DIR="${TEST_TMP}/state-A" "${BIN}" serve --status >/dev/null 2>&1; echo $?)" "serve --status is 0 while running"
banner="$(cat "${TEST_TMP}/banner-A")"
KEY="$(sed -n 's/^LLMCTL_API_KEY=//p' "${LLMCTL_ENV_FILE}" | tr -d "'\"")"
[[ -n "${KEY}" ]] || { echo "FAIL: no key generated" >&2; exit 1; }
assert_contains "${banner}" "https://127.0.0.1:${PORT_A}" "banner prints the HTTPS URL"
assert_contains "${banner}" "${LLMCTL_ENV_FILE}" "banner prints the key LOCATION"
assert_contains "${banner}" "SHA-256" "banner prints the CA fingerprint"
if [[ "${banner}" == *"${KEY}"* ]]; then printf '  FAIL: banner leaked the key\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: banner never prints the key\n'; fi
assert_eq "600" "$(stat -c %a "${TEST_TMP}/state-A/decide/gateway.pid")" "pidfile is mode 0600"
assert_eq "600" "$(stat -c %a "${LLMCTL_ENV_FILE}")" "key file is mode 0600"
P="${PORT_A}"

echo "== POST /v1/systemone: valid requests (EP-001..007) =="
row EP-001 200 - "$(req "$P" POST /v1/systemone key "${NOUL}")"
assert_contains "$(body)" '"noul":0.9' "EP-001: noul probability from the letter readout"
row EP-002 200 - "$(req "$P" POST /v1/systemone key "$(mkchoice decide-tiny 2)")"
row EP-003 200 - "$(req "$P" POST /v1/systemone key "$(mkchoice decide-tiny 20)")"
assert_contains "$(body)" '"choice":"opt0"' "EP-003: 20-option choice answered"
row EP-004 200 - "$(req "$P" POST /v1/systemone key "$(mkscore 5)")"
assert_contains "$(body)" '"legend"' "EP-004: score answer carries the legend"
row EP-005 200 - "$(req "$P" POST /v1/systemone key '{"model":"decide-tiny","state":"s","questions":{"a":{"type":"noul","instructions":"i"},"b":{"type":"choice","instructions":"j","criteria":{"x":"1","y":"2"}},"c":{"type":"score","instructions":"k","criteria":["lo","hi"]}}}')"
assert_contains "$(body)" '"a":{"type":"noul"' "EP-005: mixed questions all answered"
row EP-006a 200 - "$(req "$P" POST /v1/systemone key '{"model":"decide-tiny","state":{"b":1,"a":[1,2]},"questions":{"q":{"type":"noul","instructions":"i"}}}')"
row EP-006b 200 - "$(req "$P" POST /v1/systemone key '{"model":"decide-tiny","state":[1,2,3],"questions":{"q":{"type":"noul","instructions":"i"}}}')"
row EP-007 200 - "$(req "$P" POST /v1/systemone key "${NOUL/decide-tiny/jev-latest}")"
assert_contains "$(body)" '"model":"decide-tiny"' "EP-007: hosted alias answered by the served profile id"
row EP-005n 200 - "$(req "$P" POST /v1/systemone key '{"model":"decide-nli","state":"the server is down","questions":{"q":{"type":"noul","instructions":"urgent?"}}}')"
assert_contains "$(body)" '"noul":0.7' "NLI profile: entailment of the yes-hypothesis vs the no-hypothesis"
row EP-005c 200 - "$(req "$P" POST /v1/systemone key "$(mkchoice decide-nli 3)")"

echo "== determinism (FR-010): repeats are byte-identical =="
first="$(req "$P" POST /v1/systemone key "$(mkchoice decide-tiny 4)" >/dev/null; body)"
same=1; for _ in 1 2 3 4 5 6 7 8; do req "$P" POST /v1/systemone key "$(mkchoice decide-tiny 4)" >/dev/null; [[ "$(body)" == "${first}" ]] || same=0; done
assert_eq "1" "${same}" "8 repeats of one request give byte-identical bodies"

echo "== validation and contract errors (EP-008..018) =="
BIG="$(python3 -c 'print("x"*9000)')"
row EP-008 422 validation_failed "$(req "$P" POST /v1/systemone key "$(mkchoice decide-tiny 2 "${BIG}")")"
row EP-011 400 invalid_request "$(req "$P" POST /v1/systemone key 'this is not json')"
row EP-012 400 invalid_request "$(req "$P" POST /v1/systemone key '[1,2,3]')"
row EP-013a 400 invalid_request "$(CT=' text/plain' req "$P" POST /v1/systemone key "${NOUL}")"
row EP-013b 400 invalid_request "$(CT='' req "$P" POST /v1/systemone key "${NOUL}")"
python3 - "${P}" "${CA}" "${KEY}" <<'PY' && printf '  ok: EP-014: oversize Content-Length answered 413 before any body byte was sent\n' || { printf '  FAIL: EP-014\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }
import socket, ssl, sys
port, ca, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
ctx = ssl.create_default_context(cafile=ca)
s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=10), server_hostname="127.0.0.1")
s.sendall(("POST /v1/systemone HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: 300000\r\n\r\n" % key).encode())
resp = b""
while b"\r\n\r\n" not in resp:
    c = s.recv(4096)
    if not c: break
    resp += c
assert resp.startswith(b"HTTP/1.1 413"), resp[:80]
PY
row EP-015a 422 validation_failed "$(req "$P" POST /v1/systemone key "$(mkchoice decide-tiny 1)")"
row EP-015b 422 validation_failed "$(req "$P" POST /v1/systemone key "$(mkchoice decide-tiny 21)")"
row EP-015c 422 validation_failed "$(req "$P" POST /v1/systemone key "$(mkscore 1)")"
row EP-015d 422 validation_failed "$(req "$P" POST /v1/systemone key "$(mkscore 11)")"
row EP-015e 400 invalid_request "$(req "$P" POST /v1/systemone key "$(mkchoice decide-nli 256)")"
row EP-016 422 unknown_model "$(req "$P" POST /v1/systemone key "${NOUL/decide-tiny/no-such-model}")"
row EP-017 422 validation_failed "$(req "$P" POST /v1/systemone key "$(python3 -c 'import json;print(json.dumps({"model":"decide-tiny","state":"s"*4000,"questions":{"q":{"type":"noul","instructions":"i"*5000}}}))')")"
row EP-018a 422 validation_failed "$(req "$P" POST /v1/systemone key '{"model":"decide-tiny","state":"s","bogus":1,"questions":{"q":{"type":"noul","instructions":"i"}}}')"
row EP-018b 422 validation_failed "$(req "$P" POST /v1/systemone key '{"model":"decide-tiny","state":"s","questions":{"q":{"type":"noul","instructions":"i","extra":1}}}')"

echo "== authentication and methods (EP-009/010/025/031..033/041/051/052/060/061) =="
row EP-009 401 unauthorized "$(req "$P" POST /v1/systemone none "${NOUL}")"
row EP-010 401 unauthorized "$(req "$P" POST /v1/systemone wrong "${NOUL}")"
row EP-025 405 method_not_allowed "$(req "$P" GET /v1/systemone key)"
row EP-031 401 unauthorized "$(req "$P" GET /v1/models none)"
row EP-032 401 unauthorized "$(req "$P" GET /v1/models wrong)"
row EP-033 405 method_not_allowed "$(req "$P" POST /v1/models key '{}')"
row EP-041 405 method_not_allowed "$(req "$P" POST /healthz none '{}')"
row EP-051 401 unauthorized "$(req "$P" GET /metrics none)"
row EP-052 405 method_not_allowed "$(req "$P" POST /metrics key '{}')"
row EP-060 404 invalid_request "$(req "$P" GET /no/such/path key)"
row EP-061 401 unauthorized "$(req "$P" GET /no/such/path none)"

echo "== models, health, readiness, metrics (EP-030/040/045/050) =="
row EP-030 200 - "$(req "$P" GET /v1/models key)"
assert_contains "$(body)" '"decide-tiny"' "EP-030: lists the served profile"
assert_contains "$(body)" '"jev-latest"' "EP-030: lists the hosted alias"
assert_contains "$(body)" '"letter-logit"' "EP-030: reports the protocol"
assert_contains "$(body)" '"max_options":20' "EP-030: per-profile limits"
assert_contains "$(body)" '"models":[' "EP-030: the SDK listing (models) rides along with object/data (G-038)"
assert_contains "$(body)" '"name":"decide-tiny","description":' "EP-030: SDK entry name/description"
assert_contains "$(body)" '"name":"jev-latest"' "EP-030: aliases are listed as SDK model names too"
assert_contains "$(body)" '"release_date":"2026-' "EP-030: release_date is a fixed YYYY-MM-DD"
row EP-040 200 - "$(req "$P" GET /healthz none)"
row EP-045 200 - "$(req "$P" GET /readyz none)"
row EP-050 200 - "$(req "$P" GET /metrics key)"
m="$(body)"
if [[ "${m}" == *"printer"* || "${m}" == *"${KEY}"* ]]; then printf '  FAIL: EP-050: metrics leak state or key\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: EP-050: metrics carry no state or key\n'; fi

echo "== backend failures (EP-022/023) =="
row EP-022 422 readout_failed "$(req "$P" POST /v1/systemone key "${NOUL/the printer is on fire/LOWMASS please}")"
row EP-023 502 backend_failed "$(req "$P" POST /v1/systemone key "${NOUL/the printer is on fire/KILLME now}")"
if [[ "$(body)" == *"KILLME"* ]]; then printf '  FAIL: EP-023: engine detail leaked\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: EP-023: generic body\n'; fi

echo "== review-2 B-01/B-02/B-03/B-05/B-07: flagged answers, budgets before the engine, classified rejections =="
# B-01: an option letter missing from the readout is a flagged upper bound, never certainty
row EP-B01 200 - "$(req "$P" POST /v1/systemone key "${NOUL/the printer is on fire/MISSINGB please}")"
assert_contains "$(body)" '"flags":["option_missing"]' "B-01: the answer is flagged"
# B3-01: min(3 x floor e^-1.6, 1 - listed mass), on the scale of the probabilities
assert_contains "$(body)" '"upper_bounds":{"no":0.071776734}' "B-01: the absent option carries its upper bound"
if [[ "$(body)" == *'"noul":1,'* || "$(body)" == *'"noul":1}'* ]]; then printf '  FAIL: B-01: the missing letter became certainty\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: B-01: noul is not 1\n'; fi
# B-02 layer 2: the engine itself says the prompt does not fit -> deterministic 422, never the retryable 502
row EP-B02a 422 validation_failed "$(req "$P" POST /v1/systemone key "${NOUL/the printer is on fire/CTXOVERFLOW please}")"
# B-02 layer 1: a profile whose catalog ctx is 512 refuses a 3000-character state BEFORE contacting the engine
h0="$(hits)"
row EP-B02b 422 validation_failed "$(req "$P" POST /v1/systemone key "$(python3 -c 'import json;print(json.dumps({"model":"decide-small","state":"The invoice is overdue and billing was notified. "*60,"questions":{"q":{"type":"noul","instructions":"urgent?"}}}))')")"
assert_eq "${h0}" "$(hits)" "B-02: the over-budget request never reached the engine"
row EP-B02c 200 - "$(req "$P" POST /v1/systemone key '{"model":"decide-small","state":"short state","questions":{"q":{"type":"noul","instructions":"urgent?"}}}')"
# B-03(b): an empty state for the encoder can never succeed: refused before the engine
h0="$(hits)"
row EP-B03b 422 validation_failed "$(req "$P" POST /v1/systemone key '{"model":"decide-nli","state":"","questions":{"q":{"type":"noul","instructions":"urgent?"}}}')"
assert_eq "${h0}" "$(hits)" "B-03: the empty-state NLI request never reached the encoder"
# B-05: the per-request pair budget (4 questions x 20 options = 80 > 64) is checked before any pass
h0="$(hits)"
row EP-B05 422 validation_failed "$(req "$P" POST /v1/systemone key "$(python3 -c 'import json;print(json.dumps({"model":"decide-nli","state":"the server is down","questions":{"q%d"%i:{"type":"choice","instructions":"pick","criteria":{"o%d"%j:"d" for j in range(20)}} for i in range(4)}}))')")"
assert_eq "${h0}" "$(hits)" "B-05: the over-budget NLI request never reached the encoder"
# B-07: the mode is marked on every decision, and the listing carries the effective budgets
row EP-B07 200 - "$(req "$P" POST /v1/systemone key "${NOUL}" -D "${TEST_TMP}/hdrM")"
assert_contains "$(tr 'A-Z' 'a-z' < "${TEST_TMP}/hdrM")" "x-llmctl-decide-mode: deterministic" "B-07: x-llmctl-decide-mode on a decision"
row EP-B02d 200 - "$(req "$P" GET /v1/models key)"
assert_contains "$(body)" '"max_state_chars":' "B-02: /v1/models advertises the effective state budget"
assert_contains "$(body)" '"max_context_tokens":' "B-02: /v1/models advertises the context in tokens"
assert_contains "$(body)" '"max_pairs":64' "B-05: /v1/models advertises the encoder pair budget"
# B-07: deterministic mode refuses several slots at start
rc=0; out="$(LLMCTL_STATE_DIR="${TEST_TMP}/state-slots" LLMCTL_DECIDE_SLOTS=4 "${BIN}" serve --port "$(free_port)" 2>&1)" || rc=$?
assert_eq "2" "${rc}" "B-07: LLMCTL_DECIDE_SLOTS=4 in deterministic mode is refused at start"
assert_contains "${out}" "LLMCTL_DECIDE_MODE=throughput" "B-07: the refusal says how to fix it"
rc=0; out="$(LLMCTL_STATE_DIR="${TEST_TMP}/state-badtemp" LLMCTL_DECIDE_TEMPERATURE=NaN "${BIN}" serve --port "$(free_port)" 2>&1)" || rc=$?
assert_eq "2" "${rc}" "B-06: LLMCTL_DECIDE_TEMPERATURE=NaN is refused at start"

echo "== plain HTTP to the TLS port (EP-070) =="
rc=0; out="$(curl -sS --max-time 5 "http://127.0.0.1:${P}/healthz" 2>&1)" || rc=$?
if [[ ${rc} -ne 0 ]]; then printf '  ok: EP-070: plain HTTP gets no answer (curl rc=%s)\n' "${rc}"; else printf '  FAIL: EP-070: plain HTTP was answered: %s\n' "${out}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

echo "== EP-019: failed-auth burst is throttled, the valid key never is =="
got429=0; for _ in $(seq 1 20); do [[ "$(req "$P" POST /v1/systemone wrong "${NOUL}")" == "429" ]] && got429=1; done
assert_eq "1" "${got429}" "EP-019: burst of wrong keys reaches 429"
assert_eq "rate_limited" "$(for _ in 1 2 3; do req "$P" POST /v1/systemone wrong "${NOUL}" >/dev/null; done; errtype)" "EP-019: error_type rate_limited"
row EP-019v 200 - "$(req "$P" POST /v1/systemone key "${NOUL}")"

echo "== start gateway B (small limits, truncation opt-in) =="
start_gateway B LLMCTL_DECIDE_TRUNCATE=1 LLMCTL_DECIDE_MAX_STATE_CHARS=200 LLMCTL_DECIDE_CONCURRENCY=1 LLMCTL_DECIDE_QUEUE=0 \
  LLMCTL_DECIDE_MAX_CONNS=8 LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE=3 LLMCTL_DECIDE_READ_DEADLINE=2
PB="${PORT_B}"
row EP-008b 200 - "$(req "$PB" POST /v1/systemone key "$(mkchoice decide-tiny 2 "$(python3 -c 'print("z"*600)')")" -D "${TEST_TMP}/hdr")"
assert_contains "$(tr 'A-Z' 'a-z' < "${TEST_TMP}/hdr")" "x-llmctl-decide-truncated: true" "EP-008b: truncation header set"
row EP-008c 422 validation_failed "$(req "$PB" POST /v1/systemone key "$(python3 -c 'import json;print(json.dumps({"model":"decide-tiny","state":"s"*300,"questions":{"q":{"type":"noul","instructions":"i"*400}}}))')")"

row EP-008d 200 - "$(req "$PB" POST /v1/systemone key '{"model":"decide-nli","state":"TRUNC this premise","questions":{"q":{"type":"noul","instructions":"urgent?"}}}' -D "${TEST_TMP}/hdrN")"
assert_contains "$(tr 'A-Z' 'a-z' < "${TEST_TMP}/hdrN")" "x-llmctl-decide-truncated: true" "EP-008d: the encoder runtime truncated the premise (opt-in) -> truncation header set (G-039)"
row EP-008e 200 - "$(req "$PB" POST /v1/systemone key '{"model":"decide-nli","state":"short premise","questions":{"q":{"type":"noul","instructions":"urgent?"}}}' -D "${TEST_TMP}/hdrN2")"
if tr 'A-Z' 'a-z' < "${TEST_TMP}/hdrN2" | grep -q "x-llmctl-decide-truncated"; then printf '  FAIL: EP-008e: header set without truncation\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: EP-008e: no truncation header when nothing was truncated\n'; fi

echo "== EP-020: all slots busy and queue full -> 529 =="
SLOWREQ="${NOUL/the printer is on fire/SLOW please}"
( req "$PB" POST /v1/systemone key "${SLOWREQ}" >"${TEST_TMP}/slow.status" ) &
SLOWPID=$!
sleep 0.7
row EP-020 529 overloaded "$(req "$PB" POST /v1/systemone key "${NOUL}")"
wait "${SLOWPID}" || true
assert_eq "200" "$(cat "${TEST_TMP}/slow.status")" "EP-020: the in-flight request still completed"

echo "== EP-026: per-source connection cap sheds before TLS; a second source keeps succeeding =="
python3 - "${PB}" "${CA}" "${KEY}" <<'PY' && printf '  ok: EP-026: per-source cap closed the surplus connection, second source served\n' || { printf '  FAIL: EP-026\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }
import socket, ssl, sys, time
port, ca, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
held = []
for _ in range(3):
    s = socket.create_connection(("127.0.0.1", port), timeout=3); held.append(s)
time.sleep(0.3)
# The deliberate RST of connection shedding can arrive during connect() itself (race), or on the
# first read: both mean "shed". Data, a hang, or a successful TLS-less answer would be a failure.
try:
    extra = socket.create_connection(("127.0.0.1", port), timeout=3)
    extra.settimeout(3)
    data = extra.recv(1)
    closed = (data == b"")
except ConnectionResetError:
    closed = True
except socket.timeout:
    closed = False
assert closed, "surplus connection from the same source was not shed"
ctx = ssl.create_default_context(cafile=ca)
raw = socket.socket(); raw.bind(("127.0.0.2", 0)); raw.settimeout(5); raw.connect(("127.0.0.1", port))
tls = ctx.wrap_socket(raw, server_hostname="127.0.0.1")
tls.sendall(("GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").encode())
resp = tls.recv(200)
assert resp.startswith(b"HTTP/1.1 200"), resp
for s in held: s.close()
PY

echo "== EP-024: slow client is cut at the read deadline, others unaffected =="
python3 - "${PB}" "${CA}" <<'PY' && printf '  ok: EP-024: drip-fed request closed by the deadline\n' || { printf '  FAIL: EP-024\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }
import socket, ssl, sys, time
port, ca = int(sys.argv[1]), sys.argv[2]
ctx = ssl.create_default_context(cafile=ca)
s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=10), server_hostname="127.0.0.1")
s.settimeout(10)
start = time.time()
closed = False
try:
    for ch in b"POST /v1/systemone HTTP/1.1\r\nHost: x\r\nX-Slow: ":
        s.send(bytes([ch])); time.sleep(0.4)
    s.recv(1)
except (ssl.SSLError, ConnectionError, BrokenPipeError, OSError):
    closed = True
else:
    closed = (s.recv(1) == b"")
assert closed and time.time() - start < 9, "slow client was not cut"
PY
row EP-024o 200 - "$(req "$PB" GET /healthz none)"

echo "== gateway E: per-profile key files, no global file (G-040); unusable NLI labels (G-044) =="
mkdir -p "${TEST_TMP}/state-E/keys"
( umask 077; printf '%s\n' "${IKEY}" > "${TEST_TMP}/state-E/keys/llama-decide-tiny.key"; printf '%s\n' "${IKEY}" > "${TEST_TMP}/state-E/keys/onnx-decide-nli.key" )
start_gateway E LLMCTL_DECIDE_INTERNAL_KEY_FILE=
PE="${PORT_E}"
row EP-001e 200 - "$(req "$PE" POST /v1/systemone key "${NOUL}")"
assert_contains "$(body)" '"noul":0.9' "G-040: the per-profile llama key file authenticates the gateway to the engine"
row EP-005e 200 - "$(req "$PE" POST /v1/systemone key '{"model":"decide-nli","state":"the server is down","questions":{"q":{"type":"noul","instructions":"urgent?"}}}')"
assert_contains "$(body)" '"noul":0.7' "G-044: entailment is taken from the permuted id2label column by NAME (0.7/(0.7+0.3))"
row EP-005g 502 backend_failed "$(req "$PE" POST /v1/systemone key '{"model":"decide-nli","state":"GENERICLABELS","questions":{"q":{"type":"noul","instructions":"urgent?"}}}')"
if grep -qi "label" "${TEST_TMP}/resp"; then printf '  FAIL: G-044: the client body names the label problem\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: G-044: the client body stays generic\n'; fi
row EP-030e 200 - "$(req "$PE" GET /v1/models key)"
assert_contains "$(body)" '"status":"degraded"' "G-044: the mis-configured NLI instance is reported degraded, not served with guesses"
row EP-005h 503 not_ready "$(req "$PE" POST /v1/systemone key '{"model":"decide-nli","state":"the server is down","questions":{"q":{"type":"noul","instructions":"urgent?"}}}')"

echo "== gateway C: no engine reachable -> not_ready (EP-016b/034/046) =="
start_gateway C LLMCTL_DECIDE_ENDPOINT_DECIDE_TINY="http://127.0.0.1:1" LLMCTL_DECIDE_ENDPOINT_DECIDE_NLI="http://127.0.0.1:1" LLMCTL_DECIDE_ENDPOINT_DECIDE_SMALL="http://127.0.0.1:1"
PC="${PORT_C}"
row EP-016b 503 not_ready "$(req "$PC" POST /v1/systemone key "${NOUL}" -D "${TEST_TMP}/hdrC")"
assert_contains "$(tr 'A-Z' 'a-z' < "${TEST_TMP}/hdrC")" "retry-after:" "EP-016b: Retry-After present"
row EP-034 503 not_ready "$(req "$PC" GET /v1/models key)"
row EP-046 503 - "$(req "$PC" GET /readyz none)"
row EP-040c 200 - "$(req "$PC" GET /healthz none)"

echo "== serve --stop / --status safety (Helix 11.4.263) =="
SAFE="${TEST_TMP}/state-S"; mkdir -p "${SAFE}/decide"
sleep 300 & SLEEPPID=$!; PIDS+=("${SLEEPPID}")
printf '%s %s\n' "${SLEEPPID}" "$(date +%s)" > "${SAFE}/decide/gateway.pid"
rc=0; out="$(LLMCTL_STATE_DIR="${SAFE}" "${BIN}" serve --stop 2>&1)" || rc=$?
assert_eq "1" "${rc}" "stop refuses a pidfile that names an unrelated process"
if kill -0 "${SLEEPPID}" 2>/dev/null; then printf '  ok: the unrelated process was NOT signalled\n'; else printf '  FAIL: unrelated process was killed\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
rc=0; out="$(LLMCTL_STATE_DIR="${SAFE}" "${BIN}" serve --status 2>&1)" || rc=$?
assert_eq "1" "${rc}" "status does not report an unverified pid as running"
printf '1 %s\n' "$(date +%s)" > "${SAFE}/decide/gateway.pid"
rc=0; LLMCTL_STATE_DIR="${SAFE}" "${BIN}" serve --stop >/dev/null 2>&1 || rc=$?
assert_eq "1" "${rc}" "stop refuses pid 1"
rc=0; LLMCTL_STATE_DIR="${TEST_TMP}/state-nothing" "${BIN}" serve --stop >/dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "stop with no pidfile is a clean no-op"

pidA="$(cut -d' ' -f1 "${TEST_TMP}/state-A/decide/gateway.pid")"
for s in A B C E; do
  rc=0; out="$(LLMCTL_STATE_DIR="${TEST_TMP}/state-${s}" "${BIN}" serve --stop 2>&1)" || rc=$?
  assert_eq "0" "${rc}" "gateway ${s}: --stop verified and stopped it"
done
if kill -0 "${pidA}" 2>/dev/null; then printf '  FAIL: gateway A still alive\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: gateway A process is gone\n'; fi
assert_file_absent "${TEST_TMP}/state-A/decide/gateway.pid" "pidfile removed after stop"
assert_eq "000" "$(req "${PORT_A}" GET /healthz none)" "port closed after stop"

echo "== the request log carries no state text and no key =="
LOG="${TEST_TMP}/state-A/logs/decide-requests.jsonl"
assert_file_exists "${LOG}" "request log written"
assert_eq "600" "$(stat -c %a "${LOG}")" "request log is mode 0600"
if grep -q -e "printer" -e "${KEY}" "${LOG}"; then printf '  FAIL: log leaked state or key\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: no state text or key in the log\n'; fi

test_finish
