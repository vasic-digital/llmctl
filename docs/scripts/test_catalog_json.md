## Overview

`tests/test_catalog_json.sh` validates the project's canonical model catalog
(`models/catalog.json`) — the single source of truth every other llmctl
subsystem (planner, scheduler, downloader) reads to know which profiles
exist, which port each one binds, which engine builds it, and which
checksums its files must match. This test exists because a malformed or
internally-inconsistent catalog (a duplicate port, a missing required
field, a null checksum on a GGUF file) would silently corrupt every
downstream command's behavior; catching those defects here, against the
real production catalog file, is cheaper and more deterministic than
discovering them at `llmctl models download` time.

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/assertion
  helpers).
* `python3` with the standard-library `json` module (no external Python
  dependencies) — used both for a bare JSON-parse check and for two
  in-line Python scripts (via heredocs) that perform structural
  cross-checks.
* Reads `models/catalog.json` (`${LLMCTL_ROOT}/models/catalog.json`) — the
  real, committed production catalog, not a fixture copy.
* No environment variables specific to this test are read; `test_setup_env`
  is called for harness-convention isolation, but this test never touches
  `LLMCTL_MODELS_DIR`/`LLMCTL_STATE_DIR`/etc. — it is a pure static-data
  validation script.

## Usage examples

* Standalone: `bash tests/test_catalog_json.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate` (also related to the project's
  separate `json-check` Makefile target, which likewise validates catalog
  JSON validity as part of `make validate`).

## Edge cases

* **Catalog is not valid JSON at all**: step 1 runs `python3 -c
  'import json,sys; json.load(open(sys.argv[1]))'` against the catalog
  path and asserts exit code 0 — a syntax error in `catalog.json` fails
  here immediately, before any structural check runs.
* **A profile is missing a required field**: the cross-check script
  iterates every profile and asserts each has `engine`, `port`,
  `capability`, `min_tier`, `hf_repo`, and `files`.
* **A profile declares an unknown `engine` value**: asserted to be exactly
  `"llama"` or `"colibri"` — any other value is an error.
* **A profile declares an unknown `min_tier` value**: asserted to be one of
  `"baseline"`, `"workstation"`, `"datacenter"` (note: `"below-minimum"` is
  a tier the *planner* can classify a host into, but it is never a valid
  `min_tier` value a *profile* declares in the catalog).
* **Two profiles claim the same port**: a `ports` dict keyed by port number
  is built incrementally; a duplicate port triggers an explicit
  `"duplicate port ... (also ...)"` error naming both profiles.
* **A profile has an empty `files` list**: flagged explicitly.
* **A file entry is missing `name` or `size`**: flagged per-file.
* **A file's `sha256` field is present but malformed** (not a 64-character
  string): flagged — this is distinct from a `sha256` that is legitimately
  `null` (a per-file placeholder the download layer resolves live).
* **The top-level `ports` table (an advertised summary map, separate from
  each profile's own `port` field) disagrees with a profile's real `port`
  value**: flagged as a `"ports table mismatch"`.
* **A known/expected profile is entirely missing from the catalog**: the
  script hardcodes the expected 10-profile set (`fast`, `coder`, `vision`,
  `vision-pro`, `moe-fast`, `small`, `ws-dense-32b`, `ws-moe-30b`,
  `colibri-glm`, `colibri-qwen36`) and reports any set difference as
  `"missing profiles: ..."`.
* **A `.gguf` file entry has a null/missing `sha256`**: step 3 is a
  dedicated, separate check enforcing the project's verified-download
  contract — every GGUF file (as opposed to, say, a colibri weight shard)
  must carry a real (non-null) sha256, since GGUF profiles are the ones
  smoke-tested and verified end-to-end per the README's safety guarantees.

## Internal behaviour

1. Sources `tests/helpers.sh`, calls `test_setup_env`.
2. Sets `CATALOG` to `${LLMCTL_ROOT}/models/catalog.json`.
3. **Step 1 — bare JSON validity**: runs `python3 -c 'import json,sys;
   json.load(open(sys.argv[1]))' "${CATALOG}"`, captures its real exit
   code, asserts it is 0.
4. **Step 2 — structural cross-checks**: feeds a Python heredoc script the
   catalog path; the script loads the JSON, iterates every entry in
   `d["profiles"]`, accumulates an `errors` list for every violation
   described above (missing fields, bad `engine`/`min_tier` values,
   duplicate ports, empty/malformed file entries, ports-table mismatch,
   missing expected profiles), prints each error line-by-line as
   `ERROR: ...`, prints a final `profiles: <n>` summary line, and exits 1
   if `errors` is non-empty (else 0). The test captures this script's
   output and real exit code, prints the output for visibility, and
   asserts exit code 0.
5. **Step 3 — GGUF sha256 completeness**: a second Python heredoc iterates
   every profile's `files` list, collects any entry whose `name` ends in
   `.gguf` and whose `sha256` is falsy, prints each as `NULL sha256: ...`,
   and exits 1 if any were found. The test asserts exit code 0.
6. Calls `test_finish`.

## Related scripts

* Validates `models/catalog.json`, the single data file every catalog-aware
  library (`lib/catalog.sh`, `lib/download.sh`, `lib/scheduler.sh`) reads.
* Sources `tests/helpers.sh` for `test_setup_env`/`test_finish`/assertion
  helpers, though (unlike most other test files in this suite) it never
  needs the isolated `LLMCTL_*_DIR` environment it sets up, since it does
  not exercise any code path that writes state.
* Discovered and run by `tests/run_tests.sh`.
* Complements `tests/test_download.sh` and `tests/test_download_resume.sh`
  (sibling docs in this set), which exercise the *download* code path that
  consumes catalog entries like the ones this test validates structurally.
* Complements `make json-check` (a Makefile target validating catalog JSON
  as part of `make validate`, alongside `lint` and `test`).

## Last verified date

2026-09-17
