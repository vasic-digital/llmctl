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
echo "  ok: the fake suite asserted something"
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

# --- C-20: a SKIP is not a PASS -----------------------------------------------------------------
cat > "${harness_tmp}/test_fake_skip.sh" <<'EOF'
#!/usr/bin/env bash
echo "== preparing =="
echo "SKIP-SUITE: podman is not installed"
exit 0
EOF
cat > "${harness_tmp}/test_fake_partial.sh" <<'EOF'
#!/usr/bin/env bash
echo "  ok: something real"
printf '  SKIP: %s\n    reason: %s\n' "network install" "LLMCTL_TEST_NETWORK!=1"
exit 0
EOF
out="$(bash "${harness_tmp}/run_tests.sh" 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "a SKIP never fails the run (exit 0)"
assert_contains "${out}" "SKIP  test_fake_skip.sh (podman is not installed)" "a skipped suite is reported SKIP with its reason, not PASS"
if grep -q '^PASS  test_fake_skip.sh' <<<"${out}"; then
  printf '  FAIL: %s\n' "a skipped suite must not appear as PASS" >&2; TEST_FAILS=$((TEST_FAILS+1))
else
  printf '  ok: %s\n' "the skipped suite is not listed as PASS"
fi
assert_contains "${out}" "PASS  test_fake_partial.sh (1 skipped assertion(s))" "a passing suite that skipped assertions says so"
assert_contains "${out}" "NOT RUN (skipped suites, not passes):" "the summary lists the skipped suites separately"
assert_contains "${out}" "PASS: 2  FAIL: 0  SKIP: 1" "the totals count SKIP on its own"
cat > "${harness_tmp}/test_fake_allskipped.sh" <<'EOF'
#!/usr/bin/env bash
printf '  SKIP: %s\n    reason: %s\n' "GPU measurement" "nvidia-smi not present"
echo "RESULT: PASS"
exit 0
EOF
out="$(bash "${harness_tmp}/run_tests.sh" 2>&1)" && rc=0 || rc=$?
assert_contains "${out}" "SKIP  test_fake_allskipped.sh (every assertion skipped: nvidia-smi not present)" "a suite that asserted nothing and only skipped is a SKIP, not a PASS"
assert_contains "${out}" "PASS: 2  FAIL: 0  SKIP: 2" "...and counted as a skip"
# doc_counts.sh understands the same contract (a skipped suite is not "stale")
dc="$(mktemp -d)"; mkdir -p "${dc}/scripts" "${dc}/tests" "${dc}/docs/scripts"
cp "${LLMCTL_ROOT}/scripts/doc_counts.sh" "${dc}/scripts/"
cp "${harness_tmp}/test_fake_skip.sh" "${dc}/tests/test_fakeskip.sh"
printf 'documents **99 passing** assertions\n' > "${dc}/docs/scripts/test_fakeskip.md"
rc=0; dout="$(bash "${dc}/scripts/doc_counts.sh" --check fakeskip 2>&1)" || rc=$?
assert_contains "${dout}" "status=skipped-suite" "doc_counts reports a SKIP-SUITE suite as skipped-suite"
assert_eq 0 "${rc}" "...and does not call its page stale"
rm -rf "${dc}"
cat > "${harness_tmp}/test_fake_fail_after_skip_word.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP-SUITE: pretending"
exit 3
EOF
out="$(bash "${harness_tmp}/run_tests.sh" 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "a non-zero exit is a FAIL even if the output carries the skip marker"
assert_contains "${out}" "FAIL  test_fake_fail_after_skip_word.sh (exit 3)" "...and is reported FAIL"

# --- C2-06 / C2-10: an exit-0 suite that printed FAIL lines, or SKIP-SUITE after assertions ran, is a FAILURE ------
# (a lost assertion counter - an assertion run in a subshell - leaves "  FAIL:" in the output yet exit 0)
rm -f "${harness_tmp}/test_fake_fail_after_skip_word.sh"      # its exit 3 would make the rc assertion below vacuous
cat > "${harness_tmp}/test_fake_lostcounter.sh" <<'EOF'
#!/usr/bin/env bash
echo "  ok: one real assertion"
echo "  FAIL: an assertion that failed inside a subshell" >&2
exit 0
EOF
cat > "${harness_tmp}/test_fake_skip_after_assert.sh" <<'EOF'
#!/usr/bin/env bash
echo "  ok: a classifier assertion that already ran"
echo "SKIP-SUITE: rootless containers unavailable"
exit 0
EOF
cat > "${harness_tmp}/test_fake_skip_after_fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "  FAIL: a classifier assertion that failed" >&2
echo "SKIP-SUITE: rootless containers unavailable"
exit 0
EOF
out="$(bash "${harness_tmp}/run_tests.sh" 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "C2-06: the harness exits 1 when an exit-0 suite printed a FAIL line"
assert_contains "${out}" "FAIL  test_fake_lostcounter.sh" "C2-06: an exit-0 suite with a '  FAIL:' line is reported FAIL"
assert_contains "${out}" "FAIL  test_fake_skip_after_assert.sh" "C2-06: SKIP-SUITE after assertions ran is a FAIL, not a SKIP"
assert_contains "${out}" "FAIL  test_fake_skip_after_fail.sh" "C2-06: SKIP-SUITE after a failed assertion is a FAIL, not a SKIP"
assert_contains "${out}" "SKIP  test_fake_skip.sh (podman is not installed)" "C2-06 control: a SKIP-SUITE emitted before any assertion is still a SKIP"
rm -f "${harness_tmp}/test_fake_lostcounter.sh" "${harness_tmp}/test_fake_skip_after_assert.sh" "${harness_tmp}/test_fake_skip_after_fail.sh"

# --- C3-11: a suite that asserted NOTHING, printed RESULT: FAIL, or asserted after SKIP-SUITE is not a PASS ---------
# (and the FAIL-line detector tolerates a tab indent, ANSI colour and a missing space after the colon)
cat > "${harness_tmp}/test_fake_silent.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${harness_tmp}/test_fake_resultfail.sh" <<'EOF'
#!/usr/bin/env bash
echo "  ok: one assertion"
echo "RESULT: FAIL (3 assertion failure(s))"
exit 0
EOF
cat > "${harness_tmp}/test_fake_skip_then_assert.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP-SUITE: pretending to skip"
echo "  ok: ...but it kept asserting"
exit 0
EOF
printf '#!/usr/bin/env bash\necho "  ok: a"\nprintf "\\tFAIL: tab-indented failure\\n" >&2\nexit 0\n' > "${harness_tmp}/test_fake_tabfail.sh"
printf '#!/usr/bin/env bash\necho "  ok: a"\nprintf "\\033[31m  FAIL: coloured failure\\033[0m\\n" >&2\nexit 0\n' > "${harness_tmp}/test_fake_ansifail.sh"
printf '#!/usr/bin/env bash\necho "  ok: a"\necho "  FAIL:nospace" >&2\nexit 0\n' > "${harness_tmp}/test_fake_nospacefail.sh"
out="$(bash "${harness_tmp}/run_tests.sh" 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "C3-11: the harness exits 1"
assert_contains "${out}" "FAIL  test_fake_silent.sh" "C3-11: an exit-0 suite that printed nothing is FAIL (asserted nothing), not PASS"
assert_contains "${out}" "asserted nothing" "C3-11: ...and the reason says so"
assert_contains "${out}" "FAIL  test_fake_resultfail.sh" "C3-11: 'RESULT: FAIL' with exit 0 is FAIL"
assert_contains "${out}" "FAIL  test_fake_skip_then_assert.sh" "C3-11: assertions AFTER SKIP-SUITE make the suite FAIL, not SKIP"
assert_contains "${out}" "FAIL  test_fake_tabfail.sh" "C3-11: a tab-indented FAIL line is seen"
assert_contains "${out}" "FAIL  test_fake_ansifail.sh" "C3-11: an ANSI-coloured FAIL line is seen"
assert_contains "${out}" "FAIL  test_fake_nospacefail.sh" "C3-11: '  FAIL:x' (no space) is seen"
assert_contains "${out}" "PASS  test_fake_pass.sh" "C3-11 control: a normal suite (ok line, exit 0) is still PASS"
assert_contains "${out}" "SKIP  test_fake_skip.sh (podman is not installed)" "C3-11 control: a SKIP-SUITE before any assertion is still SKIP"
rm -f "${harness_tmp}"/test_fake_silent.sh "${harness_tmp}"/test_fake_resultfail.sh "${harness_tmp}"/test_fake_skip_then_assert.sh "${harness_tmp}"/test_fake_tabfail.sh "${harness_tmp}"/test_fake_ansifail.sh "${harness_tmp}"/test_fake_nospacefail.sh

# helpers.sh skip_suite: refuses to skip a suite whose assertions already failed
sk="$(bash -c 'source "$1/tests/helpers.sh"; TEST_FAILS=1; skip_suite "no podman"' _ "${LLMCTL_ROOT}" 2>&1)" && skrc=0 || skrc=$?
assert_eq 1 "${skrc}" "C2-06: skip_suite exits 1 when TEST_FAILS>0"
assert_contains "${sk}" "FAIL" "C2-06: ...and says why"
sk="$(bash -c 'source "$1/tests/helpers.sh"; skip_suite "no podman"' _ "${LLMCTL_ROOT}" 2>&1)" && skrc=0 || skrc=$?
assert_eq 0 "${skrc}" "C2-06 control: skip_suite with no failures exits 0"
assert_contains "${sk}" "SKIP-SUITE: no podman" "C2-06 control: ...printing the SKIP-SUITE line"

# doc_counts: the same lost-counter shape is `inconsistent` and exits 2
dc="$(mktemp -d)"; mkdir -p "${dc}/scripts" "${dc}/tests" "${dc}/docs/scripts"
cp "${LLMCTL_ROOT}/scripts/doc_counts.sh" "${dc}/scripts/"
printf '#!/usr/bin/env bash\necho "  ok: a"\necho "  FAIL: lost" >&2\nexit 0\n' > "${dc}/tests/test_lostc.sh"
printf '#!/usr/bin/env bash\necho "  ok: a"\necho "SKIP-SUITE: late"\nexit 0\n' > "${dc}/tests/test_lateskip.sh"
printf '#!/usr/bin/env bash\necho "  ok: a"\nexit 0\n' > "${dc}/tests/test_fine.sh"
rc=0; dout="$(bash "${dc}/scripts/doc_counts.sh" lostc 2>&1)" || rc=$?
assert_contains "${dout}" "status=inconsistent" "C2-10: an exit-0 suite with a FAIL line is status=inconsistent"
assert_eq 2 "${rc}" "C2-10: ...and doc_counts exits 2"
rc=0; dout="$(bash "${dc}/scripts/doc_counts.sh" lateskip 2>&1)" || rc=$?
assert_contains "${dout}" "status=inconsistent" "C2-10: SKIP-SUITE after assertions is status=inconsistent"
assert_eq 2 "${rc}" "C2-10: ...exit 2"
rc=0; dout="$(bash "${dc}/scripts/doc_counts.sh" fine 2>&1)" || rc=$?
assert_eq 0 "${rc}" "C2-10 control: a consistent suite exits 0"
case "${dout}" in *inconsistent*) printf '  FAIL: control suite flagged inconsistent\n' >&2; TEST_FAILS=$((TEST_FAILS+1)) ;; *) printf '  ok: control suite not flagged\n' ;; esac
rm -rf "${dc}"

test_finish
