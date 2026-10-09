#!/usr/bin/env bash
# test_decide_serve_enable.sh - `llmctl decide serve --enable [--now]` / `--disable` (boot-time gateway service,
# G-041 front end / G-069 / anton 2026-10-09 finding 2). systemctl and loginctl are STUBS that only log their
# argv: no real unit is ever installed, enabled or started. The Linux unit directory is a temp dir.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
mkdir -p "${TEST_TMP}/stubs"
printf '#!/bin/sh\nexit 0\n' > "${TEST_TMP}/stubs/llmctl-decide"; chmod +x "${TEST_TMP}/stubs/llmctl-decide"
export LLMCTL_DECIDE_BIN="${TEST_TMP}/stubs/llmctl-decide"
SYSLOG="${TEST_TMP}/systemctl.log"
printf '#!/bin/sh\necho "systemctl $*" >> "%s"\nexit 0\n' "${SYSLOG}" > "${TEST_TMP}/stubs/systemctl"
printf '#!/bin/sh\necho "loginctl $*" >> "%s"\nexit 0\n' "${SYSLOG}" > "${TEST_TMP}/stubs/loginctl"
chmod +x "${TEST_TMP}/stubs/systemctl" "${TEST_TMP}/stubs/loginctl"
export PATH="${TEST_TMP}/stubs:${PATH}"
CLI="${LLMCTL_ROOT}/bin/llmctl"
GU="${LLMCTL_UNIT_DIR}/llmctl-decide-gateway.service"
run() { RC=0; OUT="$("${CLI}" "$@" 2>&1)" || RC=$?; }

if [[ "$(uname -s)" == "Linux" ]]; then
echo "== Linux: --enable installs, enables, starts (stubbed systemctl) =="
: > "${SYSLOG}"
run decide serve --enable
assert_eq "0" "${RC}" "serve --enable exits 0"
assert_file_exists "${GU}" "the gateway unit was written into the (temp) user unit dir"
assert_file_contains "${SYSLOG}" "systemctl --user enable llmctl-decide-gateway.service" "enable went to the service manager"
assert_file_contains "${SYSLOG}" "systemctl --user start llmctl-decide-gateway.service" "start went to the service manager"
assert_file_contains "${SYSLOG}" "systemctl --user daemon-reload" "daemon-reload first"
BODY1="$(cat "${GU}")"

echo "== idempotent: a second --enable --now is the same result =="
: > "${SYSLOG}"
run decide serve --enable --now
assert_eq "0" "${RC}" "serve --enable --now exits 0 on an already enabled gateway"
assert_eq "${BODY1}" "$(cat "${GU}")" "unit body unchanged by the second enable"
assert_file_contains "${SYSLOG}" "systemctl --user enable llmctl-decide-gateway.service" "enable re-issued (systemctl enable is itself idempotent)"

echo "== re-enable applies a CHANGED unit (restart, never start+restart), and does not restart an unchanged one =="
: > "${SYSLOG}"
run decide serve --enable
if grep -q "restart" "${SYSLOG}"; then printf '  FAIL: unchanged unit was restarted\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: unchanged unit: no restart\n'; fi
printf '# stale\n' >> "${GU}"
: > "${SYSLOG}"
run decide serve --enable
assert_eq "0" "${RC}" "re-enable over a changed unit exits 0"
assert_file_contains "${SYSLOG}" "systemctl --user restart llmctl-decide-gateway.service" "changed unit content is applied by restart (also starts a stopped gateway)"
if grep -q "systemctl --user start llmctl-decide-gateway.service" "${SYSLOG}"; then printf '  FAIL: changed unit: gateway started AND restarted (double start)\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: changed unit: single start path (no start before restart)\n'; fi
assert_eq "${BODY1}" "$(cat "${GU}")" "unit rewritten to the current template"

echo "== --disable removes the unit =="
: > "${SYSLOG}"
run decide serve --disable
assert_eq "0" "${RC}" "serve --disable exits 0"
assert_file_absent "${GU}" "unit removed"
assert_file_contains "${SYSLOG}" "systemctl --user stop llmctl-decide-gateway.service" "stopped"
assert_file_contains "${SYSLOG}" "systemctl --user disable llmctl-decide-gateway.service" "disabled"
run decide serve --disable
assert_eq "0" "${RC}" "serve --disable on an already removed gateway is a clean no-op (idempotent)"

echo "== refuses while an engine unit template is stale (same style as the other refusals) =="
printf '[Unit]\nDescription=x\n[Service]\nExecStart=/bin/true\nStartLimitIntervalSec=60\nStartLimitBurst=5\n' > "${LLMCTL_UNIT_DIR}/llmctl-llama@.service"
: > "${SYSLOG}"
run decide serve --enable
if [[ "${RC}" -ne 0 ]]; then printf '  ok: stale template refused (rc %s)\n' "${RC}"; else printf '  FAIL: enable proceeded with a stale engine template\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_contains "${OUT}" "refusing to enable" "message says it refuses"
assert_contains "${OUT}" "llmctl install" "message names the remedy (llmctl install)"
assert_contains "${OUT}" "llmctl-llama@.service" "message names the stale unit"
if grep -q "enable llmctl-decide-gateway" "${SYSLOG}"; then printf '  FAIL: the gateway was enabled despite the refusal\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: nothing was enabled on refusal\n'; fi
assert_file_absent "${GU}" "no unit written on refusal"
rm -f "${LLMCTL_UNIT_DIR}/llmctl-llama@.service"

echo "== dry run touches nothing =="
assert_file_absent "${GU}" "precondition: no unit file"
OUT="$(LLMCTL_DRY_RUN=1 "${CLI}" decide serve --enable 2>&1)"
assert_contains "${OUT}" "[dry-run] systemctl --user enable llmctl-decide-gateway.service" "dry-run prints the enable"
assert_file_absent "${GU}" "dry-run --enable wrote NO unit file"
assert_contains "${OUT}" "[dry-run] write" "dry-run says what it would write"
fi

echo "== macOS backend (file-level, dry-run; no Mac in this suite) =="
OUT="$(LLMCTL_DRY_RUN=1 LLMCTL_SERVICE_BACKEND_FILE="${LLMCTL_ROOT}/lib/service_macos.sh" "${CLI}" decide serve --enable 2>&1)" || true
assert_contains "${OUT}" "bootstrap" "launchd path: launchctl bootstrap"
assert_contains "${OUT}" "launchctl bootout" "launchd path: an existing agent is booted out first (idempotent re-enable)"
b_out="${OUT%%launchctl bootstrap*}"; ordered=1; [[ "${b_out}" == *"launchctl bootout"* ]] || ordered=0
assert_eq "1" "${ordered}" "bootout precedes bootstrap"
MACPL="$(LLMCTL_DRY_RUN=1 LLMCTL_SERVICE_BACKEND_FILE="${LLMCTL_ROOT}/lib/service_macos.sh" "${CLI}" decide serve --enable 2>&1 >/dev/null; find "${TEST_TMP}" -name 'com.llmctl.decide*gateway*.plist' 2>/dev/null | head -1)"
assert_eq "" "${MACPL}" "macOS dry-run --enable wrote NO plist"
OUT="$(LLMCTL_DRY_RUN=1 LLMCTL_SERVICE_BACKEND_FILE="${LLMCTL_ROOT}/lib/service_macos.sh" "${CLI}" decide serve --disable 2>&1)" || true
assert_contains "${OUT}" "bootout" "launchd path: launchctl bootout"

echo "== usage errors =="
run decide serve --enable --disable;    assert_eq "2" "${RC}" "--enable with --disable is a usage error (rc 2)"
run decide serve --now;                 assert_eq "2" "${RC}" "--now alone is a usage error (rc 2)"
run decide serve --enable --foreground; assert_eq "2" "${RC}" "--enable with --foreground is a usage error (rc 2)"
run decide serve --disable --stop;      assert_eq "2" "${RC}" "--disable with --stop is a usage error (rc 2)"

echo "== help text =="
run decide help
assert_contains "${OUT}" "serve --enable" "decide help documents --enable"
assert_contains "${OUT}" "llmctl decide scale <profile> <N>" "decide help lists the scale subcommand"
assert_contains "${OUT}" "--disable" "decide help documents --disable"

[[ "${TEST_FAILS}" -eq 0 ]] || { echo "FAILED: ${TEST_FAILS}" >&2; exit 1; }
echo "OK"
