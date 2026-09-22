#!/usr/bin/env bash
# test_install_script_e2e.sh - RED/GREEN proof for scripts/install.sh, the
# one-command bootstrap that closes the gap identified in this session:
# llmctl already has full systemd --user integration (setup/download/
# install/enable, the last of which already calls `loginctl enable-linger`
# internally per lib/service_linux.sh) and it is already proven working
# end-to-end on a real host, but there was no SINGLE command chaining
# setup -> download -> install -> enable -> linger-verification -> status
# for a brand-new user or a fresh redeploy.
#
# This test proves scripts/install.sh invokes the real `bin/llmctl`
# subcommand chain in the RIGHT ORDER - setup, models download, install,
# enable, status - and correctly detects+reports BOTH the linger-confirmed
# happy path AND the linger-NOT-confirmed failure path, entirely
# hermetically: a fake `llmctl` (a thin argv-recording stub, mirroring
# this suite's fake-systemctl idiom in test_scheduler_reboot_
# reconciliation.sh) stands in on PATH-equivalent (via LLMCTL_BIN
# override... no such override exists, so instead a fake bin/llmctl is
# assembled inside a synthetic root and scripts/install.sh's own
# `_install_root`-relative invocation is exercised against it) so no real
# engine build, model download, or systemd unit is ever touched, and a
# fake `loginctl` stands in on PATH so both the Linger=yes and Linger=no
# branches are exercised without depending on this host's real linger
# state (which the real-host verification report covers separately).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

INSTALL_SH="${LLMCTL_ROOT}/scripts/install.sh"

# --- 0. RED-baseline expectation is documented, not re-asserted here: this
# test file's OWN existence is the GREEN half of the RED/GREEN pair for
# scripts/install.sh - see this session's report for the captured RED
# output ("No such file or directory") from before scripts/install.sh
# existed. Once the script exists, this file only ever exercises the GREEN
# (post-implementation) side, exactly like every other test_*_e2e.sh in
# this suite.
assert_file_exists "${INSTALL_SH}" "scripts/install.sh exists (GREEN half of the RED/GREEN pair)"
bash_n_rc=0; bash -n "${INSTALL_SH}" || bash_n_rc=$?
assert_eq 0 "${bash_n_rc}" "bash -n scripts/install.sh (syntax check - tests/test_syntax.sh's own script glob does not currently enumerate top-level scripts/*.sh, only scripts/release/*.sh, so this file asserts it directly)"

# --- fixture: a synthetic LLMCTL_ROOT whose bin/llmctl is a fake stub that
# records every argv it was called with (one invocation per line) instead
# of doing anything real, plus fake `install.sh` copied so its own
# _install_root()-relative `"${root}/bin/llmctl"` call resolves to the fake
# stub rather than the real, heavyweight bin/llmctl. -------------------------
FAKE_ROOT="${TEST_TMP}/fake-llmctl-root"
mkdir -p "${FAKE_ROOT}/bin" "${FAKE_ROOT}/scripts"
CALL_LOG="${TEST_TMP}/llmctl_calls.log"
: > "${CALL_LOG}"

cat > "${FAKE_ROOT}/bin/llmctl" <<FAKELLMCTL
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "${CALL_LOG}"
case "\${1:-}" in
  status) echo "profile port mode RAM VRAM enabled state" ;;
  *) : ;;
esac
exit 0
FAKELLMCTL
chmod +x "${FAKE_ROOT}/bin/llmctl"

cp "${INSTALL_SH}" "${FAKE_ROOT}/scripts/install.sh"
chmod +x "${FAKE_ROOT}/scripts/install.sh"

# --- fake loginctl: hermetic PATH stub for the linger-verification step,
# following this suite's own fake-systemctl idiom (test_scheduler_reboot_
# reconciliation.sh): behavior is driven by an env var this test controls,
# never by the real host's actual linger state. ------------------------------
FAKEBIN="${TEST_TMP}/fakebin"
mkdir -p "${FAKEBIN}"
cat > "${FAKEBIN}/loginctl" <<'FAKELOGINCTL'
#!/usr/bin/env bash
set -euo pipefail
# Minimal fake for `loginctl show-user <user> -p Linger`, the only
# invocation install_linger_ok() makes.
if [[ "${1:-}" == "show-user" && "${3:-}" == "-p" && "${4:-}" == "Linger" ]]; then
  printf 'Linger=%s\n' "${FAKE_LOGINCTL_LINGER:-yes}"
  exit 0
fi
echo "fake loginctl: unsupported invocation: $*" >&2
exit 1
FAKELOGINCTL
chmod +x "${FAKEBIN}/loginctl"
export PATH="${FAKEBIN}:${PATH}"

# =============================================================================
# 1. Happy path: default profile ('small'), linger confirmed. Asserts the
#    exact call sequence AND the reported PASS.
# =============================================================================
: > "${CALL_LOG}"
out="$(FAKE_LOGINCTL_LINGER=yes bash "${FAKE_ROOT}/scripts/install.sh" 2>&1)" && rc=0 || rc=$?
echo "${out}" | sed 's/^/  /'

assert_eq 0 "${rc}" "happy path: exit code 0"
assert_contains "${out}" "PASS: linger is enabled" "happy path: linger PASS reported"
assert_contains "${out}" "install complete: small" "happy path: default profile is 'small' when none given"

calls="$(cat "${CALL_LOG}")"
assert_contains "${calls}" "setup" "happy path: 'llmctl setup' was invoked"
assert_contains "${calls}" "models download small" "happy path: 'llmctl models download small' was invoked (default profile)"
assert_contains "${calls}" "install" "happy path: 'llmctl install' was invoked (writes the systemd unit TEMPLATE 'enable' depends on - see scripts/install.sh's own header for the real, root-caused reason this step exists)"
assert_contains "${calls}" "enable small" "happy path: 'llmctl enable small' was invoked"
assert_contains "${calls}" "status" "happy path: 'llmctl status' was invoked as the final step"

# Exact ORDER: setup, download, install, enable, status - each earlier line
# number strictly less than the next, proving sequencing (not merely
# presence) exactly matches setup -> download -> install -> enable ->
# linger-check -> status.
setup_line="$(grep -nx 'setup' "${CALL_LOG}" | head -1 | cut -d: -f1)"
download_line="$(grep -nx 'models download small' "${CALL_LOG}" | head -1 | cut -d: -f1)"
install_line="$(grep -nx 'install' "${CALL_LOG}" | head -1 | cut -d: -f1)"
enable_line="$(grep -nx 'enable small' "${CALL_LOG}" | head -1 | cut -d: -f1)"
status_line="$(grep -nx 'status' "${CALL_LOG}" | head -1 | cut -d: -f1)"

order_ok=0
if [[ -n "${setup_line}" && -n "${download_line}" && -n "${install_line}" && -n "${enable_line}" && -n "${status_line}" ]] \
  && (( setup_line < download_line && download_line < install_line && install_line < enable_line && enable_line < status_line )); then
  order_ok=1
fi
assert_eq 1 "${order_ok}" "happy path: real invocation order is setup -> download -> install -> enable -> status (proves scripts/install.sh's own sequencing, not just that every subcommand happened to run somewhere)"

# =============================================================================
# 2. Failure-detection branch: linger NOT confirmed (Linger=no). The script
#    MUST report FAIL with the actionable `sudo loginctl enable-linger`
#    instruction and MUST exit non-zero - proving it never silently
#    proceeds as if reboot-survival were guaranteed when it is not.
# =============================================================================
: > "${CALL_LOG}"
out2="$(FAKE_LOGINCTL_LINGER=no bash "${FAKE_ROOT}/scripts/install.sh" --profile vision 2>&1)" && rc2=0 || rc2=$?
echo "${out2}" | sed 's/^/  /'

assert_eq 1 "${rc2}" "linger-not-confirmed path: exit code 1 (non-zero - never silently proceeds)"
assert_contains "${out2}" "FAIL: linger is NOT confirmed enabled" "linger-not-confirmed path: FAIL is reported"
assert_contains "${out2}" "sudo loginctl enable-linger" "linger-not-confirmed path: actionable sudo instruction is printed (never attempted automatically)"

calls2="$(cat "${CALL_LOG}")"
assert_contains "${calls2}" "models download vision" "linger-not-confirmed path: --profile vision was honored (not the default 'small')"
assert_contains "${calls2}" "enable vision" "linger-not-confirmed path: enable ran for the requested profile before the linger check failed it"
# The final 'status' step must NOT have run - the script returns 1 as soon
# as the linger check fails, per its own Step 5/6 ordering.
status_ran_after_fail=0
grep -qx 'status' "${CALL_LOG}" && status_ran_after_fail=1
assert_eq 0 "${status_ran_after_fail}" "linger-not-confirmed path: 'llmctl status' (Step 6) did not run after the Step 5 linger check failed"

# =============================================================================
# 3. --dry-run: forwards LLMCTL_DRY_RUN=1 to every llmctl call, and the
#    linger-verification step is itself skipped (dry-run never touches real
#    systemd, so there is nothing real to verify) rather than either
#    fabricating a PASS or spuriously FAILing.
# =============================================================================
: > "${CALL_LOG}"
out3="$(bash "${FAKE_ROOT}/scripts/install.sh" --dry-run 2>&1)" && rc3=0 || rc3=$?
echo "${out3}" | sed 's/^/  /'

assert_eq 0 "${rc3}" "--dry-run: exit code 0"
assert_contains "${out3}" "[dry-run] would run: loginctl show-user" "--dry-run: linger step is honestly skipped, not silently fabricated"

# The fake llmctl doesn't itself branch on LLMCTL_DRY_RUN (it is a stub
# that always no-ops), so the load-bearing assertion is that
# scripts/install.sh actually EXPORTED it into the environment that
# invoked llmctl - proven by having the fake llmctl echo it into the call
# log for this one run.
cat > "${FAKE_ROOT}/bin/llmctl" <<FAKELLMCTL2
#!/usr/bin/env bash
set -euo pipefail
printf '%s LLMCTL_DRY_RUN=%s\n' "\$*" "\${LLMCTL_DRY_RUN:-unset}" >> "${CALL_LOG}"
case "\${1:-}" in
  status) echo "profile port mode RAM VRAM enabled state" ;;
  *) : ;;
esac
exit 0
FAKELLMCTL2
chmod +x "${FAKE_ROOT}/bin/llmctl"
: > "${CALL_LOG}"
bash "${FAKE_ROOT}/scripts/install.sh" --dry-run >/dev/null 2>&1 || true
assert_contains "$(cat "${CALL_LOG}")" "LLMCTL_DRY_RUN=1" "--dry-run: LLMCTL_DRY_RUN=1 was genuinely exported into every llmctl invocation's environment"

# =============================================================================
# 4. --skip-setup honored (Step 1 becomes an honest SKIP, not silently
#    invoking 'llmctl setup' anyway).
# =============================================================================
cat > "${FAKE_ROOT}/bin/llmctl" <<FAKELLMCTL3
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "${CALL_LOG}"
case "\${1:-}" in
  status) echo "profile port mode RAM VRAM enabled state" ;;
  *) : ;;
esac
exit 0
FAKELLMCTL3
chmod +x "${FAKE_ROOT}/bin/llmctl"
: > "${CALL_LOG}"
out4="$(FAKE_LOGINCTL_LINGER=yes bash "${FAKE_ROOT}/scripts/install.sh" --skip-setup 2>&1)" && rc4=0 || rc4=$?
assert_eq 0 "${rc4}" "--skip-setup: exit code 0"
assert_contains "${out4}" "SKIP: --skip-setup given" "--skip-setup: Step 1 is honestly reported as skipped"
setup_calls="$(grep -cx 'setup' "${CALL_LOG}" || true)"
assert_eq 0 "${setup_calls}" "--skip-setup: 'llmctl setup' was NOT invoked"

# =============================================================================
# 5. Usage errors: unknown flag and --profile with no argument both exit 2,
#    never silently ignored or treated as a profile name.
# =============================================================================
rc5=0; bash "${FAKE_ROOT}/scripts/install.sh" --bogus-flag >/dev/null 2>&1 || rc5=$?
assert_eq 2 "${rc5}" "unknown flag: exit code 2"

rc6=0; bash "${FAKE_ROOT}/scripts/install.sh" --profile >/dev/null 2>&1 || rc6=$?
assert_eq 2 "${rc6}" "--profile with no argument: exit code 2"

# =============================================================================
# 6. macOS/non-systemd host: loginctl absent -> honest SKIP, never a FAIL.
# =============================================================================
: > "${CALL_LOG}"
out7="$(PATH="/usr/bin:/bin" bash "${FAKE_ROOT}/scripts/install.sh" 2>&1)" && rc7=0 || rc7=$?
# On a host where /usr/bin:/bin genuinely has no loginctl (true on this
# dev host - loginctl lives elsewhere), this reproduces the macOS case for
# real, without any fake needed.
if command -v loginctl >/dev/null 2>&1 && PATH="/usr/bin:/bin" command -v loginctl >/dev/null 2>&1; then
  assert_skip "loginctl is present even on the narrowed PATH on this host" "loginctl-absent SKIP branch"
else
  assert_eq 0 "${rc7}" "loginctl absent: exit code 0 (never a FAIL merely because the tool is missing)"
  assert_contains "${out7}" "SKIP: 'loginctl' not found" "loginctl absent: honest SKIP is reported, not a FAIL"
fi

test_finish
