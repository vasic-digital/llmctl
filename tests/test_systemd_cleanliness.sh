#!/usr/bin/env bash
# test_systemd_cleanliness.sh - G-088: the suites that talk to the systemd --user manager must leave no
# llmctl* unit behind (no llmctl*.slice, no failed/active transient llmctl-* unit). Method: snapshot the
# names `systemctl --user list-units --all 'llmctl*'` reports, run the leak-prone suites, snapshot again,
# assert nothing NEW remains (after - before = empty). Only llmctl* names are compared (other tenants of the
# user manager - podman, tmux, desktop - are none of this test's business).
# The detector is proven with a control needle: a deliberately leaking transient unit (exact name, removed
# by exact name) MUST be reported, otherwise a clean result would mean nothing.
# Suites exercised: tests/test_unit_hardening.sh (starts transient units, some of which fail to start) and,
# when go is installed, llmctld/internal/isolation TestWrapCommand_RealSystemdRunInvocation (creates tenant
# slices). SKIPs (SKIP-SUITE) when no systemd --user manager is reachable.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
LEAK="llmctl-cleanliness-leak-$$"
cleanup() {
  systemctl --user stop "${LEAK}.service" >/dev/null 2>&1 || true
  systemctl --user reset-failed "${LEAK}.service" >/dev/null 2>&1 || true
  test_teardown_env
}
trap cleanup EXIT

if ! command -v systemd-run >/dev/null 2>&1 || ! systemd-run --user --wait --pipe --quiet --collect /bin/true >/dev/null 2>&1; then
  echo "SKIP-SUITE: no reachable systemd --user manager: cannot observe leftover units"
  exit 0
fi

snap() { systemctl --user list-units --all --plain --no-legend 'llmctl*' 2>/dev/null | awk '{print $1}' | sed 's/^●//' | grep -v '^$' | sort -u || true; }
new_since() { comm -13 <(printf '%s\n' "$1") <(printf '%s\n' "$2") | grep -v '^$' || true; }

# ---- control needle: the detector must see a leak ----
B0="$(snap)"
systemd-run --user --wait --pipe --quiet --unit="${LEAK}" -p "RuntimeMaxSec=0" /bin/false >/dev/null 2>&1 || true
A0="$(snap)"
assert_contains "$(new_since "${B0}" "${A0}")" "${LEAK}.service" "control: a deliberately leaked failed llmctl-* unit IS reported by the detector"
systemctl --user reset-failed "${LEAK}.service" >/dev/null 2>&1 || true
assert_eq "" "$(new_since "${B0}" "$(snap)")" "control: after exact-name reset-failed the leak is gone"

# ---- the suites ----
BEFORE="$(snap)"
echo "llmctl* units before: $(printf '%s' "${BEFORE}" | grep -c . || true)"
bash "${LLMCTL_ROOT}/tests/test_unit_hardening.sh" >"${TEST_TMP}/hardening.out" 2>&1 && hrc=0 || hrc=$?
assert_eq 0 "${hrc}" "test_unit_hardening.sh ran green (rc=${hrc})"
AFTER_H="$(snap)"
assert_eq "" "$(new_since "${BEFORE}" "${AFTER_H}")" "test_unit_hardening.sh leaves no new llmctl* unit behind"

if command -v go >/dev/null 2>&1; then
  slices_before="$(grep -c '^llmctl.*\.slice$' <<<"${BEFORE}" || true)"
  ( cd "${LLMCTL_ROOT}/llmctld" && go test ./internal/isolation -run TestWrapCommand_RealSystemdRunInvocation -count=1 ) >"${TEST_TMP}/go.out" 2>&1 && grc=0 || grc=$?
  assert_eq 0 "${grc}" "TestWrapCommand_RealSystemdRunInvocation green (rc=${grc})"
  assert_eq "" "$(new_since "${BEFORE}" "$(snap)")" "the isolation test leaves no new llmctl*.slice or unit behind"
  if [[ "${slices_before}" != 0 ]]; then
    assert_skip "llmctl*.slice units were already active before this run (a real tenant or an earlier leak): the 'created by this run' part of the slice cleanup is not provable now" "slice teardown proof"
  fi
else
  assert_skip "go is not installed" "isolation slice teardown"
fi
test_finish
