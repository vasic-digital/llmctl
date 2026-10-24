#!/usr/bin/env bash
# test_no_secret_on_argv.sh - class sweep 2026-10-22 (C2): a key must never be expanded onto a command line (visible in `ps`,
# /proc/<pid>/cmdline). Scan tests/*.sh and every shell script under specs/*/evidence for a curl header
# -H "Authorization: Bearer ...$..." / -H "x-api-key: ...$..." (a variable or command substitution inside the header).
# Fix pattern: a 0600 header file and `-H @file` (curl reads it; nothing on argv). A literal junk value (no `$`) is not a secret.
# Control needles: a planted violation MUST be reported; the same call using -H @file MUST pass.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
PAT='(-H|--header)[ =]+["'"'"']?(Authorization:[^"'"'"']*Bearer|[Xx]-[Aa]pi-[Kk]ey:)[^"'"'"']*\$'
PAT2='sys1\.py[^|;]*("\$\(cat|"\$K"|"\$\{K\})'   # the python helper used to take the key as an argument
scan() { grep -nE -e "${PAT}" -e "${PAT2}" "$@" 2>/dev/null || true; }
printf '%s\n' 'curl -s -H "Authorization: Bearer $K" http://x' >"${TEST_TMP}/bad.sh"
printf '%s\n' 'curl -s -H "x-api-key: $(cat kf)" http://x' >"${TEST_TMP}/bad2.sh"
printf '%s\n' 'curl -s -H "@$hf" http://x' 'curl -s -H "Authorization: Bearer wrong-literal" http://x' >"${TEST_TMP}/good.sh"
assert_eq 1 "$(scan "${TEST_TMP}/bad.sh" | wc -l)" "control needle: Authorization with a variable is reported"
assert_eq 1 "$(scan "${TEST_TMP}/bad2.sh" | wc -l)" "control needle: x-api-key with a command substitution is reported"
printf '%s\n' 'python3 sys1.py $port "$(cat keyfile)" out t' >"${TEST_TMP}/bad3.sh"
assert_eq 1 "$(scan "${TEST_TMP}/bad3.sh" | wc -l)" "control needle: the key as a helper-script argument is reported"
assert_eq 0 "$(scan "${TEST_TMP}/good.sh" | wc -l)" "negative control: -H @file and a literal junk value pass"
files=("${LLMCTL_ROOT}"/tests/test_*.sh)
while IFS= read -r f; do files+=("$f"); done < <(find "${LLMCTL_ROOT}/specs" -path '*/evidence/*' -name '*.sh' -not -path '*/python-gateway-retired/*' | sort)
assert_eq yes "$([[ ${#files[@]} -gt 120 ]] && echo yes || echo no)" "the scan covers the tests and the evidence scripts (${#files[@]} files)"
# this file's own needles contain the pattern text; exclude it
mapfile -t hits < <(scan "${files[@]}" | grep -v -e "test_no_secret_on_argv.sh" -e "test_docs_no_literal_keys.sh" | grep -v "^[0-9]*:" || true)
if [[ ${#hits[@]} -gt 0 ]]; then printf 'violation: %s\n' "${hits[@]}" >&2; fi
assert_eq 0 "${#hits[@]}" "no test or evidence script puts a key on a command line"
test_finish
