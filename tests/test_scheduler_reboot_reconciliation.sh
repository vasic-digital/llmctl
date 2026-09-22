#!/usr/bin/env bash
# test_scheduler_reboot_reconciliation.sh - RED-then-GREEN regression test for
# the post-reboot state-desync defect (root-caused 2026-09-22, real repro on
# a rebooted host, not guessed):
#
#   sched_running() (lib/scheduler.sh) enumerated ONLY the ephemeral
#   ${LLMCTL_RUNTIME_DIR}/*.run reservation-marker files. LLMCTL_RUNTIME_DIR
#   defaults to ${XDG_RUNTIME_DIR}/llmctl - a tmpfs deliberately WIPED by
#   systemd/PAM on every reboot - and *.run files are ONLY ever (re)written
#   by this project's own code (_enable_impl / _sched_start_impl, via
#   _sched_write_reservation), never by systemd itself. After a reboot,
#   systemd correctly auto-restarts an already-`enabled` persistent service
#   (WantedBy=default.target + user lingering) with NO llmctl invocation
#   involved at all, so llmctl's own bookkeeping had ZERO record of it until
#   `bin/llmctl` ran again for that exact profile: `llmctl status` reported
#   "no llmctl services running" for services that were genuinely serving
#   real traffic (independently confirmed on the diagnosing host via
#   `systemctl --user list-units`, `ss -tlnp`, and `nvidia-smi`).
#
#   This is not merely cosmetic. sched_reserved_field() - which
#   _enable_impl's own 2026-09-17 overcommit-safety check reads to compute
#   currently-reserved RAM/VRAM before allowing a NEW profile to enable -
#   iterates the SAME *.run glob, so immediately after a reboot it silently
#   reported ZERO reserved for a profile that was in fact consuming real
#   host RAM/VRAM. A subsequent `llmctl enable <new-profile>` could pass
#   that check and genuinely overcommit the host - the EXACT failure mode
#   the 2026-09-17 fix exists to prevent, reintroduced via a different
#   trigger (post-reboot state desync instead of the original
#   unconditional-write bug that fix addressed).
#
# Hermetic simulation (no real systemd is ever touched by this test): a fake
# `systemctl` stands in on PATH for the real service backend so
# svc_is_active()'s real (non-dry-run) systemctl branch can be exercised.
# LLMCTL_DRY_RUN=1's own svc_is_active branch checks for the EXISTENCE of
# the exact *.run file this scenario is missing (see service_linux.sh), so
# it can NEVER exercise this code path - LLMCTL_DRY_RUN is therefore left
# unset/0 here on purpose, and every other service-backend call this test's
# code path could reach (svc_write_env) is pure filesystem I/O with no
# systemctl invocation at all, so nothing here risks a real service action.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"

# --- fake systemctl: hermetic stand-in for the real systemd --user backend ---
FAKEBIN="${TEST_TMP}/fakebin"
mkdir -p "${FAKEBIN}"
FAKE_ACTIVE="${TEST_TMP}/fake_active_units"
FAKE_FAILED="${TEST_TMP}/fake_failed_units"
: > "${FAKE_ACTIVE}"
: > "${FAKE_FAILED}"
cat > "${FAKEBIN}/systemctl" <<'FAKESYSTEMCTL'
#!/usr/bin/env bash
# Minimal fake for the two systemctl invocations svc_is_active/svc_is_failed
# make: `systemctl --user is-active --quiet <unit>` and
# `systemctl --user is-failed --quiet <unit>`. A unit is "active" iff its
# name appears (one per line, exact match) in $FAKE_SYSTEMCTL_ACTIVE_UNITS;
# "failed" iff it appears in $FAKE_SYSTEMCTL_FAILED_UNITS. Anything else
# reports inactive/not-failed, mirroring real systemctl's exit-code
# contract (is-active: 0 active, non-zero otherwise; is-failed: 0 failed,
# non-zero otherwise) without requiring bash >= 4.3 array features (last-arg
# extraction via a portable loop, not `${@: -1}`/negative array indices).
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
sched_load_backend   # linux -> service_linux.sh; svc_is_active now calls our fake systemctl

# --- fixture: two ENABLED profiles exactly as `llmctl enable` leaves them
# (env file + .enabled marker), minus the ephemeral *.run marker - simulating
# a host reboot: tmpfs wiped, systemd auto-restarted both already-enabled
# units on its own, llmctl's own bookkeeping never ran again. -----------------
svc_write_env small llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
  --model /models/small/m.gguf --host 127.0.0.1 --port 8085 --ctx-size 8192 \
  --n-gpu-layers 99 --flash-attn auto --parallel 1 --jinja
touch "${LLMCTL_SERVICES_DIR}/small.enabled"
echo "llmctl-llama@small.service" >> "${FAKE_ACTIVE}"

svc_write_env vision-pro llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
  --model /models/vision-pro/m.gguf --host 127.0.0.1 --port 8083 --ctx-size 16384 \
  --n-gpu-layers 99 --flash-attn auto --parallel 1 --jinja
touch "${LLMCTL_SERVICES_DIR}/vision-pro.enabled"
# vision-pro is deliberately left OUT of FAKE_ACTIVE and marked FAILED
# instead - mirroring a real, independently-observed state on the diagnosing
# host (2026-09-22): an ENABLED profile can be genuinely crash-looping
# (systemd "activating (auto-restart)", there caused by a real CUDA
# out-of-memory) rather than truly active. The fix MUST NOT reconcile it
# into a false "running" state just because it is enabled.
echo "llmctl-llama@vision-pro.service" >> "${FAKE_FAILED}"

# --- sanity: the fake backend itself reports what this test assumes it does,
# independent of any llmctl code (isolates a fake-systemctl bug from a real
# scheduler.sh regression before trusting any assertion built on top of it).
systemctl --user is-active --quiet llmctl-llama@small.service
assert_eq 0 "$?" "sanity: fake systemctl reports small active"
rc=0; systemctl --user is-active --quiet llmctl-llama@vision-pro.service || rc=$?
assert_eq 3 "${rc}" "sanity: fake systemctl reports vision-pro NOT active"

# --- precondition: no .run marker for either profile yet, even though
# 'small' is genuinely active per the (fake) service backend - this is the
# exact post-reboot desync state the fix must reconcile. --------------------
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "precondition: small has no reservation marker before reconciliation"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision-pro.run" "precondition: vision-pro has no reservation marker before reconciliation"

# --- 1. sched_running() must reconcile the genuinely-active enabled profile,
# and must NOT reconcile the enabled-but-not-active one. An EXACT match
# (not merely assert_contains) also proves sched_running()'s stdout data
# contract - a bare list of profile names, one per line, that
# _sched_stop_impl's own `while read` loop parses directly - carries no
# incidental log/progress noise (a real regression this test caught during
# development: the reconciliation's own progress message was briefly
# written to the same stdout stream sched_running() callers parse as data;
# fixed by sending it to stderr instead - see _sched_reconcile_reservations).
running_list="$(sched_running)"
assert_eq "small" "${running_list}" "sched_running() lists exactly 'small' after reboot-reconciliation (previously empty - the reported defect; also proves no log noise leaks onto its stdout data contract)"

assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "sched_running() self-healed small's missing .run reservation record"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision-pro.run" "sched_running() did NOT fabricate a reservation for the non-active vision-pro"

# Reconstructed reservation uses the SAME schema _sched_write_reservation
# already writes (profile=/mode=/port=/ram_mb=/vram_mb=/started_epoch=),
# and the SAME hw_probe_json | catalog_plan_json + json_query derivation
# _enable_impl already uses - never an invented/guessed set of numbers.
assert_file_contains "${LLMCTL_RUNTIME_DIR}/small.run" "profile=small" "reconstructed reservation: profile field"
assert_file_contains "${LLMCTL_RUNTIME_DIR}/small.run" "port=8085" "reconstructed reservation: real port from a fresh plan lookup"
ram_field="$(sed -n 's/^ram_mb=//p' "${LLMCTL_RUNTIME_DIR}/small.run")"
vram_field="$(sed -n 's/^vram_mb=//p' "${LLMCTL_RUNTIME_DIR}/small.run")"
ram_ok=0; [[ -n "${ram_field}" && "${ram_field}" =~ ^[0-9]+$ ]] && ram_ok=1
vram_ok=0; [[ -n "${vram_field}" && "${vram_field}" =~ ^[0-9]+$ ]] && vram_ok=1
assert_eq 1 "${ram_ok}" "reconstructed reservation: ram_mb is a real numeric footprint from the plan"
assert_eq 1 "${vram_ok}" "reconstructed reservation: vram_mb is a real numeric footprint from the plan"

# --- 2. idempotence: a second call must not alter the reservation it already
# reconciled (no duplicate work, no clobbering a normal reservation). -------
stat_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
mtime_before="$(stat_mtime "${LLMCTL_RUNTIME_DIR}/small.run")"
sleep 1
sched_running >/dev/null
mtime_after="$(stat_mtime "${LLMCTL_RUNTIME_DIR}/small.run")"
assert_eq "${mtime_before}" "${mtime_after}" "sched_running() is idempotent - an already-reconciled reservation is left untouched on a second call"

# --- 3. THE OVERCOMMIT-SAFETY CONSEQUENCE (the actual property at stake, not
# just the display string): sched_reserved_field() must account for small's
# real RAM/VRAM footprint even though llmctl was never told about it via a
# normal start/enable in this process's lifetime. ---------------------------
used_ram="$(sched_reserved_field ram_mb)"
used_vram="$(sched_reserved_field vram_mb)"
ram_gt_zero=0; [[ "${used_ram}" -gt 0 ]] && ram_gt_zero=1
assert_eq 1 "${ram_gt_zero}" "sched_reserved_field(ram_mb) accounts for the reconciled small reservation (>0, not the pre-fix 0)"
# Cross-check against the reconciled reservation's own recorded numbers
# (never an independently-guessed constant), so this assertion tracks
# whatever hw-baseline.json's real 'small' footprint happens to be.
assert_eq "${ram_field}" "${used_ram}" "sched_reserved_field(ram_mb) == the reconciled reservation's own ram_mb (only 'small' is reserved)"
assert_eq "${vram_field}" "${used_vram}" "sched_reserved_field(vram_mb) == the reconciled reservation's own vram_mb (only 'small' is reserved)"

test_finish
