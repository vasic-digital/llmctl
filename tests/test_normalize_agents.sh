#!/usr/bin/env bash
# test_normalize_agents.sh - proves each of the 7 per-agent normalization
# filters (docs/integrations/normalize_<agent>.sh) turns two runs that
# differ ONLY in known non-deterministic fields (timestamp, temp path,
# session UUID, duration) into byte-identical output (Phase 5 T030,
# spec.md FR-047/FR-048/SC-008, Clarification 17).
#
# Honest boundary (Constitution §11.4.6, stated once here for all 7 agents):
# the fixtures in tests/fixtures/agent_output/<agent>/ are SYNTHETIC -
# constructed to exercise the documented non-deterministic field classes
# (timestamps/temp-paths/UUIDs/durations), not captured from a real run of
# any agent against a live llmctl server (that capture is release-gating,
# real-GPU work - see docs/quickstart.md). This test proves the FILTER
# MECHANICS are correct and reproducible; it does NOT claim "two runs of
# the same fixed prompt through the real agent produce byte-identical
# output" has been verified live - that verification remains a documented,
# separately-tracked release-gating step (Clarification 1's hybrid
# approach), exactly as T015's real-model verification is.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

INTEG="${LLMCTL_ROOT}/docs/integrations"
FIXDIR="${LLMCTL_ROOT}/tests/fixtures/agent_output"

for agent in opencode pi crush claude_code aider continue cline; do
  script="${INTEG}/normalize_${agent}.sh"
  fdir="${FIXDIR}/${agent}"

  assert_file_exists "${script}" "normalize_${agent}.sh exists"
  rc=0
  bash -n "${script}" || rc=$?
  assert_eq 0 "${rc}" "normalize_${agent}.sh is syntactically valid"

  assert_file_exists "${fdir}/run1.txt" "${agent}: run1 fixture exists"
  assert_file_exists "${fdir}/run2.txt" "${agent}: run2 fixture exists"
  assert_file_exists "${fdir}/expected_normalized.txt" "${agent}: expected_normalized fixture exists"

  norm1="$(bash "${script}" < "${fdir}/run1.txt")"
  norm2="$(bash "${script}" < "${fdir}/run2.txt")"
  expected="$(cat "${fdir}/expected_normalized.txt")"

  assert_eq "${norm1}" "${norm2}" "${agent}: two runs differing only in non-deterministic fields normalize to byte-identical output"
  assert_eq "${expected}" "${norm1}" "${agent}: normalized output matches the checked-in expected fixture"
done

test_finish
