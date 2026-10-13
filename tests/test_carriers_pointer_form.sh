#!/usr/bin/env bash
# test_carriers_pointer_form.sh - every root governance carrier (CLAUDE/AGENTS/QWEN/GEMINI.md) must open with the standard
# constitution pointer-inheritance heading: a NON-FENCED `## INHERITED FROM ` heading at line start. This is the exact predicate of
# the constitution's scripts/gates/lib/pointer_carrier.sh (is_pointer_carrier); a carrier without it is judged a full-restating
# consumer and false-FAILs the propagation gates. The third-party superspec example template is deliberately NOT checked.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
is_pointer_carrier() {
  awk '
    BEGIN { fenced = 0; found = 0 }
    /^(```|~~~)/ { fenced = !fenced; next }
    !fenced && /^## INHERITED FROM / { found = 1; exit }
    END { exit !found }
  ' "$1"
}
for f in CLAUDE AGENTS QWEN GEMINI; do
  p="${LLMCTL_ROOT}/${f}.md"
  [[ -f "${p}" ]] || continue
  rc=0; is_pointer_carrier "${p}" || rc=$?
  assert_eq 0 "${rc}" "${f}.md has a non-fenced '## INHERITED FROM ' heading"
done
for f in CLAUDE AGENTS QWEN GEMINI; do
  p="${LLMCTL_ROOT}/${f}.md"; [[ -f "${p}" ]] || continue
  # the llmctl-specific body must survive the heading change
  assert_eq 1 "$(grep -q '^## Project-Specific Rules for llmctl' "${p}" && echo 1 || echo 0)" "${f}.md keeps its llmctl-specific rules"
done
test_finish
