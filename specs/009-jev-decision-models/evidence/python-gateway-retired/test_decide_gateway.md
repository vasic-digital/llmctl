## Overview

`tests/test_decide_gateway.sh` proves the HTTP gateway contract of
`lib/decide_gateway.py` plus the `decide serve` / `--stop` pidfile
lifecycle in `lib/decide.sh`: `POST /v1/systemone` with a
TypeSafe-SDK-shaped body (question names never reach the model),
`/v1/models` aliases, `/healthz`, Bearer auth (401 on absent/wrong key,
`/healthz` auth-exempt), the head+tail state-truncation header, and
daemonized serve/stop including the not-running and dry-run paths. The
backend is the deterministic `tests/fixtures/decide_server.py` stub — the
real HTTP/JSON parse path executes; only the model is stubbed. All
servers run on ephemeral ports. Captured 2026-10-06: **36 passing
assertions, RESULT: PASS**.

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/
  assertion helpers).
* `lib/common.sh`, `lib/os_detect.sh`, `lib/hardware.sh`,
  `lib/catalog.sh`, `lib/decide.sh`, `lib/scheduler.sh` — sourced
  directly so the test can call `decide_serve` in-process.
* `python3` — runs the gateway (`lib/decide_gateway.py`) and the fixture
  backend (`tests/fixtures/decide_server.py`); a local `free_port`
  helper binds port 0 to allocate ephemeral ports.
* `curl` — every HTTP assertion (`-fsS` for bodies, `-s -w '%{http_code}'`
  for status codes, `-D -` for response headers).

## Usage examples

* Standalone: `bash tests/test_decide_gateway.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.
* The real invocations this test exercises:
  ```bash
  python3 lib/decide_gateway.py --port "${GW_PORT}" --backend-port "${BACKEND_PORT}" --profile decide
  python3 lib/decide_gateway.py ... --api-key test-secret-key
  python3 lib/decide_gateway.py ... --max-state-chars 64
  curl -X POST "http://127.0.0.1:${GW_PORT}/v1/systemone" -d "${BODY}"
  LLMCTL_DECIDE_BACKEND_PORT="${BACKEND_PORT}" decide_serve --profile decide --port "${SERVE_PORT}"
  decide_serve --stop
  ```

## Edge cases

* **TypeSafe-SDK wire shape**: `{model, state, questions:{name:{type,
  instructions, criteria}}}` in; `answers.team.choice == "billing"`,
  probabilities keyed by criteria keys, `confidence` present, `model`
  echoing the requested alias, `usage.input_tokens > 0` and
  `output_tokens == 1` per question (2 for a two-question body).
* **Mixed question types in one request**: a `noul` and a `score`
  question in the same body both get correctly shaped typed answers,
  with the score legend preserved.
* **`/v1/models` aliases**: `jev-latest`, `jev-preview`, and
  `llmctl-decide` (`llmctl-<profile>`) all listed.
* **Auth matrix**: absent Bearer → 401; wrong Bearer → 401; correct
  Bearer → 200; `/v1/models` also requires the key; `/healthz` stays 200
  without one (auth-exempt probe path).
* **Truncation header**: an oversized `state` against a
  `--max-state-chars 64` gateway sets `x-llmctl-decide-truncated: true`;
  the same body against the uncapped gateway sets no such header.
* **Serve lifecycle**: daemonized `decide_serve` writes the pidfile, the
  process is alive, `/healthz` answers, and a real `systemone` request
  through the served gateway returns `billing`; `--stop` exits 0, the
  process is gone, the pidfile is removed.
* **Honest not-running/dry-run paths**: a second `--stop` with no
  pidfile exits 1 with `no gateway pidfile`; `LLMCTL_DRY_RUN=1
  decide_serve` prints `DRY-RUN: python3` and writes no pidfile.
* **Cleanup is trap-based**: an `EXIT` trap kills all four fixture
  processes and best-effort stops the served gateway, so a failing
  assertion never leaks servers.

## Internal behaviour

1. Sources helpers + libs; starts one fixture backend plus three gateway
   instances (plain, `--api-key`, `--max-state-chars 64`) on ephemeral
   ports; waits for `/healthz` 200 on all three.
2. Asserts the `systemone` choice round-trip (§1), a mixed noul+score
   body (§2), and `/v1/models` aliases (§3).
3. Asserts the five-entry auth matrix (§4).
4. Asserts the truncation header presence/absence pair (§5).
5. Asserts the full `decide_serve`/`--stop`/not-running/dry-run
   lifecycle via the `LLMCTL_DECIDE_BACKEND_PORT` seam (§6), then
   `test_finish`.

## Related scripts

* Exercises `lib/decide_gateway.py` (all three endpoints + auth +
  truncation) and `lib/decide.sh`'s `decide_serve`.
* Uses `tests/fixtures/decide_server.py` as the backend stub.
* Sources `tests/helpers.sh`; discovered and run by `tests/run_tests.sh`.
* Sibling suites: `tests/test_decide.sh` (core path + wizard) and
  `tests/test_decide_download.sh` (download dispatch) — documented in
  this same set.

## Last verified date

2026-10-06
