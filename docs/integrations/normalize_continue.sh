#!/usr/bin/env bash
# normalize_continue.sh - versioned normalization filter for continue.dev's
# full CLI-output artifact (Phase 5 T030, spec.md FR-047/FR-048/SC-008,
# Clarification 17).
#
# Purpose:
#   Live-challenge determinism (SC-008) is measured at the full CLI-agent-
#   output layer, not the raw model API response. This filter strips the
#   non-deterministic field classes Clarification 17 names by name
#   (timestamps, temp paths, ordering) from continue.dev's real run output
#   so two runs of the same fixed, seeded prompt (see lib/scheduler.sh's
#   LLMCTL_SEED) can be compared byte-for-byte after filtering.
#
# Usage:
#   cn -p "<fixed prompt>" | bash docs/integrations/normalize_continue.sh > normalized.txt
#   (run twice, diff the two normalized.txt files - identical means the
#   determinism property holds end-to-end for continue.dev)
#
# Inputs:
#   continue.dev's raw stdout on this script's stdin. Expected real shape
#   (per its own docs, not yet captured live): continue.dev's cn CLI headless output (tool-call trace, --format json optionally).
#
# Outputs:
#   The same text on stdout with timestamps, temp paths, session UUIDs, and
#   elapsed-time reporting replaced by stable placeholders (see
#   lib_normalize_common.sh for the exact substitutions).
#
# Side-effects: none (pure stdin -> stdout).
#
# Dependencies: bash, sed, and this directory's lib_normalize_common.sh.
#
# Cross-references:
#   docs/integrations.md                          - continue.dev config + install
#   docs/integrations/lib_normalize_common.sh     - shared transform primitives
#   tests/fixtures/agent_output/continue/          - fixture pair proving this filter
#   tests/test_normalize_agents.sh                 - the test that runs this proof
#
# Honest boundary (Constitution §11.4.6): the field classes handled here
# (timestamps/temp-paths/UUIDs/durations) are generic patterns, not
# reverse-engineered from a captured real continue.dev run against a live
# llmctl server - that capture is release-gating, real-GPU work (see
# docs/quickstart.md's live-challenge determinism section) and is NOT
# claimed done by this filter's existence. The "ordering" field class
# Clarification 17 also names is NOT yet addressed here: no real captured
# continue.dev transcript exists yet to reveal whether, or how, its output
# needs deterministic re-ordering - tracked as a release-gating follow-up
# once a real transcript is captured, rather than guessed at now.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib_normalize_common.sh"

cat | norm_strip_timestamps | norm_strip_temp_paths | norm_strip_uuids | norm_strip_durations
