#!/usr/bin/env bash
# test_indirect_expansion_injection.sh - RED-first (review LOW-1). `${!var}` with a var NAME built from a profile name
# makes bash evaluate an array subscript, so a name like A[$(MKMARK)] runs the command substitution. The profile name must
# be allow-listed (valid_id) BEFORE the name is turned into a variable name (catalog_port, portreg_profile_var,
# portreg_dynamic_requested). The payload is entirely upper-case because the helpers upper-case the name.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
MARK="${TEST_TMP}/marker"
mkdir -p "${TEST_TMP}/bin"; printf '#!/bin/sh\ntouch "%s"\n' "${MARK}" > "${TEST_TMP}/bin/MKMARK"; chmod +x "${TEST_TMP}/bin/MKMARK"
export PATH="${TEST_TMP}/bin:${PATH}"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog portreg; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
EVIL='A[$(MKMARK)]'
chk() { if [[ -e "${MARK}" ]]; then printf '  FAIL: %s: the command substitution RAN\n' "$1" >&2; TEST_FAILS=$((TEST_FAILS+1)); rm -f "${MARK}"; else echo "  ok: $1: no side effect"; fi; }
rm -f "${MARK}"
( catalog_port "${EVIL}" ) >/dev/null 2>&1 || true;               chk "catalog_port hostile name"
( portreg_profile_var "${EVIL}" ) >/dev/null 2>&1 || true;        chk "portreg_profile_var hostile name"
( portreg_dynamic_requested "${EVIL}" ) >/dev/null 2>&1 || true;  chk "portreg_dynamic_requested hostile name"
( catalog_port_override_env_name "${EVIL}" ) >/dev/null 2>&1 || true; chk "catalog_port_override_env_name hostile name"
rc=0; ( portreg_dynamic_requested "${EVIL}" ) >/dev/null 2>&1 || rc=$?
[[ "${rc}" -ne 0 ]] && echo "  ok: a hostile name is never 'dynamic' (rc=${rc})" || { printf '  FAIL: portreg_dynamic_requested accepted a hostile name\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }
echo "== negative controls =="
assert_eq "8082" "$(catalog_port vision)" "catalog_port vision (catalog value)"
assert_eq "9999" "$(LLMCTL_PORT_VISION=9999 catalog_port vision)" "catalog_port honours the LLMCTL_PORT_VISION override"
assert_eq "LLMCTL_PORT_DECIDE_NLI" "$(portreg_profile_var decide-nli)" "portreg_profile_var maps decide-nli"
assert_eq "yes" "$(LLMCTL_PORT_VISION=auto portreg_dynamic_requested vision && echo yes || echo no)" "auto override still means dynamic"
test_finish
