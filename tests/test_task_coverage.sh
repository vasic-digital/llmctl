#!/usr/bin/env bash
# test_task_coverage.sh - T121: every FR / SC in spec.md is cited by a task in tasks.md, and every ADOPT /
# ADOPT-AFTER-VERIFICATION idea in ideas-closure.md is cited too (tests/coverage_rows.sh). Both instruments are
# proven BEFORE they are trusted on the real tree: golden-good fixture = 0 gaps; golden-bad fixtures each name
# exactly the planted gap (control needles); an empty tree is BLIND (exit 2), never clean; prefix collisions
# (FR-1 vs FR-10, 1-I1 vs 1-I10) must not credit a citation. Then the real tree is run and its real gaps are
# printed - a gap is reported, never hidden.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }
TC="${LLMCTL_ROOT}/tests/py/task_coverage.py"
ROWS="${LLMCTL_ROOT}/tests/coverage_rows.sh"
assert_file_exists "${TC}" "task_coverage.py exists"
assert_file_exists "${ROWS}" "coverage_rows.sh exists"

mk() { # <dir> <tasks-text> <closure-extra-row>
  local d="$1"; mkdir -p "${d}/research"
  printf '# Spec\n- **FR-001**: a\n- **FR-010**: b\n- **FR-087**: c\n- **SC-001**: d\n' >"${d}/spec.md"
  printf '%s\n' "$2" >"${d}/tasks.md"
  printf '| Id | Idea | Disposition | Where |\n|---|---|---|---|\n| 1-I01 | a | ADOPT | x |\n| 1-I10 | b | ADOPT-AFTER-VERIFICATION | y |\n| 2-I01 | c | ADOPT-LATER | z |\n| 3-I08 | d | ADOPT (harness) / ADOPT-LATER | w |\n%s\n' "$3" >"${d}/research/ideas-closure.md"
}
run() { rc=0; out="$("$@" 2>&1)" || rc=$?; }
GOODTASKS='- [x] T1 FR-001, FR-010 SC-001 (FR-066..068, 087) ideas 1-I01 1-I10 3-I08(harness)'

G="${TEST_TMP}/good"; mk "${G}" "${GOODTASKS}" ""
run python3 "${TC}" fr-sc --specdir "${G}"; assert_eq 0 "${rc}" "golden-good fr-sc: 0 gaps"
assert_contains "${out}" "examined defined=4 cited=4" "fr-sc examined 4 definitions (instrument sees them)"
run "${ROWS}" "${G}"; assert_eq 0 "${rc}" "golden-good rows: 0 gaps"
assert_contains "${out}" "examined defined=3 cited=3" "rows examined 3 ADOPT ids (ADOPT-LATER excluded, split ADOPT kept)"

B="${TEST_TMP}/bad_fr"; mk "${B}" "- [x] T1 FR-001 SC-001 FR-087" ""
run python3 "${TC}" fr-sc --specdir "${B}"; assert_eq 1 "${rc}" "golden-bad fr-sc: uncited FR-010 fails"
assert_contains "${out}" "GAP FR-010" "gap names exactly the planted FR (FR-001 citation must not credit FR-010)"
case "${out}" in *"GAP FR-001"*|*"GAP SC-001"*|*"GAP FR-087"*) printf '  FAIL: false gap reported\n' >&2; TEST_FAILS=$((TEST_FAILS+1));; *) printf '  ok: no false gap\n';; esac

B="${TEST_TMP}/bad_sc"; mk "${B}" "- [x] T1 FR-001 FR-010 FR-087" ""
run python3 "${TC}" fr-sc --specdir "${B}"; assert_eq 1 "${rc}" "golden-bad fr-sc: uncited SC-001 fails"
assert_contains "${out}" "GAP SC-001" "gap names the planted SC"

B="${TEST_TMP}/bad_rng"; mk "${B}" "- [x] T1 FR-001 FR-010 SC-001 FR-066..068" ""
run python3 "${TC}" fr-sc --specdir "${B}"; assert_contains "${out}" "GAP FR-087" "a range that stops before FR-087 does not cover it"

B="${TEST_TMP}/bad_row"; mk "${B}" "- [x] T1 FR-001 FR-010 FR-087 SC-001 1-I01 3-I08" ""
run "${ROWS}" "${B}"; assert_eq 1 "${rc}" "golden-bad rows: uncited 1-I10 fails"
assert_contains "${out}" "GAP 1-I10" "gap names the planted idea id"
B="${TEST_TMP}/bad_pref"; mk "${B}" "- [x] T1 1-I01 1-I100 3-I08" ""
run "${ROWS}" "${B}"; assert_contains "${out}" "GAP 1-I10" "citing 1-I100 does not credit 1-I10 (prefix collision)"
B="${TEST_TMP}/bad_new"; mk "${B}" "${GOODTASKS}" "| 9-I99 | new | ADOPT | v |"
run "${ROWS}" "${B}"; assert_contains "${out}" "GAP 9-I99" "a newly added ADOPT row without a citation is caught"

E="${TEST_TMP}/empty"; mkdir -p "${E}"
run python3 "${TC}" fr-sc --specdir "${E}"; assert_eq 2 "${rc}" "empty tree: fr-sc BLIND (exit 2), not clean"
run "${ROWS}" "${E}"; assert_eq 2 "${rc}" "empty tree: rows BLIND (exit 2), not clean"
B="${TEST_TMP}/blind_spec"; mk "${B}" "${GOODTASKS}" ""; printf '# nothing defined\n' >"${B}/spec.md"
run python3 "${TC}" fr-sc --specdir "${B}"; assert_eq 2 "${rc}" "spec with no definitions: BLIND, not clean"

echo "== real tree =="
SPECDIR="${LLMCTL_ROOT}/specs/009-jev-decision-models"
run python3 "${TC}" fr-sc --specdir "${SPECDIR}"; frrc="${rc}"; frout="${out}"
run "${ROWS}" "${SPECDIR}"; rowrc="${rc}"; rowout="${out}"
printf '%s\n%s\n' "${frout}" "${rowout}"
case "${frout}" in *"examined defined="[1-9]*) printf '  ok: fr-sc saw definitions on the real tree\n';; *) printf '  FAIL: fr-sc examined nothing on the real tree\n' >&2; TEST_FAILS=$((TEST_FAILS+1));; esac
case "${rowout}" in *"examined defined="[1-9]*) printf '  ok: rows saw ADOPT ids on the real tree\n';; *) printf '  FAIL: rows examined nothing on the real tree\n' >&2; TEST_FAILS=$((TEST_FAILS+1));; esac
assert_eq 0 "${frrc}" "real tree: every FR/SC is cited by a task"
assert_eq 0 "${rowrc}" "real tree: every ADOPT idea is cited by a task"
test_finish
