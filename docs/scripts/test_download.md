## Overview

`tests/test_download.sh` proves the core verified-download contract of
`lib/download.sh` — the mechanism behind `llmctl models download <profile>`
and `llmctl models verify <profile>` — against a local HTTP fixture
(`python3 -m http.server`), with zero network access to the real Hugging
Face CDN. It exercises the full lifecycle: a fresh download with checksum
verification, skipping an already-verified file on a second run, detecting
and re-downloading a corrupted local file, hard-failing when the catalog's
declared sha256 doesn't match what was actually downloaded, and the
evidence log this project's safety guarantees promise (a per-profile
verification log under `LLMCTL_VERIFY_DIR`).

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/assertion
  helpers).
* `lib/common.sh`, `lib/catalog.sh`, `lib/download.sh` — all three sourced
  directly so the test can call `download_profile`, `verify_profile`, and
  `llmctl_sha256` as in-process functions.
* `LLMCTL_SMOKE=0` — disables the post-download smoke test (which would
  otherwise attempt to boot a real `llama-server`); irrelevant in this
  sandbox.
* `python3 -m http.server` — serves a small synthetic fixture payload
  (`"llmctl tiny fixture model payload - NOT a real GGUF\n"`, deliberately
  labeled as fake) from a scratch webroot at a Hugging-Face-shaped resolve
  path (`toy/repo/resolve/main/model.bin`); no real GGUF content is ever
  involved.
* `curl` — used as the readiness-probe polling mechanism for the spun-up
  local HTTP server.
* A synthetically-generated catalog JSON file (`make_catalog` local
  function in this test), parameterized by the expected sha256, pointing
  its single `toy` profile's file entry at the locally-served fixture.
* `LLMCTL_HF_BASE`, `LLMCTL_CATALOG` — overridden to point at the local
  fixture server and the scratch catalog file respectively.
* `stat -c%s` / `stat -f%z` (GNU/BSD fallback pair) to compute the
  fixture payload's real byte size for the catalog.

## Usage examples

* Standalone: `bash tests/test_download.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.
* The real function-level invocations this test exercises (after sourcing
  `lib/common.sh`/`lib/catalog.sh`/`lib/download.sh` and pointing
  `LLMCTL_HF_BASE`/`LLMCTL_CATALOG` at the local fixture):
  ```bash
  download_profile toy
  verify_profile toy
  ```

## Edge cases

* **Fresh download + verify**: asserts `download_profile toy` exits 0,
  the downloaded `model.bin` exists at the expected models-dir path, its
  sha256 matches the catalog-declared value, and the per-profile evidence
  log (`${LLMCTL_VERIFY_DIR}/toy.log`) contains both a `RUN:
  _dl_verify_file` line and an `EXIT: 0` line — i.e. verification is not
  just performed but durably logged with real command/exit-code evidence.
* **Second download run skips an already-verified file**: re-running
  `download_profile toy` immediately after a successful download asserts
  the output contains `"already present and verified"` and that no
  `.part` file is left behind (confirming the download itself is atomic —
  a successful download never leaves a stray partial-download artifact).
* **A corrupted local file triggers re-download**: overwrites the already-
  downloaded `model.bin` with garbage content (`"corrupted\n"`), re-runs
  `download_profile toy`, and asserts: exit 0 (recovery succeeds); the
  output contains `"failed verification - re-downloading"` (corruption
  was detected *before* the re-download, not silently ignored); the
  final file's sha256 is correct again after the repair.
* **Catalog sha256 mismatch is a hard failure**: builds a catalog entry
  with a deliberately wrong sha256 (`BAD_SHA`, all zeros), removes any
  existing download, and asserts `download_profile toy` exits **1**, its
  output contains `"sha256 mismatch"`, and — critically — the mismatched
  downloaded content is **never renamed into its final path** (i.e. the
  atomic-rename-after-verification invariant holds even on failure: a
  bad download never silently overwrites/creates the profile's canonical
  model file).
* **`verify_profile` on an already-good, already-downloaded file**:
  restores a correct catalog, ensures a clean download exists, and asserts
  `verify_profile toy` exits 0 with output containing `"passed checksum
  verification"`.

## Internal behaviour

1. Sources `tests/helpers.sh`, calls `test_setup_env`; sources
   `lib/common.sh`, `lib/catalog.sh`, `lib/download.sh`.
2. Builds a scratch webroot (`${TEST_TMP}/www/toy/repo/resolve/main/model.bin`)
   containing a small, clearly-fake fixture payload; computes its real
   size (`stat`) and sha256 (`llmctl_sha256`).
3. Defines a local `make_catalog <sha256>` helper writing a one-profile
   `toy` catalog JSON parameterized by that sha256 (and the fixture's
   real computed size).
4. Starts `python3 -m http.server` on port 18731 bound to `127.0.0.1`,
   serving the scratch webroot; installs an `EXIT` trap to kill it; polls
   with `curl` until it answers.
5. Exports `LLMCTL_HF_BASE` (pointing at the local server) and
   `LLMCTL_SMOKE=0`.
6. **Fresh download**: generates a catalog with the correct sha256, calls
   `download_profile toy`, asserts exit 0, file existence, correct
   sha256, and the two evidence-log substrings.
7. **Skip-when-verified**: re-calls `download_profile toy`, asserts the
   `"already present and verified"` output and the absence of a `.part`
   file.
8. **Corruption recovery**: overwrites `model.bin` with garbage, re-calls
   `download_profile toy`, asserts exit 0, the
   `"failed verification - re-downloading"` output, and the corrected
   sha256 afterward.
9. **Hard sha256-mismatch failure**: generates a catalog with a
   deliberately wrong sha256, removes the profile's model directory
   entirely, calls `download_profile toy`, asserts exit 1, the
   `"sha256 mismatch"` output, and that no `model.bin` file was created at
   the final path.
10. **`verify_profile` success path**: regenerates the correct-sha256
    catalog, removes and re-downloads the profile cleanly, then calls
    `verify_profile toy` and asserts exit 0 and the
    `"passed checksum verification"` output.
11. Calls `test_finish`.

## Related scripts

* Exercises `lib/download.sh`'s `download_profile` and `verify_profile`
  functions directly (sourced), plus `lib/common.sh`'s `llmctl_sha256`
  helper and `lib/catalog.sh` (needed transitively for catalog reads).
* Sources `tests/helpers.sh` for `test_setup_env`/`test_finish`/assertion
  helpers.
* Discovered and run by `tests/run_tests.sh`.
* Sibling test `tests/test_download_resume.sh` (documented in this same
  set) covers the resume-specific behavior (partial `.part` files,
  `Range`-request handling, safe fallback for non-Range servers) layered
  on top of the base contract this file tests; it uses a different
  fixture (`tests/fixtures/range_server.py`) precisely because this file's
  plain `python3 -m http.server` fixture does not honor `Range` requests
  at all.
* Sibling test `tests/test_catalog_json.sh` (documented in this same set)
  validates the real, production `models/catalog.json` structurally; this
  test instead always builds its own throwaway single-profile catalog via
  a local `make_catalog` helper.

## Last verified date

2026-09-17
