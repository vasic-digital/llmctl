#!/usr/bin/env bash
# test_services_crashloop.sh - proves service units bound automatic restarts
# (so a permanently-broken model does not crash-loop forever) and that
# `llmctl status` surfaces a crash-looped profile with its last log line
# (FR-044, Clarification 14).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"

# --- 1. systemd --user unit bounds restarts -----------------------------------
(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/os_detect.sh"
  source "${LLMCTL_ROOT}/lib/hardware.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_install
)
UNIT="${LLMCTL_UNIT_DIR}/llmctl-llama@.service"
assert_file_contains "${UNIT}" "StartLimitBurst=5" "llama unit: bounded restart burst (5 attempts)"
assert_file_contains "${UNIT}" "StartLimitIntervalSec=60" "llama unit: bounded restart interval (60s window)"

CUNIT="${LLMCTL_UNIT_DIR}/llmctl-colibri@.service"
assert_file_contains "${CUNIT}" "StartLimitBurst=5" "colibri unit: bounded restart burst (5 attempts)"
assert_file_contains "${CUNIT}" "StartLimitIntervalSec=60" "colibri unit: bounded restart interval (60s window)"

# --- 2. launchd plist widens its restart throttle (honest partial parity) ----
(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_macos.sh"
  svc_write_env fast llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
    --model /models/fast/m.gguf --host 127.0.0.1 --port 8080
)
PLIST="${LLMCTL_PLIST_DIR}/com.llmctl.fast.plist"
assert_file_contains "${PLIST}" "<integer>60</integer>" "plist: throttle widened to 60s (launchd has no native give-up-after-N; this bounds the RATE, not the total attempts)"

# --- 3. `llmctl status` surfaces a crash-looped profile -----------------------
status_out="$(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/os_detect.sh"
  source "${LLMCTL_ROOT}/lib/hardware.sh"
  source "${LLMCTL_ROOT}/lib/catalog.sh"
  source "${LLMCTL_ROOT}/lib/scheduler.sh"
  ensure_state_dirs
  # A healthy running profile.
  cat > "${LLMCTL_RUNTIME_DIR}/fast.run" <<EOF
profile=fast
mode=cpu
port=8080
ram_mb=1024
vram_mb=0
started_epoch=1000
EOF
  # A profile whose service exceeded its restart limit and gave up (the real
  # systemd signal is \`systemctl --user is-failed\`; the dry-run marker file
  # lets this test simulate that state deterministically, per the SAME
  # pattern svc_is_active already uses for its own dry-run branch).
  cat > "${LLMCTL_RUNTIME_DIR}/broken.run" <<EOF
profile=broken
mode=cpu
port=8081
ram_mb=512
vram_mb=0
started_epoch=1000
EOF
  touch "${LLMCTL_RUNTIME_DIR}/broken.failed"
  ensure_dir "${LLMCTL_LOG_DIR}"
  printf 'starting...\nerror: model file is corrupt\n' > "${LLMCTL_LOG_DIR}/broken.log"

  sched_status
)"

assert_contains "${status_out}" "fast" "status lists the healthy profile"
assert_contains "${status_out}" "running" "healthy profile reported as running"
assert_contains "${status_out}" "failed (crash-loop)" "crash-looped profile reported as failed (crash-loop)"
assert_contains "${status_out}" "error: model file is corrupt" "crash-looped profile's last log line surfaced"

test_finish
