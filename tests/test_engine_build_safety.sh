#!/usr/bin/env bash
# test_engine_build_safety.sh - llama.cpp build safety (gaps G-115, host-safety build concurrency):
#   * the job count is bounded by AVAILABLE MEMORY, not only by cores (a CUDA compile needs ~2 GiB per job),
#   * HTTPS support (OpenSSL) is requested when the headers exist and VERIFIED after the build from the
#     build's own evidence (CMakeCache + linked libssl) - `llama-server --help` listing --ssl-* flags is NOT proof.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
source "${LLMCTL_ROOT}/lib/engine.sh"

# --- engine_jobs_for <backend> <ncpu> <mem_available_kib> [override] : pure function ---
GiB=$((1024*1024))
assert_eq 2  "$(engine_jobs_for cuda 16 $((9*GiB)))"  "cuda, 16 cores, 9 GiB available -> 2 jobs (this host's real situation)"
assert_eq 8  "$(engine_jobs_for cuda 16 $((20*GiB)))" "cuda, 16 cores, 20 GiB available -> (20-4 reserve)/2 = 8 jobs (memory-bound)"
assert_eq 16 "$(engine_jobs_for cuda 16 $((200*GiB)))" "cuda, plenty of memory -> all 16 cores"
assert_eq 1  "$(engine_jobs_for cuda 16 $((3*GiB)))"  "cuda, almost no free memory -> never below 1"
assert_eq 1  "$(engine_jobs_for cuda 16 0)"           "cuda, 0 KiB available -> 1 (never 0)"
assert_eq 5  "$(engine_jobs_for cpu 16 $((9*GiB)))"   "cpu build needs ~1 GiB per job: (9-4)/1 = 5"
assert_eq 3  "$(engine_jobs_for cpu 3 $((64*GiB)))"   "cores bound it from above"
assert_eq 1  "$(engine_jobs_for cuda 16 $((9*GiB)) 1)" "an explicit override of 1 is honoured"
assert_eq 2  "$(engine_jobs_for cuda 16 $((9*GiB)) 8)" "an override can never exceed the memory-safe count"
assert_eq 2  "$(engine_jobs_for cuda 16 $((9*GiB)) abc)" "a non-numeric override is ignored (memory-safe count)"
assert_eq 2  "$(engine_jobs_for cuda 16 $((9*GiB)) 0)"   "an override of 0 is ignored"
assert_eq 4  "$(engine_jobs_for cuda 16 unknown)"     "unknown memory (non-Linux) -> conservative min(cores,4)"

# --- engine_openssl_arg : -DLLAMA_OPENSSL=ON only when the headers exist ---
d="$(mktemp -d)"; trap 'rm -rf "${d}"' EXIT
mkdir -p "${d}/with/openssl"; : > "${d}/with/openssl/ssl.h"
assert_eq "-DLLAMA_OPENSSL=ON"  "$(engine_openssl_arg "${d}/with")"    "OpenSSL headers present -> HTTPS requested explicitly"
assert_eq "-DLLAMA_OPENSSL=OFF" "$(engine_openssl_arg "${d}/without")" "no headers -> OFF stated explicitly (never an implicit upstream default)"

# --- engine_https_verdict <build_dir> : evidence from the build itself ---
mkdir -p "${d}/b1" "${d}/b2" "${d}/b3" "${d}/b4/bin"
printf 'LLAMA_OPENSSL:BOOL=ON\n' > "${d}/b1/CMakeCache.txt"
printf 'LLAMA_OPENSSL:BOOL=OFF\n' > "${d}/b2/CMakeCache.txt"
: > "${d}/b3/CMakeCache.txt"
assert_eq "yes"     "$(engine_https_verdict "${d}/b1" 2>/dev/null | head -1)" "cache ON (and no binaries to inspect) -> yes"
assert_eq "no"      "$(engine_https_verdict "${d}/b2" 2>/dev/null | head -1)" "cache OFF -> no"
assert_eq "unknown" "$(engine_https_verdict "${d}/b3" 2>/dev/null | head -1)" "cache silent -> unknown, not a guess"
assert_eq "unknown" "$(engine_https_verdict "${d}/missing" 2>/dev/null | head -1)" "no build dir -> unknown"
# cache says ON but the built library does not link libssl -> the cache lied about the outcome: no
printf 'LLAMA_OPENSSL:BOOL=ON\n' > "${d}/b4/CMakeCache.txt"
cp /bin/true "${d}/b4/bin/llama-server"
assert_eq "no" "$(engine_https_verdict "${d}/b4" 2>/dev/null | head -1)" "cache ON but nothing links libssl -> no (control: the cache alone is not proof)"
test_finish
