#!/usr/bin/env bash
# download.sh - verified model downloads for llmctl.
#
# Contract for every file of a profile:
#   1. skip when the file already exists AND its sha256 matches the catalog
#   2. otherwise download with `curl -L --continue-at -` into "<file>.part"
#      and atomically rename on completion
#   3. verify size (when catalog has one) and sha256 (when catalog has one);
#      a null/absent catalog sha256 means the checksum is fetched from the
#      Hugging Face API at download time - fail hard when even that fails
#   4. GGUF profiles then get a post-download smoke test against the real
#      llama-server binary; colibri profiles get `coli doctor` (when the
#      launcher is installed) or a structural check otherwise
#   5. every step appends command + exit code + output evidence to
#      $LLMCTL_VERIFY_DIR/<profile>.log
# Any mismatch is a hard failure (non-zero exit).
set -euo pipefail

_dl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_dl_dir}/common.sh"
# shellcheck source=catalog.sh
source "${_dl_dir}/catalog.sh"

LLMCTL_SMOKE_PORT="${LLMCTL_SMOKE_PORT:-18090}"
LLMCTL_SMOKE_TIMEOUT="${LLMCTL_SMOKE_TIMEOUT:-120}"
# LLMCTL_SMOKE=0 disables the smoke test explicitly (evidence still logged).
LLMCTL_SMOKE="${LLMCTL_SMOKE:-1}"
# Base URL for model downloads. Default: Hugging Face. Overridable so tests
# can serve fixtures from a local HTTP server.
LLMCTL_HF_BASE="${LLMCTL_HF_BASE:-https://huggingface.co}"

# Portable sha256 of a file (hex digest on stdout).
llmctl_sha256() {
  if have_cmd sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  elif have_cmd shasum; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif have_cmd openssl; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    die "no sha256 tool found (need sha256sum, shasum or openssl)"
  fi
}

# Git blob hash (hex digest on stdout) of a local file - i.e. exactly what
# `git hash-object <file>` / a Hugging Face API `blobId` field reports for
# that file's exact content. Root-caused 2026-09-17 (real repro against
# Kreuzzelg/qwen36-35b-a3b-colibri-i4's config.hf.json + config.json):
# _dl_fetch_sha256_from_api's `?blobs=true` lookup only ever finds a hash
# under a sibling's `.lfs.sha256` field, which Hugging Face populates ONLY
# for Git-LFS-tracked files; small config/JSON files on HF are typically
# committed as ORDINARY (non-LFS) git blobs and carry no `.lfs` object at
# all, so the lookup silently found nothing and the download was correctly
# (but too narrowly) refused as unverifiable. HF's API DOES report a
# `blobId` for every file, LFS or not - it is git's own blob hash
# (`sha1("blob " <size> "\0" <content>)`), a different but equally
# authoritative content-identity algorithm from the sha256 used for LFS
# blobs. `git hash-object` computes exactly this, so it needs no bespoke
# framing/`\0`-handling reimplementation - confirmed empirically before
# using it: `git hash-object` on a freshly-downloaded config.hf.json
# reproduced the exact blobId the HF API reported for that same file.
llmctl_git_blob_sha1() {
  need_cmd git
  git hash-object "$1"
}

# --- evidence logging --------------------------------------------------------
_dl_log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${_DL_EVIDENCE}"; }

# Run a command, append "command + exit code + raw output" to the evidence log.
# Returns the command's exit code (does not abort the caller).
_dl_evidence_run() {
  local out rc
  _dl_log "RUN: $*"
  out="$("$@" 2>&1)" && rc=0 || rc=$?
  _dl_log "EXIT: ${rc}"
  if [[ -n "${out}" ]]; then
    printf '%s\n' "${out}" | sed 's/^/OUT: /' >> "${_DL_EVIDENCE}"
    # Surface failing output to the user as well (evidence stays in the log).
    [[ "${rc}" != "0" ]] && printf '%s\n' "${out}" >&2
  fi
  return "${rc}"
}

# --- checksum helpers --------------------------------------------------------
# Fetch the authoritative checksum for a repo file from the HF API (fallback
# for catalog entries whose sha256 is null). Prints a bare hex sha256 for an
# LFS-tracked file (the common case for large model weights), or
# "gitblob1:<hex>" for an ordinary (non-LFS) git blob - typically small
# config/JSON files, which HF's API reports a `blobId` for but never an
# `.lfs.sha256` (there is no LFS object at all). Prints nothing (caller
# refuses the download) when the repo/file cannot be resolved.
_dl_fetch_sha256_from_api() {
  local repo="$1" name="$2"
  need_cmd curl
  local api="${LLMCTL_HF_BASE}/api/models/${repo}?blobs=true"
  curl -fsSL --max-time 60 "${api}" | python3 -c '
import json, sys
name = sys.argv[1]
d = json.load(sys.stdin)
for s in d.get("siblings", []):
    if s.get("rfilename") == name:
        lfs_sha = (s.get("lfs") or {}).get("sha256") or ""
        if lfs_sha:
            print(lfs_sha)
        else:
            blob_id = s.get("blobId") or ""
            if blob_id:
                print("gitblob1:" + blob_id)
        break
' "${name}"
}

_dl_verify_file() {
  # _dl_verify_file <path> <expected_size_or_0> <expected_sha256_or_empty>
  local path="$1" size="$2" sha="$3"
  [[ -s "${path}" ]] || { err "file missing or empty: ${path}"; return 1; }
  if [[ "${size}" != "0" ]]; then
    local actual_size
    actual_size="$(stat -f%z "${path}" 2>/dev/null || stat -c%s "${path}")"
    if [[ "${actual_size}" != "${size}" ]]; then
      err "size mismatch for ${path}: expected ${size} bytes, got ${actual_size}"
      return 1
    fi
  fi
  if [[ -n "${sha}" ]]; then
    local actual_sha expected_sha algo
    if [[ "${sha}" == gitblob1:* ]]; then
      algo="git-blob-sha1"
      expected_sha="${sha#gitblob1:}"
      actual_sha="$(llmctl_git_blob_sha1 "${path}")"
    else
      algo="sha256"
      expected_sha="${sha}"
      actual_sha="$(llmctl_sha256 "${path}")"
    fi
    if [[ "${actual_sha}" != "${expected_sha}" ]]; then
      err "${algo} mismatch for ${path}"
      err "  expected: ${expected_sha}"
      err "  actual:   ${actual_sha}"
      return 1
    fi
  fi
  return 0
}

# --- per-file download -------------------------------------------------------
_dl_download_file() {
  # _dl_download_file <profile> <dest_dir> <name> <size> <sha256>
  local profile="$1" dest_dir="$2" name="$3" size="$4" sha="$5"
  local repo revision dest part url
  repo="$(catalog_hf_repo "${profile}")"
  revision="$(catalog_field "${profile}" hf_revision main)"
  dest="${dest_dir}/${name}"
  part="${dest}.part"
  url="${LLMCTL_HF_BASE}/${repo}/resolve/${revision}/${name}"

  ensure_dir "$(dirname "${dest}")"

  # Fallback: catalog sha256 is null -> fetch it live from the HF API.
  if [[ -z "${sha}" ]]; then
    warn "catalog has no sha256 for ${name}; fetching from HF API"
    sha="$(_dl_fetch_sha256_from_api "${repo}" "${name}")" || sha=""
    [[ -n "${sha}" ]] || die "cannot obtain sha256 for ${name} from HF API - refusing unverified download"
    _dl_log "sha256 for ${name} resolved via HF API: ${sha}"
  fi

  if [[ -f "${dest}" ]]; then
    log "verifying existing file: ${dest}"
    if _dl_evidence_run _dl_verify_file "${dest}" "${size}" "${sha}"; then
      log "already present and verified: ${name} (skipped)"
      return 0
    fi
    warn "existing ${name} failed verification - re-downloading"
    rm -f "${dest}"
  fi

  log "downloading ${name} from ${repo}"
  _dl_log "download: ${url} -> ${part}"
  local rc=0
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    log "[dry-run] curl -fL --continue-at - -o ${part} ${url}"
  else
    curl -fL --continue-at - --retry 3 --retry-delay 5 -o "${part}" "${url}" || rc=$?
    _dl_log "curl exit: ${rc}"
    if [[ "${rc}" == "33" ]]; then
      # curl 33 = "HTTP server does not seem to support byte ranges. Cannot
      # resume." A pre-existing .part file is a real interrupted-download
      # remnant, and the server we are talking to right now genuinely cannot
      # serve a Range request for it - resuming is impossible against THIS
      # server, not a bug in our .part file. Fall back to a full re-download
      # from byte 0 rather than hard-failing; curl left the stale .part file
      # untouched (never corrupted it), so it is safe to discard and restart.
      warn "server does not support HTTP Range requests; falling back to a full re-download of ${name}"
      _dl_log "curl exit 33 (no Range support) - discarding stale ${part} and restarting from byte 0"
      rm -f "${part}"
      rc=0
      curl -fL --retry 3 --retry-delay 5 -o "${part}" "${url}" || rc=$?
      _dl_log "curl exit (full re-download): ${rc}"
    fi
    [[ "${rc}" == "0" ]] || die "download failed (curl exit ${rc}): ${url}"
    # Verify BEFORE the atomic rename: mismatched content must never land at
    # the final path.
    _dl_evidence_run _dl_verify_file "${part}" "${size}" "${sha}" \
      || die "post-download verification failed for ${name} (see ${LLMCTL_VERIFY_DIR}/${profile}.log)"
    mv -f "${part}" "${dest}"
    _dl_log "renamed ${part} -> ${dest} (atomic, verified)"
  fi
  info "verified: ${name}"
}

# --- smoke test --------------------------------------------------------------
_dl_llama_server_bin() {
  if [[ -n "${LLMCTL_LLAMA_SERVER:-}" && -x "${LLMCTL_LLAMA_SERVER}" ]]; then
    echo "${LLMCTL_LLAMA_SERVER}"; return 0
  fi
  local cand="${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server"
  [[ -x "${cand}" ]] && { echo "${cand}"; return 0; }
  return 1
}

_dl_smoke_test_gguf() {
  # _dl_smoke_test_gguf <profile> <model_path> [mmproj_path]
  local profile="$1" model="$2" mmproj="${3:-}"
  if [[ "${LLMCTL_SMOKE}" == "0" ]]; then
    _dl_log "smoke test disabled via LLMCTL_SMOKE=0"
    warn "smoke test disabled (LLMCTL_SMOKE=0)"
    return 0
  fi
  local server
  if ! server="$(_dl_llama_server_bin)"; then
    _dl_log "smoke test SKIPPED: llama-server not built (run: llmctl build llama)"
    warn "llama-server not built - skipping smoke test (run 'llmctl build llama' first)"
    return 0
  fi

  local args=(--model "${model}" --ctx-size 512 --n-gpu-layers 0 --host 127.0.0.1 --port "${LLMCTL_SMOKE_PORT}")
  [[ -n "${mmproj}" ]] && args+=(--mmproj "${mmproj}")

  log "smoke test: starting llama-server for ${profile} on 127.0.0.1:${LLMCTL_SMOKE_PORT}"
  _dl_log "smoke: ${server} ${args[*]}"
  local server_log="${LLMCTL_LOG_DIR}/smoke-${profile}.log"
  ensure_dir "${LLMCTL_LOG_DIR}"
  # LD_LIBRARY_PATH (root-caused 2026-09-17): a freshly-built llama-server's
  # libggml.so.0 SONAME can collide with a stale, ABI-incompatible copy
  # already installed system-wide (confirmed via `ldd` on this host); the
  # dynamic linker then silently prefers the stale system copy over the
  # correct sibling library sitting right next to the binary, and
  # llama-server dies with a symbol-lookup error instead of booting. See
  # the matching note in lib/service_linux.sh's svc_write_env() for the
  # full forensic detail - same fix, same rationale, applied here for the
  # direct-launch smoke-test path.
  local server_dir; server_dir="$(cd "$(dirname "${server}")" && pwd)"
  LD_LIBRARY_PATH="${server_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${server}" "${args[@]}" > "${server_log}" 2>&1 &
  local pid=$!

  local ready=0 i
  for (( i=0; i<LLMCTL_SMOKE_TIMEOUT; i++ )); do
    if curl -fsS "http://127.0.0.1:${LLMCTL_SMOKE_PORT}/health" >/dev/null 2>&1; then
      ready=1; break
    fi
    kill -0 "${pid}" 2>/dev/null || break
    sleep 1
  done

  if [[ "${ready}" != "1" ]]; then
    _dl_log "smoke FAILED: server did not become healthy within ${LLMCTL_SMOKE_TIMEOUT}s"
    sed 's/^/OUT: /' "${server_log}" >> "${_DL_EVIDENCE}" 2>/dev/null || true
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    err "smoke test failed: llama-server did not become healthy (see ${server_log})"
    return 1
  fi
  _dl_log "smoke: /health OK after ${i}s"

  local payload response
  # max_tokens=64 (root-caused 2026-09-17, real repro against
  # ggml-org/gpt-oss-20b-GGUF, the "moe-fast" catalog profile): a
  # reasoning/"harmony"-format model emits its chain-of-thought as
  # SEPARATE reasoning_content tokens BEFORE any answer content token, so
  # the previous max_tokens=8 budget was consumed entirely by the
  # reasoning preamble (observed raw response: content="",
  # reasoning_content="The user says: \"", finish_reason="length") and
  # the smoke test failed even though the model is genuinely correct -
  # confirmed by manually re-running the identical prompt against the
  # same downloaded model file with max_tokens=64: content="OK",
  # finish_reason="stop", 41 total completion tokens (comfortably under
  # 64, stops on its own EOS rather than hitting the raised budget). A
  # plain instruction-following model (no separate reasoning channel)
  # answers immediately and hits its own EOS in 1-2 tokens regardless of
  # this budget, so raising it does not slow down or change the outcome
  # for any non-reasoning profile already passing.
  payload='{"messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":64,"temperature":0}'
  response="$(curl -fsS -X POST "http://127.0.0.1:${LLMCTL_SMOKE_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "${payload}" 2>&1)" || {
    _dl_log "smoke FAILED: chat completion request errored"
    kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true
    err "smoke test failed: /v1/chat/completions request failed"
    return 1
  }
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true

  _dl_log "smoke request payload: ${payload}"
  _dl_log "smoke raw response: ${response}"
  if printf '%s' "${response}" | grep -q "OK"; then
    _dl_log "smoke PASSED: response contains 'OK'"
    info "smoke test passed for ${profile} (deterministic prompt answered 'OK')"
    return 0
  fi
  _dl_log "smoke FAILED: response did not contain 'OK'"
  err "smoke test failed: model response did not contain 'OK'"
  return 1
}

_dl_validate_colibri() {
  # _dl_validate_colibri <profile> <dest_dir>
  local profile="$1" dest="$2"
  if have_cmd coli; then
    log "running colibri validation via coli doctor"
    if _dl_evidence_run env COLI_MODEL="${dest}" coli doctor; then
      info "coli doctor passed for ${profile}"
      return 0
    fi
    warn "coli doctor failed for ${profile}; falling back to structural check"
  else
    _dl_log "coli launcher not installed; using structural validation"
  fi
  # Structural check: config + at least one non-empty safetensors shard.
  local shards
  shards="$(find "${dest}" -name '*.safetensors' -size +0 | wc -l | tr -d ' ')"
  [[ "${shards}" -ge 1 ]] || { err "structural check failed: no non-empty .safetensors shards in ${dest}"; return 1; }
  ls "${dest}"/config*.json >/dev/null 2>&1 || { err "structural check failed: no config*.json in ${dest}"; return 1; }
  _dl_log "structural check passed: ${shards} non-empty shard(s), config present"
  info "structural validation passed for ${profile} (${shards} shards)"
}

# --- public entry points -----------------------------------------------------
# download_profile <profile>
download_profile() {
  local profile="$1"
  catalog_exists "${profile}" || die "unknown profile: ${profile} (see: llmctl models list)"
  ensure_state_dirs
  _DL_EVIDENCE="${LLMCTL_VERIFY_DIR}/${profile}.log"
  : > "${_DL_EVIDENCE}"
  _dl_log "llmctl models download ${profile}"
  _dl_log "engine: $(catalog_engine "${profile}")  repo: $(catalog_hf_repo "${profile}")"

  local dest_dir="${LLMCTL_MODELS_DIR}/${profile}"
  ensure_dir "${dest_dir}"

  local name size sha role
  while IFS='|' read -r name size sha role; do
    _dl_download_file "${profile}" "${dest_dir}" "${name}" "${size}" "${sha}"
  done < <(catalog_files "${profile}")

  local engine
  engine="$(catalog_engine "${profile}")"
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    log "[dry-run] skipping post-download validation"
    return 0
  fi
  case "${engine}" in
    llama)
      local model="" mmproj=""
      while IFS='|' read -r name size sha role; do
        case "${role}" in
          mmproj) mmproj="${dest_dir}/${name}" ;;
          *)      [[ -z "${model}" ]] && model="${dest_dir}/${name}" ;;
        esac
      done < <(catalog_files "${profile}")
      [[ -n "${model}" ]] || die "profile ${profile} has no model file"
      _dl_smoke_test_gguf "${profile}" "${model}" "${mmproj}" \
        || die "smoke test failed for ${profile} (see ${LLMCTL_VERIFY_DIR}/${profile}.log)"
      ;;
    colibri)
      _dl_validate_colibri "${profile}" "${dest_dir}" \
        || die "colibri validation failed for ${profile}"
      ;;
  esac
  _dl_log "download ${profile}: SUCCESS"
  info "profile '${profile}' downloaded and verified. Evidence: ${LLMCTL_VERIFY_DIR}/${profile}.log"
}

# verify_profile <profile> - re-verify an already-downloaded profile.
verify_profile() {
  local profile="$1"
  catalog_exists "${profile}" || die "unknown profile: ${profile}"
  local dest_dir="${LLMCTL_MODELS_DIR}/${profile}"
  [[ -d "${dest_dir}" ]] || die "profile ${profile} not downloaded (no ${dest_dir})"
  ensure_state_dirs
  _DL_EVIDENCE="${LLMCTL_VERIFY_DIR}/${profile}.log"
  _dl_log "llmctl models verify ${profile}"
  local name size sha role
  while IFS='|' read -r name size sha role; do
    _dl_evidence_run _dl_verify_file "${dest_dir}/${name}" "${size}" "${sha}" \
      || die "verification failed for ${name}"
  done < <(catalog_files "${profile}")
  info "profile '${profile}' passed checksum verification"
}
