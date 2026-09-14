#!/usr/bin/env bash
# test_syntax.sh - bash -n syntax check of every shipped script.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

shopt -s nullglob
scripts=( "${LLMCTL_ROOT}/bin/llmctl" "${LLMCTL_ROOT}"/lib/*.sh "${LLMCTL_ROOT}"/tests/*.sh )
echo "checking ${#scripts[@]} scripts with bash -n"
for s in "${scripts[@]}"; do
  rc=0
  bash -n "${s}" || rc=$?
  assert_eq 0 "${rc}" "bash -n ${s#"${LLMCTL_ROOT}/"}"
done

# Every shipped script must declare the bash shebang and strict mode.
for s in "${scripts[@]}"; do
  head -1 "${s}" | grep -q '^#!/usr/bin/env bash' \
    && assert_eq 0 0 "shebang: ${s#"${LLMCTL_ROOT}/"}" \
    || { assert_eq 0 1 "shebang: ${s#"${LLMCTL_ROOT}/"}"; }
  grep -q 'set -euo pipefail' "${s}" \
    && assert_eq 0 0 "strict mode: ${s#"${LLMCTL_ROOT}/"}" \
    || assert_eq 0 1 "strict mode: ${s#"${LLMCTL_ROOT}/"}"
done

test_finish
