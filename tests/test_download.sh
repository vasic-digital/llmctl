#!/usr/bin/env bash
# test_download.sh - verified-download logic against a LOCAL http fixture
# (python3 -m http.server). No network access to Hugging Face is used.
# Covers: download+verify, skip-when-verified, sha256 mismatch rejection,
# re-download of a corrupted local file, and evidence logging.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/download.sh"

PORT=18731
WWW="${TEST_TMP}/www"
mkdir -p "${WWW}/toy/repo/resolve/main"
PAYLOAD="${WWW}/toy/repo/resolve/main/model.bin"
printf 'llmctl tiny fixture model payload - NOT a real GGUF\n' > "${PAYLOAD}"
SIZE="$(stat -c%s "${PAYLOAD}" 2>/dev/null || stat -f%z "${PAYLOAD}")"
SHA="$(llmctl_sha256 "${PAYLOAD}")"

make_catalog() {
  # make_catalog <sha256> > catalog file path
  cat > "${TEST_TMP}/catalog-$1.json" <<EOF
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
      "files": [{"name": "model.bin", "size": ${SIZE}, "sha256": "$1", "role": "model"}]
    }
  }
}
EOF
  echo "${TEST_TMP}/catalog-$1.json"
}

# Serve the fixture.
python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${WWW}" >/dev/null 2>&1 &
HTTP_PID=$!
trap 'kill ${HTTP_PID} 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
  sleep 0.1
done

export LLMCTL_HF_BASE="http://127.0.0.1:${PORT}"
export LLMCTL_SMOKE=0   # no llama-server build in the test sandbox

# --- 1. fresh download + verify ----------------------------------------------
LLMCTL_CATALOG="$(make_catalog "${SHA}")"
export LLMCTL_CATALOG
out="$(download_profile toy 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "download_profile toy exit code"
printf '%s\n' "${out}" | sed 's/^/  /'
assert_file_exists "${LLMCTL_MODELS_DIR}/toy/model.bin" "model.bin exists after download"
assert_eq "${SHA}" "$(llmctl_sha256 "${LLMCTL_MODELS_DIR}/toy/model.bin")" "downloaded file sha256 matches"
assert_file_contains "${LLMCTL_VERIFY_DIR}/toy.log" "RUN: _dl_verify_file" "evidence log records verification"
assert_file_contains "${LLMCTL_VERIFY_DIR}/toy.log" "EXIT: 0" "evidence log records exit code"

# --- 2. second run skips the file --------------------------------------------
out="$(download_profile toy 2>&1)"
assert_contains "${out}" "already present and verified" "second download skips verified file"
assert_file_absent "${LLMCTL_MODELS_DIR}/toy/model.bin.part" "no .part file left behind (atomic rename)"

# --- 3. corrupted local file triggers re-download -----------------------------
printf 'corrupted\n' > "${LLMCTL_MODELS_DIR}/toy/model.bin"
out="$(download_profile toy 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "re-download of corrupted file succeeds"
assert_contains "${out}" "failed verification - re-downloading" "corruption detected before re-download"
assert_eq "${SHA}" "$(llmctl_sha256 "${LLMCTL_MODELS_DIR}/toy/model.bin")" "re-downloaded file verified"

# --- 4. catalog sha256 mismatch is a HARD failure -----------------------------
BAD_SHA="0000000000000000000000000000000000000000000000000000000000000000"
LLMCTL_CATALOG="$(make_catalog "${BAD_SHA}")"
export LLMCTL_CATALOG
rm -rf "${LLMCTL_MODELS_DIR}/toy"
out="$(download_profile toy 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "sha256 mismatch -> hard failure"
assert_contains "${out}" "sha256 mismatch" "mismatch reported"
# the mismatched file must not be renamed into place
assert_file_absent "${LLMCTL_MODELS_DIR}/toy/model.bin" "mismatched content never lands at the final path"

# --- 5. verify_profile on the good file ---------------------------------------
LLMCTL_CATALOG="$(make_catalog "${SHA}")"
export LLMCTL_CATALOG
rm -rf "${LLMCTL_MODELS_DIR}/toy"
download_profile toy >/dev/null 2>&1
out="$(verify_profile toy 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "verify_profile exit code"
assert_contains "${out}" "passed checksum verification" "verify_profile success message"

test_finish
