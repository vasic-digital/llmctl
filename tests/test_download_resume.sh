#!/usr/bin/env bash
# test_download_resume.sh - proves llmctl resumes an interrupted model
# download rather than restarting from scratch every time (FR-045,
# Clarification 15), against BOTH a server that honors HTTP Range requests
# (genuine partial resume) and one that does not (safe fallback to a full
# re-download, never a corrupted/incomplete final file).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/download.sh"

export LLMCTL_SMOKE=0   # no llama-server build in the test sandbox

make_catalog() {
  # make_catalog <size> <sha256> > catalog file path
  cat > "${TEST_TMP}/catalog-$2.json" <<EOF
{
  "version": 1,
  "notes": "test catalog",
  "ports": {"toy": 9999},
  "profiles": {
    "toy": {
      "engine": "llama",
      "capability": ["chat"],
      "min_tier": "baseline",
      "port": 9999,
      "hf_repo": "toy/repo",
      "hf_revision": "main",
      "desc": "tiny test profile",
      "defaults": {"ctx": 512, "ngl": 0, "parallel": 1, "flash_attn": "off"},
      "files": [{"name": "model.bin", "size": $1, "sha256": "$2", "role": "model"}]
    }
  }
}
EOF
  echo "${TEST_TMP}/catalog-$2.json"
}

# --- 1. genuine resume against a Range-capable server ------------------------
# Real Hugging Face CDN honors Range requests, so this is the primary,
# production-representative case.
WWW1="${TEST_TMP}/www1/toy/repo/resolve/main"
mkdir -p "${WWW1}"
head -c 5000 /dev/urandom | base64 | head -c 5000 > "${WWW1}/model.bin"
FULL_SHA="$(llmctl_sha256 "${WWW1}/model.bin")"
FULL_SIZE=5000
REQLOG="${TEST_TMP}/reqlog.txt"
: > "${REQLOG}"

PORT1=18921
python3 "${LLMCTL_ROOT}/tests/fixtures/range_server.py" "${PORT1}" "${WWW1}/model.bin" "${REQLOG}" \
  "/toy/repo/resolve/main/model.bin" &
RANGE_PID=$!
trap 'kill ${RANGE_PID} 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT1}/toy/repo/resolve/main/model.bin" -o /dev/null 2>/dev/null && break
  sleep 0.1
done
: > "${REQLOG}"  # discard the readiness-probe request above

export LLMCTL_HF_BASE="http://127.0.0.1:${PORT1}"
LLMCTL_CATALOG="$(make_catalog "${FULL_SIZE}" "${FULL_SHA}")"
export LLMCTL_CATALOG

# Simulate a prior download killed at byte 2000 of 5000.
mkdir -p "${LLMCTL_MODELS_DIR}/toy"
head -c 2000 "${WWW1}/model.bin" > "${LLMCTL_MODELS_DIR}/toy/model.bin.part"

out="$(download_profile toy 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "resume against Range-capable server succeeds"
assert_eq "${FULL_SHA}" "$(llmctl_sha256 "${LLMCTL_MODELS_DIR}/toy/model.bin")" "resumed file's sha256 matches the full payload"
assert_file_absent "${LLMCTL_MODELS_DIR}/toy/model.bin.part" "no .part file left behind after successful resume"
assert_file_contains "${REQLOG}" "bytes=2000-" "server actually received a Range request starting at the pre-existing byte offset (genuine resume, not a from-scratch refetch)"

kill "${RANGE_PID}" 2>/dev/null || true
trap - EXIT

# --- 2. safe fallback against a server that does NOT support Range ----------
# Some servers (and this test's own plain http.server fixture, matching
# test_download.sh's existing pattern) ignore Range and always return the
# full file from byte 0. Resume must not corrupt or truncate the final file
# in that case - it must fall back to a full re-download.
WWW2="${TEST_TMP}/www2/toy/repo/resolve/main"
mkdir -p "${WWW2}"
cp "${WWW1}/model.bin" "${WWW2}/model.bin"

PORT2=18922
python3 -m http.server "${PORT2}" --bind 127.0.0.1 --directory "${TEST_TMP}/www2" >/dev/null 2>&1 &
PLAIN_PID=$!
trap 'kill ${PLAIN_PID} 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT2}/" >/dev/null 2>&1 && break
  sleep 0.1
done

export LLMCTL_HF_BASE="http://127.0.0.1:${PORT2}"
rm -f "${LLMCTL_MODELS_DIR}/toy/model.bin" "${LLMCTL_MODELS_DIR}/toy/model.bin.part"
head -c 2000 "${WWW2}/model.bin" > "${LLMCTL_MODELS_DIR}/toy/model.bin.part"

out="$(download_profile toy 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "download succeeds even when the server does not support Range (falls back to full re-download)"
assert_eq "${FULL_SHA}" "$(llmctl_sha256 "${LLMCTL_MODELS_DIR}/toy/model.bin")" "fallback-re-downloaded file's sha256 matches the full payload"
assert_file_absent "${LLMCTL_MODELS_DIR}/toy/model.bin.part" "no .part file left behind after fallback re-download"

kill "${PLAIN_PID}" 2>/dev/null || true
trap - EXIT

test_finish
