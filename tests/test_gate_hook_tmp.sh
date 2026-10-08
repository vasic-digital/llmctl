#!/usr/bin/env bash
# test_gate_hook_tmp.sh - templates/agents/llmctl-gate-hook.sh must not write through a predictable
# /tmp name (review-2 C-17). The old wrapper redirected the gate's stderr to
# ${TMPDIR}/llmctl-gate.$$.err; with a symlink planted at that name (the pid is knowable: the plant
# runs in the same process, then exec's the hook) it truncated the symlink's victim. The hook is run
# for real; only the gateway is unreachable on purpose (the gate then fails closed with an "ask").
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
HOOK="${LLMCTL_ROOT}/templates/agents/llmctl-gate-hook.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }
SHARED="${TEST_TMP}/shared-tmp"; mkdir -p "${SHARED}"
VICTIM="${TEST_TMP}/victim.txt"; printf 'PRECIOUS\n' >"${VICTIM}"
EVENT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp","session_id":"s1"}'
rc=0
out="$(printf '%s' "${EVENT}" | TMPDIR="${SHARED}" LLMCTL_ENDPOINT=https://127.0.0.1:1 bash -c '
  ln -s "'"${VICTIM}"'" "${TMPDIR}/llmctl-gate.$$.err"   # the name the OLD hook used (same pid after exec)
  exec bash "'"${HOOK}"'" --agent claude-code' 2>/dev/null)" || rc=$?
assert_eq "PRECIOUS" "$(cat "${VICTIM}")" "a symlink planted at the predictable name did not get its target truncated"
assert_contains "${out}" '"permissionDecision": "ask"' "the hook still fails closed (ask) with the gateway unreachable"
assert_eq "0" "${rc}" "...and exits 0 with that decision"
assert_eq "" "$(find "${SHARED}" -mindepth 1 ! -type l)" "no stray temp file is left behind (the planted link is the only entry)"
# an unwritable TMPDIR: the hook is fail-closed, not fail-open
rc=0; out="$(printf '%s' "${EVENT}" | TMPDIR="${TEST_TMP}/does/not/exist" bash "${HOOK}" --agent claude-code 2>"${TEST_TMP}/e")" || rc=$?
assert_eq "2" "${rc}" "no private temp file can be made: blocked (exit 2), never allowed"
assert_file_contains "${TEST_TMP}/e" "cannot create a private temporary file" "...with the reason"
test_finish
