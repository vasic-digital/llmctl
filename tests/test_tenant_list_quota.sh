#!/usr/bin/env bash
# test_tenant_list_quota.sh - 006-cli-daemon-wiring T016/US3: `llmctl
# tenant create/list/quota` against a REAL running llmctld (never a
# mock) - including the two genuinely-new server routes this feature
# adds (GET /v1/tenants, GET+PUT /v1/tenants/:id/quota, already proven
# at the Go/HTTP level by TestListTenants/TestTenantQuota_ViewAndSet in
# llmctld/internal/api/routes_tenants_test.go).
#
# See tests/test_cluster_join_leave.sh's header comment for the full
# environment-architecture finding this test shares: this host's curl
# has no HTTP/3 support, and llmctld's cluster API is HTTP/3-QUIC-only
# (UDP), so no curl-based request in this environment can complete a
# 2xx round trip against a real llmctld.
#
# What this test DOES prove for real: `tenant create/list/quota`
# hard-fail with the SAME "llmctld unreachable" message whether no
# daemon is running or a real one is running-but-curl-unreachable
# (FR-008/FR-009/SC-002), for all three subcommands including the two
# BRAND NEW routes (list/quota) this feature adds server-side - proving
# the new bash wiring reaches cluster::require_daemon identically to
# the pre-existing create path, never a different (e.g. hung, crashed,
# malformed-request) failure mode just because the route is new. What
# it does NOT (and cannot, on this host) prove: the success path (US3
# Acceptance Scenarios 1/2/3 - create-then-list, and quota view/set
# round-tripping through the real enforcer state) - explicitly SKIPPED,
# never silently omitted.
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

run_llmctl_tenant() {
  local endpoint="$1"; shift
  RC=0
  OUT="$(LLMCTL_CLUSTER_ENDPOINT="${endpoint}" LLMCTL_CLUSTER_TOKEN="test-token" "${LLMCTL_ROOT}/bin/llmctl" tenant "$@" 2>&1)" || RC=$?
}

# --- Scenario A: no daemon at all -----------------------------------------
run_llmctl_tenant "https://127.0.0.1:19621" create "demo"
assert_eq 1 "${RC}" "tenant create, no daemon at all: exits non-zero"
assert_contains "${OUT}" "llmctld unreachable" "tenant create, no daemon at all: clear unreachable message"

run_llmctl_tenant "https://127.0.0.1:19621" list
assert_eq 1 "${RC}" "tenant list, no daemon at all: exits non-zero"
assert_contains "${OUT}" "llmctld unreachable" "tenant list, no daemon at all: clear unreachable message"

run_llmctl_tenant "https://127.0.0.1:19621" quota "demo" --max-concurrent-requests 5
assert_eq 1 "${RC}" "tenant quota (set), no daemon at all: exits non-zero"
assert_contains "${OUT}" "llmctld unreachable" "tenant quota (set), no daemon at all: clear unreachable message"

run_llmctl_tenant "https://127.0.0.1:19621" quota "demo"
assert_eq 1 "${RC}" "tenant quota (view), no daemon at all: exits non-zero"
assert_contains "${OUT}" "llmctld unreachable" "tenant quota (view), no daemon at all: clear unreachable message"

# --- Scenario B: a REAL, genuinely running, healthy llmctld ---------------
llmctld_bootstrap "${LLMCTLD_BIN}" "n1" 19622
NODE_PID="${LLMCTLD_PID}"
NODE_ADDR="${LLMCTLD_API_ADDR}"
trap 'kill "${NODE_PID}" 2>/dev/null || true' EXIT

assert_file_contains "${LLMCTLD_LOG}" "READY node_id=n1" "node: real READY line observed"

hostdep_begin "success path runs only when the host curl has HTTP3 (G-089/G-106)"
if SKIP_WHY="$(cluster_cli_skip_reason "https://${NODE_ADDR}")"; then
  run_llmctl_tenant "https://${NODE_ADDR}" create "demo"
  assert_eq 1 "${RC}" "tenant create against a REAL running daemon: still exits non-zero, never hangs or crashes"
  assert_contains "${OUT}" "llmctld unreachable" "tenant create against a REAL running daemon: SAME unreachable message"

  run_llmctl_tenant "https://${NODE_ADDR}" list
  assert_eq 1 "${RC}" "tenant list against a REAL running daemon: exits non-zero (the NEW GET /v1/tenants route reaches the same unreachable gate)"
  assert_contains "${OUT}" "llmctld unreachable" "tenant list against a REAL running daemon: SAME unreachable message"

  run_llmctl_tenant "https://${NODE_ADDR}" quota "demo" --max-concurrent-requests 5
  assert_eq 1 "${RC}" "tenant quota (set) against a REAL running daemon: exits non-zero (the NEW PUT /v1/tenants/:id/quota route reaches the same unreachable gate)"
  assert_contains "${OUT}" "llmctld unreachable" "tenant quota (set) against a REAL running daemon: SAME unreachable message"

  run_llmctl_tenant "https://${NODE_ADDR}" quota "demo"
  assert_eq 1 "${RC}" "tenant quota (view) against a REAL running daemon: exits non-zero (the NEW GET /v1/tenants/:id/quota route reaches the same unreachable gate)"
  assert_contains "${OUT}" "llmctld unreachable" "tenant quota (view) against a REAL running daemon: SAME unreachable message"

  assert_skip "${SKIP_WHY} - so no curl-based request can complete a 2xx round trip here, and US3 Acceptance Scenarios 1/2/3 (create-then-list shows the tenant, quota view/set round-trips through the real enforcer state) cannot be exercised on this host. The underlying Go/HTTP-level behavior these routes implement IS proven for real by TestListTenants and TestTenantQuota_ViewAndSet in llmctld/internal/api/routes_tenants_test.go (real httptest round trips, no mocks)." \
    "tenant create/list/quota success path (US3 Acceptance Scenarios 1/2/3)"
else
  export LLMCTL_CLUSTER_CERT_DIR="${LLMCTLD_CLI_CERT_DIR}"
  resp="$(cluster_curl_h3 -sS --max-time 5 -X POST "https://${NODE_ADDR}/v1/auth/token" -H 'Content-Type: application/json' \
    -d "{\"api_key_id\":\"${LLMCTLD_ADMIN_KEY_ID}\",\"api_key_secret\":\"${LLMCTLD_ADMIN_KEY_SECRET}\"}")"
  TOK="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("token",""))' "${resp}")"
  assert_eq "yes" "$([[ -n "${TOK}" ]] && echo yes || echo no)" "the bootstrap admin key exchanges for a JWT over the real transport"
  tenant_cli() { RC=0; OUT="$(LLMCTL_CLUSTER_ENDPOINT="https://${NODE_ADDR}" LLMCTL_CLUSTER_TOKEN="${TOK}" "${LLMCTL_ROOT}/bin/llmctl" tenant "$@" 2>&1)" || RC=$?; }
  tenant_cli create "demo"
  assert_eq 0 "${RC}" "tenant create: exit 0 against the real daemon"
  assert_contains "${OUT}" '"id":"demo"' "tenant create: the daemon echoes the created tenant"
  tenant_cli list
  assert_eq 0 "${RC}" "tenant list: exit 0"
  assert_contains "${OUT}" '"id":"demo"' "tenant list: create-then-list shows the tenant (US3 Acceptance Scenario 1)"
  tenant_cli quota "demo" --max-concurrent-requests 5
  assert_eq 0 "${RC}" "tenant quota (set): exit 0"
  assert_contains "${OUT}" '"max_concurrent_requests":5' "tenant quota (set): the new limit is echoed"
  tenant_cli quota "demo"
  assert_eq 0 "${RC}" "tenant quota (view): exit 0"
  assert_contains "${OUT}" '"max_concurrent_requests":5' "tenant quota (view): the limit set above round-trips through the real enforcer state (US3 Acceptance Scenarios 2/3)"
fi

hostdep_end
test_finish
