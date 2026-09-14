#!/usr/bin/env bash
# test_services.sh - service unit / plist generation for both backends.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"

# --- Linux: systemd --user template units -------------------------------------
(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/os_detect.sh"
  source "${LLMCTL_ROOT}/lib/hardware.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_install
)

UNIT="${LLMCTL_UNIT_DIR}/llmctl-llama@.service"
assert_file_contains "${UNIT}" "Restart=always" "llama unit: Restart=always"
assert_file_contains "${UNIT}" "RestartSec=5" "llama unit: RestartSec=5"
assert_file_contains "${UNIT}" "StartLimitIntervalSec=0" "llama unit: StartLimitIntervalSec=0"
# baseline fixture: total 32768 MiB -> MemoryMax=(32768-4096)=28672M, MemoryHigh=25804M
assert_file_contains "${UNIT}" "MemoryMax=28672M" "llama unit: MemoryMax from probed RAM"
assert_file_contains "${UNIT}" "MemoryHigh=25804M" "llama unit: MemoryHigh = 90% of MemoryMax"
assert_file_contains "${UNIT}" "EnvironmentFile=${LLMCTL_SERVICES_DIR}/%i.env" "llama unit: per-profile EnvironmentFile"
assert_file_contains "${UNIT}" 'ExecStart=${LLMCTL_EXEC} ${LLMCTL_ARGS}' "llama unit: ExecStart from env file"
assert_file_contains "${UNIT}" "append:${LLMCTL_LOG_DIR}/%i.log" "llama unit: log location"

CUNIT="${LLMCTL_UNIT_DIR}/llmctl-colibri@.service"
assert_file_exists "${CUNIT}" "colibri unit installed"
assert_file_contains "${CUNIT}" "Description=llmctl colibri inference server" "colibri unit: description"

# env file generation for a llama profile
(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_write_env fast llama /opt/llmctl/vendor/llama.cpp/build/bin/llama-server \
    --model /models/fast/m.gguf --host 127.0.0.1 --port 8080 --ctx-size 8192 \
    --n-gpu-layers 99 --flash-attn auto --parallel 1 --jinja
)
assert_file_contains "${LLMCTL_SERVICES_DIR}/fast.env" "LLMCTL_ENGINE=llama" "env file: engine"
assert_file_contains "${LLMCTL_SERVICES_DIR}/fast.env" "--port 8080" "env file: port in args"
assert_file_contains "${LLMCTL_SERVICES_DIR}/fast.env" "--n-gpu-layers 99" "env file: ngl in args"

# dry-run lifecycle prints instead of executing
captured="$(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/os_detect.sh"
  source "${LLMCTL_ROOT}/lib/hardware.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_enable fast
)"
assert_contains "${captured}" "[dry-run] systemctl --user enable llmctl-llama@fast.service" "dry-run enable"
assert_contains "${captured}" "[dry-run] systemctl --user start llmctl-llama@fast.service" "dry-run start"

# --- macOS: launchd plist generation -------------------------------------------
captured="$(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_macos.sh"
  svc_write_env fast llama /opt/llmctl/vendor/llama.cpp/build/bin/llama-server \
    --model /models/fast/m.gguf --host 127.0.0.1 --port 8080
)"
PLIST="${LLMCTL_PLIST_DIR}/com.llmctl.fast.plist"
assert_file_contains "${PLIST}" "<string>com.llmctl.fast</string>" "plist: label"
assert_file_contains "${PLIST}" "<key>KeepAlive</key>" "plist: KeepAlive"
assert_file_contains "${PLIST}" "<key>ThrottleInterval</key>" "plist: ThrottleInterval"
assert_file_contains "${PLIST}" "<integer>5</integer>" "plist: throttle 5s"
assert_file_contains "${PLIST}" "<string>--port</string>" "plist: arg present"
assert_file_contains "${PLIST}" "<string>8080</string>" "plist: port present"
assert_file_contains "${PLIST}" "${LLMCTL_LOG_DIR}/fast.log" "plist: log path"
# plist is parseable XML
rc=0
python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "${PLIST}" || rc=$?
assert_eq 0 "${rc}" "plist parses (plistlib)"

captured="$(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_macos.sh"
  svc_enable fast
)"
assert_contains "${captured}" "[dry-run] launchctl bootstrap" "dry-run launchctl bootstrap"

test_finish
