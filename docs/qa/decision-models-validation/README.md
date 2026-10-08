# Decision-Models Feature — Validation Evidence

> **HISTORICAL (2026-10-07).** This directory records the validation runs of the *first
> candidate* of the decision-models feature (Python gateway `lib/decide_gateway.py`, the
> `LLMCTL_ONNX_FAKE` / `LLMCTL_DECIDE_BACKEND_*` seams). That candidate was never released; the Python
> gateway and `tests/test_decide_gateway.sh` were retired and replaced by the Go gateway
> (`docs/decide-gateway.md`, `tests/test_gateway_endpoints.sh`). The evidence below is kept
> verbatim as history and no longer describes the shipped code.


**Run date (UTC):** 2026-10-06

This directory captures the full deterministic test-suite runs for the
decision-models feature (`llmctl decide`, profiles `decide-tiny` /
`decide` / `decide-pro`, `lib/decide.sh` + `lib/decide_gateway.py`),
per the project's captured-evidence contract (Constitution §11.4.5 /
§11.4.69 — real captured command output, never an absence-of-error
inference).

## Files

- `stage12-test-output.txt` — full captured output of the combined
  `make test` run (two consecutive `bash tests/run_tests.sh` passes),
  stages 1–2 of the feature: **PASS: 33  FAIL: 7** (all 7 environment-only,
  see below).
- `stage34-test-output.txt` — full captured output of the same combined
  run after stages 3–4 (interactive wizard + HTTP gateway): **PASS: 34
  FAIL: 7** (the same 7 environment-only failures; the two runs inside the
  file are identical).

The +1 PASS between the two files is `tests/test_decide_gateway.sh`
(stage 4); stages 1–2 already included `tests/test_decide.sh` and the
catalog/planner additions.

## New test suites and assertion counts

| Suite | Assertions (captured `ok:` lines, 2026-10-06, this host) | Result |
|---|---|---|
| `tests/test_decide.sh` (core path: prompt building, exact softmax/confidence shaping, full `decide_ask` against the stub backend, option caps, wizard refusal/happy/abort paths, capacity/status) | 55 | PASS |
| `tests/test_decide_gateway.sh` (`/v1/systemone`, `/v1/models`, auth matrix, truncation header, `decide serve`/`--stop` lifecycle) | 36 | PASS |
| `tests/test_decide_download.sh` (capability-based dispatch to `_dl_smoke_test_decision`, skip-with-reason branch) | 9 | PASS |

Assertion counts were captured by re-running each suite standalone on
2026-10-06 and counting `ok:` lines (`bash tests/test_decide*.sh`).
Note: the feature's design doc projected `test_decide.sh` as "43+15"
(core+interactive) — the real captured count on this host is 55; the
projection predated final assertion additions. `test_decide_gateway.sh`'s
projected 36 matches the capture exactly.

## Iteration 2 (2026-10-06): the `onnx` engine + three new profiles

Iteration 2 added the `onnx` engine (`lib/onnx_server.py`, encoder-class
decision models) and the `decide-nli` (8096) / `decide-2b` (8098) /
`decide-max` catalog profiles (the candidate port 8099 of that iteration was later moved to 8097; see CHANGELOG.md).

- `iter2-test-output.txt` — full captured output of the combined
  `make test` run after iteration 2: **PASS: 36  FAIL: 7** — the same 7
  pre-existing environment-only failures documented below (no Go
  toolchain, empty/uninitialized submodules, not a full git checkout);
  the +2 PASS over stage34 are the two new onnx suites below.

| Suite | Assertions (captured `ok:` lines, 2026-10-06, this host) | Result |
|---|---|---|
| `tests/test_onnx_server.sh` (the real `lib/onnx_server.py` end to end via the documented `LLMCTL_ONNX_FAKE=1` seam: startup errors, exact noul/choice/score math computed from the fake formula, label-order detection, auth matrix, 4 MiB body bound, truncation header, validation 400s, JSON logging) | 28 | PASS |
| `tests/test_onnx_download.sh` (toy `onnx`-engine profile through the verified download pipeline: structural validation, real runner launch + three probes under the fake seam, idempotent re-download, deps-missing SKIP-with-reason) | 21 | PASS |

Assertion counts were captured from the `ok:` lines inside
`iter2-test-output.txt` itself.

## The 7 pre-existing environment failures (all environment-only)

These fail identically on hosts without the feature's changes; none is
caused by or related to the decision-models work:

| Test | Exit | Root cause (from captured output) |
|---|---|---|
| `test_apikey_lifecycle.sh` | 1 | `ERROR: required command 'go' not found` — no Go toolchain on this host (llmctld tests) |
| `test_cluster_join_leave.sh` | 1 | same — no Go toolchain |
| `test_tenant_list_quota.sh` | 1 | same — no Go toolchain |
| `test_constitution_inheritance.sh` | 1 | `constitution/Constitution.md`, `CLAUDE.md`, `AGENTS.md` MISSING — the `constitution/` submodule is an empty, uninitialized directory in this checkout |
| `test_engine.sh` | 1 | engine submodule assertions fail — `submodules/llama.cpp` / `submodules/colibri` are empty (not initialized) |
| `test_engine_cpu_regression.sh` | 128 | git operations against the empty engine submodules fail (exit 128 = git fatal) |
| `test_setup_e2e.sh` | 1 | end-to-end setup requires building engines from the empty submodules (doctor itself reports `WARN submodule ... not initialized`) |

Summary of the environment: **no Go toolchain, empty/uninitialized git
submodules, and this workspace is not a full git checkout** — the three
root causes cover all 7 failures. Every failure's output is preserved
verbatim in the two captured files above.
