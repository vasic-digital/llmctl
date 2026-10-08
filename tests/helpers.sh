#!/usr/bin/env bash
# helpers.sh - shared assertion helpers for llmctl tests (sourced by test_*.sh).
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLMCTL_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
export LLMCTL_ROOT

TEST_FAILS=0

# assert_eq <expected> <actual> <message>
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    printf '  ok: %s\n' "$3"
  else
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$3" "$1" "$2" >&2
    TEST_FAILS=$((TEST_FAILS+1))
  fi
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then
    printf '  ok: %s\n' "$3"
  else
    printf '  FAIL: %s\n    needle not found: %s\n    haystack: %.500s\n' "$3" "$2" "$1" >&2
    TEST_FAILS=$((TEST_FAILS+1))
  fi
}

# assert_file_contains <file> <needle> <message>
assert_file_contains() {
  if [[ -f "$1" ]] && grep -qF -- "$2" "$1"; then
    printf '  ok: %s\n' "$3"
  else
    printf '  FAIL: %s\n    %s not found in %s\n' "$3" "$2" "$1" >&2
    TEST_FAILS=$((TEST_FAILS+1))
  fi
}

# assert_rc <expected-rc> <message> <cmd...>
assert_rc() {
  local want="$1" msg="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "${want}" "${rc}" "${msg} (rc)"
}

# assert_file_exists <file> <message>
assert_file_exists() {
  if [[ -f "$1" ]]; then
    printf '  ok: %s\n' "$2"
  else
    printf '  FAIL: %s\n    file missing: %s\n' "$2" "$1" >&2
    TEST_FAILS=$((TEST_FAILS+1))
  fi
}

# assert_file_absent <file> <message>
assert_file_absent() {
  if [[ ! -e "$1" ]]; then
    printf '  ok: %s\n' "$2"
  else
    printf '  FAIL: %s\n    file should not exist: %s\n' "$2" "$1" >&2
    TEST_FAILS=$((TEST_FAILS+1))
  fi
}

# Isolated per-test environment. Call at the top of every test.
test_setup_env() {
  TEST_TMP="$(mktemp -d)"
  export LLMCTL_STATE_DIR="${TEST_TMP}/state"
  export LLMCTL_RUNTIME_DIR="${TEST_TMP}/state/run"
  export LLMCTL_CONFIG_DIR="${TEST_TMP}/config"
  export LLMCTL_DATA_DIR="${TEST_TMP}/data"
  export LLMCTL_MODELS_DIR="${TEST_TMP}/models"
  export LLMCTL_LOG_DIR="${TEST_TMP}/state/logs"
  export LLMCTL_VERIFY_DIR="${TEST_TMP}/state/verify"
  export LLMCTL_SERVICES_DIR="${TEST_TMP}/state/services"
  export LLMCTL_UNIT_DIR="${TEST_TMP}/systemd-user"
  export LLMCTL_PLIST_DIR="${TEST_TMP}/LaunchAgents"
  export NO_COLOR=1
  # Disabled by default for every hermetic test: _sched_wait_ready polls a
  # REAL http://127.0.0.1:<port>/v1/models after a start/switch, but every
  # existing fake-systemctl fixture's "start" verb only flips a state file -
  # it never binds a real listening socket, so leaving the production
  # default (60s) active here would make ordinary scheduler tests hang for
  # a full minute and then fail on an unrelated concern. A dedicated test
  # (test_scheduler_wait_ready.sh) exercises the real wait against a real,
  # deliberately-delayed HTTP fixture and sets its own non-zero timeout.
  export LLMCTL_READY_TIMEOUT=0
  # Hermetic by default: the port allocator / registry adapter (lib/portreg.sh)
  # is OFF for every test unless the test opts in (LLMCTL_PORTREG=1 plus an
  # LLMCTL_DECIDE_BIN it built itself). Otherwise a host that happens to hold
  # a built build/llmctl-decide would bind-test real documented ports (8080
  # is routinely taken by sibling projects) and change unrelated results.
  export LLMCTL_PORTREG=0
  unset LLMCTL_DECIDE_BIN LLMCTL_PORT_STRATEGY LLMCTL_PORT_RANGE LLMCTL_SERVICE_BACKEND_FILE
  mkdir -p "${LLMCTL_STATE_DIR}" "${LLMCTL_RUNTIME_DIR}"
}

test_teardown_env() {
  # `[[ ... ]] && cmd` as a bare statement returns the condition's own exit
  # status (1) when false, which - under this file's `set -e` - aborts the
  # calling script entirely the moment a test skips test_setup_env (TEST_TMP
  # unset) and calls test_finish directly. Wrapped in `if` so the function
  # always returns 0 regardless of whether TEST_TMP was ever set.
  if [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP}" ]]; then
    rm -rf "${TEST_TMP}"
  fi
}

# skip_suite <reason>
# C2-06: skip a WHOLE suite (tests/run_tests.sh prints SKIP, not PASS). Only legal before any assertion
# failed: a suite whose TEST_FAILS is already > 0 must not hide those failures behind a SKIP, so it exits 1.
skip_suite() {
  if [[ "${TEST_FAILS:-0}" -gt 0 ]]; then
    printf '  FAIL: skip_suite("%s") called after %d assertion failure(s); a suite that already failed cannot skip\n' "$1" "${TEST_FAILS}" >&2
    exit 1
  fi
  printf 'SKIP-SUITE: %s\n' "$1"
  exit 0
}

# assert_skip <reason> <message>
# 006-cli-daemon-wiring: an honest, printed, non-counted SKIP for an
# assertion this test genuinely cannot make in the current environment
# (Constitution §11.4.3: SKIP-with-reason is the correct fallback when
# required topology is absent; silent omission or a fabricated PASS are
# both forbidden). Never increments TEST_FAILS - a skip is neither a
# pass nor a failure of THIS test run, but it MUST be loud, not silent.
assert_skip() {
  printf '  SKIP: %s\n    reason: %s\n' "$2" "$1" >&2
}

# curl_has_http3 - the SAME predicate lib/cluster.sh uses (_cluster_http3_supported): does this curl list
# HTTP3 among its features? (G-089: a probe, never a hard-coded "this host has no HTTP/3".)
curl_has_http3() { curl --version 2>/dev/null | grep -qiE '(^| )HTTP3( |$)'; }

# cluster_cli_skip_reason <https://host:port>
# G-089 + G-106: can the product's CLI transport (lib/cluster.sh = curl, HTTP/3 when the curl supports it,
# explicit --cacert + client --cert/--key from the daemon's CLI certificate directory, full verification)
# complete a 2xx round trip with the daemon at <endpoint>? Prints the MEASURED reason and returns 0 when it
# cannot (callers then SKIP with that reason and keep the "unreachable" assertions); prints nothing and
# returns 1 when it can (callers then run the success path).
# Reasons: (1) the curl has no HTTP3 feature (parsed from `curl --version`); (2) HTTP3 curl present but a
# real request through lib/cluster.sh's own transport fails (curl exit code + message are quoted, not guessed).
# The probe goes through cluster::request itself - the SAME code the CLI uses - never a hand-built curl line.
cluster_cli_skip_reason() {
  local ep="$1" out rc=0
  if ! curl_has_http3; then
    printf 'curl --version lists no HTTP3 feature (Features: %s); llmctld serves its cluster API over HTTP/3-QUIC (UDP) only and this curl cannot speak QUIC (the certificate side - SANs, CA, client certificate - is provided by the daemon, G-106)' \
      "$(curl --version 2>/dev/null | sed -n 's/^Features: //p')"
    return 0
  fi
  out="$(LLMCTL_CLUSTER_ENDPOINT="${ep}" LLMCTL_CLUSTER_CERT_DIR="${LLMCTLD_CLI_CERT_DIR:-}" \
    bash -c 'source "$1/lib/cluster.sh"; cluster::request GET /v1/cluster/status' _ "${LLMCTL_ROOT}" 2>&1)" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    printf 'this curl has HTTP3 but a request through lib/cluster.sh (cluster CA + CLI client certificate from %s) fails: curl exit %s: %s' \
      "${LLMCTLD_CLI_CERT_DIR:-<unset>}" "${rc}" "$(printf '%s' "${out}" | head -c 240 | tr '\n' ' ')"
    return 0
  fi
  return 1
}

# cluster_curl_h3 <curl args...>
# Direct curl against the daemon with the SAME TLS inputs lib/cluster.sh uses (explicit --cacert and the CLI
# client certificate/key from LLMCTLD_CLI_CERT_DIR, HTTP/3, full verification). For tests that call a daemon
# route the CLI has no subcommand for (e.g. POST /v1/auth/token). Never passes -k.
cluster_curl_h3() {
  curl --http3 --cacert "${LLMCTLD_CLI_CERT_DIR}/ca.crt" --cert "${LLMCTLD_CLI_CERT_DIR}/client.crt" \
    --key "${LLMCTLD_CLI_CERT_DIR}/client.key" "$@"
}

# hostdep_begin <reason> / hostdep_end
# G-084: bracket assertions whose NUMBER depends on the host (a branch that runs only when llama-server
# is/is not built, only when go is installed ...). scripts/doc_counts.sh excludes `  ok:` lines between
# the markers from the count a docs page may claim, so documented counts compare host-independent
# assertions only. The markers are plain lines on stdout; nothing else reads them.
hostdep_begin() { printf 'HOSTDEP-BEGIN: %s\n' "$1"; }
hostdep_end() { printf 'HOSTDEP-END\n'; }

# llmctld_build
# 006-cli-daemon-wiring: builds the REAL llmctld binary once into
# TEST_TMP (never an in-process fake), printing its path on stdout.
# Mirrors llmctld/test/integration/cluster_bootstrap_test.go's own
# buildLLMCtld helper exactly (Constitution §11.4.27: every non-unit
# test interacts with the real, fully implemented system).
llmctld_build() {
  need_cmd go "install Go via your package manager"
  local bin_path="${TEST_TMP}/llmctld"
  ( cd "${LLMCTL_ROOT}/llmctld" && go build -o "${bin_path}" ./cmd/llmctld ) 1>&2
  echo "${bin_path}"
}

# llmctld_bootstrap <bin_path> <node_id> <api_port>
# 006-cli-daemon-wiring: starts a REAL llmctld "cluster bootstrap" node
# as a real OS process (never a mock), waits for its own real READY
# line (never a fixed sleep guess), and registers its PID + CA/state
# directory for the caller to use. Sets (via global vars, since bash has
# no struct return): LLMCTLD_PID, LLMCTLD_CA_CERT, LLMCTLD_CA_KEY,
# LLMCTLD_ADMIN_KEY_ID, LLMCTLD_ADMIN_KEY_SECRET, LLMCTLD_API_ADDR, LLMCTLD_CLI_CERT_DIR (G-106: the
# directory with ca.crt/client.crt/client.key the daemon wrote for the shell CLI),
# LLMCTLD_LOG. Caller MUST kill LLMCTLD_PID (e.g. via a trap) before
# exiting - see test_teardown_env's sibling discipline.
llmctld_bootstrap() {
  local bin_path="$1" node_id="$2" api_port="$3"
  local dir="${TEST_TMP}/${node_id}"
  mkdir -p "${dir}"
  LLMCTLD_CA_CERT="${dir}/ca.crt"
  LLMCTLD_CA_KEY="${dir}/ca.key"
  LLMCTLD_LOG="${dir}/node.log"

  LLMCTLD_JWT_SIGNING_KEY="test-signing-key-006-cli-daemon-wiring" \
    "${bin_path}" cluster bootstrap \
      -node-id "${node_id}" \
      -ca-cert "${LLMCTLD_CA_CERT}" \
      -ca-key "${LLMCTLD_CA_KEY}" \
      -raft-bind "127.0.0.1:0" \
      -api-bind "127.0.0.1:${api_port}" \
      -bootstrap-admin \
      -llmctl-path "${LLMCTL_ROOT}/bin/llmctl" \
      >"${LLMCTLD_LOG}" 2>&1 &
  LLMCTLD_PID=$!

  local waited=0
  while [[ "${waited}" -lt 100 ]]; do
    if grep -q '^READY ' "${LLMCTLD_LOG}" 2>/dev/null; then
      break
    fi
    if ! kill -0 "${LLMCTLD_PID}" 2>/dev/null; then
      printf 'llmctld_bootstrap: node %s exited before printing READY; log:\n' "${node_id}" >&2
      cat "${LLMCTLD_LOG}" >&2
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if ! grep -q '^READY ' "${LLMCTLD_LOG}" 2>/dev/null; then
    printf 'llmctld_bootstrap: node %s never printed READY within 10s; log:\n' "${node_id}" >&2
    cat "${LLMCTLD_LOG}" >&2
    return 1
  fi

  LLMCTLD_API_ADDR="$(grep -oP '(?<=api_addr=)\S+' "${LLMCTLD_LOG}" | head -1)"
  LLMCTLD_CLI_CERT_DIR="$(grep -oP '(?<=^CLI_CERT_DIR=)\S+' "${LLMCTLD_LOG}" | head -1)"
  LLMCTLD_ADMIN_KEY_ID="$(grep -oP '(?<=BOOTSTRAP_ADMIN_KEY_ID=)\S+' "${LLMCTLD_LOG}" | head -1)"
  LLMCTLD_ADMIN_KEY_SECRET="$(grep -oP '(?<=BOOTSTRAP_ADMIN_KEY_SECRET=)\S+' "${LLMCTLD_LOG}" | head -1)"
  export LLMCTLD_PID LLMCTLD_CA_CERT LLMCTLD_CA_KEY LLMCTLD_CLI_CERT_DIR LLMCTLD_LOG LLMCTLD_API_ADDR LLMCTLD_ADMIN_KEY_ID LLMCTLD_ADMIN_KEY_SECRET
}

# Finish a test file: exit non-zero when any assertion failed.
test_finish() {
  test_teardown_env
  if [[ "${TEST_FAILS}" -gt 0 ]]; then
    printf 'RESULT: FAIL (%d assertion failure(s))\n' "${TEST_FAILS}" >&2
    exit 1
  fi
  printf 'RESULT: PASS\n'
  exit 0
}
