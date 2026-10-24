#!/usr/bin/env bash
# test_no_trap_replacement.sh - class sweep 2026-10-22: a second `trap '...' EXIT` in a test REPLACES the first, so a fixture
# process the first trap would have killed (HTTP_PID) is leaked. Scan: within one tests/*.sh file, for every pair of
# top-level EXIT traps, each ${VAR} / $VAR named in the earlier trap body must also be named in the later one.
# Control needles: a planted file with the defect MUST be reported; the same file fixed MUST pass.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
SCAN="${TEST_TMP}/scan.py"
cat >"${SCAN}" <<'PY'
import re,sys
bad=0
for f in sys.argv[1:]:
    traps=[]
    for n,l in enumerate(open(f,errors="replace"),1):
        m=re.match(r"""^trap\s+(['"])(.*)\1\s+EXIT\s*$""",l.rstrip("\n"))
        if m: traps.append((n,set(re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)",m.group(2)))))
    for i in range(1,len(traps)):
        for j in range(i):
            miss=traps[j][1]-traps[i][1]
            if miss:
                print(f"{f}:{traps[i][0]}: EXIT trap replaces the one at line {traps[j][0]} and drops {sorted(miss)}"); bad+=1
sys.exit(1 if bad else 0)
PY
printf '%s\n' "trap 'kill \${A_PID}' EXIT" "trap 'kill \${B_PID}' EXIT" >"${TEST_TMP}/bad.sh"
printf '%s\n' "trap 'kill \${A_PID}' EXIT" "trap 'kill \${A_PID} \${B_PID}' EXIT" >"${TEST_TMP}/good.sh"
rc=0; python3 "${SCAN}" "${TEST_TMP}/bad.sh" >/dev/null || rc=$?
assert_eq 1 "${rc}" "control needle: a planted trap replacement is reported"
rc=0; python3 "${SCAN}" "${TEST_TMP}/good.sh" >/dev/null || rc=$?
assert_eq 0 "${rc}" "negative control: a trap that keeps every earlier variable passes"
rc=0; out="$(python3 "${SCAN}" "${LLMCTL_ROOT}"/tests/test_*.sh 2>&1)" || rc=$?
[[ -z "${out}" ]] || printf '%s\n' "${out}" >&2
assert_eq 0 "${rc}" "no tests/test_*.sh replaces an earlier EXIT trap and drops its variables"
assert_eq yes "$([[ $(ls "${LLMCTL_ROOT}"/tests/test_*.sh | wc -l) -gt 100 ]] && echo yes || echo no)" "the scan covered the whole test directory (>100 files)"
test_finish
