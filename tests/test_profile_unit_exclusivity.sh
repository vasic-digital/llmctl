#!/usr/bin/env bash
# test_profile_unit_exclusivity.sh - RED-first. Defect: ~/.local/state/llmctl/services/<profile>.env is keyed by PROFILE,
# so llmctl-llama@decide-nli and llmctl-onnx@decide-nli were BOTH enabled for one profile (_svc_unit_for ~428,
# svc_enable ~457 enable the unit for the engine in the env file and never disable a sibling engine's unit).
# Contract: svc_enable <profile> leaves exactly ONE enabled llmctl-*@<profile>.service. "Enabled" in the fixture =
# a symlink in $LLMCTL_UNIT_DIR/default.target.wants/; the stale sibling must be removed, or (dry-run) a
# `disable llmctl-<other>@<profile>.service` command emitted. Only a temp LLMCTL_UNIT_DIR is used.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
for l in common os_detect hardware service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
W="${LLMCTL_UNIT_DIR:?}/default.target.wants"; mkdir -p "${W}" "${LLMCTL_SERVICES_DIR}"
( svc_install ) >/dev/null 2>&1
clear_w() { find "${W:?}" -maxdepth 1 -type l -delete; }
enable_both() { clear_w; ln -s ../llmctl-llama@.service "${W}/llmctl-llama@decide-nli.service"; ln -s ../llmctl-onnx@.service "${W}/llmctl-onnx@decide-nli.service"; }
count() { find "${W}" -maxdepth 1 -name 'llmctl-*@decide-nli.service' | wc -l; }
printf 'LLMCTL_PROFILE=decide-nli\nLLMCTL_ENGINE=onnx\nLLMCTL_PORT=8096\n' > "${LLMCTL_SERVICES_DIR}/decide-nli.env"

enable_both; assert_eq "2" "$(count)" "fixture: two enabled units for decide-nli (the live-host state)"
out="$( ( svc_enable decide-nli ) 2>&1 )" || true
n="$(count)"
if [[ "${n}" == 1 ]] || [[ "${out}" == *"disable llmctl-llama@decide-nli.service"* ]]; then echo "  ok: svc_enable decide-nli removes/disables the stale llama sibling (enabled symlinks left: ${n})"
else printf '  FAIL: svc_enable decide-nli left %s enabled units for one profile and emitted no disable of llmctl-llama@decide-nli.service\n    output: %.300s\n' "${n}" "${out}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if [[ -e "${W}/llmctl-onnx@decide-nli.service" || "${out}" == *"enable llmctl-onnx@decide-nli.service"* ]]; then echo "  ok: the engine of record (onnx) stays enabled"
else printf '  FAIL: the onnx unit of record is no longer enabled\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

echo "== negative control: a profile with a single enabled unit is untouched =="
clear_w; ln -s ../llmctl-onnx@.service "${W}/llmctl-onnx@decide-nli.service"
out="$( ( svc_enable decide-nli ) 2>&1 )" || true
assert_eq "1" "$(count)" "single enabled unit stays enabled"
case "${out}" in *"disable llmctl-"*) printf '  FAIL: a disable was emitted for a profile with one enabled unit: %s\n' "${out}" >&2; TEST_FAILS=$((TEST_FAILS+1));; *) echo "  ok: no spurious disable";; esac
test_finish
