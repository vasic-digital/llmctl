#!/usr/bin/env bash
# test_enabled_unit_warn.sh - RED-first (review MEDIUM-3). After a SIGKILL (oomd or MemoryMax) a unit never restarts by
# design (RestartPreventExitStatus=SIGKILL), so `llmctl status` and `llmctl doctor` must WARN on any ENABLED engine unit
# that is failed or inactive instead of showing nothing. "Enabled" = default.target.wants symlink; dry-run state: a
# <runtime>/<profile>.run reservation = active, <profile>.failed marker = failed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
W="${LLMCTL_UNIT_DIR:?}/default.target.wants"; mkdir -p "${W}" "${LLMCTL_SERVICES_DIR}"
touch "${LLMCTL_UNIT_DIR}/llmctl-llama@.service"
ln -s ../llmctl-llama@.service "${W}/llmctl-llama@fast.service"
ln -s ../llmctl-llama@.service "${W}/llmctl-llama@small.service"
printf 'LLMCTL_PROFILE=fast\nLLMCTL_ENGINE=llama\n' > "${LLMCTL_SERVICES_DIR}/fast.env"
printf 'LLMCTL_PROFILE=small\nLLMCTL_ENGINE=llama\n' > "${LLMCTL_SERVICES_DIR}/small.env"
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

echo "== fast: enabled, inactive (e.g. SIGKILLed then not restarted); small: running (control) =="
printf 'port=8080\nmode=gpu\nram_mb=2048\nvram_mb=100\n' > "${LLMCTL_RUNTIME_DIR}/small.run"
st="$("${LLMCTL}" status 2>&1 | strip)"
assert_contains "${st}" "enabled but inactive" "status WARNs about the enabled-but-inactive unit"
assert_contains "${st}" "fast" "...naming it"
if grep -E 'enabled but' <<<"${st}" | grep -q 'small'; then printf '  FAIL: control: the running profile small was flagged\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: control: the running profile small is not flagged"; fi
doc="$("${LLMCTL}" doctor 2>&1 | strip || true)"
if grep -E '^WARN' <<<"${doc}" | grep -q 'llmctl-llama@fast.*inactive'; then echo "  ok: doctor WARNs about llmctl-llama@fast (inactive)"
else printf '  FAIL: doctor has no WARN for the enabled-but-inactive llmctl-llama@fast\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

case "${st}${doc}" in *"OOM-killed"*) printf '  FAIL: the WARN text claims an OOM kill without evidence\n' >&2; TEST_FAILS=$((TEST_FAILS+1));; *) echo "  ok: the WARN says the unit is down, it does not claim an OOM kill";; esac
assert_contains "${st}" "down" "status WARN says the unit is down"

echo "== failed state =="
: > "${LLMCTL_RUNTIME_DIR}/fast.failed"; printf 'port=8080\nmode=gpu\nram_mb=2048\nvram_mb=100\n' > "${LLMCTL_RUNTIME_DIR}/fast.run"
st="$("${LLMCTL}" status 2>&1 | strip)"
assert_contains "${st}" "failed" "status shows the failed unit"
doc="$("${LLMCTL}" doctor 2>&1 | strip || true)"
if grep -E '^WARN' <<<"${doc}" | grep -q 'llmctl-llama@fast.*failed'; then echo "  ok: doctor WARNs about llmctl-llama@fast (failed)"
else printf '  FAIL: doctor has no WARN for the failed llmctl-llama@fast\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

echo "== control: everything enabled is running -> no such WARN =="
rm -f "${LLMCTL_RUNTIME_DIR}/fast.failed"; printf 'port=8081\nmode=gpu\nram_mb=2048\nvram_mb=100\n' > "${LLMCTL_RUNTIME_DIR}/fast.run"
doc="$("${LLMCTL}" doctor 2>&1 | strip || true)"
if grep -E '^WARN' <<<"${doc}" | grep -qE 'enabled but (inactive|failed)'; then printf '  FAIL: control: doctor WARNed although every enabled unit is active\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: control: no enabled-but-down WARN"; fi
test_finish
