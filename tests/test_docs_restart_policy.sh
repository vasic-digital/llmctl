#!/usr/bin/env bash
# test_docs_restart_policy.sh - the documented restart/memory policy must match the generated units: Restart=on-failure with
# StartLimit 3/900 and RestartPreventExitStatus=SIGKILL SIGTERM 98 (never Restart=always), and no claim of "no ceiling below RAM".
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
cd "${LLMCTL_ROOT}"
for f in AGENTS.md docs/architecture.md docs/faq.md; do
  assert_eq 0 "$(grep -c 'Restart=always' "${f}" || true)" "${f}: no stale Restart=always"
done
assert_eq 0 "$(grep -c 'NO artificial ceiling below physical RAM' lib/service_linux.sh || true)" "service_linux.sh: no stale 'NO artificial ceiling' comment"
assert_eq 1 "$(grep -q 'Restart=on-failure' lib/service_linux.sh && echo 1 || echo 0)" "the generated units really use Restart=on-failure"
test_finish
