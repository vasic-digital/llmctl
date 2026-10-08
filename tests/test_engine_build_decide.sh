#!/usr/bin/env bash
# test_engine_build_decide.sh - `llmctl build decide` builds the Go decision binary for real
# and the produced binary runs (usage error rc 2 with no subcommand).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

# --- C-25: `build all` includes decide; G-078: a bare `llmctl build` prints usage and builds nothing ---
( source "${LLMCTL_ROOT}/lib/engine.sh"
  : > "${TEST_TMP}/calls"
  engine_ensure_submodules() { :; }
  engine_build_llama()   { echo llama   >> "${TEST_TMP}/calls"; }
  engine_build_colibri() { echo colibri >> "${TEST_TMP}/calls"; }
  engine_build_onnx()    { echo onnx    >> "${TEST_TMP}/calls"; }
  engine_build_decide()  { echo decide  >> "${TEST_TMP}/calls"; }
  engine_build all ) >/dev/null 2>&1
assert_eq "llama colibri onnx decide" "$(tr '\n' ' ' < "${TEST_TMP}/calls" | sed 's/ $//')" "build all builds llama, colibri, onnx AND decide (C-25)"
rc=0; out="$(LLMCTL_DRY_RUN=1 bash "${LLMCTL_ROOT}/bin/llmctl" build 2>&1)" || rc=$?
assert_eq 2 "${rc}" "a bare 'llmctl build' exits 2 (G-078)"
assert_contains "${out}" "usage: llmctl build <llama|colibri|onnx|decide|all>" "...printing the usage, a target is required"
case "${out}" in *"building"*|*"cmake"*|*"configure"*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: a bare 'llmctl build' started building: ${out}" >&2 ;; *) echo "  ok: a bare 'llmctl build' started no build" ;; esac
if ! command -v go >/dev/null 2>&1; then echo "SKIP-SUITE: go toolchain not installed"; exit 0; fi
out="$(mktemp -d)"; trap 'rm -rf "${out}"' EXIT
export LLMCTL_DECIDE_BUILD_OUT="${out}/llmctl-decide"
source "${LLMCTL_ROOT}/lib/engine.sh"
if ! ( engine_build decide >"${out}/build.log" 2>&1 ); then cat "${out}/build.log" >&2; TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: engine_build decide exited non-zero" >&2; fi
assert_eq "yes" "$([[ -x "${LLMCTL_DECIDE_BUILD_OUT}" ]] && echo yes || echo no)" "binary was produced and is executable"
rc=0; [[ -x "${LLMCTL_DECIDE_BUILD_OUT}" ]] && { "${LLMCTL_DECIDE_BUILD_OUT}" >/dev/null 2>"${out}/run.err" || rc=$?; } || rc=127
assert_eq "2" "${rc}" "built binary exits 2 (usage) with no subcommand"
rc=0; ( engine_build bogus >/dev/null 2>&1 ) || rc=$?
assert_eq "yes" "$([[ "${rc}" -ne 0 ]] && echo yes || echo no)" "unknown build target is still refused"
test_finish
