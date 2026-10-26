#!/usr/bin/env bash
# test_isolation_slice_cleanup.sh - hermetic regression guard for the G-088 slice cleanup of the Go test
# llmctld/internal/isolation TestWrapCommand_RealSystemdRunInvocation (review of release/3.3.0, finding M-3).
#
# Defect it guards: the Go test's t.Cleanup ran `systemctl --user stop` on llmctl.slice and llmctl-tenant.slice
# whenever they were inactive before the test - REAL llmctl unit names the harness guard
# (tests/fixtures/guard/systemctl) refuses, so tests/test_systemd_cleanliness.sh failed (guard log + leftover slices)
# on a host whose real slices were inactive, and passed (masking it) once they were active.
#
# Method: NO real unit is touched. The harness guard stays first on PATH, but LLMCTL_TEST_REAL_SYSTEMCTL points at a
# fake systemctl that answers every `is-active` with "inactive" (exit 3, the worst case: nothing pre-exists) and logs
# every call; a fake systemd-run on PATH logs its argv and exits 0. The Go test is then run for real.
# Asserted: the guard refused nothing; no stop of a real llmctl unit name or of any llmctl-tenant-* slice reached the
# (fake) service manager; the slice the test asked systemd-run for is a test-only name, and exactly that name is
# stopped in cleanup. Control: the fake systemctl's is-active/stop are really reached (log not empty), so a clean
# result is not an artifact of the fakes being bypassed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT

if ! command -v go >/dev/null 2>&1; then
  echo "SKIP-SUITE: go is not installed: the isolation Go test cannot be run"
  exit 0
fi

FAKE="${TEST_TMP}/fakebin"; mkdir -p "${FAKE}"
SCTL_LOG="${TEST_TMP}/fake-systemctl.log"; SRUN_LOG="${TEST_TMP}/fake-systemd-run.log"
: > "${SCTL_LOG}"; : > "${SRUN_LOG}"
cat > "${FAKE}/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${SCTL_LOG}"
for a in "\$@"; do [[ "\${a}" == is-active ]] && exit 3; done
exit 0
EOF
cat > "${FAKE}/systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${SRUN_LOG}"
exit 0
EOF
chmod 700 "${FAKE}/systemctl" "${FAKE}/systemd-run"
# The guard (already first on PATH from test_setup_env) execs this fake instead of the host's systemctl.
export LLMCTL_TEST_REAL_SYSTEMCTL="${FAKE}/systemctl"
# systemd-run is resolved by exec.LookPath in the Go test: the fake goes before the host's one. The guard dir stays
# ahead of it so `systemctl` still resolves to the guard.
export PATH="${TESTS_DIR}/fixtures/guard:${FAKE}:${PATH}"
[[ "$(command -v systemctl)" == "${TESTS_DIR}/fixtures/guard/systemctl" ]] || { echo "setup: guard not first on PATH" >&2; exit 1; }

( cd "${LLMCTL_ROOT}/llmctld" && go test ./internal/isolation -run 'TestWrapCommand_RealSystemdRunInvocation$' -count=1 -v ) \
  >"${TEST_TMP}/go.out" 2>&1 && grc=0 || grc=$?
assert_eq 0 "${grc}" "TestWrapCommand_RealSystemdRunInvocation green against the fakes (rc=${grc}; $(tail -3 "${TEST_TMP}/go.out" | tr '\n' ' '))"
assert_contains "$(cat "${TEST_TMP}/go.out")" "--- PASS: TestWrapCommand_RealSystemdRunInvocation" "the Go test really ran (not skipped)"

# control: the fakes were reached through the guard
assert_contains "$(cat "${SCTL_LOG}")" "is-active" "control: the Go test's is-active probes reached the fake systemctl"
assert_contains "$(cat "${SRUN_LOG}")" "--scope" "control: the Go test invoked the fake systemd-run"

guard_hits="$(cat "${LLMCTL_TEST_GUARD_LOG}" 2>/dev/null || true)"
assert_eq "" "${guard_hits}" "the harness guard refused nothing (no stop of a real llmctl unit name)"
: > "${LLMCTL_TEST_GUARD_LOG}"   # consumed here; test_finish would otherwise count it a second time

real_stops="$(grep -E '(^| )stop( |$)' "${SCTL_LOG}" | grep -E '(^| )(llmctl\.slice|llmctl-tenant\.slice|llmctl-tenant-[^ ]*\.slice)( |$)' || true)"
assert_eq "" "${real_stops}" "cleanup stops no llmctl.slice / llmctl-tenant.slice / llmctl-tenant-*.slice"

slice_arg="$(grep -oE -- '--slice=[^ ]+' "${SRUN_LOG}" | head -1 || true)"
slice="${slice_arg#--slice=}"
case "${slice}" in
  llmctltest_*.slice) assert_eq ok ok "systemd-run was given a test-only slice (${slice})" ;;
  *) assert_eq "llmctltest_*.slice" "${slice}" "systemd-run was given a test-only slice" ;;
esac
assert_eq "0" "$(grep -c -- '--slice=llmctl-tenant-' "${SRUN_LOG}" || true)" "systemd-run never received the production llmctl-tenant-* slice"
stops="$(grep -E '(^| )stop( |$)' "${SCTL_LOG}" || true)"
assert_contains "${stops}" "${slice:-<none>}" "cleanup stops exactly the test-only slice it created"
assert_eq "1" "$(grep -cE '(^| )stop( |$)' "${SCTL_LOG}" || true)" "cleanup issues exactly one stop"
test_finish
