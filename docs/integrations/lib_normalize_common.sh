#!/usr/bin/env bash
# lib_normalize_common.sh - shared normalization primitives for the 7
# per-agent CLI-output normalization filters (Phase 5 T030,
# specs/001-llmctl-completion/spec.md FR-047/FR-048/SC-008/Clarification 17).
#
# Purpose:
#   Live-challenge determinism is measured at the full CLI-agent-output
#   layer (the complete artifact each agent produces), not the raw model
#   API response - so two runs of the same deterministic prompt (see
#   lib/scheduler.sh's LLMCTL_SEED, Phase 5 T029) are compared AFTER
#   stripping known non-deterministic fields that vary between runs for
#   reasons that have nothing to do with the model's actual answer:
#   wall-clock timestamps, per-run temp-directory/session-id paths, and
#   (where a given agent's output genuinely has no defined order) line
#   ordering. This file holds the transformation PRIMITIVES; each
#   normalize_<agent>.sh applies the subset relevant to that agent's real
#   output shape and documents why.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib_normalize_common.sh"
#   norm_strip_timestamps <<<"${raw}" | norm_strip_temp_paths | norm_strip_uuids
#
# Inputs:
#   Each `norm_*` function reads its transformation input on stdin.
#
# Outputs:
#   The transformed text on stdout, with the corresponding non-deterministic
#   field class replaced by a stable, greppable placeholder token
#   (`<TIMESTAMP>`, `<TMPPATH>`, `<UUID>`, `<DURATION>`) - the SAME
#   placeholder every time, which is what makes two independent runs
#   comparable byte-for-byte after filtering.
#
# Side-effects: none (pure stdin -> stdout text transforms).
#
# Dependencies: bash, sed. No llmctl lib/ sourcing - standalone by design,
# exactly like the sibling install_<agent>.sh scripts.
#
# Cross-references:
#   docs/integrations.md                    - per-agent normalization docs
#   docs/integrations/normalize_<agent>.sh   - the 7 per-agent filters
#   tests/fixtures/agent_output/<agent>/     - fixture pairs proving each filter
#   specs/001-llmctl-completion/spec.md      - FR-047, FR-048, SC-008, Clarification 17
#
# Honest boundary (Constitution §11.4.6): these primitives strip the THREE
# non-deterministic field CLASSES spec.md Clarification 17 names by name
# (timestamps, temp paths, ordering). They are deliberately generic patterns,
# not reverse-engineered from a captured real run of any of the 7 agents
# against a live llmctl server (that capture is release-gating, real-GPU
# work per Clarification 1's hybrid approach and is NOT claimed done here -
# see docs/quickstart.md's live-challenge determinism section). Each
# per-agent filter's header states plainly that its exact regex set is
# expected to be refined once a real captured transcript is available.
set -euo pipefail

# ISO 8601 timestamps (2026-09-15T12:34:56Z, with optional fractional
# seconds and +HH:MM/-HH:MM offset) and common human-readable log timestamps
# (Sep 15 12:34:56, 12:34:56 PM).
norm_strip_timestamps() {
  sed -E \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})?/<TIMESTAMP>/g' \
    -e 's/[A-Z][a-z]{2} [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2}/<TIMESTAMP>/g' \
    -e 's/[0-9]{1,2}:[0-9]{2}:[0-9]{2} ?(AM|PM)/<TIMESTAMP>/g'
}

# Per-run temp-directory paths: /tmp/<random>, macOS's /var/folders/.../T/...,
# and Windows-style %TEMP%-derived paths that leak into cross-platform tool
# output as C:\Users\...\AppData\Local\Temp\....
norm_strip_temp_paths() {
  sed -E \
    -e 's#/tmp/[A-Za-z0-9_./-]+#<TMPPATH>#g' \
    -e 's#/var/folders/[A-Za-z0-9_./-]+#<TMPPATH>#g' \
    -e 's#[A-Za-z]:\\Users\\[^\\]+\\AppData\\Local\\Temp\\[A-Za-z0-9_.\\-]+#<TMPPATH>#g'
}

# UUID v4-shaped session/request identifiers (8-4-4-4-12 hex), which several
# of these agents embed in per-run temp paths, log lines, or trace IDs.
norm_strip_uuids() {
  sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<UUID>/g'
}

# Wall-clock durations / elapsed-time reporting the agent prints alongside
# its real answer (e.g. "(12,345 tokens, 3.2s)", "Took 0.87s") - the
# underlying deterministic answer is unaffected by how long this particular
# run happened to take.
norm_strip_durations() {
  sed -E \
    -e 's/[0-9]+(\.[0-9]+)?s\)/<DURATION>s)/g' \
    -e 's/Took [0-9]+(\.[0-9]+)?s/Took <DURATION>s/g'
}
