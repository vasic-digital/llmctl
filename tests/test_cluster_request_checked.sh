#!/usr/bin/env bash
# test_cluster_request_checked.sh - 006-cli-daemon-wiring T019/T020: proves
# cluster::request_checked genuinely distinguishes all three outcomes
# spec.md's Edge Cases require ("auth-vs-unreachable-vs-app-error
# distinction"): reachable+2xx, reachable+non-2xx, and unreachable - AND
# proves the pre-existing cluster::request function's own output/exit-code
# contract is completely unmodified (research.md R3's additive-only design
# decision; the one existing caller, `cluster status`, must see zero
# behavior change).
#
# Real HTTP round trip against a REAL, running local HTTP server (python3's
# stdlib http.server, the SAME "no mocks, real local fixture" pattern
# test_download.sh already uses for a real download source) - never a
# mocked transport. It deliberately does NOT talk to a real llmctld: this
# host's curl build has no HTTP/3 support (`curl --version` lacks
# "HTTP3" in its Features line) and llmctld's cluster API server
# (llmctld/internal/api/server.go's NewServer) serves EXCLUSIVELY over
# HTTP/3 via a UDP-only QUIC listener (confirmed empirically this
# session: a real bootstrapped llmctld shows only a UDP socket in
# `ss -tulpn`, and a plain-TCP curl request to it fails with
# "Connection refused", identical to no daemon running at all) - so no
# curl-based bash test can ever reach a real llmctld's success path in
# this environment. That is a pre-existing daemon/environment
# architecture fact this feature's Assumptions section did not
# anticipate (it assumed only request/response SHAPES might need bash-
# side handling, not the transport protocol itself), tracked separately
# (see docs/qa/006-cli-daemon-wiring/ for the full writeup) - it is NOT
# a defect in cluster::request_checked's OWN logic, which this test
# proves correct against a real HTTP server that curl on this host CAN
# actually speak to.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/cluster.sh"

PORT=18732
FIXTURE_DIR="${TEST_TMP}/fixture_server"
mkdir -p "${FIXTURE_DIR}"

cat > "${FIXTURE_DIR}/server.py" <<'PYEOF'
import http.server
import json
import sys

ROUTES = {
    ("GET", "/ok"): (200, {"status": "ok"}),
    ("POST", "/ok"): (200, {"status": "ok", "created": True}),
    ("GET", "/forbidden"): (403, {"error": "requires a role granting tenant:manage"}),
    ("GET", "/missing"): (404, {"error": "tenant \"ghost\" not found"}),
}

class Handler(http.server.BaseHTTPRequestHandler):
    def _serve(self, method):
        length = int(self.headers.get("Content-Length", 0))
        if length:
            self.rfile.read(length)
        key = (method, self.path)
        status, body = ROUTES.get(key, (404, {"error": "no such fixture route"}))
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self._serve("GET")

    def do_POST(self):
        self._serve("POST")

    def log_message(self, fmt, *args):
        pass  # keep test output clean; failures are asserted, not eyeballed

if __name__ == "__main__":
    port = int(sys.argv[1])
    http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF

python3 "${FIXTURE_DIR}/server.py" "${PORT}" >/dev/null 2>&1 &
FIXTURE_PID=$!
trap 'kill ${FIXTURE_PID} 2>/dev/null || true' EXIT

# Wait for the real server to actually accept connections (never a fixed
# sleep guess) before issuing any request against it.
waited=0
until curl -sS --max-time 1 "http://127.0.0.1:${PORT}/ok" >/dev/null 2>&1; do
  waited=$((waited + 1))
  [[ "${waited}" -lt 50 ]] || { echo "fixture HTTP server never became reachable" >&2; exit 1; }
  sleep 0.1
done

export LLMCTL_CLUSTER_ENDPOINT="http://127.0.0.1:${PORT}"
unset LLMCTL_CLUSTER_TOKEN 2>/dev/null || true

# --- Outcome 1: reachable + 2xx -> exit 0, body on stdout ------------------
out="$(cluster::request_checked GET /ok)"; rc=$?
assert_eq 0 "${rc}" "request_checked: 2xx GET returns exit 0"
assert_contains "${out}" '"status": "ok"' "request_checked: 2xx GET prints the real response body"

out="$(cluster::request_checked POST /ok '{"x":1}')"; rc=$?
assert_eq 0 "${rc}" "request_checked: 2xx POST returns exit 0"
assert_contains "${out}" '"created": true' "request_checked: 2xx POST prints the real response body"

# --- Outcome 2: reachable + non-2xx -> exit 1, daemon's own error body -----
rc=0
out="$(cluster::request_checked GET /forbidden)" || rc=$?
assert_eq 1 "${rc}" "request_checked: 403 GET returns exit 1 (never a transport-failure code, never 0)"
assert_contains "${out}" "requires a role granting tenant:manage" "request_checked: 403 GET prints the daemon's real error body"

rc=0
out="$(cluster::request_checked GET /missing)" || rc=$?
assert_eq 1 "${rc}" "request_checked: 404 GET returns exit 1"
assert_contains "${out}" 'tenant \"ghost\" not found' "request_checked: 404 GET prints the daemon's real error body"

# --- Outcome 3: unreachable -> curl's own transport exit code, unchanged ---
export LLMCTL_CLUSTER_ENDPOINT="http://127.0.0.1:1"  # nothing listens on port 1
rc=0
cluster::request_checked GET /ok >/dev/null 2>&1 || rc=$?
# rc must be curl's OWN transport-failure exit code (e.g. 7 = connection
# refused), never 0 (this function's 2xx signal) and never 1 (this
# function's non-2xx-HTTP-response signal) - a transport failure must
# never be mistaken for either HTTP outcome.
is_transport_code="true"
[[ "${rc}" -eq 0 || "${rc}" -eq 1 ]] && is_transport_code="false"
assert_eq "true" "${is_transport_code}" "request_checked: unreachable daemon returns curl's own transport exit code (got ${rc}), distinct from both HTTP-status outcomes (0/1)"
export LLMCTL_CLUSTER_ENDPOINT="http://127.0.0.1:${PORT}"

# --- Regression guard: cluster::request's PRE-EXISTING contract is untouched
# (research.md R3's additive-only decision + FR's implicit no-regression
# bar): it prints the body regardless of HTTP status and its exit code is
# ALWAYS curl's raw exit code (0 on any HTTP response, reachable or not,
# status-blind) - the exact gap request_checked exists to close, proven
# still present and unchanged on the untouched function.
out="$(cluster::request GET /forbidden)"; rc=$?
assert_eq 0 "${rc}" "cluster::request (untouched): still exits 0 on a non-2xx HTTP response - unchanged pre-existing behavior"
assert_contains "${out}" "requires a role granting tenant:manage" "cluster::request (untouched): still prints the response body regardless of status - unchanged pre-existing behavior"

test_finish
