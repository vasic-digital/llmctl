#!/usr/bin/env bash
# test_apikey_lifecycle.sh - 006-cli-daemon-wiring T009/US2: `llmctl
# apikey create <scope>` and `llmctl apikey rotate <key-id>` against a
# REAL running llmctld (never a mock).
#
# See tests/test_cluster_join_leave.sh's header comment for the full
# environment-architecture finding this test shares: this host's curl
# has no HTTP/3 support, and llmctld's cluster API is HTTP/3-QUIC-only
# (UDP), so no curl-based request in this environment can complete a
# 2xx round trip against a real llmctld - proven again below against a
# genuinely running, healthy daemon (not merely asserted from the
# join/leave test in isolation).
#
# What this test DOES prove for real: `apikey create`/`apikey rotate`
# hard-fail with the SAME "llmctld unreachable" message whether no
# daemon is running or a real one is running-but-curl-unreachable
# (FR-008/FR-009/SC-002). What it does NOT (and cannot, on this host)
# prove: the success path (US2 Acceptance Scenarios 1/2 - a real usable
# key issued, then genuinely rotated) - explicitly SKIPPED, never
# silently omitted.
#
# G-106 UPDATE (OD-21 / T131): the certificate side of the HTTP/3 round trip
# is fixed. The daemon's certificates carry SANs (127.0.0.1, ::1, localhost,
# hostname, -api-bind host, -advertise names), `llmctld cluster bootstrap|join`
# writes ca.crt + client.crt + client.key (0700 dir, 0600 files, CLI_CERT_DIR=
# on stdout) and lib/cluster.sh passes --cacert/--cert/--key (never -k). The
# suite exports LLMCTL_CLUSTER_CERT_DIR=$LLMCTLD_CLI_CERT_DIR on a curl that
# has the HTTP3 feature and runs the success path; on a curl without HTTP3
# (this host) it still SKIPs, with the measured Features line. The remaining
# limit is the host's curl, not the daemon or the CLI.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"

LLMCTLD_BIN="$(llmctld_build)"

run_llmctl_apikey() {
  local endpoint="$1"; shift
  RC=0
  OUT="$(LLMCTL_CLUSTER_ENDPOINT="${endpoint}" LLMCTL_CLUSTER_TOKEN="test-token" "${LLMCTL_ROOT}/bin/llmctl" apikey "$@" 2>&1)" || RC=$?
}

# --- Scenario A: no daemon at all -----------------------------------------
run_llmctl_apikey "https://127.0.0.1:19611" create "model-viewer"
assert_eq 1 "${RC}" "apikey create, no daemon at all: exits non-zero"
assert_contains "${OUT}" "llmctld unreachable" "apikey create, no daemon at all: clear unreachable message"

run_llmctl_apikey "https://127.0.0.1:19611" rotate "some-key-id"
assert_eq 1 "${RC}" "apikey rotate, no daemon at all: exits non-zero"
assert_contains "${OUT}" "llmctld unreachable" "apikey rotate, no daemon at all: clear unreachable message"

# --- Scenario B: a REAL, genuinely running, healthy llmctld ---------------
llmctld_bootstrap "${LLMCTLD_BIN}" "n1" 19612
NODE_PID="${LLMCTLD_PID}"
NODE_ADDR="${LLMCTLD_API_ADDR}"
trap 'kill "${NODE_PID}" 2>/dev/null || true' EXIT

assert_file_contains "${LLMCTLD_LOG}" "READY node_id=n1" "node: real READY line observed"
key_id_present="false"
[[ -n "${LLMCTLD_ADMIN_KEY_ID}" ]] && key_id_present="true"
assert_eq "true" "${key_id_present}" "node: a real BOOTSTRAP_ADMIN_KEY_ID was printed (proves auth.Store is genuinely live)"

hostdep_begin "success path runs only when the host curl has HTTP3 (G-089/G-106)"
if SKIP_WHY="$(cluster_cli_skip_reason "https://${NODE_ADDR}")"; then
  run_llmctl_apikey "https://${NODE_ADDR}" create "model-viewer"
  assert_eq 1 "${RC}" "apikey create against a REAL running daemon: still exits non-zero, never hangs or crashes"
  assert_contains "${OUT}" "llmctld unreachable" "apikey create against a REAL running daemon: SAME unreachable message as no-daemon-at-all"

  run_llmctl_apikey "https://${NODE_ADDR}" rotate "${LLMCTLD_ADMIN_KEY_ID}"
  assert_eq 1 "${RC}" "apikey rotate against a REAL running daemon: exits non-zero"
  assert_contains "${OUT}" "llmctld unreachable" "apikey rotate against a REAL running daemon: SAME unreachable message"

  assert_skip "${SKIP_WHY} - so no curl-based request can complete a 2xx round trip here, and US2 Acceptance Scenarios 1/2 (a real usable key issued, then genuinely rotated so the old key stops authenticating) cannot be exercised on this host" \
    "apikey create/rotate success path (US2 Acceptance Scenarios 1/2)"
else
  export LLMCTL_CLUSTER_CERT_DIR="${LLMCTLD_CLI_CERT_DIR}"
  tok_exchange() { # tok_exchange <key-id> <secret> -> prints "<http-status> <token-or-empty>"
    local resp code
    resp="$(cluster_curl_h3 -sS --max-time 5 -w '\n%{http_code}' -X POST "https://${NODE_ADDR}/v1/auth/token" -H 'Content-Type: application/json' \
      -d "{\"api_key_id\":\"$1\",\"api_key_secret\":\"$2\"}" 2>/dev/null)" || true
    code="${resp##*$'\n'}"; resp="${resp%$'\n'*}"
    printf '%s %s' "${code}" "$(python3 -c 'import json,sys
try: print(json.loads(sys.argv[1]).get("token",""))
except Exception: print("")' "${resp}")"
  }
  read -r code ADMIN_TOKEN <<<"$(tok_exchange "${LLMCTLD_ADMIN_KEY_ID}" "${LLMCTLD_ADMIN_KEY_SECRET}")"
  assert_eq 200 "${code}" "the bootstrap admin key exchanges for a JWT over the real transport"
  export LLMCTL_CLUSTER_TOKEN="${ADMIN_TOKEN}"
  RC=0; OUT="$(LLMCTL_CLUSTER_ENDPOINT="https://${NODE_ADDR}" "${LLMCTL_ROOT}/bin/llmctl" apikey create "model-viewer" 2>&1)" || RC=$?
  assert_eq 0 "${RC}" "apikey create: exit 0 against the real daemon"
  assert_contains "${OUT}" '"id":"' "apikey create: the response carries the new key id"
  assert_contains "${OUT}" '"secret":"' "apikey create: the response carries the one-time secret"
  NEW_ID="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["id"])' "${OUT}")"
  NEW_SECRET="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["secret"])' "${OUT}")"
  read -r code _ <<<"$(tok_exchange "${NEW_ID}" "${NEW_SECRET}")"
  assert_eq 200 "${code}" "the freshly created key genuinely authenticates (token exchange 200)"
  RC=0; OUT="$(LLMCTL_CLUSTER_ENDPOINT="https://${NODE_ADDR}" "${LLMCTL_ROOT}/bin/llmctl" apikey rotate "${NEW_ID}" 2>&1)" || RC=$?
  assert_eq 0 "${RC}" "apikey rotate: exit 0 against the real daemon"
  ROT_SECRET="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["secret"])' "${OUT}")"
  assert_eq "yes" "$([[ -n "${ROT_SECRET}" && "${ROT_SECRET}" != "${NEW_SECRET}" ]] && echo yes || echo no)" "apikey rotate: a NEW secret is returned"
  read -r code _ <<<"$(tok_exchange "${NEW_ID}" "${NEW_SECRET}")"
  assert_eq "yes" "$([[ "${code}" != 200 ]] && echo yes || echo no)" "the OLD secret stops authenticating after rotation (status ${code})"
  read -r code _ <<<"$(tok_exchange "${NEW_ID}" "${ROT_SECRET}")"
  assert_eq 200 "${code}" "the rotated secret authenticates"
fi

hostdep_end
test_finish
