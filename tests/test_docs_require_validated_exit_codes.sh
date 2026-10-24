#!/usr/bin/env bash
# test_docs_require_validated_exit_codes.sh - the documented `require-validated` exit codes must match lib/validate.sh:
# require_validated() returns 0 (fresh passing record), 1 (NOT validated for ANY reason: no record, stale record, a record
# for another launch/host, a FAIL record) and 2 (cannot determine). "0 pass / 1 wrong answer / 2 undetermined" is the
# mapping of `llmctl validate` ONLY. A doc that glues the validate mapping onto require-validated is wrong (3.3.0 review).
# DOC_ROOT (default: the repository) lets the test be pointed at another tree to observe it RED.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
ROOT="${DOC_ROOT:-${LLMCTL_ROOT}}"

# yes <pattern> <text> -> prints 1 when the ERE matches, else 0 (no pipe into grep -q, no pipefail trap)
yes() { if grep -qE -- "$1" <<<"$2"; then echo 1; else echo 0; fi; }
# flat <file> -> the file on one line (so a sentence wrapped over lines is still one sentence)
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# the code contract the docs are checked against (control: these must exist, else this test is blind)
fn="$(sed -n '/^require_validated()/,/^}/p' "${LLMCTL_ROOT}/lib/validate.sh")"
assert_eq 1 "$(yes 'return 2' "${fn}")" "validate.sh: require_validated has a 'return 2' (cannot determine)"
assert_eq 1 "$(yes 'NOT validated for use' "${fn}")" "validate.sh: require_validated says 'NOT validated for use' on the return-1 path"
assert_eq 1 "$(yes '^[[:space:]]+return 1$' "${fn}")" "validate.sh: require_validated has the 'return 1' not-validated path"

for f in docs/faq.md docs/user-manual.md docs/validation.md README.md; do
  # forbidden: a require-validated sentence that maps 1 to "wrong answer" (window of 160 chars after the command)
  assert_eq 0 "$(yes 'require-validated[^.;]{0,160}`?0`? pass, `?1`? wrong answer' "$(flat "${ROOT}/${f}")")" "${f}: require-validated is not documented as '0 pass, 1 wrong answer'"
done
# required: the three docs that state the gate's exit codes say what 1 means for require-validated
for f in docs/faq.md docs/user-manual.md README.md; do
  assert_eq 1 "$(yes '[Nn][Oo][Tt] validated for any reason' "$(flat "${ROOT}/${f}")")" "${f}: exit 1 of require-validated = 'not validated for any reason'"
done
assert_eq 1 "$(yes 'For `llmctl validate`: `0` pass, `1` wrong answer' "$(flat "${ROOT}/docs/validation.md")")" "docs/validation.md: the 0/1/2 verdict mapping is scoped to 'llmctl validate'"
test_finish
