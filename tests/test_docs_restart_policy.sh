#!/usr/bin/env bash
# test_docs_restart_policy.sh - the documented restart/memory policy must match the generated units: Restart=on-failure with
# StartLimit 3/900 and RestartPreventExitStatus=SIGKILL SIGTERM 98 (never Restart=always), and no claim of "no ceiling below RAM".
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
cd "${LLMCTL_ROOT}"
for f in AGENTS.md CLAUDE.md QWEN.md GEMINI.md docs/architecture.md docs/faq.md; do
  assert_eq 0 "$(grep -c 'Restart=always' "${f}" || true)" "${f}: no stale Restart=always"
done
for f in lib/svc_hook.sh lib/scheduler.sh; do
  assert_eq 0 "$(grep -c 'Restart=always' "${f}" || true)" "${f}: no comment describing the current policy as Restart=always"
done
# F1: the user manual, the service_linux/test_services* script docs and the test classification doc describe CURRENT behaviour
for f in docs/user-manual.md docs/scripts/service_linux.md docs/scripts/test_services.md docs/scripts/test_services_crashloop.md docs/testing/TEST_TYPE_CLASSIFICATION.md; do
  assert_eq 0 "$(grep -c 'Restart=always' "${f}" || true)" "${f}: no stale Restart=always"
  assert_eq 0 "$(grep -c 'StartLimitBurst=5\|StartLimitBurst` (5)\|StartLimitIntervalSec=60' "${f}" || true)" "${f}: no stale StartLimit 5/60"
done
assert_eq 0 "$(grep -c 'hard cgroup ceiling at the physical limit' docs/user-manual.md || true)" "docs/user-manual.md: no stale 'ceiling at the physical limit'"
assert_eq 0 "$(grep -c 'NO artificial ceiling below physical RAM' lib/service_linux.sh || true)" "service_linux.sh: no stale 'NO artificial ceiling' comment"
assert_eq 1 "$(grep -q 'Restart=on-failure' lib/service_linux.sh && echo 1 || echo 0)" "the generated units really use Restart=on-failure"
test_finish
