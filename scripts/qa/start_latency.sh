#!/usr/bin/env bash
# start_latency.sh - wall-clock cost of `llmctl start` (dry run) in two trees, measured alternately.
#
# usage: scripts/qa/start_latency.sh <tree-a> <tree-b> <out-file> [N]
#
# Each round runs `llmctl start small` once in tree A and once in tree B, each in its own fresh state directory under
# a mktemp -d root, with LLMCTL_DRY_RUN=1 (no unit is written or started) and the fixture hardware file
# tests/fixtures/hw-baseline.json of tree A. Alternating the trees spreads host load evenly over both. Pinned to CPUs
# 0,1. Output: one line per run "<tree> <rc> <ms>", then the mean per tree. Exit 1 if any run returned non-zero.
# Unit-class timing (dry run): it measures the CLI's own work, not a model start.
set -euo pipefail
A="${1:?tree-a}"; B="${2:?tree-b}"; OUT="${3:?out-file}"; N="${4:-5}"
A="$(cd "${A}" && pwd)"; B="$(cd "${B}" && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf -- "${ROOT:?}"' EXIT
: > "${OUT}"
for i in $(seq 1 "${N}"); do
  for tree in "${A}" "${B}"; do
    R="${ROOT}/run${i}-$(basename "${tree}")"; S="${R}/state"
    st=$(date +%s%N)
    rc=0
    env LLMCTL_STATE_DIR="${S}" LLMCTL_RUNTIME_DIR="${S}/run" LLMCTL_CONFIG_DIR="${R}/config" LLMCTL_DATA_DIR="${R}/data" \
      LLMCTL_MODELS_DIR="${R}/models" LLMCTL_LOG_DIR="${S}/logs" LLMCTL_VERIFY_DIR="${S}/verify" \
      LLMCTL_SERVICES_DIR="${S}/services" LLMCTL_UNIT_DIR="${R}/su" LLMCTL_PLIST_DIR="${R}/la" NO_COLOR=1 LLMCTL_DRY_RUN=1 \
      LLMCTL_FAKE_HW="${A}/tests/fixtures/hw-baseline.json" \
      timeout 120 taskset -c 0,1 bash "${tree}/bin/llmctl" start small >/dev/null 2>&1 || rc=$?
    printf '%s %s %s\n' "${tree}" "${rc}" "$(( ($(date +%s%N) - st) / 1000000 ))" >> "${OUT}"
  done
done
awk '{s[$1]+=$3; n[$1]++; if ($2 != 0) bad++} END {for (k in s) printf "mean %s %d ms (n=%d)\n", k, s[k]/n[k], n[k]; printf "nonzero_rc %d\n", bad+0; exit (bad > 0)}' "${OUT}" | tee -a "${OUT}"
