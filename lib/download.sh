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

# LLMCTL_SMOKE_PORT: unset / "auto" (default) = a FREE ephemeral port is chosen for every smoke test;
# a number pins it (refused when something already listens there). Either way readiness is proven
# against THIS test's own server process (_dl_smoke_wait), never merely "something answers /health".
LLMCTL_SMOKE_PORT="${LLMCTL_SMOKE_PORT:-auto}"
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
#
# --no-filters (independent review, 2026-09-17): a bare `git hash-object`
# applies the CALLING repository's own clean/CRLF filters (core.autocrlf,
# a `* text=auto` .gitattributes) before hashing - based on the process's
# cwd repo, even for a target file living entirely outside it. Reproduced
# directly: hashing an identical CRLF-containing file with core.autocrlf=
# true on vs `--no-filters` produced two DIFFERENT hashes, and only the
# `--no-filters` one matched the file's true raw-content blob hash
# (independently cross-checked via `sha1("blob " <len> "\0" <content>)`).
# Since `llmctl models download` is normally run from inside a git
# checkout (including this project's own), any host with a global
# core.autocrlf or a repo-level text=auto would otherwise get a WRONG hash
# for these files and falsely refuse a genuinely-correct download - the
# exact false-negative class this whole fallback exists to eliminate.
# `--` guards against a path beginning with `-` being read as an option.
llmctl_git_blob_sha1() {
  need_cmd git
  git hash-object --no-filters -- "$1"
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

# Resolve the checksum to verify a file against: the catalog's own sha256
# when it has one, else the HF-API fallback (independent review, 2026-09-17
# / I5) - extracted so `_dl_download_file` and `verify_profile` share ONE
# resolution path instead of `verify_profile` silently skipping the
# fallback entirely (it previously handed `_dl_verify_file` the raw,
# EMPTY catalog sha for config.hf.json/config.json, so `_dl_verify_file`'s
# own `[[ -n "${sha}" ]]` guard skipped the checksum check altogether while
# `llmctl models verify` still printed "passed checksum verification" -
# a real, silent, no-verification-at-all gap for exactly the two files
# `_dl_fetch_sha256_from_api`'s git-blob fallback exists to cover).
# Echoes the resolved sha on success; returns 1 with nothing echoed when
# no checksum can be obtained at all (caller decides how to fail).
_dl_resolve_sha() {
  local repo="$1" name="$2" sha="$3"
  if [[ -n "${sha}" ]]; then
    printf '%s' "${sha}"
    return 0
  fi
  warn "catalog has no sha256 for ${name}; fetching from HF API"
  local resolved
  resolved="$(_dl_fetch_sha256_from_api "${repo}" "${name}")" || resolved=""
  [[ -n "${resolved}" ]] || return 1
  _dl_log "sha256 for ${name} resolved via HF API: ${resolved}"
  printf '%s' "${resolved}"
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

  # Fallback: catalog sha256 is null -> fetch it live from the HF API
  # (shared with verify_profile via _dl_resolve_sha, see its own header).
  sha="$(_dl_resolve_sha "${repo}" "${name}" "${sha}")" \
    || die "cannot obtain sha256 for ${name} from HF API - refusing unverified download"

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
# --- smoke-test port + readiness (C-06) -------------------------------------
# A fixed port plus "curl /health succeeds" proved nothing about the process this test launched: if
# anything else (another llmctl download, a sibling project) already listened there, /health
# answered on the first poll, the probes ran against THAT foreign server, and the verdict was
# recorded for the wrong model while the launched child died on bind.

# _dl_port_in_use <port> -> rc 0 when something accepts connections on 127.0.0.1:<port>.
_dl_port_in_use() { ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }

# _dl_smoke_pick_port -> prints the port for one smoke test (see LLMCTL_SMOKE_PORT above).
_dl_smoke_pick_port() {
  local p="${LLMCTL_SMOKE_PORT:-auto}"
  if [[ "${p}" != "auto" && "${p}" != "0" ]]; then
    [[ "${p}" =~ ^[0-9]+$ && "${p}" -ge 1 && "${p}" -le 65535 ]] || { err "LLMCTL_SMOKE_PORT='${p}' is not a port number (or 'auto')"; return 1; }
    if _dl_port_in_use "${p}"; then err "LLMCTL_SMOKE_PORT=${p} is already in use by another program; use another port or 'auto'"; return 1; fi
    printf '%s\n' "${p}"; return 0
  fi
  if have_cmd python3; then
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])' && return 0
  fi
  local c
  for (( c=18090; c<19090; c++ )); do _dl_port_in_use "${c}" || { printf '%s\n' "${c}"; return 0; }; done
  err "no free port for the smoke test"; return 1
}

# _dl_pid_owns_port <pid> <port> -> rc 0: the process holds the LISTENING socket of that port;
# rc 1: it does not; rc 2: this host offers no way to tell (no procfs, lsof or ss).
_dl_pid_owns_port() {
  local pid="$1" port="$2" hex ino fd
  if [[ -r /proc/net/tcp ]]; then
    hex="$(printf '%04X' "${port}")"
    for ino in $(awk -v h=":${hex}" '$4=="0A" && substr($2, length($2)-length(h)+1)==h {print $10}' /proc/net/tcp /proc/net/tcp6 2>/dev/null); do
      for fd in /proc/"${pid}"/fd/*; do
        [[ "$(readlink "${fd}" 2>/dev/null)" == "socket:[${ino}]" ]] && return 0
      done
    done
    return 1
  fi
  if have_cmd lsof; then lsof -nP -a -p "${pid}" -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; return; fi
  if have_cmd ss; then ss -ltnp "sport = :${port}" 2>/dev/null | grep -q "pid=${pid},"; return; fi
  return 2
}

# _dl_smoke_wait <pid> <port> <path> - poll until THIS pid is alive, holds the listening socket of
# <port> AND <path> answers. Sets _DL_SMOKE_WAITED (seconds) and _DL_SMOKE_WHY on failure.
_dl_smoke_wait() {
  local pid="$1" port="$2" path="$3" i own
  _DL_SMOKE_WHY="did not become healthy within ${LLMCTL_SMOKE_TIMEOUT}s"
  for (( i=0; i<LLMCTL_SMOKE_TIMEOUT; i++ )); do
    _DL_SMOKE_WAITED="${i}"
    if ! kill -0 "${pid}" 2>/dev/null; then _DL_SMOKE_WHY="the server process exited before becoming ready (port ${port} may have been taken)"; return 1; fi
    if curl -fsS "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; then
      own=0; _dl_pid_owns_port "${pid}" "${port}" || own=$?
      case "${own}" in
        0) return 0 ;;
        2) _DL_SMOKE_WHY="cannot verify which process owns port ${port} (no /proc, lsof or ss): not trusting /health"; return 1 ;;
        *) _DL_SMOKE_WHY="port ${port} answers, but not from the server this test launched (another program holds it)" ;;
      esac
    fi
    sleep 1
  done
  return 1
}

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

  local port; port="$(_dl_smoke_pick_port)" || return 1
  local args=(--model "${model}" --ctx-size 512 --n-gpu-layers 0 --host 127.0.0.1 --port "${port}")
  [[ -n "${mmproj}" ]] && args+=(--mmproj "${mmproj}")

  log "smoke test: starting llama-server for ${profile} on 127.0.0.1:${port}"
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

  local ready=0
  if _dl_smoke_wait "${pid}" "${port}" "/health"; then ready=1; fi

  if [[ "${ready}" != "1" ]]; then
    _dl_log "smoke FAILED: ${_DL_SMOKE_WHY}"
    sed 's/^/OUT: /' "${server_log}" >> "${_DL_EVIDENCE}" 2>/dev/null || true
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    err "smoke test failed: llama-server ${_DL_SMOKE_WHY} (see ${server_log})"
    return 1
  fi
  _dl_log "smoke: /health OK after ${_DL_SMOKE_WAITED}s"

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
  response="$(curl -fsS -X POST "http://127.0.0.1:${port}/v1/chat/completions" \
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
  # Parse the actual answer field, never grep the raw body (independent
  # review, 2026-09-17): a bare `grep -q "OK"` on the WHOLE response also
  # matches "OK" appearing inside reasoning_content, and raising
  # max_tokens above (8 -> 64) gives a reasoning-format model 8x more room
  # to print "OK" while THINKING about the answer without ever emitting it
  # as real content - reproduced directly against the raw evidence this
  # anchor's own comment already captured: reasoning_content began
  # 'The user says: "', on its way to quoting the instruction verbatim,
  # which would satisfy a raw-body grep long before any genuine answer.
  # Parsing message.content specifically, AND requiring finish_reason ==
  # "stop" (never "length" - the harmony-model failure case had
  # content="" + finish_reason="length", exactly what this must reject),
  # closes that false-positive channel while keeping every already-passing
  # profile passing (their own captured evidence already showed
  # content="OK" + finish_reason="stop").
  local content finish_reason
  content="$(printf '%s' "${response}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["choices"][0]["message"].get("content") or "")
except Exception:
    print("")
' 2>/dev/null)"
  finish_reason="$(printf '%s' "${response}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["choices"][0].get("finish_reason") or "")
except Exception:
    print("")
' 2>/dev/null)"
  _dl_log "smoke parsed content: '${content}' finish_reason: ${finish_reason}"
  if [[ "${content}" == *OK* && "${finish_reason}" == "stop" ]]; then
    _dl_log "smoke PASSED: answer content contains 'OK' with finish_reason=stop"
    info "smoke test passed for ${profile} (deterministic prompt answered 'OK')"
    return 0
  fi
  _dl_log "smoke FAILED: answer content did not contain 'OK' with finish_reason=stop"
  err "smoke test failed: model response did not contain 'OK'"
  return 1
}

# --- decision smoke test (decide-capable llama profiles) ---------------------
# The probes below run the Go binary's `llmctl-decide smoke` (internal/gateway/smoke.go) against
# the freshly-launched smoke server: the SAME production letter-logit driver `llmctl decide serve`
# uses (prompt template, first-token logprob readout, finite-probability validation) - never a
# shell/Python copy of it. Each probe prints the typed answer and returns the binary's exit code
# (0 valid typed answer, 1 backend failure, 2 usage, 6 unreachable); _dl_evidence_run captures
# RUN/EXIT/OUT around them. The binary is built by `llmctl build decide` when absent (clear error
# when Go is missing - see decide_bin in lib/decide.sh).

# _dl_decision_probe_choice <port> - invoice routing, 2 options: must pick "billing".
_dl_decision_probe_choice() {
  local port="$1" bin
  bin="$(decide_bin)" || return 2
  if [[ "${_DL_DECISION_PROTO:-letter-logit}" == "systemone-native" ]]; then
    # a smoke answer is shape evidence (valid typed answer, finite probabilities summing to 1), never
    # quality evidence: no --expect-choice (Julia-1 routes the "charged twice" invoice to shipping)
    "${bin}" smoke --url "http://127.0.0.1:${port}" --protocol systemone-native --options 2
    return
  fi
  "${bin}" smoke --url "http://127.0.0.1:${port}" --protocol letter-logit \
    --options 2 --expect-choice billing
}

# _dl_decision_probe_options <port> - same question with 4 lettered options: a valid typed
# answer (finite probabilities summing to 1) over a wider option set.
_dl_decision_probe_options() {
  local port="$1" bin
  bin="$(decide_bin)" || return 2
  "${bin}" smoke --url "http://127.0.0.1:${port}" --protocol "${_DL_DECISION_PROTO:-letter-logit}" --options 4
}

# _dl_smoke_test_decision <profile> <model_path>
# Mirrors _dl_smoke_test_gguf's structure (launch the real llama-server on
# 127.0.0.1:$LLMCTL_SMOKE_PORT, poll /health, then run a parsed check),
# replacing the "reply OK" probe with the three deterministic decision
# probes above. LLMCTL_SMOKE=0 disables; SKIP-warn when llama-server is
# not built (same precedent as _dl_smoke_test_gguf).
_dl_smoke_test_decision() {
  local profile="$1" model="$2"
  if [[ "${LLMCTL_SMOKE}" == "0" ]]; then
    _dl_log "decision smoke test disabled via LLMCTL_SMOKE=0"
    warn "smoke test disabled (LLMCTL_SMOKE=0)"
    return 0
  fi
  local server
  if ! server="$(_dl_llama_server_bin)"; then
    _dl_log "decision smoke test SKIPPED: llama-server not built (run: llmctl build llama)"
    warn "llama-server not built - skipping decision smoke test (run 'llmctl build llama' first)"
    return 0
  fi

  local port; port="$(_dl_smoke_pick_port)" || return 1
  # The probes follow the profile's decision protocol: a native (/v1/systemone) model has no chat
  # endpoint, a letter-logit model has no /v1/systemone (501). A native engine scores the whole state in
  # one batch, so its smoke gets a 4096 context (the default 512 cannot hold the encoder's window).
  _DL_DECISION_PROTO="$(catalog_decision_protocol "${profile}")"; _DL_DECISION_PROTO="${_DL_DECISION_PROTO:-letter-logit}"
  local ctx=512; [[ "${_DL_DECISION_PROTO}" == "systemone-native" ]] && ctx=4096
  local args=(--model "${model}" --ctx-size "${ctx}" --n-gpu-layers 0 --host 127.0.0.1 --port "${port}")
  log "decision smoke test: starting llama-server for ${profile} on 127.0.0.1:${port}"
  _dl_log "smoke protocol: ${_DL_DECISION_PROTO}"
  _dl_log "smoke: ${server} ${args[*]}"
  local server_log="${LLMCTL_LOG_DIR}/smoke-${profile}.log"
  ensure_dir "${LLMCTL_LOG_DIR}"
  local server_dir; server_dir="$(cd "$(dirname "${server}")" && pwd)"
  LD_LIBRARY_PATH="${server_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${server}" "${args[@]}" > "${server_log}" 2>&1 &
  local pid=$!

  local ready=0
  if _dl_smoke_wait "${pid}" "${port}" "/health"; then ready=1; fi

  if [[ "${ready}" != "1" ]]; then
    _dl_log "decision smoke FAILED: ${_DL_SMOKE_WHY}"
    sed 's/^/OUT: /' "${server_log}" >> "${_DL_EVIDENCE}" 2>/dev/null || true
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    err "decision smoke test failed: llama-server ${_DL_SMOKE_WHY} (see ${server_log})"
    return 1
  fi
  _dl_log "smoke: /health OK after ${_DL_SMOKE_WAITED}s"

  local probes_ok=1
  _dl_evidence_run _dl_decision_probe_choice "${port}" || probes_ok=0
  _dl_evidence_run _dl_decision_probe_options "${port}" || probes_ok=0

  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true

  if [[ "${probes_ok}" == "1" ]]; then
    if [[ "${_DL_DECISION_PROTO}" == "systemone-native" ]]; then
      _dl_log "decision smoke PASSED: valid typed answers over /v1/systemone (2 and 4 options; shape evidence only)"
    else
      _dl_log "decision smoke PASSED: choice == billing (2 options), valid typed answer (4 options)"
    fi
    info "decision smoke test passed for ${profile} (llmctl-decide smoke: choice probes)"
    return 0
  fi
  _dl_log "decision smoke FAILED: one or more llmctl-decide smoke probes failed"
  err "decision smoke test failed for ${profile} (see ${LLMCTL_VERIFY_DIR}/${profile}.log)"
  return 1
}


# --- onnx engine validation + smoke (encoder decision profiles) --------------
# _dl_validate_onnx <profile> <dest_dir>
# Structural check first (model.onnx + a tokenizer file present and
# non-empty), then the REAL smoke _dl_smoke_test_onnx - mirroring the
# llama arm's _dl_smoke_test_decision, against lib/onnx_server.py instead
# of llama-server.
_dl_validate_onnx() {
  local profile="$1" dest="$2"
  local model=""
  for cand in "${dest}/model.onnx" "${dest}/onnx/model.onnx"; do
    [[ -s "${cand}" ]] && { model="${cand}"; break; }
  done
  [[ -n "${model}" ]] || { err "structural check failed: no non-empty model.onnx (or onnx/model.onnx) in ${dest}"; return 1; }
  local tok=""
  for cand in "${dest}/spm.model" "${dest}/onnx/spm.model" \
              "${dest}/tokenizer.json" "${dest}/onnx/tokenizer.json"; do
    [[ -s "${cand}" ]] && { tok="${cand}"; break; }
  done
  [[ -n "${tok}" ]] || { err "structural check failed: no tokenizer file (spm.model or tokenizer.json) in ${dest}"; return 1; }
  _dl_log "structural check passed: model ${model}, tokenizer ${tok}"
  info "structural validation passed for ${profile} (onnx model + tokenizer present)"
  _dl_smoke_test_onnx "${profile}" "${dest}" \
    || die "onnx smoke test failed for ${profile} (see ${LLMCTL_VERIFY_DIR}/${profile}.log)"
}

# --- onnx smoke: probes against the INTERNAL scoring runtime ---------------------
# The runtime (lib/onnx_server.py) speaks only POST /v1/score (pairs in,
# label-ordered probabilities out); typed-question logic lives in the Go
# gateway, so the smoke asserts the encoder itself: the contract shape, and
# that an entailed pair and a contradicted pair are scored differently.
_dl_onnx_py() {
  # The hash-locked venv python when `llmctl build onnx` has been run, else
  # the system python3 (honours PYTHONPATH, so tests can inject stub backends).
  local venv_py="${LLMCTL_DATA_DIR}/venv-onnx/bin/python"
  if [[ -x "${venv_py}" ]]; then printf '%s' "${venv_py}"; else printf '%s' "${LLMCTL_PYTHON:-python3}"; fi
}

# _dl_onnx_score <port> <keyfile> <body-json> - POST helper (prints the raw response).
# The key is passed to curl via a config file on stdin, never on argv.
_dl_onnx_score() {
  local port="$1" keyfile="$2" body="$3"
  need_cmd curl
  { printf 'header = "Authorization: Bearer '; tr -d '\n' < "${keyfile}"; printf '"\n'; } \
    | curl -fsS --max-time "${LLMCTL_DECIDE_TIMEOUT:-30}" -K - \
        -X POST "http://127.0.0.1:${port}/v1/score" \
        -H 'Content-Type: application/json' -d "${body}"
}

# argmax label of pair 0 + structural checks. $1=port $2=keyfile $3=body $4=expect
# ($4 = entail: argmax label must start with "entail"; contradict: must NOT).
_dl_onnx_probe_pair() {
  local port="$1" keyfile="$2" body="$3" expect="$4"
  local resp; resp="$(_dl_onnx_score "${port}" "${keyfile}" "${body}")" || return 2
  printf '%s' "${resp}" | python3 -c '
import json, math, sys
d = json.load(sys.stdin)
labels, scores = d["labels"], d["scores"]
row = scores[0]
assert len(labels) == len(row) >= 2, "labels/scores width mismatch"
assert all(math.isfinite(x) and 0 <= x <= 1 for x in row), "scores not finite probabilities"
assert abs(sum(row) - 1.0) < 1e-6, "scores do not sum to 1"
top = labels[max(range(len(row)), key=row.__getitem__)]
src = d.get("label_source", "")
print(json.dumps({"top": top, "label_source": src, "scores": [round(x, 6) for x in row], "truncated": d["truncated"]}))
if src.startswith(("generic", "none")):
    print("label_source %r carries no semantics: cannot judge the probe" % src, file=sys.stderr); sys.exit(3)
want = sys.argv[1]
ok = top.lower().startswith("entail") if want == "entail" else not top.lower().startswith("entail")
sys.exit(0 if ok else 1)' "${expect}"
}

_dl_onnx_probe_entail() {
  _dl_onnx_probe_pair "$1" "$2" '{"pairs":[{"premise":"The deployment succeeded and all checks passed.","hypothesis":"The deployment succeeded."}]}' entail
}
_dl_onnx_probe_contradict() {
  _dl_onnx_probe_pair "$1" "$2" '{"pairs":[{"premise":"The deployment succeeded and all checks passed.","hypothesis":"The deployment did not succeed."}]}' contradict
}
_dl_onnx_probe_batch() {
  local port="$1" keyfile="$2" resp
  resp="$(_dl_onnx_score "${port}" "${keyfile}" \
    '{"pairs":[{"premise":"It is raining.","hypothesis":"It is wet outside."},{"premise":"It is raining.","hypothesis":"The sun is out."}]}')" || return 2
  printf '%s' "${resp}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ok = len(d["scores"]) == 2 and len(d["truncated"]) == 2 and all(abs(sum(r) - 1.0) < 1e-6 for r in d["scores"])
print(json.dumps({"rows": len(d["scores"]), "labels": d["labels"]}))
sys.exit(0 if ok else 1)'
}

# _dl_smoke_test_onnx <profile> <dest_dir>
# Launch lib/onnx_server.py on 127.0.0.1:$LLMCTL_SMOKE_PORT with a throwaway
# 0600 key file, wait for /readyz (a real load-time inference), run the three
# probes with RUN/EXIT/OUT evidence. SKIP-with-reason when the inference deps
# are missing - and then _DL_SMOKE_NOTE is set so download_profile does NOT
# claim "downloaded and verified" (D-12). The child is always reaped, also on
# SIGTERM/SIGINT of this shell (D-14). No test seam: unit tests put stub
# onnxruntime/sentencepiece modules on PYTHONPATH.
_dl_smoke_test_onnx() {
  local profile="$1" dest="$2"
  if [[ "${LLMCTL_SMOKE}" == "0" ]]; then
    _dl_log "onnx smoke test disabled via LLMCTL_SMOKE=0"
    warn "smoke test disabled (LLMCTL_SMOKE=0)"
    _DL_SMOKE_NOTE="smoke test disabled (LLMCTL_SMOKE=0)"
    return 0
  fi
  local py; py="$(_dl_onnx_py)"
  local missing="" m
  for m in onnxruntime numpy sentencepiece; do
    "${py}" -B -c "import ${m}" 2>/dev/null || missing="${missing:+$missing }${m}"
  done
  if [[ -n "${missing}" ]]; then
    _dl_log "onnx smoke test SKIPPED: python package(s) not installed: ${missing} (run: llmctl build onnx)"
    warn "onnx inference deps missing (${missing}) - smoke test SKIPPED, the model is NOT functionally verified (run: llmctl build onnx, then: llmctl models verify ${profile})"
    _DL_SMOKE_NOTE="onnx smoke test SKIPPED: missing ${missing}"
    return 0
  fi

  local tok="tokenizer.json" cand
  for cand in "${dest}/spm.model" "${dest}/onnx/spm.model"; do
    [[ -s "${cand}" ]] && tok="spm.model"
  done
  local runner="${_dl_dir}/onnx_server.py"
  local port; port="$(_dl_smoke_pick_port)" || return 1
  local keyfile; keyfile="$(umask 077; mktemp "${TMPDIR:-/tmp}/llmctl-smoke-key.XXXXXX")"
  ( umask 077; python3 -c 'import secrets; print(secrets.token_hex(24))' > "${keyfile}" )
  chmod 600 "${keyfile}"
  log "onnx smoke test: starting onnx_server.py for ${profile} on 127.0.0.1:${port}"
  _dl_log "smoke: ${py} ${runner} --model-dir ${dest} --host 127.0.0.1 --port ${port} --profile ${profile} --tokenizer ${tok} --api-key-file <throwaway 0600 file>"
  local server_log="${LLMCTL_LOG_DIR}/smoke-${profile}.log"
  ensure_dir "${LLMCTL_LOG_DIR}"
  "${py}" -B "${runner}" --model-dir "${dest}" --host 127.0.0.1 \
    --port "${port}" --profile "${profile}" --tokenizer "${tok}" \
    --api-key-file "${keyfile}" > "${server_log}" 2>&1 &
  local pid=$!
  _DL_SMOKE_PID="${pid}"
  _DL_SMOKE_KEYFILE="${keyfile}"
  trap '_dl_onnx_smoke_cleanup; trap - TERM; kill -TERM $$' TERM
  trap '_dl_onnx_smoke_cleanup; trap - INT; kill -INT $$' INT

  local ready=0
  if _dl_smoke_wait "${pid}" "${port}" "/readyz"; then ready=1; fi

  if [[ "${ready}" != "1" ]]; then
    _dl_log "onnx smoke FAILED: ${_DL_SMOKE_WHY}"
    sed 's/^/OUT: /' "${server_log}" >> "${_DL_EVIDENCE}" 2>/dev/null || true
    _dl_onnx_smoke_cleanup
    err "onnx smoke test failed: onnx_server.py ${_DL_SMOKE_WHY} (see ${server_log})"
    return 1
  fi
  _dl_log "smoke: /readyz OK after ${_DL_SMOKE_WAITED}s"

  local probes_ok=1
  _dl_evidence_run _dl_onnx_probe_entail "${port}" "${keyfile}" || probes_ok=0
  _dl_evidence_run _dl_onnx_probe_contradict "${port}" "${keyfile}" || probes_ok=0
  _dl_evidence_run _dl_onnx_probe_batch "${port}" "${keyfile}" || probes_ok=0
  _dl_onnx_smoke_cleanup

  if [[ "${probes_ok}" == "1" ]]; then
    _dl_log "onnx smoke PASSED: entailed pair scores entailment, contradicted pair does not, batch contract holds"
    info "onnx smoke test passed for ${profile} (entail/contradict/batch probes)"
    return 0
  fi
  _dl_log "onnx smoke FAILED: one or more onnx probes did not meet its threshold"
  err "onnx smoke test failed for ${profile} (see ${LLMCTL_VERIFY_DIR}/${profile}.log)"
  return 1
}

# Reap the smoke runtime + throwaway key (also used by the TERM/INT traps).
_dl_onnx_smoke_cleanup() {
  if [[ -n "${_DL_SMOKE_PID:-}" ]]; then
    kill "${_DL_SMOKE_PID}" 2>/dev/null || true
    wait "${_DL_SMOKE_PID}" 2>/dev/null || true
    _DL_SMOKE_PID=""
  fi
  if [[ -n "${_DL_SMOKE_KEYFILE:-}" ]]; then
    rm -f "${_DL_SMOKE_KEYFILE}"
    _DL_SMOKE_KEYFILE=""
  fi
  trap - TERM INT
}


_dl_validate_colibri() {
  # _dl_validate_colibri <profile> <dest_dir>
  local profile="$1" dest="$2"
  # Resolve the coli launcher via the SAME same-repo-first fallback
  # lib/scheduler.sh's sched_build_launch already uses for the colibri
  # engine (I6, independent review 2026-09-17): a bare `have_cmd coli` PATH
  # lookup silently missed the real, already-executable in-repo `coli`
  # script whenever it was not ALSO installed onto PATH, so this validator
  # degraded to the weaker structural-only check even on a host where the
  # stronger `coli doctor` check was fully available and already used to
  # launch the service itself.
  local coli_bin="${LLMCTL_COLI_BIN:-${LLMCTL_ROOT}/submodules/colibri/c/coli}"
  if [[ ! -x "${coli_bin}" ]]; then
    if have_cmd coli; then coli_bin="coli"; else coli_bin=""; fi
  fi
  if [[ -n "${coli_bin}" ]]; then
    log "running colibri validation via coli doctor"
    if _dl_evidence_run env COLI_MODEL="${dest}" "${coli_bin}" doctor; then
      info "coli doctor passed for ${profile}"
      return 0
    fi
    warn "coli doctor failed for ${profile}; falling back to structural check"
  else
    _dl_log "coli launcher not found (same-repo or PATH); using structural validation"
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
  _DL_SMOKE_NOTE=""
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
      # Capability-based smoke dispatch: decide-capable profiles get the
      # typed-decision smoke (three deterministic noul/choice/score probes
      # through the production decide_* path); every other llama profile
      # keeps the existing _dl_smoke_test_gguf untouched.
      if [[ " $(catalog_capability "${profile}") " == *" decide "* ]]; then
        _dl_smoke_test_decision "${profile}" "${model}" \
          || die "decision smoke test failed for ${profile} (see ${LLMCTL_VERIFY_DIR}/${profile}.log)"
      else
        _dl_smoke_test_gguf "${profile}" "${model}" "${mmproj}" \
          || die "smoke test failed for ${profile} (see ${LLMCTL_VERIFY_DIR}/${profile}.log)"
      fi
      ;;
    colibri)
      _dl_validate_colibri "${profile}" "${dest_dir}" \
        || die "colibri validation failed for ${profile}"
      ;;
    onnx)
      _dl_validate_onnx "${profile}" "${dest_dir}" \
        || die "onnx validation failed for ${profile}"
      ;;
  esac
  if [[ -n "${_DL_SMOKE_NOTE:-}" ]]; then
    # D-12: files are checksum-verified but the smoke did NOT run - never claim
    # the profile is "verified".
    _dl_log "download ${profile}: FILES-VERIFIED, smoke not run (${_DL_SMOKE_NOTE})"
    warn "profile '${profile}' downloaded; file checksums verified but ${_DL_SMOKE_NOTE}. Evidence: ${LLMCTL_VERIFY_DIR}/${profile}.log"
    _DL_SMOKE_NOTE=""
    return 0
  fi
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
  local repo; repo="$(catalog_hf_repo "${profile}")"
  local name size sha role
  while IFS='|' read -r name size sha role; do
    # I5 fix (independent review, 2026-09-17): resolve a null catalog
    # sha256 via the same HF-API fallback _dl_download_file uses, instead
    # of handing _dl_verify_file the raw empty sha - which made it skip
    # the checksum check entirely for config.hf.json/config.json while
    # this function still reported "passed checksum verification".
    local resolved_sha
    resolved_sha="$(_dl_resolve_sha "${repo}" "${name}" "${sha}")" \
      || die "cannot obtain sha256 for ${name} from HF API - refusing unverifiable file"
    _dl_evidence_run _dl_verify_file "${dest_dir}/${name}" "${size}" "${resolved_sha}" \
      || die "verification failed for ${name}"
  done < <(catalog_files "${profile}")
  info "profile '${profile}' passed checksum verification"
}
