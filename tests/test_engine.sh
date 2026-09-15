#!/usr/bin/env bash
# test_engine.sh - engine source-path resolution and submodule-presence
# detection. Full compiles (cmake/make against the real ~3500-file llama.cpp
# and colibri trees) are release-gating concerns (Clarification 1's hybrid
# approach), not part of this fast/deterministic suite - this file covers
# the parts of lib/engine.sh that are cheap and deterministic to verify:
# which directory it resolves as the engine SOURCE, and whether it
# correctly detects an initialized-vs-missing submodule there.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/engine.sh"

# --- 1. source paths resolve to the real pinned git submodules ---------------
# The project's actual git submodules (per .gitmodules, pinned tags,
# `git submodule status` clean) live under submodules/llama.cpp and
# submodules/colibri - NOT vendor/llama.cpp or vendor/colibri (which are a
# separate, un-pinned, directly-committed copy left over from an earlier
# design - see the Phase 3 investigation in tasks.md/progress.yml).
assert_eq "${LLMCTL_ROOT}/submodules/llama.cpp" "${LLMCTL_LLAMA_SRC}" \
  "LLMCTL_LLAMA_SRC resolves to the real git submodule, not the un-pinned vendor/ copy"
assert_eq "${LLMCTL_ROOT}/submodules/colibri" "${LLMCTL_COLIBRI_SRC}" \
  "LLMCTL_COLIBRI_SRC resolves to the real git submodule, not the un-pinned vendor/ copy"

# --- 2 & 3. engine_ensure_submodules checks the SAME paths (submodules/,
# not vendor/) against a fake LLMCTL_ROOT, run in its own subshell so the
# override never leaks into the rest of this test file. -----------------------
run_ensure_submodules() {
  # run_ensure_submodules <fake-root>
  (
    export LLMCTL_ROOT="$1"
    # shellcheck source=../lib/common.sh
    source "${TESTS_DIR}/../lib/common.sh"
    # shellcheck source=../lib/os_detect.sh
    source "${TESTS_DIR}/../lib/os_detect.sh"
    # shellcheck source=../lib/engine.sh
    source "${TESTS_DIR}/../lib/engine.sh"
    engine_ensure_submodules
  ) 2>&1
}

FAKE_ROOT="${TEST_TMP}/fake-root"
mkdir -p "${FAKE_ROOT}/submodules/llama.cpp" "${FAKE_ROOT}/submodules/colibri"
touch "${FAKE_ROOT}/submodules/llama.cpp/.git" "${FAKE_ROOT}/submodules/colibri/.git"

out="$(run_ensure_submodules "${FAKE_ROOT}")" && rc=0 || rc=$?
assert_eq 0 "${rc}" "engine_ensure_submodules exits 0 when submodules/{llama.cpp,colibri}/.git are present"
assert_eq "" "${out}" "no 'not initialized' warning when the real submodule paths are present"

# A missing submodule at the CORRECT path is detected and reported.
rm -f "${FAKE_ROOT}/submodules/colibri/.git"
out="$(run_ensure_submodules "${FAKE_ROOT}")" || true
assert_contains "${out}" "submodule submodules/colibri not initialized" \
  "missing submodule is reported at its real path (submodules/colibri), not the old vendor/colibri"

# --- 4. LLMCTL_DRY_RUN=1 prints the would-be build actions instead of
# actually invoking cmake/make - every other heavy/side-effecting module in
# this codebase (scheduler.sh, service_linux.sh, service_macos.sh,
# download.sh) already supports this; engine.sh was the one exception,
# which made verifying `llmctl setup`'s full orchestration in a fast test
# impossible without a real multi-minute compile. ---------------------------
export LLMCTL_DRY_RUN=1
captured="$(engine_build_llama 2>&1)"
assert_contains "${captured}" "[dry-run]" "engine_build_llama prints [dry-run] instead of invoking cmake"
assert_contains "${captured}" "cmake" "engine_build_llama's dry-run output names the cmake command it would run"

captured="$(engine_build_colibri 2>&1)"
assert_contains "${captured}" "[dry-run]" "engine_build_colibri prints [dry-run] instead of invoking make"

test_finish
