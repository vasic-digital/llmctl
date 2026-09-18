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

run_llmctl_apikey "https://${NODE_ADDR}" create "model-viewer"
assert_eq 1 "${RC}" "apikey create against a REAL running daemon: still exits non-zero, never hangs or crashes"
assert_contains "${OUT}" "llmctld unreachable" "apikey create against a REAL running daemon: SAME unreachable message as no-daemon-at-all"

run_llmctl_apikey "https://${NODE_ADDR}" rotate "${LLMCTLD_ADMIN_KEY_ID}"
assert_eq 1 "${RC}" "apikey rotate against a REAL running daemon: exits non-zero"
assert_contains "${OUT}" "llmctld unreachable" "apikey rotate against a REAL running daemon: SAME unreachable message"

assert_skip "this host's curl has no HTTP/3 support and llmctld's cluster API is HTTP/3-QUIC-only (UDP) - no curl-based request can complete a 2xx round trip in this environment, so US2 Acceptance Scenarios 1/2 (a real usable key issued, then genuinely rotated so the old key stops authenticating) cannot be exercised here" \
  "apikey create/rotate success path (US2 Acceptance Scenarios 1/2)"

test_finish
