#!/usr/bin/env bash
# test_harness_systemctl_guard.sh - review 2026-10-15 finding 11: the test harness never lets a suite reach the REAL
# service manager with a real llmctl unit name (tests/fixtures/guard/systemctl, installed by tests/helpers.sh). Every
# probe below names a unit that does not exist or only READS, so even a broken guard changes nothing on the host.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
command -v systemctl >/dev/null 2>&1 || skip_suite "no systemctl on this host (nothing to guard)"
GUARD="${LLMCTL_ROOT}/tests/fixtures/guard/systemctl"
assert_eq "${GUARD}" "$(command -v systemctl)" "the harness guard is first on PATH"
assert_eq 1 "$([[ -n "${LLMCTL_TEST_REAL_SYSTEMCTL}" && "${LLMCTL_TEST_REAL_SYSTEMCTL}" != "${GUARD}" ]] && echo 1 || echo 0)" "the real systemctl is remembered (${LLMCTL_TEST_REAL_SYSTEMCTL})"
for u in llmctl-llama@guard-selftest-nonexistent.service llmctl-onnx@guard-selftest-nonexistent.service \
         llmctl-colibri@guard-selftest-nonexistent.service llmctl-decide-gateway-guard-selftest.service; do
  for v in stop disable restart kill; do
    rc=0; systemctl --user "${v}" "${u}" >/dev/null 2>&1 || rc=$?
    assert_eq 1 "${rc}" "refused: systemctl --user ${v} ${u}"
  done
done
assert_eq 16 "$(wc -l < "${LLMCTL_TEST_GUARD_LOG}")" "every refusal is logged (test_finish fails a suite with any)"
: > "${LLMCTL_TEST_GUARD_LOG}"     # this suite's refusals were deliberate
rc=0; systemctl --version >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "a read (systemctl --version) passes through to the real binary"
rc=0; out="$(systemctl --user is-active llmctl-llama@guard-selftest-nonexistent.service 2>/dev/null)" || rc=$?
assert_eq "inactive" "${out}" "is-active (a read) of a real-pattern name passes through"
# a nested suite (the mutants harness runs suites from a suite) keeps the parent's real binary, never the guard itself
nested="$(bash -c 'source "$1/tests/helpers.sh"; test_setup_env; printf "%s" "${LLMCTL_TEST_REAL_SYSTEMCTL}"; test_teardown_env' _ "${LLMCTL_ROOT}")"
assert_eq "${LLMCTL_TEST_REAL_SYSTEMCTL}" "${nested}" "nested harness: the real systemctl is not replaced by the guard"
test_finish
