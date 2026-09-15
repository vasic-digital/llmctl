#!/usr/bin/env bash
# test_hardware_probe.sh - probe runs on this host and honors LLMCTL_FAKE_HW.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"

# 1. Real probe produces valid JSON with the required keys (this works on any
#    Linux/macOS host; that is the probe's whole job).
captured="$(hw_probe_json)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "real probe exit code"
keys="$(printf '%s' "${captured}" | json_stdin '" ".join(sorted(d.keys()))')"
assert_eq "arch cpu gpu_total_vram_mb gpus memory os storage" "${keys}" "probe JSON top-level keys"
cores="$(printf '%s' "${captured}" | json_stdin 'd["cpu"]["cores"]')"
rc=0
[[ "${cores}" =~ ^[0-9]+$ && "${cores}" -ge 1 ]] || rc=1
assert_eq 0 "${rc}" "probe reports a sane core count (${cores})"
mem="$(printf '%s' "${captured}" | json_stdin 'd["memory"]["total_mb"]')"
rc=0
[[ "${mem}" =~ ^[0-9]+$ && "${mem}" -gt 0 ]] || rc=1
assert_eq 0 "${rc}" "probe reports total memory (${mem} MiB)"

# 2. Human rendering works.
human="$(hw_probe_human)"
assert_contains "${human}" "CPU:" "human output has CPU line"
assert_contains "${human}" "RAM:" "human output has RAM line"
assert_contains "${human}" "Storage:" "human output has Storage line"

# 3. Fake fixture override returns the fixture verbatim.
fake="$(LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" hw_probe_json)"
model="$(printf '%s' "${fake}" | json_stdin 'd["cpu"]["model"]')"
assert_eq "AMD Ryzen 7 2700X Eight-Core Processor" "${model}" "fake probe returns fixture model"
vram="$(printf '%s' "${fake}" | json_stdin 'd["gpu_total_vram_mb"]')"
assert_eq 12288 "${vram}" "fake probe returns fixture VRAM"

# 4. Broken overrides fail loudly (subshells contain die()'s exit), and fail
#    for the RIGHT reason - captured, not discarded to /dev/null, so a
#    regression that crashes for some unrelated cause could never pass this
#    silently (Constitution §11.4/§11.4.1: an rc-only check does not prove
#    the failure is the one this test claims to exercise).
rc=0
errout="$( ( LLMCTL_FAKE_HW="/nonexistent.json" hw_probe_json ) 2>&1 1>/dev/null )" || rc=$?
assert_eq 1 "${rc}" "missing fixture file -> probe fails"
assert_contains "${errout}" "LLMCTL_FAKE_HW is set but unreadable" "missing fixture file fails for the real stated reason"
echo '{"not": "closed"' > "${TEST_TMP}/broken.json"
rc=0
errout="$( ( LLMCTL_FAKE_HW="${TEST_TMP}/broken.json" hw_probe_json ) 2>&1 1>/dev/null )" || rc=$?
assert_eq 1 "${rc}" "invalid fixture JSON -> probe fails"
assert_contains "${errout}" "LLMCTL_FAKE_HW fixture is not valid JSON" "invalid fixture JSON fails for the real stated reason"

test_finish
