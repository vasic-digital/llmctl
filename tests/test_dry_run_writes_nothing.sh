#!/usr/bin/env bash
# test_dry_run_writes_nothing.sh - `LLMCTL_DRY_RUN=1 llmctl install` must WRITE NOTHING.
#
# Root cause (2026-10-26, reproduced in a throw-away state tree before the fix: 3 unit templates, the enforcement marker
# `unit-enforcement` and the state directories were created under LLMCTL_DRY_RUN=1): svc_install (lib/service_linux.sh,
# lib/service_macos.sh) only guarded the systemctl / loginctl CALLS with LLMCTL_DRY_RUN; its file writes were unconditional,
# by an old design decision ("unit files are still written so their content is testable", used by ~80 hermetic tests).  To an
# operator "dry run" means "show me, change nothing" - and the marker it wrote switches every installed unit over to the
# validation gate, a real, host-wide behaviour change.
# Now: dry_run_pure (lib/common.sh) is true for LLMCTL_DRY_RUN=1 and the install path prints the plan and touches nothing.
# The historical file-writing mode is an EXPLICIT test seam, LLMCTL_DRY_RUN_WRITE=1, which tests/helpers.sh test_setup_env
# sets for the hermetic suites that read generated units; this suite unsets it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
unset LLMCTL_DRY_RUN_WRITE
rm -f "${LLMCTL_STATE_DIR}/unit-enforcement"        # test_setup_env models an INSTALLED llmctl; this suite starts from a clean host
rm -rf "${LLMCTL_STATE_DIR}/run" "${LLMCTL_STATE_DIR}/.test-harness"
SNAP_ROOT="${TEST_TMP}"

# snap - every path under TEST_TMP (directories included) with size and mtime: any create/modify/delete changes it
snap() { find "${SNAP_ROOT}" -mindepth 1 -printf '%p %y %s %T@\n' 2>/dev/null | sort; }

# check_dry_install <llmctl-bin> - prints the output; returns 0 when nothing was written, 3 when something was
check_dry_install() {
  local bin="$1" before after rc=0
  before="$(snap)"
  LLMCTL_DRY_RUN=1 "${bin}" install >"${TEST_TMP}/install.out" 2>&1 || rc=$?
  after="$(snap)"
  # the output capture itself lives in TEST_TMP: exclude it from the comparison
  before="$(grep -v '/install.out ' <<<"${before}" || true)"; after="$(grep -v '/install.out ' <<<"${after}" || true)"
  if [[ "${rc}" != 0 ]]; then echo "install exited ${rc}" >&2; return 4; fi
  if [[ "${before}" == "${after}" ]]; then return 0; fi
  diff <(echo "${before}") <(echo "${after}") | grep '^[<>]' | head -12 >&2 || true
  return 3
}

echo "== 1. LLMCTL_DRY_RUN=1 llmctl install: nothing is created, modified or removed"
rc=0; check_dry_install "${LLMCTL_ROOT}/bin/llmctl" 2>"${TEST_TMP}/diff.err" || rc=$?
assert_eq 0 "${rc}" "no file or directory was written (rc 0 = identical tree before/after; $(head -3 "${TEST_TMP}/diff.err" | tr '\n' '|'))"
out="$(cat "${TEST_TMP}/install.out")"
assert_contains "${out}" "[dry-run]" "the plan is printed with the [dry-run] prefix"
assert_contains "${out}" "llmctl-llama@.service" "the plan names the llama unit template it would write"
assert_contains "${out}" "unit-enforcement" "the plan names the enforcement marker it would write"
assert_contains "${out}" "daemon-reload" "the systemctl step is still printed, not run"
assert_contains "${out}" "enable-linger" "the linger step is still printed, not run"
if [[ -e "${LLMCTL_STATE_DIR}/unit-enforcement" ]]; then printf '  FAIL: the enforcement marker exists after a dry run\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: no enforcement marker after a dry run\n'; fi

echo "== 2. control: the historical test seam LLMCTL_DRY_RUN_WRITE=1 still writes (the harness can see writes - not vacuous)"
rc=0; LLMCTL_DRY_RUN_WRITE=1 check_dry_install "${LLMCTL_ROOT}/bin/llmctl" 2>/dev/null || rc=$?
assert_eq 3 "${rc}" "with LLMCTL_DRY_RUN_WRITE=1 the same install DOES write (units + marker), and the snapshot comparison sees it"
assert_file_exists "${LLMCTL_UNIT_DIR}/llmctl-llama@.service" "legacy mode: the unit template is written"
assert_file_exists "${LLMCTL_STATE_DIR}/unit-enforcement" "legacy mode: the marker is written"
rm -rf "${LLMCTL_UNIT_DIR}" "${LLMCTL_STATE_DIR}/unit-enforcement" "${LLMCTL_STATE_DIR}/services" "${LLMCTL_STATE_DIR}/verify" \
       "${LLMCTL_STATE_DIR}/logs" "${LLMCTL_STATE_DIR}/run" "${LLMCTL_MODELS_DIR}"

echo "== 3. launchd backend: svc_install under a dry run writes nothing either"
rc=0
before="$(snap)"
( source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_macos.sh"; LLMCTL_DRY_RUN=1 svc_install ) >"${TEST_TMP}/mac.out" 2>&1 || rc=$?
after="$(snap)"
before="$(grep -v '/mac.out ' <<<"${before}" || true)"; after="$(grep -v '/mac.out ' <<<"${after}" || true)"
assert_eq 0 "${rc}" "macOS svc_install under a dry run exits 0"
assert_eq "${before}" "${after}" "macOS svc_install under a dry run changed nothing"

echo "== 4. paired mutation: a dry-run guard that never fires (the pre-fix behaviour) must turn section 1 RED"
M="${TEST_TMP}/tree.mut"
mkdir -p "${M}/bin" "${M}/lib"
for e in "${LLMCTL_ROOT}"/*; do case "$(basename "${e}")" in bin|lib) ;; *) ln -s "${e}" "${M}/$(basename "${e}")" ;; esac; done
cp "${LLMCTL_ROOT}/bin/llmctl" "${M}/bin/llmctl"
for f in "${LLMCTL_ROOT}"/lib/*; do [[ "$(basename "${f}")" == common.sh ]] || ln -sf "${f}" "${M}/lib/"; done
python3 -I - "${LLMCTL_ROOT}/lib/common.sh" "${M}/lib/common.sh" <<'PY'
import sys
src, dst = sys.argv[1:3]
s = open(src).read()
old = 'dry_run_pure() { [[ "${LLMCTL_DRY_RUN:-0}" == "1" && "${LLMCTL_DRY_RUN_WRITE:-0}" != "1" ]]; }'
if s.count(old) != 1:
    sys.exit("mutation anchor found %d times (dry_run_pure moved?)" % s.count(old))
open(dst, "w").write(s.replace(old, 'dry_run_pure() { return 1; }'))
PY
if cmp -s "${LLMCTL_ROOT}/lib/common.sh" "${M}/lib/common.sh"; then printf '  FAIL: the mutant is identical to the original\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: the mutant differs from the original\n'; fi
rm -rf "${LLMCTL_UNIT_DIR}" "${LLMCTL_STATE_DIR}/unit-enforcement" "${LLMCTL_STATE_DIR}/services" "${LLMCTL_STATE_DIR}/verify" \
       "${LLMCTL_STATE_DIR}/logs" "${LLMCTL_STATE_DIR}/run" "${LLMCTL_MODELS_DIR}"
rc=0; check_dry_install "${M}/bin/llmctl" 2>/dev/null || rc=$?
assert_eq 3 "${rc}" "MUTANT (guard never fires) -> files were written: section 1 goes RED on the original defect"

test_finish
