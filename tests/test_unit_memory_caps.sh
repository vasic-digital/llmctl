#!/usr/bin/env bash
# test_unit_memory_caps.sh - RED-first (fix/bounded-restart-and-pressure-gates).
# Root cause (2): lib/service_linux.sh svc_install wrote MemoryHigh=MemoryMax=<total RAM> for every unit, so a runaway
# profile could take the whole machine before its cgroup limit applied, and MemoryHigh==MemoryMax has no throttle zone.
# Contract asserted here: the EFFECTIVE cap of a profile (a per-profile drop-in
# <unit-dir>/llmctl-<engine>@<profile>.service.d/*.conf when present, else the template) is within [1.25x, 2.0x] of the
# profile's plan footprint (ram_mb); never total RAM; MemoryHigh < MemoryMax; plus swap/priority/stop-timeout directives.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
TOTAL=32768

# shellcheck disable=SC1090
for l in common os_detect hardware catalog service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done

FAKE_DECIDE="${TEST_TMP}/fake-decide"; printf '#!/bin/sh\nexit 0\n' > "${FAKE_DECIDE}"; chmod +x "${FAKE_DECIDE}"
export LLMCTL_DECIDE_BIN="${FAKE_DECIDE}"
mkdir -p "${LLMCTL_UNIT_DIR}"; : > "${LLMCTL_UNIT_DIR}/llmctl-decide-gateway.service"   # installed gateway -> regenerated
( svc_install ) >/dev/null 2>&1 || { echo "  FAIL: svc_install failed" >&2; TEST_FAILS=$((TEST_FAILS+1)); }

PLAN="${TEST_TMP}/plan.json"
hw_probe_json | catalog_plan_json > "${PLAN}"
fp() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["profiles"][sys.argv[2]]["ram_mb"])' "${PLAN}" "$1"; }

# val <file> <Key> -> last value of Key=, empty when absent
val() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
# to_mib <5000M|1G|bytes|infinity> -> MiB (empty for infinity/empty)
to_mib() { case "$1" in *M) echo "${1%M}";; *G) echo $(( ${1%G} * 1024 ));; ''|infinity) echo "";; *[!0-9]*) echo "";; *) echo $(( $1 / 1048576 ));; esac; }
# effective <engine> <profile> <Key> -> drop-in value if a drop-in sets it, else template value
effective() {
  local d="${LLMCTL_UNIT_DIR}/llmctl-$1@$2.service.d" v="" f
  if [[ -d "${d}" ]]; then for f in "${d}"/*.conf; do [[ -f "${f}" ]] && { x="$(val "${f}" "$3")"; [[ -n "${x}" ]] && v="${x}"; }; done; fi
  [[ -n "${v}" ]] || v="$(val "${LLMCTL_UNIT_DIR}/llmctl-$1@.service" "$3")"
  printf '%s' "${v}"
}

check_cap() { # <label> <engine> <profile> <unitfile-for-static-keys>
  local label="$1" eng="$2" prof="$3" f="$4" need cap hi lo2 hi2
  # a per-profile drop-in may be produced by writing the env + enabling (dry-run) - do it when the unit is a template
  if [[ "${eng}" != gateway ]]; then
    ( svc_write_env "${prof}" "${eng}" /bin/true --port 18999; svc_enable "${prof}" ) >/dev/null 2>&1 || true
  fi
  need="$(fp "${prof}")"
  cap="$(to_mib "$(effective "${eng}" "${prof}" MemoryMax)")"
  hi="$(to_mib "$(effective "${eng}" "${prof}" MemoryHigh)")"
  lo2=$(( need * 125 / 100 )); hi2=$(( need * 2 ))
  [[ "${cap}" != "${TOTAL}" ]] && echo "  ok: ${label}: MemoryMax != total RAM (${cap:-unset})" \
    || { printf '  FAIL: %s: MemoryMax equals total RAM (%s MiB)\n' "${label}" "${TOTAL}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
  if [[ -n "${cap}" && "${cap}" -ge "${lo2}" && "${cap}" -le "${hi2}" ]]; then echo "  ok: ${label}: MemoryMax ${cap} MiB within [${lo2},${hi2}] of footprint ${need}"
  else printf '  FAIL: %s: MemoryMax %s MiB not within [%s,%s] (1.25x-2.0x of plan footprint %s MiB)\n' "${label}" "${cap:-unset}" "${lo2}" "${hi2}" "${need}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  if [[ -n "${hi}" && -n "${cap}" && "${hi}" -lt "${cap}" ]]; then echo "  ok: ${label}: MemoryHigh < MemoryMax (throttle zone exists)"
  else printf '  FAIL: %s: MemoryHigh (%s) is not below MemoryMax (%s)\n' "${label}" "${hi:-unset}" "${cap:-unset}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
}

static_keys() { # <label> <unitfile>
  local label="$1" f="$2" t
  assert_eq "0" "$(val "${f}" MemorySwapMax)" "${label}: MemorySwapMax=0"
  assert_contains "$(grep -E '^Nice=' "${f}" || true)" "Nice=" "${label}: Nice= set"
  assert_contains "$(grep -E '^IOWeight=' "${f}" || true)" "IOWeight=" "${label}: IOWeight= set"
  assert_contains "$(grep -E '^OOMScoreAdjust=' "${f}" || true)" "OOMScoreAdjust=" "${label}: OOMScoreAdjust= set"
  t="$(val "${f}" TimeoutStopSec)"; t="${t%s}"
  if [[ "${t}" =~ ^[0-9]+$ && "${t}" -le 30 ]]; then echo "  ok: ${label}: TimeoutStopSec=${t}s <= 30"
  else printf '  FAIL: %s: TimeoutStopSec=%s (must be <= 30s)\n' "${label}" "${t:-unset}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  if [[ "$(val "${f}" MemoryHigh)" == "$(val "${f}" MemoryMax)" && -n "$(val "${f}" MemoryMax)" ]]; then
    printf '  FAIL: %s: MemoryHigh == MemoryMax (%s)\n' "${label}" "$(val "${f}" MemoryMax)" >&2; TEST_FAILS=$((TEST_FAILS+1))
  else echo "  ok: ${label}: MemoryHigh != MemoryMax"; fi
}

check_cap "llama/vision" llama vision "${LLMCTL_UNIT_DIR}/llmctl-llama@.service"
check_cap "colibri/colibri-qwen36" colibri colibri-qwen36 "${LLMCTL_UNIT_DIR}/llmctl-colibri@.service"
check_cap "onnx/decide-nli" onnx decide-nli "${LLMCTL_UNIT_DIR}/llmctl-onnx@.service"
for u in llama@ colibri@ onnx@; do static_keys "${u}.service" "${LLMCTL_UNIT_DIR}/llmctl-${u}.service"; done
static_keys "decide-gateway" "${LLMCTL_UNIT_DIR}/llmctl-decide-gateway.service"
gcap="$(to_mib "$(val "${LLMCTL_UNIT_DIR}/llmctl-decide-gateway.service" MemoryMax)")"
if [[ -n "${gcap}" && "${gcap}" -lt "${TOTAL}" ]]; then echo "  ok: decide-gateway: MemoryMax ${gcap} < total RAM"
else printf '  FAIL: decide-gateway: MemoryMax %s is not below total RAM %s\n' "${gcap:-unset}" "${TOTAL}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

# --- negative control: the SAME predicates must reject a literal copy of the old behaviour (MemoryHigh=MemoryMax=total)
OLD="${TEST_TMP}/old.service"
printf '[Service]\nMemoryHigh=%sM\nMemoryMax=%sM\n' "${TOTAL}" "${TOTAL}" > "${OLD}"
oldcap="$(to_mib "$(val "${OLD}" MemoryMax)")"; need="$(fp vision)"
neg=0
[[ "${oldcap}" != "${TOTAL}" ]] || neg=$((neg+1))
[[ "${oldcap}" -ge $(( need * 125 / 100 )) && "${oldcap}" -le $(( need * 2 )) ]] || neg=$((neg+1))
[[ "$(val "${OLD}" MemoryHigh)" != "$(val "${OLD}" MemoryMax)" ]] || neg=$((neg+1))
[[ -n "$(val "${OLD}" MemorySwapMax)" ]] || neg=$((neg+1))
assert_eq "4" "${neg}" "negative control: the predicates reject the old MemoryHigh=MemoryMax=total unit on all 4 counts"

test_finish
