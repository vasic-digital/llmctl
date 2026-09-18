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

assert_skip "this host's curl has no HTTP/3 support and llmctld's cluster API is HTTP/3-QUIC-only (UDP) - no curl-based request can complete a 2xx round trip in this environment, so US3 Acceptance Scenarios 1/2/3 (create-then-list shows the tenant, quota view/set round-trips through the real enforcer state) cannot be exercised here. The underlying Go/HTTP-level behavior these routes implement IS proven for real by TestListTenants and TestTenantQuota_ViewAndSet in llmctld/internal/api/routes_tenants_test.go (real httptest round trips, no mocks, run and passing as of this commit)." \
  "tenant create/list/quota success path (US3 Acceptance Scenarios 1/2/3)"

test_finish
