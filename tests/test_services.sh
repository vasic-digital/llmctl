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
assert_file_contains "${UNIT}" "StartLimitBurst=5" "llama unit: StartLimitBurst=5 (bounded restarts, FR-044)"
assert_file_contains "${UNIT}" "StartLimitIntervalSec=60" "llama unit: StartLimitIntervalSec=60 (bounded restarts, FR-044)"
# Operator decision (Phase 6 T035, 2026-09-15): served-model resource limits
# carry NO artificial ceiling - a served profile gets maximal performance and
# the full probed hardware, not a percentage/headroom-reduced cap. baseline
# fixture: total 32768 MiB -> MemoryMax=MemoryHigh=32768M (the full probed
# total, no subtraction, no throttle zone below the max).
assert_file_contains "${UNIT}" "MemoryMax=32768M" "llama unit: MemoryMax = full probed RAM, no artificial ceiling"
assert_file_contains "${UNIT}" "MemoryHigh=32768M" "llama unit: MemoryHigh = MemoryMax (no soft-throttle zone below the max, for maximal performance)"
assert_file_contains "${UNIT}" "EnvironmentFile=${LLMCTL_SERVICES_DIR}/%i.env" "llama unit: per-profile EnvironmentFile"
assert_file_contains "${UNIT}" 'ExecStart=${LLMCTL_EXEC} ${LLMCTL_ARGS}' "llama unit: ExecStart from env file (documented in the template comment)"
assert_file_contains "${UNIT}" "ExecStart=/bin/bash -c 'set -f; exec \"\$LLMCTL_EXEC\" \$LLMCTL_ARGS'" "llama unit: the real ExecStart execs LLMCTL_EXEC through a shell, globbing off"
assert_file_contains "${UNIT}" "svc_hook.sh\" prestart %i" "llama unit: ExecStartPre rotates the internal key per start (G-028)"
assert_file_contains "${UNIT}" "ExecStartPost=-/bin/bash" "llama unit: ExecStartPost publishes the service in the registry (non-fatal)"
assert_file_contains "${UNIT}" "svc_hook.sh\" unregister %i" "llama unit: ExecStopPost removes the registry row"
# FR-083: restart bounds live in [Unit] (systemd ignores StartLimitIntervalSec= in [Service])
sect_of() { awk -v key="$2" 'BEGIN{s=""} /^\[/{s=$0} index($0,key"=")==1{print s; exit}' "$1"; }
assert_eq "[Unit]" "$(sect_of "${UNIT}" StartLimitIntervalSec)" "llama unit: StartLimitIntervalSec is in [Unit]"
assert_eq "[Unit]" "$(sect_of "${UNIT}" StartLimitBurst)" "llama unit: StartLimitBurst is in [Unit]"
assert_file_contains "${UNIT}" "NoNewPrivileges=yes" "llama unit: verified-effective hardening (NoNewPrivileges)"
assert_file_contains "${UNIT}" "ProtectSystem=full" "llama unit: verified-effective hardening (ProtectSystem=full)"
assert_file_contains "${UNIT}" "append:${LLMCTL_LOG_DIR}/%i.log" "llama unit: log location"

# --- crash-loop guard (live run 2026-10-08, decide-kev-9b) ----------------------------------------------------
# The primary host's INSTALLED llmctl-llama@.service predated the [Unit] fix: StartLimitBurst=5 and
# StartLimitIntervalSec=60 sat at lines 36-37 inside [Service]; systemd logged "Unknown key 'StartLimitIntervalSec' in
# section [Service], ignoring" (live-models/decide-kev-*/engine-journal-tail.txt) and `systemctl --user show` reports
# StartLimitIntervalUSec=10s StartLimitBurst=5. With RestartSec=5 five starts can never land inside 10 s, so an engine
# that dies at start (kev-9b: CUDA OOM) restarts forever. svc_start/svc_enable must refuse such a unit, by name.
GU="${TEST_TMP}/guard-units"; mkdir -p "${GU}"
awk '/^StartLimit(Burst|IntervalSec)=/{next} {print} /^RestartSec=/{print "StartLimitBurst=5"; print "StartLimitIntervalSec=60"}' \
  "${UNIT}" > "${GU}/llmctl-llama@.service"
assert_eq "[Service]" "$(sect_of "${GU}/llmctl-llama@.service" StartLimitIntervalSec)" "fixture: the host's stale layout (StartLimit* inside [Service])"
guard_try() {  # guard_try <unit-dir> <fn> -> "rc|output"
  local o r=0
  o="$( export LLMCTL_UNIT_DIR="$1"; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; "$2" decide-kev-9b 2>&1 )" || r=$?
  printf '%s|%s' "${r}" "${o}"
}
g="$(guard_try "${GU}" svc_start)"
assert_eq "1" "${g%%|*}" "svc_start refuses a unit whose restart bound systemd ignores (would restart-loop forever)"
assert_contains "${g}" "llmctl install" "...and names the fix (regenerate with llmctl install)"
assert_eq "no-start" "$(case "${g}" in *"systemctl --user start"*) echo started ;; *) echo no-start ;; esac)" "...without ever starting the unit"
g="$(guard_try "${GU}" svc_enable)"
assert_eq "1" "${g%%|*}" "svc_enable refuses the same unit (a persistent service would loop across reboots)"
grep -v '^StartLimit' "${UNIT}" > "${GU}/llmctl-llama@.service"
g="$(guard_try "${GU}" svc_start)"
assert_eq "1" "${g%%|*}" "svc_start refuses a unit with no StartLimit*= at all (systemd default 10s/5 never trips at RestartSec=5)"
g="$(guard_try "${LLMCTL_UNIT_DIR}" svc_start)"
assert_eq "0" "${g%%|*}" "golden-false: the freshly generated unit (bounds in [Unit]) starts"
assert_contains "${g}" "systemctl --user start llmctl-llama@decide-kev-9b.service" "golden-false: ...and really issues the start"

CUNIT="${LLMCTL_UNIT_DIR}/llmctl-colibri@.service"
assert_file_exists "${CUNIT}" "colibri unit installed"
assert_file_contains "${CUNIT}" "Description=llmctl colibri inference server" "colibri unit: description"

# env file generation for a llama profile
(
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_write_env fast llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
    --model /models/fast/m.gguf --host 127.0.0.1 --port 8080 --ctx-size 8192 \
    --n-gpu-layers 99 --flash-attn auto --parallel 1 --jinja
)
assert_file_contains "${LLMCTL_SERVICES_DIR}/fast.env" "LLMCTL_ENGINE=llama" "env file: engine"
assert_file_contains "${LLMCTL_SERVICES_DIR}/fast.env" "--port 8080" "env file: port in args"
assert_file_contains "${LLMCTL_SERVICES_DIR}/fast.env" "--n-gpu-layers 99" "env file: ngl in args"
assert_file_contains "${LLMCTL_SERVICES_DIR}/fast.env" "LLMCTL_PORT=8080" "env file: port recorded for the registration hook"
assert_file_contains "${LLMCTL_SERVICES_DIR}/fast.env" "LLMCTL_REG_TOKEN=llama-server" "env file: process-identity token for the registry"
# D-03: the record is owner-only even under a permissive umask
(
  umask 022
  source "${LLMCTL_ROOT}/lib/common.sh"
  source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_write_env perm-check llama /opt/x/llama-server --port 9 --api-key-file /k/key
)
assert_eq "600" "$(stat -c %a "${LLMCTL_SERVICES_DIR}/perm-check.env")" "env file is mode 0600 under umask 022 (D-03)"
assert_file_contains "${LLMCTL_SERVICES_DIR}/perm-check.env" "LLMCTL_KEY_FILE=/k/key" "env file names the key FILE path (never the key)"

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
  svc_write_env fast llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
    --model /models/fast/m.gguf --host 127.0.0.1 --port 8080
)"
PLIST="${LLMCTL_PLIST_DIR}/com.llmctl.fast.plist"
assert_file_contains "${PLIST}" "<string>com.llmctl.fast</string>" "plist: label"
assert_file_contains "${PLIST}" "<key>KeepAlive</key>" "plist: KeepAlive"
assert_file_contains "${PLIST}" "<key>ThrottleInterval</key>" "plist: ThrottleInterval"
assert_file_contains "${PLIST}" "<integer>60</integer>" "plist: throttle 60s (bounded restart rate, FR-044)"
assert_file_contains "${PLIST}" "<string>--port</string>" "plist: arg present"
assert_file_contains "${PLIST}" "<string>8080</string>" "plist: port present"
assert_eq "600" "$(stat -c %a "${PLIST}")" "plist is mode 0600"
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
