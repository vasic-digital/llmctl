#!/usr/bin/env bash
# test_scheduler_bind_host.sh - configurable engine bind host
# (LLMCTL_BIND_HOST / LLMCTL_BIND_HOST_<PROFILE>), exercised for real
# against sched_build_launch (the FUNCTIONAL path every start/enable/switch
# actually launches its engine through).
#
# Root cause this covers: sched_build_launch hardcoded "--host 127.0.0.1"
# at BOTH engine-construction sites (the llama.cpp path and the `colibri
# serve` path), so a genuinely-running, healthy systemd-managed llmctl
# service was never reachable from anywhere but the local machine - not
# even another device on the same LAN - confirmed live via `ss -tlnp`
# showing every llama-server socket bound to 127.0.0.1 with no override
# path anywhere in the codebase (grep for LLMCTL_BIND_HOST found nothing
# pre-fix).
#
# Per explicit operator mandate ("Everything must be fully accessible from
# local network"), the new default is LAN-accessible (0.0.0.0), not
# localhost-only - the opposite polarity from the port-override precedent
# this test otherwise mirrors (tests/test_port_override.sh), because the
# operator asked for the *host to change its default*, not merely to gain
# an opt-in escape hatch. LLMCTL_BIND_HOST (global) and
# LLMCTL_BIND_HOST_<PROFILE> (per-profile, same name-derivation rule as
# LLMCTL_PORT_<PROFILE> - see catalog_bind_host_override_env_name) let an
# operator lock a specific profile - or the whole host - back to
# 127.0.0.1-only.
#
# Both engine paths are exercised here (llama via "fast", colibri via
# "colibri-qwen36"); a fix touching only one would look complete but leave
# the other engine unreachable from the LAN.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/scheduler.sh"

export LLMCTL_DRY_RUN=1

# --- 1. name-derivation helper -------------------------------------------------
assert_eq "LLMCTL_BIND_HOST_FAST" "$(catalog_bind_host_override_env_name fast)" \
  "override env-var name for a simple profile"
assert_eq "LLMCTL_BIND_HOST_WS_DENSE_32B" "$(catalog_bind_host_override_env_name ws-dense-32b)" \
  "override env-var name for a hyphenated profile (hyphens -> underscores, uppercased)"
assert_eq "LLMCTL_BIND_HOST_COLIBRI_QWEN36" "$(catalog_bind_host_override_env_name colibri-qwen36)" \
  "override env-var name for another hyphenated profile"

# --- 2. catalog_bind_host(): no override -> LAN-accessible default -------------
assert_eq "0.0.0.0" "$(catalog_bind_host fast)" \
  "catalog_bind_host fast (no override): LAN-accessible default, per operator mandate"

# --- 3. global LLMCTL_BIND_HOST override applies to every profile --------------
out="$(LLMCTL_BIND_HOST=127.0.0.1 catalog_bind_host fast)"
assert_eq "127.0.0.1" "${out}" "global LLMCTL_BIND_HOST=127.0.0.1 applies to fast"
out="$(LLMCTL_BIND_HOST=127.0.0.1 catalog_bind_host small)"
assert_eq "127.0.0.1" "${out}" "global LLMCTL_BIND_HOST=127.0.0.1 applies to small too (unscoped)"

# --- 4. per-profile override takes precedence and does not leak ---------------
out="$(LLMCTL_BIND_HOST_FAST=192.168.1.50 catalog_bind_host fast)"
assert_eq "192.168.1.50" "${out}" "catalog_bind_host fast honors LLMCTL_BIND_HOST_FAST"
out="$(LLMCTL_BIND_HOST_FAST=192.168.1.50 catalog_bind_host small)"
assert_eq "0.0.0.0" "${out}" \
  "LLMCTL_BIND_HOST_FAST does not leak into an unrelated profile (small keeps the LAN-accessible default)"
out="$(LLMCTL_BIND_HOST=127.0.0.1 LLMCTL_BIND_HOST_FAST=192.168.1.50 catalog_bind_host fast)"
assert_eq "192.168.1.50" "${out}" "per-profile override wins over the global override for the same profile"

# --- 5. still profile-validated (no silent bypass) -----------------------------
rc=0
out="$(LLMCTL_BIND_HOST_FAST=192.168.1.50 catalog_bind_host does-not-exist 2>&1)" || rc=$?
assert_eq 1 "${rc}" "an override for an unknown profile still dies (die() exits 1), never silently returns the override"
assert_contains "${out}" "unknown profile: does-not-exist" "die() message is the same as the no-override unknown-profile path"

# --- 6. THE FUNCTIONAL PATH: sched_build_launch, llama engine ("fast") --------
sched_build_launch fast cpu 8080 8192 99 1 auto
assert_contains "${SCHED_ARGS[*]}" "--host 0.0.0.0" \
  "llama engine, no override: sched_build_launch binds fast to 0.0.0.0 (LAN-accessible default)"

out="$(LLMCTL_BIND_HOST=127.0.0.1 bash -c '
  source "'"${LLMCTL_ROOT}"'/lib/common.sh"
  source "'"${LLMCTL_ROOT}"'/lib/os_detect.sh"
  source "'"${LLMCTL_ROOT}"'/lib/hardware.sh"
  source "'"${LLMCTL_ROOT}"'/lib/catalog.sh"
  source "'"${LLMCTL_ROOT}"'/lib/scheduler.sh"
  export LLMCTL_DRY_RUN=1
  sched_build_launch fast cpu 8080 8192 99 1 auto
  printf "%s\n" "${SCHED_ARGS[*]}"
')"
assert_contains "${out}" "--host 127.0.0.1" \
  "llama engine: global LLMCTL_BIND_HOST=127.0.0.1 overrides fast back to localhost-only"

out="$(LLMCTL_BIND_HOST_FAST=192.168.1.50 bash -c '
  source "'"${LLMCTL_ROOT}"'/lib/common.sh"
  source "'"${LLMCTL_ROOT}"'/lib/os_detect.sh"
  source "'"${LLMCTL_ROOT}"'/lib/hardware.sh"
  source "'"${LLMCTL_ROOT}"'/lib/catalog.sh"
  source "'"${LLMCTL_ROOT}"'/lib/scheduler.sh"
  export LLMCTL_DRY_RUN=1
  sched_build_launch fast cpu 8080 8192 99 1 auto
  printf "%s\n" "${SCHED_ARGS[*]}"
')"
assert_contains "${out}" "--host 192.168.1.50" \
  "llama engine: LLMCTL_BIND_HOST_FAST plumbs into sched_build_launch's real --host flag"

# --- 7. THE FUNCTIONAL PATH: sched_build_launch, colibri engine
# ("colibri-qwen36") - a fix touching only the llama branch would leave
# colibri's own hardcoded --host untouched. ------------------------------------
sched_build_launch colibri-qwen36 cpu 8091 8192 99 1 auto
assert_contains "${SCHED_ARGS[*]}" "--host 0.0.0.0" \
  "colibri engine, no override: sched_build_launch binds colibri-qwen36 to 0.0.0.0 (LAN-accessible default)"

out="$(LLMCTL_BIND_HOST=127.0.0.1 bash -c '
  source "'"${LLMCTL_ROOT}"'/lib/common.sh"
  source "'"${LLMCTL_ROOT}"'/lib/os_detect.sh"
  source "'"${LLMCTL_ROOT}"'/lib/hardware.sh"
  source "'"${LLMCTL_ROOT}"'/lib/catalog.sh"
  source "'"${LLMCTL_ROOT}"'/lib/scheduler.sh"
  export LLMCTL_DRY_RUN=1
  sched_build_launch colibri-qwen36 cpu 8091 8192 99 1 auto
  printf "%s\n" "${SCHED_ARGS[*]}"
')"
assert_contains "${out}" "--host 127.0.0.1" \
  "colibri engine: global LLMCTL_BIND_HOST=127.0.0.1 overrides colibri-qwen36 back to localhost-only"

# --- 8. lib/download.sh's smoke-test host is DELIBERATELY untouched -----------
# (one-shot, ephemeral, localhost-only verification during download - never
# LAN-reachable, regardless of LLMCTL_BIND_HOST; a regression here would
# mean the fix accidentally widened a surface it was never meant to touch).
assert_file_contains "${LLMCTL_ROOT}/lib/download.sh" "--host 127.0.0.1" \
  "lib/download.sh's smoke-test launch is still hardcoded to 127.0.0.1 (untouched by design)"

test_finish
