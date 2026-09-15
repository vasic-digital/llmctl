#!/usr/bin/env bash
# test_run_tests_format.sh - verifies tests/run_tests.sh emits grep-parseable
# CMD:/OUTPUT:/EXIT: markers for every test file it runs (Phase 4 T021,
# spec.md FR-002: "producing deterministic evidence (exit codes, raw output)
# for every test").
#
# Runs a COPY of run_tests.sh against an isolated temp directory containing
# one fake test_*.sh, never the real tests/ dir - this script itself matches
# the test_*.sh glob run_tests.sh enumerates, so invoking the real harness
# from inside a test it would itself re-enumerate causes unbounded recursive
# self-invocation. Copying the harness into an isolated directory with a
# single controlled fixture avoids that while still exercising the real,
# unmodified harness logic as a real subprocess (anti-bluff: no mocking of
# the code under test).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

harness_tmp="$(mktemp -d)"
trap 'rm -rf "${harness_tmp}"' EXIT

cp "${LLMCTL_ROOT}/tests/run_tests.sh" "${harness_tmp}/run_tests.sh"
cat > "${harness_tmp}/test_fake_pass.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake test body output"
exit 0
EOF
chmod +x "${harness_tmp}/test_fake_pass.sh" "${harness_tmp}/run_tests.sh"

out="$(bash "${harness_tmp}/run_tests.sh" 2>&1)" && rc=0 || rc=$?

assert_eq 0 "${rc}" "isolated harness exits 0 on an all-passing fake suite"
assert_contains "${out}" "CMD:  bash ${harness_tmp}/test_fake_pass.sh" "CMD: line names the real invoked command"
assert_contains "${out}" "OUTPUT:" "OUTPUT: label present (grep-parseable evidence marker, FR-002)"
assert_contains "${out}" "fake test body output" "raw subprocess output is captured"
assert_contains "${out}" "EXIT: 0" "EXIT: line present with the real captured exit code"

# The three markers must appear in this order for one test block, not just
# be present anywhere in the whole-run output (a naive `assert_contains`
# on each label alone would pass even if OUTPUT: appeared, say, only in the
# SUMMARY section unrelated to any individual test).
cmd_line="$(grep -n "^CMD:" <<<"${out}" | head -1 | cut -d: -f1)"
output_line="$(grep -n "^OUTPUT:" <<<"${out}" | head -1 | cut -d: -f1)"
exit_line="$(grep -n "^EXIT:" <<<"${out}" | head -1 | cut -d: -f1)"
if [[ -n "${cmd_line}" && -n "${output_line}" && -n "${exit_line}" \
      && "${cmd_line}" -lt "${output_line}" && "${output_line}" -lt "${exit_line}" ]]; then
  printf '  ok: %s\n' "CMD: / OUTPUT: / EXIT: appear in that order for one test block"
else
  printf '  FAIL: %s\n    cmd_line=%s output_line=%s exit_line=%s\n' \
    "CMD: / OUTPUT: / EXIT: appear in that order for one test block" \
    "${cmd_line:-<missing>}" "${output_line:-<missing>}" "${exit_line:-<missing>}" >&2
  TEST_FAILS=$((TEST_FAILS+1))
fi

test_finish
