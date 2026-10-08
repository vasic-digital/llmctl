## Overview

`lib/onnx_server.py` is the **internal encoder scoring runtime** behind
llmctl's `onnx` engine (the `decide-nli` profile, an NLI/sequence-
classification ONNX export). It is deliberately minimal: a stdlib
`http.server` process that loads an ONNX encoder with `onnxruntime`
(Python-only, which is the only reason Python survives here) and scores
batches of `(premise, hypothesis)` pairs. It contains **no typed-question
logic** — `noul|choice|score`, option derivation, confidence and the public
API belong to the Go decision gateway, which calls this process over
loopback. The wire contract is
`specs/009-jev-decision-models/contracts/encoder-runtime.md`.

It is launched by `lib/scheduler.sh`'s `onnx` arm (with the python of the
hash-locked venv built by `llmctl build onnx`) and by `lib/download.sh`'s
`_dl_smoke_test_onnx`; never directly by users.

## Prerequisites

* A hash-locked private venv: `llmctl build onnx` (creates
  `$LLMCTL_DATA_DIR/venv-onnx` from `lib/lock/requirements-onnx.lock` with
  `--require-hashes --no-deps`; needs Python >= 3.11 for the lock, PyPI
  access for the build only). Without it the runtime dies at startup with a
  message pointing at `llmctl build onnx`.
* A model directory with `model.onnx` (or `onnx/model.onnx`), a tokenizer
  (`spm.model` via `sentencepiece`, or `tokenizer.json` via `tokenizers`) and
  the model's `config.json` (label order).
* A key file (mode 0600). The scheduler creates
  `$LLMCTL_STATE_DIR/keys/onnx-<profile>.key` on first real launch.

## Options and environment

| Option | Meaning |
|---|---|
| `--model-dir DIR` | required |
| `--port N` | required; binds `127.0.0.1` only (`--host` must be `127.0.0.1`) |
| `--profile NAME` | required (model name `llmctl-<profile>`) |
| `--api-key-file F` | required; 0600 file with the bearer key (never argv/env) |
| `--tokenizer NAME` | bare file name: `spm.model` (default) or `tokenizer.json` |
| `--max-tokens N` | sequence cap; else `LLMCTL_CTX_<PROFILE>`; else 512 |

Environment: `LLMCTL_ONNX_MAX_PAIRS` (64), `LLMCTL_ONNX_MAX_BODY_BYTES` (4 MiB),
`LLMCTL_ONNX_MAX_CONCURRENCY` (4), `LLMCTL_ONNX_SOCKET_TIMEOUT` (30 s),
`LLMCTL_CTX_<PROFILE>`. Non-numeric values exit 2 cleanly.
There are no test seams: tests inject stub `onnxruntime`/`sentencepiece`/
`tokenizers` modules via `PYTHONPATH` (`tests/fixtures/onnx_stubs/`).

## Usage examples

```bash
# As the scheduler launches it:
~/.local/share/llmctl/venv-onnx/bin/python lib/onnx_server.py \
  --model-dir ~/.local/share/llmctl/models/decide-nli --host 127.0.0.1 --port 8096 \
  --profile decide-nli --max-tokens 512 --tokenizer spm.model \
  --api-key-file ~/.local/state/llmctl/keys/onnx-decide-nli.key

curl -s localhost:8096/healthz                       # {"status": "ok"}
curl -s localhost:8096/readyz                        # {"status": "ready"}
curl -s -X POST localhost:8096/v1/score \
  -H "Authorization: Bearer $(cat ~/.local/state/llmctl/keys/onnx-decide-nli.key)" \
  -d '{"pairs":[{"premise":"The invoice was paid.","hypothesis":"The invoice is settled."}]}'
```

## Edge cases

* Only the premise is truncated (token level); `truncated[i]` says so. A
  hypothesis that alone exceeds `max_tokens` -> `422 hypothesis_too_long`.
* `config.json` beside `model.onnx` wins over the other location. `LABEL_n`
  only / no config -> served but flagged in `label_source` (clients must not
  assign NLI semantics). Malformed id2label -> startup error rc 1.
* A graph declaring `token_type_ids` is fed it; a graph without it is not.
* Logit count != label count, NaN/Inf logits, backend exceptions -> JSON 500,
  never a dropped connection. A failed load-time smoke -> `/readyz` 503 and
  `/v1/score` 503, `/healthz` stays 200.
* Half-sent requests are cut by the socket timeout; an error before the body
  is read closes the connection so leftover bytes are never mis-parsed.

## Internal behaviour

`Scorer` (guarded imports, tokenizer, ORT session, declared-input detection,
batched padded `session.run`, float64 softmax) behind `make_handler` (auth,
limits, JSON errors) on a `ThreadingHTTPServer` subclass; one `smoke()` at
load sets `ready`. Logs are single-line JSON on stdout and never contain
request text.

## Related scripts

* `lib/lock/requirements-onnx.lock`, `lib/engine.sh` (`engine_build_onnx`)
* `lib/scheduler.sh` (onnx launch arm), `lib/download.sh` (`_dl_smoke_test_onnx`)
* `tests/test_onnx_runtime.sh`, `tests/test_onnx_server.sh`,
  `tests/test_engine_build_onnx.sh`, `tests/test_onnx_download.sh`

## Last verified date

2026-10-07
