## Overview

`lib/download.sh` implements llmctl's verified model download pipeline: for
every file listed in a catalog profile it either confirms an already-present
file still matches its expected size/checksum, or downloads it with
resumable `curl`, verifies it (size + checksum, resolving a missing catalog
checksum live from the Hugging Face API when needed), and atomically renames
it into place only after verification passes. After every file for a profile
is downloaded, GGUF (`llama`) profiles get a real post-download smoke test
against a genuine `llama-server` process, and `colibri` profiles get a
structural or `coli doctor`-backed validation. Every step of every run is
appended as timestamped evidence to `${LLMCTL_VERIFY_DIR}/<profile>.log`.
It exists so a downloaded model is never trusted without cryptographic proof
it matches what the catalog (or Hugging Face itself) says it should be —
per this project's anti-bluff / verified-download design goal
(`docs/architecture.md`, `README.md`).

## Prerequisites

* Sources `lib/common.sh` and `lib/catalog.sh` from its own directory
  (`_dl_dir`).
* `curl` — required for both the model download itself and the live
  Hugging Face API checksum fallback (`_dl_fetch_sha256_from_api`).
* `python3` — used to parse the Hugging Face API JSON response and to parse
  the smoke test's chat-completion JSON response.
* One of `sha256sum`, `shasum`, or `openssl` for `llmctl_sha256` (`die`s if
  none are found).
* `git` for `llmctl_git_blob_sha1` — only needed when a catalog file's
  checksum resolves to a `gitblob1:<hex>` value (i.e. the file is an
  ordinary, non-LFS-tracked git blob on Hugging Face, typically small
  config/JSON files).
* For the GGUF smoke test: a built `llama-server` binary, resolved via
  `LLMCTL_LLAMA_SERVER` (if set and executable) or the default build path
  `${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server` — its absence
  is a soft skip (warned, not a failure; see Edge cases).
* For colibri validation: the `coli` launcher, resolved via
  `LLMCTL_COLI_BIN` (if set and executable), the in-repo path
  `${LLMCTL_ROOT}/submodules/colibri/c/coli`, or `coli` on `PATH` — also a
  soft fallback (see Edge cases).
* Network access to `${LLMCTL_HF_BASE}` (default
  `https://huggingface.co`) for downloads and API checksum lookups.
* `${LLMCTL_VERIFY_DIR}`, `${LLMCTL_MODELS_DIR}`, `${LLMCTL_LOG_DIR}` (from
  `common.sh`) must be writable — `ensure_state_dirs` is called at the start
  of both public entry points.

## Usage examples

```sh
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/download.sh"

download_profile fast          # download + verify + smoke-test/validate "fast"
verify_profile fast            # re-verify an already-downloaded profile's checksums

# via the CLI:
bin/llmctl models download fast
bin/llmctl models verify fast

# dry-run: prints the curl command instead of downloading, skips post-download validation
LLMCTL_DRY_RUN=1 bin/llmctl models download fast

# tune or disable the smoke test
LLMCTL_SMOKE=0 bin/llmctl models download fast              # skip smoke test (evidence still logged)
LLMCTL_SMOKE_PORT=18099 LLMCTL_SMOKE_TIMEOUT=180 bin/llmctl models download fast

# point downloads/verification at a fixture HTTP server (test pattern)
LLMCTL_HF_BASE=http://127.0.0.1:8000 bin/llmctl models download fast

# override the llama-server binary or coli launcher used for validation
LLMCTL_LLAMA_SERVER=/custom/path/llama-server bin/llmctl models download fast
LLMCTL_COLI_BIN=/custom/path/coli bin/llmctl models download colibri-glm
```

## Edge cases

* **Already-verified files are skipped, not re-downloaded**:
  `_dl_download_file` checks for an existing destination file first; if it
  passes `_dl_verify_file` (size + checksum), the function logs and returns
  immediately without touching the network. A file that exists but *fails*
  verification is deleted (`rm -f`) and the full download proceeds.
* **A null catalog checksum triggers a live Hugging Face API lookup**
  (`_dl_resolve_sha`), shared identically by both `_dl_download_file` and
  `verify_profile` — this was itself a fixed bug (I5, documented in the file
  header): `verify_profile` used to hand the raw empty catalog sha straight
  to `_dl_verify_file`, whose own `[[ -n "${sha}" ]]` guard silently skipped
  the checksum check while `verify_profile` still printed "passed checksum
  verification." An unresolvable checksum (API lookup returns nothing) is a
  hard failure (`die "cannot obtain sha256 ... refusing unverified
  download"` / `"refusing unverifiable file"`), never a silent pass.
* **Two distinct checksum algorithms are supported and auto-selected**: a
  bare hex string is treated as sha256 (verified via `llmctl_sha256`); a
  `gitblob1:<hex>`-prefixed string is treated as a git blob sha1 (verified
  via `llmctl_git_blob_sha1`) — this distinction exists because Hugging
  Face's API reports a `.lfs.sha256` for LFS-tracked files (large model
  weights) but only a `blobId` (git's own blob hash) for ordinary,
  non-LFS-tracked small files like `config.json`, which have no LFS object
  at all.
* **`llmctl_git_blob_sha1` uses `git hash-object --no-filters`, not a bare
  `git hash-object`**: the file's own comment documents a real, reproduced
  bug where a bare call applies the *calling* repository's own clean/CRLF
  filters (`core.autocrlf`, a `* text=auto` `.gitattributes`) based on the
  process's cwd repo — even for a target file entirely outside that repo —
  producing a wrong hash and a false verification failure on any host with
  those settings enabled (confirmed by comparing against an independently
  computed raw git blob hash). `--` also guards against a filename beginning
  with `-` being misread as an option.
* **`curl` exit code 33 (no HTTP Range support) triggers an automatic
  full-redownload fallback**, not a hard failure: the stale `.part` file is
  discarded and a fresh, non-resumed `curl` call is retried from byte 0 —
  documented as "resuming is impossible against THIS server, not a bug in
  our `.part` file," and the stale file is never corrupted by this path,
  only discarded.
* **Verification happens before the atomic rename, never after**: a
  freshly-downloaded `.part` file is verified in place; only on success is
  it `mv -f`'d to its final destination name — a mismatched download can
  never land at the final, "trusted" path, even transiently.
* **The GGUF smoke test degrades to a warning, not a failure, when
  `llama-server` isn't built**: `_dl_llama_server_bin` failing to resolve a
  binary causes `_dl_smoke_test_gguf` to log and warn "skipping smoke test
  (run 'llmctl build llama' first)" and return success (`0`) — a profile can
  be downloaded and marked verified without ever having been smoke-tested if
  the engine simply hasn't been built yet. `LLMCTL_SMOKE=0` produces the
  same soft-skip behavior but for an explicit opt-out rather than a missing
  binary.
* **The smoke test's LD_LIBRARY_PATH fix works around a real ABI collision**:
  the freshly-built `llama-server`'s `libggml.so.0` SONAME can collide with
  an older, incompatible system-installed copy; without prepending the
  binary's own directory to `LD_LIBRARY_PATH`, the dynamic linker can
  silently prefer the wrong system copy and the server dies with a
  symbol-lookup error instead of booting — documented as the same root cause
  and fix as `lib/service_linux.sh`'s `svc_write_env()`.
* **The smoke test's readiness poll distinguishes "still starting" from
  "already died"**: each iteration of the up-to-`LLMCTL_SMOKE_TIMEOUT`-second
  loop checks `/health` first, then falls back to `kill -0 "${pid}"` to
  detect an early process exit and break out of the loop immediately rather
  than waiting out the full timeout on a process that's already gone.
* **The smoke test's completion request uses `max_tokens=64`, not a smaller
  budget**, specifically to accommodate "harmony"/reasoning-format models
  that emit chain-of-thought as separate `reasoning_content` tokens *before*
  any real answer content — the file documents a real reproduced failure
  where a lower budget (8) was entirely consumed by the reasoning preamble,
  leaving `content=""` and `finish_reason="length"` even though the model
  itself was working correctly.
* **The smoke test parses `message.content` specifically, and requires
  `finish_reason == "stop"`** — it deliberately does not grep the raw
  response body for "OK", because a raw-body match would also match "OK"
  appearing inside `reasoning_content` while the model is still "thinking"
  about the answer, which the file documents as a real reproduced false
  positive risk given the same reasoning-format models above.
* **Colibri validation prefers `coli doctor`, falling back to a structural
  check on failure or when no launcher is found**: it resolves the launcher
  via the same same-repo-first-then-PATH order the scheduler itself uses
  (fixing an independently-reviewed bug, I6, where a bare `have_cmd coli`
  PATH-only lookup silently missed an in-repo, already-executable `coli`
  script that wasn't also installed onto `PATH`); if `coli doctor` fails, it
  warns and falls back to checking for at least one non-empty
  `.safetensors` shard plus a `config*.json` file rather than hard-failing
  immediately.
* **`LLMCTL_DRY_RUN=1` still downloads-and-verifies each file's presence
  check, but logs the curl invocation instead of running it, and skips
  post-download validation entirely** — `download_profile` explicitly
  checks `LLMCTL_DRY_RUN` after the file loop and returns before dispatching
  to the smoke test / colibri validation branch.
* **Every step, success or failure, is appended to the evidence log**
  (`_dl_log`/`_dl_evidence_run`) — `_dl_evidence_run` captures both stdout
  and stderr of the wrapped command, records its exit code, and additionally
  re-prints the command's output to the *caller's* stderr when it failed
  (`[[ "${rc}" != "0" ]] && printf ... >&2`), so a failure is visible
  immediately in the terminal as well as preserved in the log file.

## Internal behaviour

1. **Checksum helpers**: `llmctl_sha256` (portable sha256 via whichever tool
   is available) and `llmctl_git_blob_sha1` (git blob sha1 via
   `git hash-object --no-filters`).
2. **Evidence logging**: `_dl_log` (timestamped append to `_DL_EVIDENCE`)
   and `_dl_evidence_run` (runs a command, captures output+exit code,
   appends both, surfaces failing output to stderr, returns the real exit
   code without aborting the caller).
3. **Checksum resolution**: `_dl_fetch_sha256_from_api` (queries the HF
   `?blobs=true` API for a repo/file, prints either a bare sha256 or a
   `gitblob1:`-prefixed blob id) and `_dl_resolve_sha` (prefers the
   catalog's own sha256, falling back to the API lookup, shared by both
   download and verify paths).
4. **File verification**: `_dl_verify_file` (checks non-empty, optional size
   match, optional checksum match with algorithm auto-detected from the
   `gitblob1:` prefix).
5. **Per-file download**: `_dl_download_file` — resolves the repo/revision/
   URL, resolves the checksum (`_dl_resolve_sha`), skips already-verified
   existing files, otherwise downloads to a `.part` file with resumable
   `curl` (with the exit-33 full-redownload fallback), verifies the `.part`
   file, and atomically renames it into place.
6. **Smoke test resolution + execution**: `_dl_llama_server_bin` (resolves
   the binary path) and `_dl_smoke_test_gguf` (launches the server in the
   background with `LD_LIBRARY_PATH` fixed up, polls `/health` up to
   `LLMCTL_SMOKE_TIMEOUT` seconds, sends a deterministic chat-completion
   request, parses `content`/`finish_reason`, kills the server, and reports
   pass/fail — all logged as evidence).
7. **Colibri validation**: `_dl_validate_colibri` (resolves the `coli`
   launcher, runs `coli doctor` if available, falls back to a structural
   shard+config check).
8. **Public entry points**: `download_profile` (validates the profile
   exists, sets up the evidence log, downloads every file from
   `catalog_files`, then dispatches to the GGUF smoke test or colibri
   validation based on `catalog_engine`, skipping validation entirely under
   `LLMCTL_DRY_RUN`) and `verify_profile` (validates the profile is already
   downloaded, re-resolves and re-checks every file's checksum via the same
   `_dl_resolve_sha`/`_dl_verify_file` path, with no download or smoke test
   involved).

## Related scripts

* Sources `lib/common.sh` and `lib/catalog.sh`.
* Called by `bin/llmctl`'s `models download` and `models verify` command
  branches (`download_profile`, `verify_profile`).
* Depends on `lib/catalog.sh` for `catalog_exists`, `catalog_hf_repo`,
  `catalog_field`, `catalog_files`, `catalog_engine`.
* Its smoke test path expects a binary built by `lib/engine.sh`'s
  `engine_build_llama` (`engine_llama_server_bin`'s output path); its
  colibri validation path expects the `coli` launcher built/installed by
  `lib/engine.sh`'s `engine_build_colibri`.
* Exercised by `tests/test_download.sh` (checksum verification, smoke test
  logic), `tests/test_download_resume.sh` (the curl-33 resume/fallback
  path), and `tests/fixtures/range_server.py` (a local HTTP fixture server
  used to serve deterministic download responses without hitting the real
  Hugging Face API).

## Last verified date

2026-09-17
