## Overview

`tests/test_onnx_server.sh` covers the startup, argument and secret-handling
contract of the internal encoder scoring runtime (`lib/onnx_server.py`,
documented in `docs/scripts/onnx_server.md`): required options and exit
codes, the key-file rules (0600, non-empty, never argv/env), loopback-only
binding, bare `--tokenizer`, clean errors for bad env values and missing
deps, and refusal to guess a malformed label order. The wire contract
(`/v1/score`, `/healthz`, `/readyz`) is covered by `tests/test_onnx_runtime.sh`.
Typed-question assertions (noul/choice/score over `/v1/systemone`) and the
(historical) `LLMCTL_ONNX_FAKE` seam were removed with the old runtime; that logic now
belongs to the Go gateway.

## Prerequisites

* `bash`, `python3`, and `numpy` is NOT required for these startup checks.
  Stub backends come from `tests/fixtures/onnx_stubs` via `PYTHONPATH`.

## Usage examples

* `bash tests/test_onnx_server.sh`

## Edge cases

* `--api-key <value>` is rejected (argparse abbreviation is disabled so it
  cannot silently match `--api-key-file`).
* `LLMCTL_BIND_HOST`, `LLMCTL_DECIDE_API_KEY` (a retired variable, kept here only as a negative check), `LLMCTL_API_KEY` have no effect on the runtime.

## Internal behaviour

Runs the real script with `python3 -B` and asserts exit status + message for
each refusal; no server is bound (every case exits before listening).

## Related scripts

`lib/onnx_server.py`, `tests/test_onnx_runtime.sh`, `tests/fixtures/onnx_stubs/`.

## Last verified date

2026-10-07
