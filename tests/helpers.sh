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
# LLMCTLD_ADMIN_KEY_ID, LLMCTLD_ADMIN_KEY_SECRET, LLMCTLD_API_ADDR,
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
  LLMCTLD_ADMIN_KEY_ID="$(grep -oP '(?<=BOOTSTRAP_ADMIN_KEY_ID=)\S+' "${LLMCTLD_LOG}" | head -1)"
  LLMCTLD_ADMIN_KEY_SECRET="$(grep -oP '(?<=BOOTSTRAP_ADMIN_KEY_SECRET=)\S+' "${LLMCTLD_LOG}" | head -1)"
  export LLMCTLD_PID LLMCTLD_CA_CERT LLMCTLD_CA_KEY LLMCTLD_LOG LLMCTLD_API_ADDR LLMCTLD_ADMIN_KEY_ID LLMCTLD_ADMIN_KEY_SECRET
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
