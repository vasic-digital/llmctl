#!/usr/bin/env bash
# test_mem_dropin_lifecycle.sh - RED-first (review MEDIUM-2). The per-profile memory drop-in must exist for every enabled
# profile, never fail silently, be reported when missing, and not leak: `llmctl install` writes it (and the footprint
# record) for already-enabled profiles; a skipped write warns; svc_stale_units reports an installed engine unit with no
# cap file; svc_disable removes llmctl's own 05-memory.conf (never the operator's 10-hostsafety.conf); an engine change
# does not leave the other engine's drop-in behind.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
U="${LLMCTL_UNIT_DIR}"; W="${U}/default.target.wants"; mkdir -p "${W}" "${LLMCTL_SERVICES_DIR}"
D="${U}/llmctl-llama@vision.service.d"

echo "== install writes the cap for an already-enabled profile =="
printf 'LLMCTL_PROFILE=vision\nLLMCTL_ENGINE=llama\nLLMCTL_PORT=8082\n' > "${LLMCTL_SERVICES_DIR}/vision.env"
( svc_install ) >/dev/null 2>&1 || true
ln -s ../llmctl-llama@.service "${W}/llmctl-llama@vision.service"
( svc_install ) >/dev/null 2>&1 || true
assert_file_exists "${D}/05-memory.conf" "svc_install wrote 05-memory.conf for the enabled profile vision"
assert_file_contains "${LLMCTL_SERVICES_DIR}/vision.env" "LLMCTL_FOOTPRINT_MB=" "...and recorded LLMCTL_FOOTPRINT_MB in its env record"

echo "== a skipped write is loud =="
out="$( ( unset -f catalog_plan_json; _svc_write_mem_dropin vision llama ) 2>&1 )" || true
assert_contains "${out}" "no per-profile memory cap" "skipped drop-in write prints a warning"

echo "== an installed engine unit without a cap file is reported =="
rm -rf "${D}"
stale="$(svc_stale_units 2>&1)"
assert_contains "${stale}" "no per-profile memory cap" "svc_stale_units reports llmctl-llama@vision without a cap file"
assert_contains "${stale}" "llmctl-llama@vision" "...naming the unit"

echo "== disable removes llmctl's own drop-in, never the operator's =="
mkdir -p "${D}"; printf '[Service]\nMemoryMax=1G\n' > "${D}/05-memory.conf"; printf '[Service]\nMemoryMax=2G\n' > "${D}/10-hostsafety.conf"
( svc_disable vision ) >/dev/null 2>&1 || true
assert_file_absent "${D}/05-memory.conf" "svc_disable removed 05-memory.conf"
assert_file_exists "${D}/10-hostsafety.conf" "svc_disable left the operator's 10-hostsafety.conf"

echo "== an engine change leaves no stale drop-in for the other engine =="
S="${U}/llmctl-llama@small.service.d"; mkdir -p "${S}"; printf '[Service]\nMemoryMax=1G\n' > "${S}/05-memory.conf"
( _svc_write_mem_dropin small colibri ) >/dev/null 2>&1 || true
assert_file_absent "${S}/05-memory.conf" "the llama drop-in for small was removed when small became a colibri unit"
assert_file_exists "${U}/llmctl-colibri@small.service.d/05-memory.conf" "the colibri drop-in exists"
echo "== N3: a scaled instance key (decide-tiny.2) takes the base profile's cap, without a warning =="
printf 'LLMCTL_PROFILE=decide-tiny\nLLMCTL_ENGINE=llama\nLLMCTL_PORT=8099\n' > "${LLMCTL_SERVICES_DIR}/decide-tiny.2.env"
out="$( _svc_write_mem_dropin decide-tiny.2 llama 2>&1 )" || true
case "${out}" in *"no per-profile memory cap"*) printf '  FAIL: N3: warned for a scaled instance whose base profile is known: %s\n' "${out}" >&2; TEST_FAILS=$((TEST_FAILS+1));; *) echo "  ok: N3: no warning";; esac
assert_file_exists "${U}/llmctl-llama@decide-tiny.2.service.d/05-memory.conf" "N3: the scaled instance got a per-profile cap file"
assert_file_contains "${LLMCTL_SERVICES_DIR}/decide-tiny.2.env" "LLMCTL_FOOTPRINT_MB=" "N3: footprint recorded for the scaled instance"
test_finish
