#!/usr/bin/env bash
# test_setup_e2e.sh - fresh-clone simulation of `llmctl setup` (FR-001, US1
# Acceptance Scenario 1: "Given a fresh clone of llmctl, When running
# ./bin/llmctl setup, Then all engines build, hardware is probed, and the
# model catalog is validated").
#
# A genuinely fresh clone doesn't have gigabytes of already-built engine
# source ready to compile in seconds, so this test builds a real,
# structurally-fresh LLMCTL_ROOT (bin/ and lib/ symlinked read-only from the
# real repo - the CODE under test; fake submodules/*/.git markers - a fresh
# clone that ran `git submodule update --init` but hasn't built anything
# yet) and runs the REAL `bin/llmctl setup` entrypoint as a subprocess
# against it with LLMCTL_DRY_RUN=1 (release-gating real compiles are a
# separate, documented manual procedure - see docs/quickstart.md, T015).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

FRESH_ROOT="${TEST_TMP}/fresh-clone"
mkdir -p "${FRESH_ROOT}/bin" "${FRESH_ROOT}/models" "${FRESH_ROOT}/submodules/llama.cpp" "${FRESH_ROOT}/submodules/colibri"

ln -s "${LLMCTL_ROOT}/bin/llmctl" "${FRESH_ROOT}/bin/llmctl"
ln -s "${LLMCTL_ROOT}/lib" "${FRESH_ROOT}/lib"
ln -s "${LLMCTL_ROOT}/models/catalog.json" "${FRESH_ROOT}/models/catalog.json"
# A fresh `git submodule update --init` leaves a .git file/link in each
# submodule but nothing built yet - exactly what engine_ensure_submodules
# checks for.
touch "${FRESH_ROOT}/submodules/llama.cpp/.git" "${FRESH_ROOT}/submodules/colibri/.git"

export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
export LLMCTL_DRY_RUN=1

out="$("${FRESH_ROOT}/bin/llmctl" setup 2>&1)" && rc=0 || rc=$?
echo "${out}" | sed 's/^/  /'

assert_eq 0 "${rc}" "llmctl setup exit code (fresh-clone simulation)"
assert_contains "${out}" "llmctl setup: doctor -> build -> plan" "setup announces its own orchestration sequence"

# Hardware probed (from the deterministic baseline fixture, not the real host).
assert_contains "${out}" "PASS OS:" "doctor phase: hardware/OS probe ran"
assert_contains "${out}" "submodule submodules/llama.cpp initialized" "doctor phase: real submodule path checked (not the removed vendor/ path)"
assert_contains "${out}" "submodule submodules/colibri initialized" "doctor phase: real submodule path checked (not the removed vendor/ path)"
assert_contains "${out}" "catalog valid JSON" "doctor phase: model catalog validated"

# Engines "build" (dry-run - see the file header for why a fresh-clone
# simulation cannot do a real multi-minute compile).
assert_contains "${out}" "[dry-run] cmake -S" "build phase: llama.cpp engine build was invoked (dry-run)"
assert_contains "${out}" "[dry-run] make -C" "build phase: colibri engine build was invoked (dry-run)"

# Plan phase ran against the SAME probed hardware, using the real catalog.
assert_contains "${out}" "fast" "plan phase: catalog profiles considered"

assert_contains "${out}" "setup complete" "setup reports completion"

test_finish
