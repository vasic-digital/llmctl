# Contract: internal encoder scoring runtime (`lib/onnx_server.py`)

| Field | Value |
|---|---|
| Status | normative for the Python runtime; the Go gateway (`internal/server`) is the only intended client |
| Scope | INTERNAL. Not a public API. No typed-question logic (noul/choice/score live in Go). |
| Why Python at all | `onnxruntime` is Python-only; this process exists to run it and nothing else |
| Python | >= 3.9 for the script; the hash-locked venv (`lib/lock/requirements-onnx.lock`) needs >= 3.11 |
| Last verified | 2026-10-07 (`tests/test_onnx_runtime.sh`, `tests/test_onnx_server.sh`, real onnxruntime 1.30.0 smoke) |

## Transport and security

* Binds **only** `127.0.0.1` (any other `--host` is refused; no env override).
* Every `/v1/*` call needs `Authorization: Bearer <key>`. The per-profile key is
  read from `--api-key-file` (mode 0600, otherwise the runtime refuses to start);
  it is never accepted on argv or from the environment. Compared with
  `hmac.compare_digest`. The scheduler creates
  `$LLMCTL_STATE_DIR/keys/onnx-<profile>.key` (0600) on first real launch; rotate
  by deleting it and restarting. The Go gateway reads the same file.
* `GET /healthz` (unauthenticated) -> `200 {"status":"ok"}` exactly. No profile name, no backend call.
* `GET /readyz` (unauthenticated) -> `200 {"status":"ready"}` or `503 {"status":"not_ready"}`.
  Readiness is the result of **one real 1-pair inference run at load**; a runtime whose
  smoke failed stays up (liveness) but answers `/v1/score` with `503 not_ready`.
* HTTP/1.1 keep-alive; per-connection socket timeout (`LLMCTL_ONNX_SOCKET_TIMEOUT`,
  default 30 s); threaded with a bounded semaphore (`LLMCTL_ONNX_MAX_CONCURRENCY`,
  default 4; `503 busy` after 5 s). Errors raised before the body is read close the
  connection (`Connection: close`); errors after a fully read body keep it open.

## `POST /v1/score`

Request (`Content-Length` required, chunked refused with 411, body cap
`LLMCTL_ONNX_MAX_BODY_BYTES` default 4 MiB checked before reading -> 413):

```json
{"pairs": [{"premise": "…", "hypothesis": "…"}, …]}
```

`pairs`: non-empty array, at most `LLMCTL_ONNX_MAX_PAIRS` (default 64, else 413);
`premise` and `hypothesis` non-empty strings. The body must be a JSON object (else 400).

Response `200`:

```json
{"labels": ["entailment","neutral","contradiction"],
 "label_source": "config:onnx/config.json",
 "scores": [[0.91,0.06,0.03], …],
 "truncated": [false, …],
 "model": "llmctl-<profile>",
 "max_tokens": 512}
```

* `labels` are in the model's **id2label order**, read from the `config.json` that sits
  beside the resolved `model.onnx` (falling back to the other of `<dir>/config.json`,
  `<dir>/onnx/config.json`). `scores[i][j]` is the float64 softmax probability of
  `labels[j]` for pair `i`.
* `label_source` is `config:<relpath>`, or flagged: `generic-config:<relpath> (LABEL_n …)`
  when id2label only holds `LABEL_n` names, or `none (…)` when no id2label exists (labels are
  then `LABEL_0..n-1` by logits count). **A client must not map `generic-config`/`none`
  to entailment/contradiction semantics.** A binary head answers `labels` =
  `["entailment","not_entailment"]` (the pinned decide-nli model does; live 2026-10-08); the client
  uses P(entailment) and must not split `not_entailment` into neutral/contradiction. A malformed id2label (non-integer or
  non-contiguous ids) is a startup error, never a guess.
* **Truncation is premise-only**, at token level, so the hypothesis and the special tokens
  always survive: SentencePiece path `[CLS] p[:budget] [SEP] h [SEP]`; `tokenizer.json`
  path uses the library's `only_first` truncation. `truncated[i]` reports it per pair.
  If the hypothesis alone cannot fit `max_tokens`: `422 hypothesis_too_long`.
* `max_tokens`: `--max-tokens`, else `LLMCTL_CTX_<PROFILE>`, else 512 (the scheduler passes the
  profile ctx as `--max-tokens`).
* The graph is fed exactly the inputs it declares among `input_ids`, `attention_mask`,
  `token_type_ids`; a graph needing any other input is a startup error.
* logits width must equal the label count and every logit must be finite, otherwise
  `500 label_count_mismatch` / `500 non_finite_logits`. `NaN`/`Inf` are never serialised.

Errors are always JSON `{"error": "<code>", "message": "…"}` with an HTTP status:
400 `bad_request`, 401 `unauthorized`, 404 `not_found`, 405 `method_not_allowed`,
408 `request_timeout`, 411 `length_required`, 413 `body_too_large`/`too_many_pairs`,
422 `hypothesis_too_long`, 500 `inference_failed`/`label_count_mismatch`/`non_finite_logits`/
`internal_error`, 503 `not_ready`/`busy`. The connection is never dropped without a response.

## Removed from the previous runtime (now Go's job or deleted)

`/v1/systemone`, `/v1/models`, `/health` (profile-leaking), typed-question derivation
(`noul|choice|score`), `LLMCTL_ONNX_FAKE`, `LLMCTL_DECIDE_API_KEY`, `LLMCTL_BIND_HOST`,
`--api-key`, `--max-state-chars`, head+tail state truncation, usage estimates.

## Provisioning

`llmctl build onnx` creates `$LLMCTL_DATA_DIR/venv-onnx` from `lib/lock/requirements-onnx.lock`
with `pip install --require-hashes --no-deps --only-binary=:all:` (or the equivalent `uv pip`
when python3-venv is unavailable). A lock marked `UNPINNED` or without hashes is refused.
The scheduler launches the runtime with that venv's python.
