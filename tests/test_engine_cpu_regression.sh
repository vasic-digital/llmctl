#!/usr/bin/env bash
# test_engine_cpu_regression.sh - 005-cuda-gpu-inference T013: permanent
# regression guard proving the CUDA engine.sh change (the cuda) branch's
# CMAKE_CUDA_FLAGS compiler-compatibility flag, if/when one is added by
# T005) is genuinely ADDITIVE - with nvcc absent from PATH,
# engine_detect_backend still returns exactly "cpu", and
# engine_build_llama's emitted cmake command line for the cpu) branch
# still contains -DGGML_NATIVE=ON and does NOT contain -DGGML_CUDA=ON nor
# any CMAKE_CUDA_FLAGS entry. This is User Story 3 (spec.md) / FR-003 /
# FR-004 / SC-005: a host without a capable GPU (or, as tested here, a
# host that simply has no nvcc on PATH) must be completely unaffected by
# this feature.
#
# This test intentionally PASSES against BOTH the pre-005 lib/engine.sh
# and the post-005 lib/engine.sh (per tasks.md T013: "though it should
# currently PASS ... this task's job is to LOCK that guarantee in as a
# permanent regression test, not discover a new defect"). The paired
# mutation that proves this gate is not a bluff lives in
# docs/qa/005-cuda-gpu-inference/meta_test_evidence.txt (T014).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/engine.sh"

# Build a "no nvcc" PATH by shadowing every real bin/sbin directory with a
# directory of symlinks to the SAME binaries, minus anything named
# "nvcc*". Root-caused (this session, real repro, not guessed):
# quickstart.md Step 6's documented `grep -v cuda` PATH-stripping approach
# does NOT work on THIS host, because the distro `nvidia-cuda-toolkit`
# package installs nvcc as a plain wrapper script directly at
# /usr/bin/nvcc (confirmed: `readlink -f "$(command -v nvcc)"` ->
# /usr/bin/nvcc, a 112-byte POSIX-shell wrapper) rather than under a
# path segment containing the literal substring "cuda" (that only
# happens with NVIDIA's own .run-installer layout, /usr/local/cuda/bin -
# see research.md R1, which this host's install does NOT use). Since
# /bin and /sbin are usrmerge symlinks to /usr/bin and /usr/sbin on this
# host, shadowing those two real directories (while leaving every other
# PATH entry, including plugin-cache bin/ dirs that hold none of the
# tools this test needs, untouched) removes nvcc from resolution without
# breaking bash/cat/grep/sed/python3/cmake/mktemp, all of which this
# test (and the sourced lib/*.sh files) genuinely need to keep running.
NO_NVCC_DIR="${TEST_TMP}/no-nvcc-usr-bin"
NO_NVCC_SBIN_DIR="${TEST_TMP}/no-nvcc-usr-sbin"
mkdir -p "${NO_NVCC_DIR}" "${NO_NVCC_SBIN_DIR}"
shopt -s nullglob
for f in /usr/bin/*; do
  base="$(basename "${f}")"
  [[ "${base}" == nvcc* ]] && continue
  ln -sf "${f}" "${NO_NVCC_DIR}/${base}"
done
for f in /usr/sbin/*; do
  base="$(basename "${f}")"
  [[ "${base}" == nvcc* ]] && continue
  ln -sf "${f}" "${NO_NVCC_SBIN_DIR}/${base}"
done
shopt -u nullglob
assert_file_absent "${NO_NVCC_DIR}/nvcc" \
  "the shadow no-nvcc bin directory genuinely excludes nvcc"

# Replace every "/usr/bin", "/bin", "/usr/sbin", "/sbin" PATH segment
# (in whatever order/count they appear in the real PATH) with the shadow
# directories built above; every other segment (including any real
# /usr/local/cuda/bin, which this host does not have but a future one
# might) is left completely alone.
NO_CUDA_PATH="$(IFS=: ; for seg in ${PATH}; do
  case "${seg}" in
    /usr/bin|/bin)   printf '%s\n' "${NO_NVCC_DIR}" ;;
    /usr/sbin|/sbin) printf '%s\n' "${NO_NVCC_SBIN_DIR}" ;;
    /usr/local/cuda/bin) ;;   # exclude explicitly - the OTHER nvcc check in engine_detect_backend
    *) printf '%s\n' "${seg}" ;;
  esac
done | paste -sd: -)"

REAL_BASH="$(command -v bash)"

# --- 1. engine_detect_backend returns exactly "cpu" with no nvcc on PATH ----
backend="$(PATH="${NO_CUDA_PATH}" "${REAL_BASH}" -c 'source "'"${LLMCTL_ROOT}"'/lib/common.sh"; source "'"${LLMCTL_ROOT}"'/lib/os_detect.sh"; source "'"${LLMCTL_ROOT}"'/lib/engine.sh"; command -v nvcc >&2 || true; engine_detect_backend')"
assert_eq "cpu" "${backend}" "engine_detect_backend returns 'cpu' when nvcc is absent from PATH"

# --- 2. the cpu) branch's dry-run cmake invocation is unaffected ------------
captured="$(PATH="${NO_CUDA_PATH}" LLMCTL_DRY_RUN=1 "${REAL_BASH}" -c 'source "'"${LLMCTL_ROOT}"'/lib/common.sh"; source "'"${LLMCTL_ROOT}"'/lib/os_detect.sh"; source "'"${LLMCTL_ROOT}"'/lib/engine.sh"; engine_build_llama' 2>&1)"

assert_contains "${captured}" "-DGGML_NATIVE=ON" \
  "cpu-only dry-run cmake invocation still contains -DGGML_NATIVE=ON"

if [[ "${captured}" == *"-DGGML_CUDA=ON"* ]]; then
  printf '  FAIL: %s\n    cmake invocation unexpectedly contains -DGGML_CUDA=ON with no nvcc on PATH\n' \
    "cpu-only dry-run cmake invocation does NOT contain -DGGML_CUDA=ON" >&2
  TEST_FAILS=$((TEST_FAILS+1))
else
  printf '  ok: %s\n' "cpu-only dry-run cmake invocation does NOT contain -DGGML_CUDA=ON"
fi

if [[ "${captured}" == *"CMAKE_CUDA_FLAGS"* ]]; then
  printf '  FAIL: %s\n    cmake invocation unexpectedly contains a CMAKE_CUDA_FLAGS entry with no nvcc on PATH\n' \
    "cpu-only dry-run cmake invocation does NOT contain any CMAKE_CUDA_FLAGS entry (the T005 compiler-compatibility flag is cuda)-branch-only)" >&2
  TEST_FAILS=$((TEST_FAILS+1))
else
  printf '  ok: %s\n' "cpu-only dry-run cmake invocation does NOT contain any CMAKE_CUDA_FLAGS entry (the T005 compiler-compatibility flag is cuda)-branch-only)"
fi

# --- 3. real backend detection on THIS host (whatever it is right now) is
# unaffected by this test's PATH manipulation once restored - a sanity
# check that we did not corrupt the caller's own environment. -------------
real_backend="$(engine_detect_backend)"
assert_contains "cuda metal rocm cpu" "${real_backend}" \
  "engine_detect_backend on the real (unmodified) PATH still returns one of the known backends (got: ${real_backend})"

test_finish
