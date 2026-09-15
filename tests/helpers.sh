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
