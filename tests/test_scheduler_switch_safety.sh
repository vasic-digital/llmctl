#!/usr/bin/env bash
# test_scheduler_switch_safety.sh - RED-then-GREEN regression test for a
# real, live-reproduced defect (2026-09-22): `llmctl switch <profile>`
# stopped EVERY currently-running profile first, then tried to start the
# requested one - and if that start failed for ANY reason (budget gate,
# systemd refusing the unit, etc.), the host was left with ZERO running
# llmctl services and NO automatic recovery. Live repro on the diagnosing
# host: `llmctl switch fast` stopped small+vision (both healthy, verified,
# serving real traffic), then failed to start fast with "needs 5716 MiB
# RAM ... but only 0 MiB RAM ... remain" - and the error's OWN suggested
# fix was "llmctl switch fast", the exact command that had just failed,
# leaving the operator to manually run `llmctl start small` to restore
# service. A switch that can strand the host with FEWER running services
# than before it was attempted defeats the entire point of "switch on
# demand" - the whole promise is that trying a different profile is safe.
#
# This test exercises the SYSTEMD-REFUSAL failure path (svc_start
# returning false, e.g. "llmctl install" was never run for that profile's
# unit template) rather than the budget-gate path the live incident hit -
# both are real _sched_start_impl failure modes and both must trigger the
# SAME rollback wrapper in _sched_switch_impl, so covering one hermetically
# is a faithful regression test for the wrapper itself; the budget-gate
# path already has its own separate, real, live-captured evidence from
# this session (see the commit message for the fix this test accompanies).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"

# --- fake systemctl: is-active/is-failed (state queries) + start/stop
# (lifecycle) - start/stop actually mutate FAKE_ACTIVE so the fixture
# behaves like a real service backend; a designated "poison" unit's start
# always fails, simulating svc_start returning false for any reason
# (crash, missing unit template, etc. - _sched_start_impl treats all such
# reasons identically: `if ! svc_start "${p}"; then ... return 1; fi`). ----
FAKEBIN="${TEST_TMP}/fakebin"
mkdir -p "${FAKEBIN}"
FAKE_ACTIVE="${TEST_TMP}/fake_active_units"
FAKE_FAILED="${TEST_TMP}/fake_failed_units"
: > "${FAKE_ACTIVE}"
: > "${FAKE_FAILED}"
cat > "${FAKEBIN}/systemctl" <<'FAKESYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--user" ]] || { echo "fake systemctl: expected --user, got: $*" >&2; exit 1; }
shift
verb="${1:-}"; shift || true
unit=""
for a in "$@"; do unit="${a}"; done
case "${verb}" in
  is-active)
    grep -qxF "${unit}" "${FAKE_SYSTEMCTL_ACTIVE_UNITS}" 2>/dev/null && exit 0
    exit 3
    ;;
  is-failed)
    grep -qxF "${unit}" "${FAKE_SYSTEMCTL_FAILED_UNITS}" 2>/dev/null && exit 0
    exit 1
    ;;
  start)
    if [[ -n "${FAKE_SYSTEMCTL_POISON_UNIT:-}" && "${unit}" == "${FAKE_SYSTEMCTL_POISON_UNIT}" ]]; then
      echo "fake systemctl: refusing to start ${unit} (poisoned for this test)" >&2
      exit 1
    fi
    grep -qxF "${unit}" "${FAKE_SYSTEMCTL_ACTIVE_UNITS}" 2>/dev/null || echo "${unit}" >> "${FAKE_SYSTEMCTL_ACTIVE_UNITS}"
    exit 0
    ;;
  stop)
    grep -vxF "${unit}" "${FAKE_SYSTEMCTL_ACTIVE_UNITS}" > "${FAKE_SYSTEMCTL_ACTIVE_UNITS}.tmp" 2>/dev/null || true
    mv "${FAKE_SYSTEMCTL_ACTIVE_UNITS}.tmp" "${FAKE_SYSTEMCTL_ACTIVE_UNITS}"
    exit 0
    ;;
  show)
    # _svc_ensure_tenant_slice_dropin/other incidental queries - answer
    # honestly-empty rather than erroring the whole fake out.
    exit 0
    ;;
  *)
    echo "fake systemctl: unsupported verb for this test: ${verb}" >&2
    exit 1
    ;;
esac
FAKESYSTEMCTL
chmod +x "${FAKEBIN}/systemctl"
export PATH="${FAKEBIN}:${PATH}"
export FAKE_SYSTEMCTL_ACTIVE_UNITS="${FAKE_ACTIVE}"
export FAKE_SYSTEMCTL_FAILED_UNITS="${FAKE_FAILED}"

source "${LLMCTL_ROOT}/lib/scheduler.sh"
sched_load_backend

# --- placeholder model files: sched_build_launch (called from inside
# _sched_start_impl, which sched_switch uses internally) requires each
# profile's model file to genuinely EXIST on disk before it will build a
# launch command - real content is irrelevant here (the fake systemctl
# stands in for the actual service backend), only existence matters. -------
for entry in "small:Llama-3.2-3B-Instruct-Q4_K_M.gguf" \
             "vision:gemma-3-4b-it-Q4_K_M.gguf" \
             "vision-pro:gemma-3-12b-it-Q4_K_M.gguf" \
             "fast:Llama-3.1-8B-Instruct-Q4_K_M.gguf"; do
  profile="${entry%%:*}"; fname="${entry#*:}"
  mkdir -p "${LLMCTL_MODELS_DIR}/${profile}"
  : > "${LLMCTL_MODELS_DIR}/${profile}/${fname}"
done
: > "${LLMCTL_MODELS_DIR}/vision/mmproj-model-f16.gguf"
: > "${LLMCTL_MODELS_DIR}/vision-pro/mmproj-model-f16.gguf"

# --- fixture: small + vision genuinely running (enabled, active, real
# reservation markers - the normal, healthy pre-switch state). Written
# directly via svc_write_env + a manual .enabled marker + FAKE_ACTIVE
# (mirroring test_scheduler_reboot_reconciliation.sh's proven pattern)
# rather than the real sched_enable, which additionally re-verifies the
# model's sha256 - irrelevant to this test's actual subject (switch's
# stop/start/rollback sequencing), and this keeps the fixture's OWN model
# placeholders honestly just-existence rather than needing real checksums
# too. ------------------------------------------------------------------
svc_write_env small llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
  --model "${LLMCTL_MODELS_DIR}/small/Llama-3.2-3B-Instruct-Q4_K_M.gguf" \
  --host 127.0.0.1 --port 8085 --ctx-size 8192 --n-gpu-layers 99 --flash-attn auto --parallel 1 --jinja
touch "${LLMCTL_SERVICES_DIR}/small.enabled"
echo "llmctl-llama@small.service" >> "${FAKE_ACTIVE}"
_sched_write_reservation small gpu 8085 2048 2949

svc_write_env vision llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
  --model "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf" \
  --host 127.0.0.1 --port 8082 --ctx-size 8192 --n-gpu-layers 99 --flash-attn auto --parallel 1 --jinja
touch "${LLMCTL_SERVICES_DIR}/vision.enabled"
echo "llmctl-llama@vision.service" >> "${FAKE_ACTIVE}"
_sched_write_reservation vision gpu 8082 2048 4210

assert_eq "small
vision" "$(sched_running | sort)" "precondition: small + vision are both genuinely running before any switch attempt"

# =====================================================================
# 1. Switching to a profile whose start FAILS must roll back to the
#    previously-running set, never leave the host with nothing running.
# =====================================================================
export FAKE_SYSTEMCTL_POISON_UNIT="llmctl-llama@fast.service"
rc=0
sched_switch fast 2>/tmp/switch_stderr_$$.txt || rc=$?
switch_err="$(cat /tmp/switch_stderr_$$.txt)"; rm -f /tmp/switch_stderr_$$.txt

assert_eq 1 "${rc}" "sched_switch returns the ORIGINAL failure (non-zero) when the target profile's start fails"
assert_eq "small
vision" "$(sched_running | sort)" "REGRESSION GUARD: a failed switch rolls back to the exact previously-running set (small+vision) instead of leaving the host with nothing running"
assert_contains "${switch_err}" "restoring the previously-running set" "the failure output explains that a rollback was attempted"
assert_contains "${switch_err}" "rollback succeeded" "the failure output confirms the rollback actually worked"

# =====================================================================
# 2. Happy path: switching to a profile that starts successfully stops
#    the old set and leaves ONLY the new profile running.
# =====================================================================
unset FAKE_SYSTEMCTL_POISON_UNIT
rc=0
sched_switch vision-pro >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "sched_switch succeeds when the target profile's start genuinely succeeds"
assert_eq "vision-pro" "$(sched_running)" "a successful switch leaves ONLY the newly-requested profile running (small+vision correctly stopped)"

# =====================================================================
# 3. No-op case: switching to the profile that is ALREADY the only one
#    running must not needlessly stop+restart it (no model-reload churn).
# =====================================================================
: > "${FAKE_ACTIVE}"
echo "llmctl-llama@vision-pro.service" >> "${FAKE_ACTIVE}"
BEFORE_RESERVATION_MTIME="$(stat -c %Y "${LLMCTL_RUNTIME_DIR}/vision-pro.run" 2>/dev/null || echo 0)"
sleep 1.1
rc=0
sched_switch vision-pro >/dev/null 2>&1 || rc=$?
AFTER_RESERVATION_MTIME="$(stat -c %Y "${LLMCTL_RUNTIME_DIR}/vision-pro.run" 2>/dev/null || echo 0)"
assert_eq 0 "${rc}" "switching to the already-running profile succeeds (no-op)"
assert_eq "${BEFORE_RESERVATION_MTIME}" "${AFTER_RESERVATION_MTIME}" "REGRESSION GUARD: switching to the already-solely-running profile does NOT rewrite its reservation (no needless stop+restart / model-reload churn)"

# =====================================================================
# 4. Error-message honesty regression: a budget-gate failure must ONLY
#    suggest 'llmctl switch <p>' when something ELSE is genuinely
#    running to free room from. Real, live-hit bug (2026-09-22): this
#    suggestion fired even when called FROM INSIDE llmctl switch itself
#    (which had already stopped everything before this check runs),
#    telling the operator to run the EXACT command that had just
#    failed. With nothing else running, the message must instead name
#    the real constraint (the HOST's own available RAM/VRAM). ------------
# 4a. Something else IS running (vision-pro, from case 3 above) -
#     starting 'ws-moe-30b' (needs 25889 MiB RAM) exceeds the fixture's
#     ~25904 MiB budget once vision-pro's own ~9824 MiB reservation is
#     subtracted (leaves ~16080 MiB) -> the 'switch' suggestion is the
#     CORRECT, actionable one here.
rc=0
start_out="$(sched_start ws-moe-30b 2>&1)" || rc=$?
assert_eq 1 "${rc}" "starting an oversized profile while another is running fails (sanity for message-context test 4a)"
assert_contains "${start_out}" "stopping another running profile: llmctl switch ws-moe-30b" "4a: WITH another profile running, the message correctly suggests switch"

# 4b. NOTHING is running (stop everything first) AND the host itself is
#     genuinely too small for ANY profile (a separate, deliberately tiny
#     hw fixture - the standard 30GB fixture leaves enough budget that
#     something always fits alone, which would reach the model-file
#     check instead of the RAM-gate this assertion targets). With
#     nothing running, the message must NOT suggest 'llmctl switch small'
#     (there is nothing left for a switch to stop) - it must name the
#     real host-RAM constraint instead.
_sched_stop_impl all
assert_eq "" "$(sched_running)" "precondition for 4b: nothing is running"
TINY_HW="${TEST_TMP}/hw-tiny.json"
cat > "${TINY_HW}" <<'EOF'
{
  "os": "linux", "arch": "x86_64",
  "cpu": {"cores": 8, "model": "test", "arch": "x86_64", "simd": [], "apple_silicon": false, "apple_chip": null},
  "memory": {"total_mb": 4096, "available_mb": 4096},
  "gpus": [{"vendor": "nvidia", "name": "test GPU", "vram_mb": 2048, "driver": "1", "cuda_version": "12.0"}],
  "gpu_total_vram_mb": 2048,
  "storage": {"path": "/tmp", "free_mb": 500000, "type": "nvme"}
}
EOF
rc=0
start_out="$(LLMCTL_FAKE_HW="${TINY_HW}" sched_start small 2>&1)" || rc=$?
assert_eq 1 "${rc}" "starting even the smallest profile on a genuinely-too-small host still fails (sanity for message-context test 4b)"
case "${start_out}" in
  *"llmctl switch small"*)
    assert_eq 0 1 "4b REGRESSION: message wrongly suggests 'llmctl switch small' (the exact command with nothing to switch away from) - got: ${start_out:0:300}"
    ;;
  *)
    assert_eq 0 0 "4b: with NOTHING running, the message does NOT suggest the circular 'llmctl switch small'"
    ;;
esac
assert_contains "${start_out}" "this host's own available RAM/VRAM is currently too low" "4b: message instead names the real, honest constraint (host RAM/VRAM, not another llmctl profile)"

test_finish
