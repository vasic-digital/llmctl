#!/usr/bin/env bash
# test_syntax.sh - bash -n syntax check of every shipped script.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

shopt -s nullglob
scripts=( "${LLMCTL_ROOT}/bin/llmctl" "${LLMCTL_ROOT}"/lib/*.sh "${LLMCTL_ROOT}"/tests/*.sh "${LLMCTL_ROOT}"/docs/integrations/*.sh "${LLMCTL_ROOT}"/scripts/release/*.sh )
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
  # a script may be exempt from -e only with an in-file "# STRICT-EXEMPT: <reason>" line AND still set -u/pipefail
  if grep -q 'set -euo pipefail' "${s}" || { grep -q '^# STRICT-EXEMPT: .\+' "${s}" && grep -q '^set -uo pipefail' "${s}"; }; then
    assert_eq 0 0 "strict mode: ${s#"${LLMCTL_ROOT}/"}"
  else
    assert_eq 0 1 "strict mode: ${s#"${LLMCTL_ROOT}/"}"
  fi
done

test_finish
