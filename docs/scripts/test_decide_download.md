## Overview

`tests/test_decide_download.sh` proves the capability-based dispatch in
`lib/download.sh`: a profile whose capability contains `decide` must route
its post-download validation through `_dl_smoke_test_decision`, **never**
through `_dl_smoke_test_gguf` — with the per-profile evidence log as
proof. It mirrors `tests/test_download.sh` exactly: a synthetic
single-profile catalog (`toy-decide`, capability `["decide"]`) pointing at
a local `python3 -m http.server` fixture, zero network access to the real
Hugging Face CDN. Captured 2026-10-07: **19 passing host-independent assertions, RESULT:
PASS**. Two sections are bracketed with `hostdep_begin`/`hostdep_end`
(section 2: a branch on whether a real llama-server is built; section 3: runs only
when `go` is installed) and are not counted in the documented number
(`scripts/doc_counts.sh` reports them as `hostdep=N`; 8 on a host with go and no built
llama-server, 3 on a host without go and with no llama-server); this is why the figure
does not drift between hosts (G-084).

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/
  assertion helpers).
* `lib/common.sh`, `lib/catalog.sh`, `lib/decide.sh`, `lib/download.sh` —
  all sourced directly so the test can call `download_profile`,
  `llmctl_sha256`, and `_dl_llama_server_bin` in-process. `lib/decide.sh`
  is required because `_dl_smoke_test_decision` calls `decide_bin`.
* `python3 -m http.server` — serves a small synthetic fixture payload
  (`"llmctl tiny fixture decision-model payload - NOT a real GGUF\n"`,
  deliberately labeled as fake) at a Hugging-Face-shaped resolve path.
* A synthetically-generated catalog JSON file (`make_catalog` local
  function) whose single `toy-decide` profile carries capability
  `["decide"]` and the fixture's real computed size/sha256.
* `LLMCTL_HF_BASE`, `LLMCTL_CATALOG` — overridden to point at the local
  fixture server and the scratch catalog.
* `curl` — fixture readiness polling; `go` for section 3.

## Usage examples

* Standalone: `bash tests/test_decide_download.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.
* The real function-level invocations this test exercises:
  ```bash
  LLMCTL_SMOKE=0 download_profile toy-decide
  LLMCTL_SMOKE=1 download_profile toy-decide   # skip-with-reason branch
  ```

## Edge cases

* **Dispatch proof via the evidence log**: with `LLMCTL_SMOKE=0`, the
  download succeeds, the file lands with the correct sha256, and
  `${LLMCTL_VERIFY_DIR}/toy-decide.log` contains
  `decision smoke test disabled via LLMCTL_SMOKE=0` — the string only the
  decision smoke path emits — and does **not** contain
  `RUN: _dl_smoke_test_gguf` (asserted by explicit absence).
* **Skip-with-reason when llama-server is not built**: with
  `LLMCTL_SMOKE=1` and no built binary, the download still exits 0 (the
  same soft-skip precedent as `_dl_smoke_test_gguf`), the evidence log
  records `decision smoke test SKIPPED: llama-server not built`, and the
  operator-facing output warns `skipping decision smoke test`.
* **Built-llama-server branch is an honest `assert_skip`**: the toy
  payload is not a real GGUF, so launching the real llama-server against it
  would prove nothing; section 3 drives the same smoke path with a fake engine.
* **Section 3 - the smoke path through the real Go binary**: the test builds
  `llmctl-decide` and the Go fake engine (`internal/gateway/internal/fakebackends`) into a
  scratch dir, points `LLMCTL_LLAMA_SERVER` at a wrapper that starts the fake on the fixed smoke
  port, sets `LLMCTL_DECIDE_BIN`, and runs `download_profile` with `LLMCTL_SMOKE=1`: the evidence
  log must record the probes (`RUN: _dl_decision_probe_choice`), the typed `billing` answer and
  `decision smoke PASSED`. Two negatives: an engine that answers 500 (`-chat-status 500`) must FAIL the
  smoke and the download, and an unusable `LLMCTL_DECIDE_BIN` must fail with a message naming the variable
  (no silent skip). Without `go` the section is an `assert_skip`.

## Internal behaviour

1. Sources helpers + libs; builds the scratch webroot and computes the
   fixture payload's real size (`stat`) and sha256 (`llmctl_sha256`).
2. Defines `make_catalog <sha256>` writing the one-profile `toy-decide`
   catalog (engine `llama`, capability `["decide"]`, port 9998).
3. Starts `python3 -m http.server` on a free ephemeral port (N-25: no fixed port literal), exports
   `LLMCTL_HF_BASE`/`LLMCTL_CATALOG`.
4. Runs `download_profile toy-decide` with `LLMCTL_SMOKE=0` and asserts
   the decision-dispatch evidence (§1 of the test).
5. Re-runs with `LLMCTL_SMOKE=1` and asserts the SKIP-with-reason branch
   (or `assert_skip`s when a real llama-server exists) (§2).
6. Builds the binary + fake engine and asserts the smoke pass, the failing-engine and the
   unusable-binary negatives (§3), then `test_finish`.

## Related scripts

* Exercises `lib/download.sh`'s `download_profile` and its
  capability-based dispatch to `_dl_smoke_test_decision`; sources
  `lib/decide.sh` (whose `decide_bin` the decision smoke test calls to run `llmctl-decide smoke`).
* Sources `tests/helpers.sh`; discovered and run by `tests/run_tests.sh`.
* Sibling suites: `tests/test_download.sh` (the base verified-download
  contract this file mirrors), `tests/test_decide.sh` and
  `tests/test_gateway_endpoints.sh` and `tests/test_regression_defects.sh`.

## Last verified date

2026-10-06
