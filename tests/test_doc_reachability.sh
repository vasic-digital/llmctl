#!/usr/bin/env bash
# test_doc_reachability.sh - Constitution 11.4.212: the main README is the entry point of ALL documentation; no doc under
# docs/ may be an orphan (unreachable, directly or transitively, through markdown links starting at README.md).
# scripts/check_doc_reachability.sh is the checker. It is proven here BEFORE it is trusted on the real tree:
#   * control needle: a planted orphan MUST be reported (a checker that cannot see an orphan says nothing about the tree);
#   * negative control: the same tree with the orphan linked MUST pass (no false positive);
#   * link forms: relative, ../ , anchors, directory links, titles, transitive chains;
#   * the real repository: zero orphans.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
CHECK="${LLMCTL_ROOT}/scripts/check_doc_reachability.sh"
assert_file_exists "${CHECK}" "scripts/check_doc_reachability.sh exists"

mk_tree() { # <dir>
  local d="$1"
  mkdir -p "${d}/docs/sub" "${d}/docs/dir"
  printf '# R\n[a](docs/a.md) [dir](docs/dir/) [ext](https://example.org/x.md) [anchor](docs/anchor.md#sec "title")\n' >"${d}/README.md"
  printf '# a\n[b](sub/b.md)\n' >"${d}/docs/a.md"
  printf '# b\n[back](../a.md) [c](../c.md)\n' >"${d}/docs/sub/b.md"
  printf '# c\n' >"${d}/docs/c.md"
  printf '# dir readme\n' >"${d}/docs/dir/README.md"
  printf '# anchor\n' >"${d}/docs/anchor.md"
}

T="${TEST_TMP}/tree"; mk_tree "${T}"
rc=0; out="$(bash "${CHECK}" --root "${T}" 2>&1)" || rc=$?
assert_eq 0 "${rc}" "a fully linked tree passes (relative, ../, anchor+title, directory and transitive links)"
assert_contains "${out}" "orphans=0" "the checker reports orphans=0 on the clean tree"

printf '# orphan\n' >"${T}/docs/orphan.md"
rc=0; out="$(bash "${CHECK}" --root "${T}" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "CONTROL NEEDLE: a planted orphan fails the check"
assert_contains "${out}" "docs/orphan.md" "the orphan is named"
assert_contains "${out}" "orphans=1" "exactly one orphan is counted"
case "${out}" in *"docs/sub/b.md"*) assert_eq "absent" "listed" "a transitively linked doc is not reported" ;; *) assert_eq 0 0 "a transitively linked doc is not reported" ;; esac

printf '[orphan](orphan.md)\n' >>"${T}/docs/c.md"
rc=0; out="$(bash "${CHECK}" --root "${T}" 2>&1)" || rc=$?
assert_eq 0 "${rc}" "NEGATIVE CONTROL: linking the orphan from a reachable doc makes the same tree pass"

# a doc reachable only from an orphan is still an orphan (reachability starts at README.md only)
printf '# deep\n' >"${T}/docs/deep.md"; printf '# island\n[deep](deep.md)\n' >"${T}/docs/island.md"
rc=0; out="$(bash "${CHECK}" --root "${T}" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "an island of docs linking only each other is unreachable"
assert_contains "${out}" "docs/deep.md" "the island's far end is reported too"

# --check-links: a broken link is a failure only when asked for
rm -f "${T}/docs/island.md" "${T}/docs/deep.md"
printf '[gone](nowhere.md)\n' >>"${T}/docs/c.md"
rc=0; bash "${CHECK}" --root "${T}" >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "a broken link does not fail the default check"
rc=0; out="$(bash "${CHECK}" --root "${T}" --check-links 2>&1)" || rc=$?
assert_eq 1 "${rc}" "--check-links fails on a broken link"
assert_contains "${out}" "nowhere.md" "the broken target is named"

# usage errors
rc=0; bash "${CHECK}" --bogus >/dev/null 2>&1 || rc=$?
assert_eq 2 "${rc}" "an unknown option is a usage error"
rc=0; bash "${CHECK}" --root "${TEST_TMP}/does-not-exist" >/dev/null 2>&1 || rc=$?
assert_eq 2 "${rc}" "a missing root is a usage error"
mkdir -p "${TEST_TMP}/empty"
rc=0; bash "${CHECK}" --root "${TEST_TMP}/empty" >/dev/null 2>&1 || rc=$?
assert_eq 2 "${rc}" "a root without README.md is a usage error (never a vacuous pass)"

# the real tree
rc=0; out="$(bash "${CHECK}" 2>&1)" || rc=$?
assert_eq 0 "${rc}" "the real repository has no orphan documentation (README.md is the entry point)"
assert_contains "${out}" "orphans=0" "real tree: orphans=0"
test_finish
