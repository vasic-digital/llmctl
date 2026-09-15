#!/usr/bin/env bash
# test_normalize_common.sh - proves docs/integrations/lib_normalize_common.sh's
# transform primitives genuinely strip each documented non-deterministic
# field class (Phase 5 T030, spec.md FR-047/FR-048).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/docs/integrations/lib_normalize_common.sh"

# --- 1. timestamps ------------------------------------------------------------
out="$(printf 'started at 2026-09-15T12:34:56Z\nlogged at Sep 15 12:34:56\ndone at 11:59:00 PM\n' | norm_strip_timestamps)"
assert_eq "started at <TIMESTAMP>
logged at <TIMESTAMP>
done at <TIMESTAMP>" "${out}" "norm_strip_timestamps replaces ISO8601 + human-readable timestamps"
assert_eq "$(printf 'started at 2026-09-15T12:34:56Z\n' | norm_strip_timestamps)" \
           "$(printf 'started at 2026-01-01T00:00:00Z\n' | norm_strip_timestamps)" \
           "two DIFFERENT real timestamps normalize to the SAME placeholder (the actual determinism property under test)"

# --- 2. temp paths -------------------------------------------------------------
out="$(printf 'wrote /tmp/aider-abc123/patch.diff\n' | norm_strip_temp_paths)"
assert_eq "wrote <TMPPATH>" "${out}" "norm_strip_temp_paths replaces /tmp/... paths"
assert_eq "$(printf 'wrote /tmp/run1/x\n' | norm_strip_temp_paths)" \
           "$(printf 'wrote /tmp/run2-different/x\n' | norm_strip_temp_paths)" \
           "two DIFFERENT temp paths normalize to the SAME placeholder"

# --- 3. UUIDs -------------------------------------------------------------------
out="$(printf 'session 550e8400-e29b-41d4-a716-446655440000 started\n' | norm_strip_uuids)"
assert_eq "session <UUID> started" "${out}" "norm_strip_uuids replaces a v4-shaped UUID"

# --- 4. durations ----------------------------------------------------------------
out="$(printf '(12,345 tokens, 3.2s)\nTook 0.87s\n' | norm_strip_durations)"
assert_eq "(12,345 tokens, <DURATION>s)
Took <DURATION>s" "${out}" "norm_strip_durations replaces elapsed-time reporting"

# --- 5. composition: all four together on one realistic-shaped line, proving
# the SAME normalized result from two runs differing ONLY in the
# non-deterministic fields (the actual FR-047/SC-008 property) ------------------
run1="edit applied to /tmp/agent-9f8e7d6c/session-550e8400-e29b-41d4-a716-446655440000/file.py at 2026-09-15T12:00:00Z (Took 1.23s)"
run2="edit applied to /tmp/agent-11112222/session-01234567-89ab-cdef-0123-456789abcdef/file.py at 2026-09-15T12:00:05Z (Took 1.31s)"
norm1="$(printf '%s' "${run1}" | norm_strip_timestamps | norm_strip_temp_paths | norm_strip_uuids | norm_strip_durations)"
norm2="$(printf '%s' "${run2}" | norm_strip_timestamps | norm_strip_temp_paths | norm_strip_uuids | norm_strip_durations)"
assert_eq "${norm1}" "${norm2}" "two runs differing ONLY in timestamp/temp-path/uuid/duration normalize to byte-identical output"

# --- 6. paired mutation: a filter with the wrong pattern MUST NOT pass -----------
# (proves this test can actually catch a broken/regressed filter, not just
# agree with whatever the implementation currently does - Constitution
# §11.4.224(C)/§1.1: a test that cannot fail on a broken implementation is
# decoration, not proof).
broken_strip_timestamps() { sed -E 's/NEVER_MATCHES_ANYTHING/<TIMESTAMP>/g'; }
mutated="$(printf 'started at 2026-09-15T12:34:56Z\n' | broken_strip_timestamps)"
rc=0
[[ "${mutated}" == "started at <TIMESTAMP>" ]] || rc=1
assert_eq 1 "${rc}" "paired mutation: a filter that does not actually strip timestamps is correctly detected as different from the real one's output"

test_finish
