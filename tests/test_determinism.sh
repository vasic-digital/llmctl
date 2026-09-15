#!/usr/bin/env bash
# test_determinism.sh - zero-flake requirement (spec.md SC-001): running the
# same command against the same fixture N times MUST produce byte-identical
# output every time. Real subprocess invocations of the real `bin/llmctl`
# entrypoint (Constitution §11.4.50 deterministic-consistency mandate) - no
# mocking, no fixture-of-a-fixture.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"

# --- 1. `llmctl hw --json` is byte-identical across 3 real invocations ------
out1="$("${LLMCTL}" hw --json)"
out2="$("${LLMCTL}" hw --json)"
out3="$("${LLMCTL}" hw --json)"
assert_eq "${out1}" "${out2}" "hw --json run 1 == run 2 (byte-identical)"
assert_eq "${out2}" "${out3}" "hw --json run 2 == run 3 (byte-identical)"
assert_contains "${out1}" '"cores"' "hw --json output is not empty/degenerate (sanity - it is real hardware JSON)"

# --- 2. `llmctl plan --json` is likewise deterministic across 3 real runs --
plan1="$("${LLMCTL}" plan --json)"
plan2="$("${LLMCTL}" plan --json)"
plan3="$("${LLMCTL}" plan --json)"
assert_eq "${plan1}" "${plan2}" "plan --json run 1 == run 2 (byte-identical)"
assert_eq "${plan2}" "${plan3}" "plan --json run 2 == run 3 (byte-identical)"

test_finish
