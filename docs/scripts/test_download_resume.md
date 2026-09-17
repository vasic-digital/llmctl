## Overview

`tests/test_download_resume.sh` proves that llmctl's model downloader
(`lib/download.sh`) genuinely **resumes** an interrupted download rather
than restarting it from scratch every time (FR-045, Clarification 15). It
covers both the primary, production-representative case — a server (like
the real Hugging Face CDN) that honors HTTP `Range` requests, giving a
genuine partial resume — and the safe-fallback case: a server that ignores
`Range` and always returns the full file from byte 0, where the downloader
must still produce a correct, uncorrupted, non-truncated final file rather
than silently splicing a partial-resume attempt onto a full response.

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/assertion
  helpers).
* `lib/common.sh`, `lib/catalog.sh`, `lib/download.sh` — all three sourced
  directly so the test can call `download_profile` and `llmctl_sha256` as
  in-process functions.
* `LLMCTL_SMOKE=0` — disables the downloader's post-download smoke-test
  step (which would otherwise try to boot a real `llama-server`); not
  meaningful in this sandboxed test environment.
* `python3` — used to run `tests/fixtures/range_server.py` (a small custom
  HTTP server fixture that deliberately supports `Range` requests and logs
  every request it receives) and, in the second scenario, the stock
  `python3 -m http.server` module (which does **not** honor `Range`
  requests, serving as the "server without Range support" case).
* `curl` — used both as the readiness-probe polling mechanism for each
  spun-up local HTTP server and, indirectly, as the download client
  `lib/download.sh` itself uses.
* A synthetically-generated catalog JSON file (`make_catalog` local
  function in this test), pointing a `toy` profile's single file entry at
  the locally-served fixture payload with its real computed size and
  sha256 — never the real `models/catalog.json`.
* `LLMCTL_HF_BASE` — overridden per-scenario to point at
  `http://127.0.0.1:<port>` (the locally spun-up fixture server) instead
  of the real Hugging Face CDN.
* `LLMCTL_CATALOG` — overridden to point at the scratch catalog file this
  test generates.
* `head -c`, `base64` — used to synthesize the ~5000-byte random test
  payload.

## Usage examples

* Standalone: `bash tests/test_download_resume.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.
* The real function-level invocation this test exercises (after sourcing
  the three `lib/*.sh` files and pointing `LLMCTL_HF_BASE`/`LLMCTL_CATALOG`
  at the local fixture):
  ```bash
  download_profile toy
  ```

## Edge cases

* **Genuine resume against a Range-capable server**: simulates a prior
  download that was killed partway through by pre-placing a
  `model.bin.part` file containing exactly the first 2000 of 5000 bytes.
  Asserts `download_profile toy` succeeds (exit 0), the resumed file's
  sha256 matches the full expected payload, no `.part` file is left
  behind, and — the decisive proof of genuine resume rather than a
  from-scratch refetch that merely happens to produce the right final
  bytes — the fixture server's request log actually recorded a `Range:
  bytes=2000-` header, i.e. the downloader genuinely requested only the
  missing tail.
* **Safe fallback when the server does not support `Range`**: repeats the
  same "killed at byte 2000 of 5000" setup against a plain
  `python3 -m http.server` (which always serves the full file from byte
  0, ignoring any `Range` header the client sends), and asserts
  `download_profile toy` still succeeds, still produces a file whose
  sha256 matches the full expected payload, and still leaves no `.part`
  file behind — i.e. the downloader must not corrupt or truncate the
  final file when its resume attempt is silently ignored by the server;
  it must detect this and fall back to treating the response as a full
  re-download.
* **Fixture-server cleanup on early exit**: both server-spawning blocks
  install a `trap 'kill ${PID} 2>/dev/null || true' EXIT` immediately
  after backgrounding the server process, then explicitly `kill` it and
  `trap - EXIT` once that scenario's assertions complete — ensuring
  neither locally-spawned HTTP server process (nor its listening port)
  survives the test even if an assertion fails partway through.

## Internal behaviour

1. Sources `tests/helpers.sh`, calls `test_setup_env`; sources
   `lib/common.sh`, `lib/catalog.sh`, `lib/download.sh`.
2. Exports `LLMCTL_SMOKE=0`.
3. Defines a local `make_catalog <size> <sha256>` helper that writes a
   minimal one-profile (`toy`) catalog JSON to `${TEST_TMP}` and echoes
   its path.
4. **Scenario 1 (Range-capable server)**:
   * Builds a ~5000-byte random payload under
     `${TEST_TMP}/www1/toy/repo/resolve/main/model.bin`, computes its real
     size and sha256.
   * Starts `tests/fixtures/range_server.py` on port 18921 serving that
     exact file at the expected Hugging-Face-shaped resolve path, logging
     every request to `${TEST_TMP}/reqlog.txt`; polls it with `curl` in a
     retry loop until it answers, then discards the readiness-probe's own
     log line.
   * Points `LLMCTL_HF_BASE` at the fixture server and `LLMCTL_CATALOG` at
     a freshly generated catalog describing the full expected size/sha256.
   * Pre-places a 2000-byte `model.bin.part` (simulating an interrupted
     prior download), then calls `download_profile toy` and asserts:
     exit 0; final sha256 matches; no leftover `.part` file; the request
     log contains a `bytes=2000-` Range header.
   * Kills the fixture server and clears the `EXIT` trap.
5. **Scenario 2 (non-Range-capable server)**:
   * Copies the same payload to a second webroot (`www2`).
   * Starts a stock `python3 -m http.server` on port 18922, waits for
     readiness via `curl`.
   * Points `LLMCTL_HF_BASE` at this second server; removes any leftover
     `model.bin`/`model.bin.part` from scenario 1, then pre-places a fresh
     2000-byte `model.bin.part`.
   * Calls `download_profile toy` and asserts: exit 0; final sha256
     matches the full payload; no leftover `.part` file (i.e. the fallback
     path produced a correct, non-corrupted, non-truncated file even
     though the server ignored the resume attempt entirely).
   * Kills the second fixture server and clears the `EXIT` trap.
6. Calls `test_finish`.

## Related scripts

* Exercises `lib/download.sh`'s `download_profile` function directly
  (sourced), plus `lib/common.sh`'s `llmctl_sha256` helper and
  `lib/catalog.sh` (needed transitively by `download_profile` to read
  catalog profile entries).
* Uses `tests/fixtures/range_server.py`, a custom Python HTTP-server
  fixture that specifically honors `Range` requests and logs every
  request it serves (distinct from the stock `python3 -m http.server`
  used both here for the non-Range scenario and in
  `tests/test_download.sh`).
* Sources `tests/helpers.sh` for `test_setup_env`/`test_finish`/assertion
  helpers.
* Discovered and run by `tests/run_tests.sh`.
* Sibling test `tests/test_download.sh` (documented in this same set)
  covers the downloader's core verified-download contract (checksum
  verification, skip-when-already-verified, corruption re-download,
  hard-failure on catalog sha256 mismatch, evidence logging) against a
  plain, non-resuming `python3 -m http.server` fixture; this test is
  specifically about the *resume* behavior layered on top of that
  contract.

## Last verified date

2026-09-17
