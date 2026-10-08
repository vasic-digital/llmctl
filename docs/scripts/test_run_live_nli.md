## Overview

`tests/test_run_live_nli.sh` guards the live encoder runner `specs/009-jev-decision-models/evidence/realcheck/run_live_nli.sh`. On the first real-model run (2026-10-08, D-06) the runner obtained the gateway access key with `llmctl decide key export`, which is the startup-file installer: it needs `--file` and prints no key, so the key file came out empty and the run stopped with "no access key could be exported". The suite proves the runner's `acquire_access_key` now writes exactly the real key. Measured with `scripts/doc_counts.sh --check run_live_nli`: **9 passing assertions** (no failures, no skips).

## Prerequisites

* `tests/helpers.sh`, the Go toolchain (the suite builds `cmd/llmctl-decide` into a temp dir; without `go` it prints `SKIP-SUITE`). No network, no models, no running gateway.

## Usage

* Standalone: `bash tests/test_run_live_nli.sh`; also run by `make test`.
* Check the documented count: `bash scripts/doc_counts.sh --check run_live_nli`.

## What it proves

* With a key created by the real `llmctl decide key rotate` in a temp `LLMCTL_HOME`, `acquire_access_key` (sourced from the runner with `RUN_LIVE_NLI_LIB_ONLY=1`) exits 0 and writes a non-empty, mode-0600 file whose bytes equal `llmctl decide key show --yes-print` (compared with `cmp`; the key is never printed).
* The runner calls `live_checks.py` from its own directory (the old `specs-realcheck/` path did not exist in the tree).

## RED

Against the pre-fix runner body (`key export`) the suite failed 3 assertions: the key file was empty, it did not match the real key, and the `live_checks.py` path was stale.

## What it does NOT prove

* The rest of the live run (runtime start, gateway, golden): that needs the real model and is run by hand on a host that has it.

## Related

[test_keyring_go_cli](test_keyring_go_cli.md), [run_tests](run_tests.md).
