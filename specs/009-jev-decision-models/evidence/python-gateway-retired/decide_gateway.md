## Overview

`lib/decide_gateway.py` is the HTTP gateway behind
`llmctl decide serve`: a stdlib-only Python 3 server
(`http.server.ThreadingHTTPServer` + `urllib`, no third-party packages —
the same precedent as `tests/fixtures/range_server.py`) that exposes a
running decision profile over the Jev / TypeSafe-SDK wire shape
(`POST /v1/systemone`, `GET /v1/models`, `GET /healthz`). It is launched
by `lib/decide.sh`'s `decide_serve`, never directly by users. It is also
the **single source of truth for the decision prompt template**:
`lib/decide.sh`'s `decide_build_prompt` delegates to this file's
`--render-prompt` CLI mode, so the lettered-option template exists exactly
once. With `--backend-engine onnx` (passed automatically by
`decide_serve` from `catalog_engine <profile>`) the gateway instead
becomes a pure proxy: `POST /v1/systemone` is forwarded verbatim to the
onnx backend's native, same-shaped endpoint (a single extra loopback
hop — the documented latency cost) and the response, including its own
`usage` block, is returned unchanged; auth, the 4 MiB body bound, and
head+tail truncation still apply at the gateway. The operator-facing
endpoint reference is `docs/decide-gateway.md`.

## Prerequisites

* `python3` (already a hard llmctl dependency); no pip packages.
* A reachable backend llama-server (`--backend-host`/`--backend-port`,
  normally resolved by `decide_serve` from the profile's catalog port
  after `decide_ensure_server`).
* Environment (all optional): `LLMCTL_DECIDE_PORT` (listen port, default
  8095), `LLMCTL_BIND_HOST` (bind host, default 127.0.0.1),
  `LLMCTL_DECIDE_API_KEY` (Bearer key; `--api-key` wins),
  `LLMCTL_DECIDE_TIMEOUT` (backend timeout, default 30 s),
  `LLMCTL_DECIDE_TEMPERATURE` (calibration, default 1.0),
  `LLMCTL_DECIDE_MAX_OPTIONS` (default 20, hard cap 26),
  `LLMCTL_DECIDE_MAX_STATE_CHARS` (default 8192; `--max-state-chars`
  wins), `LLMCTL_SEED` (pinned into backend requests),
  `LLMCTL_DECIDE_BACKEND_HOST`/`LLMCTL_DECIDE_BACKEND_PORT` (backend
  overrides, used by the test seam).

## Usage examples

```sh
# Normal operation is via the CLI (see docs/decide-gateway.md):
bin/llmctl decide serve --profile decide --port 8095
bin/llmctl decide serve --stop

# Direct invocation (as tests/test_decide_gateway.sh does):
python3 lib/decide_gateway.py --port 18095 --backend-port 18777 \
    --profile decide                          # open gateway
python3 lib/decide_gateway.py --port 18096 --backend-port 18777 \
    --profile decide --api-key test-secret-key   # Bearer-auth gateway
python3 lib/decide_gateway.py --port 18097 --backend-port 18777 \
    --profile decide --max-state-chars 64        # truncating gateway

# Prompt-renderer CLI mode (the interface decide_build_prompt uses):
python3 lib/decide_gateway.py --render-prompt --type choice \
    --state "Routing." --instructions "Which team?" \
    --criteria '{"a":"desc a","b":"desc b"}'
```

## Edge cases

* **Question names are never rendered into the prompt** (Jev 1P
  semantics); only `instructions`/`criteria` reach the model. Names only
  key the `answers` map.
* **`/healthz` is auth-exempt** so probes keep working when `--api-key`
  is set; every `/v1/*` path returns 401 without a matching Bearer key.
* **Bounded request body**: `Content-Length` must be present and ≤ 4 MiB
  (`state` is separately capped at `--max-state-chars`, so 4 MiB is far
  beyond any legitimate body); anything else is a 400.
* **Head+tail truncation**: an oversized `state` keeps the first and last
  halves with a `...[state truncated to N chars]...` marker and sets the
  response header `x-llmctl-decide-truncated: true`; `0` disables the cap.
* **`usage.input_tokens` is an honest estimate** (`ceil(chars/4)` summed
  over the rendered prompts), not a tokenizer count; `output_tokens` is
  exact (one per question).
* **Error mapping**: 400 for malformed bodies/missing fields/invalid
  criteria, 401 for auth failures, 404 for unknown paths, 502 for backend
  query failures or unusable logprobs (`no option letters found ...`,
  missing `top_logprobs`).
* **`--render-prompt` mode requires `--instructions`** and exits 2 with a
  `decide: ...` message otherwise; its option-derivation error messages
  and exit code match `decide_options_json` in `lib/decide.sh` exactly.
* **Server mode requires `--profile` and `--backend-port`** (or
  `LLMCTL_DECIDE_BACKEND_PORT`); both die with rc 2 when absent.
* **The response-shaping math mirrors `decide_shape_response` in
  `lib/decide.sh` exactly** (softmax over matched letter logprobs /
  temperature; confidence `(n·p_max − 1)/(n−1)` clamped to [0,1]) — the
  file header carries a keep-in-sync note for editors.

## Internal behaviour

1. `derive_options(qtype, criteria)` — option/legend derivation identical
   to `lib/decide.sh`'s `decide_options_json` (letters A..Z in criteria
   order; `noul` is the fixed yes/no pair; caps enforced here).
2. `render_prompt(qtype, state, instructions, criteria)` — the ONE
   Pattern A prompt template (fixed header, `State:` block, `Question:`
   line, lettered options, single-letter trailer).
3. `shape_answer(qtype, raw, options, legend, temperature)` — Jev-shaped
   typed answer from a raw `/v1/chat/completions` response; raises
   `ValueError` on unusable input (mapped to 502 by the handler).
4. `class Gateway` — shared config/state: backend URLs, `backend_engine`
   (`llama` renders + shapes locally; `onnx` proxies), `/health`
   probing (≤ 5 s), `query_logprobs` (bounded `urllib` POST with optional
   pinned seed), `proxy_systemone` (the onnx-mode verbatim forward;
   failures map to 502 `onnx backend query failed: ...`),
   `truncate_state` (head+tail).
5. `make_handler(gw)` — the `BaseHTTPRequestHandler`: HTTP/1.1, JSON
   `_send`, `_authorized` Bearer check, `do_GET` (`/healthz`,
   `/v1/models` with `jev-latest`/`jev-preview`/`llmctl-<profile>`
   aliases), `do_POST` (`/v1/systemone`: validate → truncate → per-
   question derive/render/query/shape → usage estimate → optional
   truncation header).
6. `main()` — argparse; `--render-prompt` CLI mode or
   `ThreadingHTTPServer` server mode.

## Related scripts

* Launched and lifecycle-managed by `lib/decide.sh`'s `decide_serve`
  (`--port`/`--backend-host`/`--backend-port`/`--profile`/`--model-id`/
  optional `--api-key` are all assembled there).
* Serves the prompt template to `lib/decide.sh`'s `decide_build_prompt`
  via `--render-prompt`.
* Exercised by `tests/test_decide_gateway.sh` against
  `tests/fixtures/decide_server.py` (the deterministic stub backend).

## Last verified date

2026-10-06
