#!/usr/bin/env bash
# test_start_gate.sh - RED-first (fix/bounded-restart-and-pressure-gates).
# Root cause (5): start admission (lib/scheduler.sh _sched_start_impl, budget = MemAvailable-4096) never reads
# /proc/pressure/memory and restarts bypass admission (ExecStartPre only rotates the key). Contract:
#   * `svc_hook.sh gate` refuses with exit 75 (EX_TEMPFAIL) + a message naming memory pressure when the PSI fixture
#     (LLMCTL_PSI_FILE, /proc/pressure/memory format) has full avg10 > 2 or some avg10 > 10, or the meminfo fixture
#     (LLMCTL_MEMINFO_FILE) has MemAvailable below the floor; avg10=0 + ample memory passes (exit 0).
#   * llmctl start / enable / switch (dry-run) refuse with rc 75 under the same fixture; validate too when the command exists.
#   * the generated unit carries an ExecStartPre gate line BEFORE the key-rotating prestart, so RESTARTS are gated too.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"; HOOK="${LLMCTL_ROOT}/lib/svc_hook.sh"

mkpsi() { printf 'some avg10=%s avg60=0.00 avg300=0.00 total=1\nfull avg10=%s avg60=0.00 avg300=0.00 total=1\n' "$2" "$3" > "$1"; }
mkmem() { printf 'MemTotal:       33554432 kB\nMemFree:  %s kB\nMemAvailable:   %s kB\n' "$2" "$2" > "$1"; }
mkpsi "${TEST_TMP}/psi_ok" 0.00 0.00
mkpsi "${TEST_TMP}/psi_full" 0.50 3.50
mkpsi "${TEST_TMP}/psi_some" 12.00 0.00
mkmem "${TEST_TMP}/mem_ok" 30000000
mkmem "${TEST_TMP}/mem_low" 400000
export LLMCTL_MEMINFO_FILE="${TEST_TMP}/mem_ok"

run() { # run <psi> <cmd...> -> "rc|output"
  local psi="$1" o r=0; shift
  o="$(LLMCTL_PSI_FILE="${psi}" timeout 30 "$@" 2>&1)" || r=$?
  printf '%s|%s' "${r}" "${o}"
}
expect_refused() { # <label> <result>
  local rc="${2%%|*}" out="${2#*|}" want="${3:-75}"
  assert_eq "${want}" "${rc}" "$1: refused with exit ${want}"
  case "${out,,}" in *pressure*|*available*) echo "  ok: $1: message names the cause";; *) printf '  FAIL: %s: no clear pressure/memory message: %.200s\n' "$1" "${out}" >&2; TEST_FAILS=$((TEST_FAILS+1));; esac
}

echo "== svc_hook.sh gate =="
expect_refused "gate full avg10=3.5" "$(run "${TEST_TMP}/psi_full" bash "${HOOK}" gate vision)"
expect_refused "gate some avg10=12" "$(run "${TEST_TMP}/psi_some" bash "${HOOK}" gate vision)"
expect_refused "gate low MemAvailable" "$(LLMCTL_MEMINFO_FILE="${TEST_TMP}/mem_low" run "${TEST_TMP}/psi_ok" bash "${HOOK}" gate vision)"
r="$(run "${TEST_TMP}/psi_ok" bash "${HOOK}" gate vision)"
assert_eq "0" "${r%%|*}" "gate with avg10=0 and ample MemAvailable passes (negative control: the gate is not a constant refusal)"

echo "== llmctl start/enable/switch under pressure =="
for sub in "start fast" "enable small" "switch coder"; do   # distinct profiles: no shared dry-run state
  # shellcheck disable=SC2086
  expect_refused "llmctl ${sub}" "$(run "${TEST_TMP}/psi_full" "${LLMCTL}" ${sub})"
done
r="$(run "${TEST_TMP}/psi_ok" "${LLMCTL}" start vision)"
assert_eq "0" "${r%%|*}" "llmctl start vision with avg10=0 still succeeds (dry-run)"
if grep -qE '^[[:space:]]*validate\)' "${LLMCTL}"; then
  # validate maps the gate's rc 75 to exit 2 (UNDETERMINED, "refused under memory pressure"): a refusal is not a verdict
  expect_refused "llmctl validate" "$(run "${TEST_TMP}/psi_full" "${LLMCTL}" validate vision)" 2
else
  assert_skip "this branch's bin/llmctl has no validate command (it lives uncommitted in the main tree); revisit when merged" "llmctl validate refuses under pressure"
fi

echo "== generated unit gates RESTARTS =="
# shellcheck disable=SC1090
for l in common os_detect hardware service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
( svc_install ) >/dev/null 2>&1
for eng in llama colibri onnx; do
  U="${LLMCTL_UNIT_DIR}/llmctl-${eng}@.service"
  g="$(grep -nE '^ExecStartPre=.*svc_hook\.sh.* gate' "${U}" | head -1 | cut -d: -f1 || true)"
  p="$(grep -nE '^ExecStartPre=.*svc_hook\.sh.* prestart' "${U}" | head -1 | cut -d: -f1 || true)"
  if [[ -n "${g}" && -n "${p}" && "${g}" -lt "${p}" ]]; then echo "  ok: ${eng}: ExecStartPre gate (line ${g}) precedes prestart key rotation (line ${p})"
  else printf '  FAIL: %s: no ExecStartPre gate line ahead of prestart (gate=%s prestart=%s)\n' "${eng}" "${g:-none}" "${p:-none}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
done
test_finish
