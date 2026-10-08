## Overview

`tests/test_onnx_runtime.sh` starts 14 real instances of the internal encoder
runtime (`lib/onnx_server.py`) on ephemeral loopback ports, each with a
different stub model spec, and drives them over real sockets with
`tests/fixtures/onnx_rt_contract.py` (60+ checks): `/healthz` body, `/readyz`
ready/not_ready, bearer auth (env key ignored), label order from the pinned
`config.json` (permuted order, `onnx/` vs root precedence, `LABEL_n` and
missing-config flags), exactly-declared graph inputs (`token_type_ids` only
when declared), premise-only truncation on both the SentencePiece and
`tokenizers` paths (hypothesis and special tokens survive, `truncated` per
pair, 422 when the hypothesis alone is too long), ctx from
`LLMCTL_CTX_<PROFILE>`, JSON 4xx/5xx for every failure (wrong logits count,
NaN, backend exception, bad bodies, limits, chunked), keep-alive correctness
after errors, socket timeout on half-sent requests, and 16 concurrent
requests. It also checks the process: key not in argv/environ, listener on
127.0.0.1 only, request text never logged, no `.pyc` litter, no `FAKE`/
`BACKEND_*` seam and no typed-question code in the runtime, and
`hmac.compare_digest` use via an in-process spy.

## Prerequisites

`bash`, `curl`, `python3` with `numpy` (otherwise a printed SKIP). Only the
model backends are stubs (`tests/fixtures/onnx_stubs/`: `onnxruntime`,
`sentencepiece`, `tokenizers`, shaped by a JSON spec in `model.onnx`).

## Usage examples

`bash tests/test_onnx_runtime.sh`

## Edge cases

The stub "nli" logits are `contradiction` iff the hypothesis segment contains
the `not` token id; this is a wiring oracle, not a semantic one. Real
onnxruntime 1.30.0 + real `tokenizers` were exercised separately (see the
task report), not by this hermetic test.

## Internal behaviour

Bash creates model dirs/specs and servers, writes `ports.json`, then runs the
python driver (prints `ok:`/`FAIL:` lines counted by the bash harness).

## Related scripts

`lib/onnx_server.py`, `tests/test_onnx_server.sh`, `tests/fixtures/onnx_rt_contract.py`.

## Last verified date

2026-10-07
