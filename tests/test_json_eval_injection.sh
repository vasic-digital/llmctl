#!/usr/bin/env bash
# test_json_eval_injection.sh - RED-first security regression. json_stdin / json_query (lib/common.sh) run their argument
# through Python eval(); any call site that interpolates a profile name into that expression is code injection. Contract:
#   * the footprint lookup (_svc_write_mem_dropin), catalog_exists and the catalog field readers refuse a hostile profile
#     name (allow-list ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$) with NO side effect;
#   * json_stdin / json_query themselves refuse dunder/import expressions and run with restricted builtins (defence in
#     depth for the many call sites that interpolate an already-validated name);
#   * legitimate lookups still work (negative controls).
# The marker file lives inside this test's temp dir only.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
for l in common os_detect hardware catalog service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
MARK="${TEST_TMP}/llmctl-inject-$$"
# Valid-expression payloads (eval() takes an expression, not statements): each keeps the surrounding expression valid and
# runs the command as a side effect, for the three quoting styles used by the call sites.
SQ="vision']['ram_mb'] if __import__('os').system('touch ${MARK}') or True else d['profiles']['vision"
EVIL="${SQ}"
EVIL2="vision\"].get(\"port\") if __import__('os').system('touch ${MARK}') or True else d[\"profiles\"][\"vision"
EVIL_CE="x' in d[\"profiles\"] or __import__('os').system('touch ${MARK}') or 'y"
fired() { [[ -e "${MARK}" ]]; }
reset() { rm -f "${MARK:?}"; }
chk() { # <label>
  if fired; then printf '  FAIL: %s: injected command RAN (marker created)\n' "$1" >&2; TEST_FAILS=$((TEST_FAILS+1)); reset
  else echo "  ok: $1: no side effect"; fi
}

reset; ( _svc_write_mem_dropin "${EVIL}" llama ) >/dev/null 2>&1 || true; chk "_svc_write_mem_dropin hostile name"
reset; ( _svc_write_mem_dropin "${EVIL2}" llama ) >/dev/null 2>&1 || true; chk "_svc_write_mem_dropin hostile name (double quote)"
ls "${LLMCTL_UNIT_DIR}"/*.d >/dev/null 2>&1 && { printf '  FAIL: a drop-in directory was created for a hostile profile name\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); } || echo "  ok: no drop-in directory created for the hostile name"
reset; rc=0; ( catalog_exists "${EVIL_CE}" ) >/dev/null 2>&1 || rc=$?; chk "catalog_exists hostile name"
[[ "${rc}" -ne 0 ]] && echo "  ok: catalog_exists refuses (rc=${rc})" || { printf '  FAIL: catalog_exists accepted a hostile name\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }
reset; ( catalog_field "${EVIL2}" port ) >/dev/null 2>&1 || true; chk "catalog_field hostile name"
reset; ( catalog_capability "${EVIL2}" ) >/dev/null 2>&1 || true; chk "catalog_capability hostile name"
reset; printf '{"a":1}' | json_stdin "__import__('os').system('touch ${MARK}')" >/dev/null 2>&1 || true; chk "json_stdin refuses an import expression"
reset; printf '{"a":1}' > "${TEST_TMP}/d.json"; json_query "${TEST_TMP}/d.json" "__import__('os').system('touch ${MARK}')" >/dev/null 2>&1 || true; chk "json_query refuses an import expression"
reset; printf '{"a":1}' | json_stdin "[c for c in ().__class__.__bases__[0].__subclasses__() if c.__name__=='Popen'][0](['touch','${MARK}'])" >/dev/null 2>&1 || true; chk "json_stdin refuses a dunder-walk expression"

echo "== negative controls: legitimate lookups still work =="
assert_eq "1" "$(printf '{"a":1}' | json_stdin 'd["a"]')" "json_stdin legitimate expression"
assert_eq "2" "$(json_query "${TEST_TMP}/d.json" 'len(d.keys())+1')" "json_query legitimate expression (builtins len)"
assert_eq "yes" "$(catalog_exists vision >/dev/null 2>&1 && echo yes || echo no)" "catalog_exists vision"
assert_eq "no" "$(catalog_exists no-such-profile >/dev/null 2>&1 && echo yes || echo no)" "catalog_exists unknown profile"
( _svc_write_mem_dropin vision llama ) >/dev/null 2>&1 || true
assert_file_exists "${LLMCTL_UNIT_DIR}/llmctl-llama@vision.service.d/10-memory.conf" "legitimate profile still gets its memory drop-in"
test_finish
