# 009 — Disposition of the NEW-IN-JEV files (second team's llmctl copy)

**Created**: 2026-10-07 | **Status**: Draft input to planning | **Scope**: every NEW-IN-JEV, non-GENERATED file of
`/home/milosvasic/Projects/jev/llmctl/llmctl` (candidate tree) per `jev-llmctl-inventory.tsv`.
**Companion files**: [`../spec.md`](../spec.md), [`../source-findings.md`](../source-findings.md) (D-/I- ids), `jev-llmctl-inventory.tsv`.

**Method / provenance.** Every file below was read in full (all lines) in this session. Statements are CONFIRMED when the code/text was
read, and CONFIRMED-RUNTIME when additionally reproduced by a throw-away run (scratch dir only; the candidate tree was not modified,
`PYTHONDONTWRITEBYTECODE=1`; host Python 3.14.4; `shellcheck` is NOT installed here, so no lint result is claimed; `bash -n` and
`ast.parse` passed on all code files). INFERRED = deduced, not observed. Nothing here was run against a real model (none is installed).
Where the real repo (HEAD `a9ebefe`, VERSION 3.0.2) was consulted that is stated. New defects use ids **N-nn** (D-nn are from
`source-findings.md`). No credentials appear anywhere.

Vocabulary: the wire type string for the yes/no question is literally `"noul"` (spec says "yes/no"); the CLI flag is `--type noul`.

---

## 0. Inventory: lines and full sha256 (candidate tree, 2026-10-07)

| File | Lines | sha256 |
|---|---:|---|
| lib/decide.sh | 952 | 89a0899775da28b1148f24cf8db161580de1b6afa28325d8c29cfebbb9d17d48 |
| lib/decide_gateway.py | 460 | 2fa40694616479d331df4a22db60ed548db3680819a9011e0ad603fb0c6955ed |
| lib/onnx_server.py | 542 | 81595e3afcaf8cbb2b37dbb54389d16cc7490fb95bd2810f688fe0cac39f1b8a |
| tests/fixtures/decide_server.py | 89 | 84598c732674703e20b2f54ab74fb20137211b1eaa13661b9020229af57b29d3 |
| tests/fixtures/onnx_decide_server.py | 107 | 8b07aebd3585002c3d2743e6e97e6fee453d7f4392a768c23535f00f21b7bfed |
| tests/test_decide.sh | 346 | e54ba6a20e71d07a06b7b23f402caa02cf2d5238590887c0091d719243098636 |
| tests/test_decide_download.sh | 95 | 8aee5d6d190d7ddcee4eb45cab2a625ce1abca831b9c3098d8842088efdfcf4a |
| tests/test_decide_gateway.sh | 238 | 4e694f4be48e9b678667aac2f566345becd5c92472ebc3f7b64acaa88d72c1df |
| tests/test_onnx_download.sh | 112 | 21d80ba7a97c3caf4944696778c0a757514ab3e33b5cbe7b152b5447060aca10 |
| tests/test_onnx_server.sh | 225 | fc24b5d37ad88ffbc3eaec0a9cf6e8294a869d3d5d00ff5da868c0685f1f812e |
| docs/decision-models.md | 310 | 31e91a638ef5bf0eebd2fecf363245452306f994aa7688058bdf51b7288d3636 |
| docs/decide-gateway.md | 194 | daf7de3bca6577f2f427877e2adb049b4591b295d7da5762ff36f4dbb1766a3b |
| docs/scripts/decide.md | 185 | 62a114e3205a2be2ac28f2490abeaf76af9f9efb5fd6c4f04b8b28f766a5f44d |
| docs/scripts/decide_gateway.md | 128 | 54aa063b769b7ccb4f2f061a9a5d52b4ef7bc3799cd9cdd6fdc5faf6c1ca3804 |
| docs/scripts/onnx_server.md | 146 | 82ab1290d30ea14a9ddd230fc27c8664a9e946718658a9a216a7b04c9c79962c |
| docs/scripts/test_decide.md | 117 | f339dafcf296194434954605d5d8477cacf4c57cc22cefe11dd6278a7c98634d |
| docs/scripts/test_decide_download.md | 88 | 946e91caf11d7bfc5f63918ab6e0307fe86ea7cd047cde4f42bce3ac11a3612a |
| docs/scripts/test_decide_gateway.md | 97 | 42d1664c52a42c3317e33f91656a294d95aab1c8dbc785810d980ac1011cc93d |
| docs/scripts/test_onnx_download.md | 95 | b2ac401159734c5d436edf08b23d759413dcccd36f7b31ec892a4841e67813c0 |
| docs/scripts/test_onnx_server.md | 83 | fbb1de519e37ff32066b299c63a00ad2be2b1bcf59fd191d8fc59cb9f7925891 |
| docs/research/README.md | 18 | 1f6f4b75480ccc5969efc4d08cef27a3f5764fbe9dc2f2c3df1a592faccee966 |
| docs/research/decision-model-hashes.md | 182 | 9728332bd81699b99bb357ce3ae137c57ddd81a9b04facf967fa0e19dd3f9051 |
| docs/research/encoder-model-hashes.md | 523 | 25230f4e756a5c929586c15033e1f8cadd7e4863e1402f53b8e38744bfb183bd |
| docs/research/jev-ecosystem.md | 220 | f1d72caff9e6ab4e54fc715906dc7a1679b9b8176235236bcd2c8ccd6fe39b2f |
| docs/research/llmctl-architecture.md | 268 | dd8fb48077fddd6c1052ce1ec9e68f72996c5c18b250092c5f3d82c7fa05970e |
| docs/qa/decision-models-validation/README.md | 80 | afd4234ca5bc54b83afb89fc1f18eaa4ab98a8a1993a9cd63a55f789fd1f7dc2 |
| docs/qa/decision-models-validation/iter2-test-output.txt | 3359 | 80ce4b3ba57fd70722b0b24cd6dd170dff69906920a54dcb4ba026b593cd81d6 |
| docs/qa/decision-models-validation/stage12-test-output.txt | 1469 | c4962cf8fe7f4d8cb0459d75782ef17c915197e14876800b78fe5812f80303c7 |
| docs/qa/decision-models-validation/stage34-test-output.txt | 3061 | 4e0bb3850505a8ed5f869b7ff57d63b01a7e4274034417571510080da2cec162 |
| lib/__pycache__/onnx_server.cpython-312.pyc | n/a (binary) | c2fa47e92b3e07bdcadaf7f7004026869853c34e43ee0b3ca99d221604beb76e |
| lib/__pycache__/decide_gateway.cpython-312.pyc | n/a (binary) | c47e2371278befe79b496b957c457ecad261706a33126c359b9dcc9aa44d1881 |
| tests/fixtures/__pycache__/onnx_decide_server.cpython-312.pyc | n/a (binary) | 922241cd3718d625391535fa2238c8058726022e9f1d52f36cefb6067df76f26 |
| tests/fixtures/__pycache__/decide_server.cpython-312.pyc | n/a (binary) | 25f059cec027740d68884e1a1b525783f66140ee26a77748deb1497b09e242f1 |

The four `.pyc` files: **GENERATED, compiled for CPython 3.12 -> never import, never track; add `__pycache__/` to `.gitignore` if absent (D-25).**

Files outside this list that the new files call (not dispositioned here, needed for the call graph): candidate `lib/scheduler.sh` (onnx arm, ~l.408-427; rank `decide` l.56),
`lib/download.sh` (`_dl_smoke_test_decision` l.451, `_dl_validate_onnx` l.516, `_dl_onnx_probe_*`, `_dl_smoke_test_onnx` l.602), `lib/catalog.sh` (`catalog_engine`, `catalog_plan_json` decision subtree),
`bin/llmctl` (dispatch `decide)` l.202; usage l.80-87), `models/catalog.json`.

---

## 1. Per-file sections

### 1.1 `lib/decide.sh` (952 lines) — bash CLI + gateway lifecycle

**Purpose.** `llmctl decide {ask|capacity|status|interactive|serve|help}`; renders/queries/shapes typed decisions against a profile's engine; owns the gateway pid/daemon lifecycle. Sourced by `bin/llmctl`; sources `common.sh`, `catalog.sh`; uses `scheduler.sh` functions (`sched_is_running`, `sched_is_enabled`, `sched_start`) at call time (sourced elsewhere).

**Public surface (functions).** `decide_usage`, `decide_options_json <type> <criteria>`, `_decide_opts_part <doc> <options|legend>`, `decide_build_prompt <type> <state> <instr> [criteria]` (delegates to `decide_gateway.py --render-prompt`), `decide_query_logprobs <host> <port> <prompt> <n>`, `decide_shape_response <type> <raw> <options_json> [legend_json]`, `decide_query_onnx <host> <port> <type> <state> <instr> [criteria]`, `_decide_profile_downloaded <p>`, `decide_resolve_profile`, `decide_ensure_server <p>`, `decide_ask`, `decide_capacity [--json]`, `decide_status [--json]`, `_decide_downloaded_profiles`, `decide_interactive`, `decide_serve`, `cmd_decide`. `download.sh` (`_dl_smoke_test_decision`, `_dl_decision_probe_*`) calls `decide_build_prompt/decide_query_logprobs/decide_shape_response`.

**CLI flags.** `ask`: `--profile --type --state --state-file --instructions --criteria --json --interactive`. `interactive`: same minus `--json`, plus `--interactive`. `capacity|status`: `--json` (only `$1` inspected). `serve`: `--profile --port --api-key --foreground --stop`. Bare `decide` -> wizard iff stdin AND stdout are TTYs (l.940), else rc 2.

**Env vars (defaults).** `LLMCTL_DECIDE_PORT`=8095 (l.61), `LLMCTL_DECIDE_TEMPERATURE`=1.0 (l.62), `LLMCTL_DECIDE_NO_INTERACTIVE`=0, `LLMCTL_DECIDE_MAX_OPTIONS`=20 (hard cap 26 hard-coded l.455), `LLMCTL_DECIDE_TIMEOUT`=30 (curl `--max-time`), `LLMCTL_DECIDE_PROFILE` (unset -> `decide-tiny` if downloaded else `decide`), `LLMCTL_DECIDE_API_KEY` (serve), `LLMCTL_DECIDE_BACKEND_HOST`=127.0.0.1 and `LLMCTL_DECIDE_BACKEND_PORT` (test seams, l.466/471/875/878), `LLMCTL_SEED` (-> payload `seed` int), `LLMCTL_DRY_RUN`, `LLMCTL_RUNTIME_DIR`, `LLMCTL_LOG_DIR`, `LLMCTL_MODELS_DIR`. `LLMCTL_DECIDE_MAX_STATE_CHARS` is documented in the header (l.35) but not read here (read by the two Python servers). Internal inter-process env channel (not user config): `LLMCTL_DECIDE_RAW/OPTS/LEGEND/TEMP/STATE/INSTR/CRIT/MODEL/PORT_USED/LATENCY_MS/PAIRS/LEVELS/TRUE/FALSE/PLAN_DOC`.

**Constants/thresholds.** options 2..20 practical / 26 hard (A..Z); score levels 2..10; noul fixed `A=yes`,`B=no`; `top_logprobs = max(n_options, 5)`, `max_tokens=1`, `temperature=0` (request) and `LLMCTL_DECIDE_TEMPERATURE` (divisor in softmax; <=0 or unparsable -> 1.0); confidence `(n*p_max-1)/(n-1)` clamped [0,1] (n=1 -> 1.0); gateway readiness poll 30 x 0.2 s = 6 s (l.911-920); stop: TERM, 50 x 0.1 s wait, then KILL + 0.2 s (l.849-857); wizard state terminator = a line that is exactly `.`; wizard prints state preview `%.200s`.

**External deps.** `python3` (everything JSON/math), `curl`, `awk` (wizard), `find`/`grep` (downloaded check), `kill`, `nohup`, `sleep` (fractional), `python3 -m json.tool` (TTY pretty print); llama-server (`/v1/chat/completions`), onnx server (`/v1/systemone`); `hw_probe_json | catalog_plan_json` (capacity).

**Key behaviours.** (1) Option cap + criteria validation happen before any backend call (rc 2). (2) With `LLMCTL_DECIDE_BACKEND_PORT` set, server bring-up is bypassed entirely. (3) Otherwise `decide_ensure_server` -> `sched_start` (admission control / budget refusal with numbers comes from the scheduler). (4) llama engine: client-side render -> POST -> top_logprobs[0] -> letters -> softmax. (5) onnx engine: POST `{"state","questions":{"q":{type,instructions,criteria?}}}` and take `answers.q`. (6) Output always gets additive `"model"` and `"evidence":{"server_port","latency_ms"}`. (7) `--json` prints single line; otherwise pretty-prints only when stdout is a TTY. (8) wizard: thin prompter, flags skip steps, abort at `Proceed?` -> rc 0 with no stdout.

**Known defects (D-ids).** D-02 (no key sent to onnx runtime / gateway), D-03 (`--api-key` on argv, l.890), D-04 (docs/guard), D-05 (stop kills any pid, l.840-866), D-11 (test seams in production: l.466-472, 875-879), D-19 (gateway readiness probes 127.0.0.1 http, no unit), D-20 (`SECONDS` integer seconds x1000, l.488-498), D-24 (stale comments: l.26 header comment is fine but usage/`build`), D-28 (state inserted raw into prompt), D-29 (`LLMCTL_DECIDE_API_KEY`).

**NEW defects.**
- **N-01 (H) CONFIRMED-RUNTIME**: state/instructions/criteria are passed as *argv* to python (`decide.sh:184-186` -> `decide_gateway.py --render-prompt --state ...`; also l.107 `python3 - type criteria`). A 200 000-char `--state-file` fails with `lib/decide.sh: line 184: /usr/bin/python3: Argument list too long` (rc 126) — Linux per-argument cap is 128 KiB (`MAX_ARG_STRLEN`). Also exposes user state in `/proc/*/cmdline` while the call runs (privacy; same class as D-03). Fix: stdin/file/fd transport everywhere.
- **N-02 (M) CONFIRMED**: the CLI path applies **no state-length handling at all** (no `--max-state-chars`, no truncation header); only the gateway truncates (8192 chars). On llama a too-long state yields an opaque `backend query failed` (curl `-fsS` hides the body, l.212); on onnx it is silently cut by tokens (D-01).
- **N-03 (M) CONFIRMED-RUNTIME (equivalent code in gateway)**: letter matching is `strip().upper()` over single characters (l.263-264) -> a lower-case article token `" a"` is counted as option **A**; `"I"`/`"a"` collide with real letters. Reproduced on `shape_answer` (identical logic): `" a"` -0.1 treated as `A`. Fix: match exact letter tokens (optionally one leading space), case-sensitive.
- **N-04 (M) CONFIRMED-RUNTIME (gateway copy)**: `noul` returns exactly `0.0` when `A` is absent from `top_logprobs` (renormalises over matched letters only; l.273-287); all-`-inf` logprobs produce `NaN` probabilities and `confidence 1.0`, and `json.dumps` then emits the invalid-JSON token `NaN`. No finite-check. (Spec edge case: "all readouts outside letters -> explicit error" is only partly handled.)
- **N-05 (M) CONFIRMED-RUNTIME**: invalid `LLMCTL_SEED` -> Python traceback from the payload builder (l.208 `int(seed)`); same at `decide_gateway.py:233` (inside a request thread -> dropped connection).
- **N-06 (M) CONFIRMED-RUNTIME**: wizard on EOF (`decide_interactive --interactive </dev/null`) terminates the *whole calling shell silently* (printed the profile list, then no further output, no rc line) because `read` returns 1 under the file-level `set -euo pipefail` (l.53/680). Needs `read ... || return 2` with a message.
- **N-07 (L) CONFIRMED**: `decide_capacity`/`decide_status` look only at `$1`; any other argument (e.g. `--jsno`) is silently ignored (l.533, 567).
- **N-08 (L) CONFIRMED**: `docs/scripts/decide.md:175` names `decide_model_downloaded`; the code function is `_decide_profile_downloaded`.
- **N-09 (L) INFERRED**: `bash read -p` prints its prompt only when stdin is a terminal; with `--interactive` and piped stdin the "prompts go to stderr" claim (docs/scripts/decide.md:102) is not observable. Verify when rewriting docs.
- **N-10 (M) INFERRED/UNCONFIRMED**: the readout takes only the *first generated token* (`top_logprobs[0]`); a model/template that emits a thinking/format token first yields "no option letters found". Must be measured per profile in real runs (US3).
- **N-11 (M) INFERRED**: SC-001 requires byte-identical repeats; `temperature=0` + optional seed does not by itself guarantee bit-identical logprobs across llama.cpp slot/batch compositions. Must be measured on the real engine.

**Portability.** No `mapfile`, `declare -A`, `${x,,}`, `local -n`, GNU `sed -r`/`readlink -f`/`date -d` (grep verified). `read -r -p`, `printf '%.200s'`, fractional `sleep`, `find -size +0`, arrays, `${v:+...}` are fine on bash 3.2; `seq` used only in tests. Relies on Python3 (>=3.7 for the called scripts). `set -euo pipefail` at file scope changes the sourcing shell (pre-existing repo convention).

**Changes needed for the clarified spec.**
1. Key: remove `LLMCTL_DECIDE_API_KEY`/`--api-key`; add one resolver (env `LLMCTL_API_KEY` -> `.env` (reuse any existing loader, D-31) -> generate-once, 0600) used by `ask`, `serve`, smoke, health; never on argv (stdin/`curl --config`/header file), never echoed; deliberate `key show` command only.
2. HTTPS only: every `http://` URL (l.213, 332, 913, 490, 497) -> `https://` with `--cacert <certdir>/server.crt` (verify by default; no `-k`); cert dir under `$HOME` (`llmctl/cert`), auto-create, explicit renew; gateway readiness probe over HTTPS.
3. Bind: gateway/runtime listen on the network by default but refuse to start without a key; engine servers (llama-server/onnx behind a decision profile) must be forced to `127.0.0.1` regardless of `LLMCTL_BIND_HOST*` (today the scheduler uses `catalog_bind_host`, default `0.0.0.0`, for the onnx arm).
4. Remove test seams from production code (`LLMCTL_DECIDE_BACKEND_HOST/PORT`); replace by function-override injection in tests or a test-only wrapper script (D-11/FR-024).
5. Stop: verify `/proc/<pid>/cmdline` (Linux) / `ps -o command=` (macOS) identity before TERM/KILL; lock around start/stop (D-05/FR-023).
6. Multi-instance (FR-029): `--instance N` or `--count`, per-instance port/pidfile/log; today there is exactly one `decide-gateway.pid` and one fixed port per profile.
7. State transport via stdin/file; real ms latency (monotonic clock; macOS `date` has no `%N`, use python `time.monotonic_ns`).
8. Wizard EOF handling (N-06); strict arg validation for `capacity|status` (N-07); apply/announce state truncation consistently with the servers (N-02); finite-number checks (N-04).
9. Prompt-injection (D-28): keep the template single-sourced but document residual risk; add option-order sensitivity measurement (spec edge case).

**DISPOSITION: IMPORT-WITH-CHANGES (heavy).** Keep command surface, wizard, option derivation, capacity/status; rewrite transport/auth/stop/lifecycle parts as above.

---

### 1.2 `lib/decide_gateway.py` (460 lines) — HTTP gateway + prompt template

**Purpose.** (a) `--render-prompt` CLI = the single source of the lettered-option prompt; (b) `ThreadingHTTPServer` exposing the hosted-Jev wire shape; llama mode renders/queries/shapes locally, onnx mode proxies verbatim.

**Flags.** `--render-prompt --type --state --instructions --criteria --port(env LLMCTL_DECIDE_PORT, 8095) --bind-host(env LLMCTL_BIND_HOST or 127.0.0.1) --backend-host(env LLMCTL_DECIDE_BACKEND_HOST, 127.0.0.1) --backend-port(env LLMCTL_DECIDE_BACKEND_PORT, 0) --profile --backend-engine {llama,onnx}(llama) --model-id --api-key --max-state-chars(env LLMCTL_DECIDE_MAX_STATE_CHARS, 8192; 0 disables)`.

**Env.** `LLMCTL_DECIDE_MAX_OPTIONS`(20, read at import l.54), `LLMCTL_DECIDE_API_KEY`, `LLMCTL_DECIDE_TIMEOUT`(30 s), `LLMCTL_DECIDE_TEMPERATURE`(1.0), `LLMCTL_SEED`, `LLMCTL_BIND_HOST`, `LLMCTL_DECIDE_PORT`, `LLMCTL_DECIDE_BACKEND_HOST/PORT`. NOTE `LLMCTL_BIND_HOST` is **not exported** by `lib/common.sh` (export list l.39-40 omits it), so by default the shell-launched gateway sees nothing and binds `127.0.0.1`; but an operator who exports `LLMCTL_BIND_HOST=0.0.0.0` for the chat servers silently exposes the (keyless by default) gateway as well (CONFIRMED by reading argparse default l.420).

**Constants.** `PROMPT_HEADER` = "You are a decision engine. Read the state and answer the question with exactly one letter."; trailer "Answer with a single letter." / "Answer:"; body cap 4 MiB (`4*1024*1024`, l.325); health timeout `min(timeout,5.0)`; aliases `jev-latest`, `jev-preview`, `llmctl-<profile>`, plus `--model-id`; `max_tokens=1`, `temperature=0`, `top_logprobs=max(n,5)`; usage `input_tokens = max(1, ceil(chars/4))`, `output_tokens = len(questions)`, `total_tokens` sum. HTTP/1.1, `Content-Length` mandatory.

**Deps.** stdlib only (`argparse json math os sys urllib http.server`); `ThreadingHTTPServer` needs Python >=3.7; ordered criteria needs insertion-ordered dicts (3.7+). Backend: llama-server `/health`, `/v1/chat/completions`; or onnx `/v1/systemone`.

**Behaviours.** Validation order (POST): path 404 -> auth 401 -> Content-Length (<=0 or >4 MiB -> 400) -> JSON -> `state` non-empty str -> `questions` non-empty dict -> head+tail state truncation (`...[state truncated to N chars]...`, header `x-llmctl-decide-truncated: true`) -> per question: dict, type in {noul,choice,score}, non-empty instructions, `derive_options` (SystemExit caught -> 400 generic) -> backend call sequentially (one llama pass per question) -> `shape_answer` (ValueError -> 502). Question names never reach the model. GET `/healthz` is unauthenticated; GET other paths check auth *before* 404 whereas POST checks path before auth (inconsistent).

**Known defects.** D-02, D-04 (l.420 bind, `/healthz` leaks profile l.291), D-08 (l.333 CONFIRMED-RUNTIME: body `"x"` -> AttributeError -> `curl rc=52` empty reply), D-09 (no thread/time limits, `exc` echoed l.350/385), D-19, D-23 (`==` compare l.285), D-28.

**NEW defects.**
- **N-12 (M) CONFIRMED-RUNTIME**: keep-alive desync. Error paths (401, 400-oversize, 404 on POST) return without reading the request body on a persistent HTTP/1.1 connection (l.313-327); the unread body is then parsed as the next request line. Observed: after a 401 with a body, the connection produced no further response within 1.5 s (blocked waiting for a newline). Same pattern in `onnx_server.py:417-426`. Fix: drain/limit-read or `Connection: close` on errors.
- **N-13 (M) CONFIRMED**: backend 4xx/5xx from the onnx runtime (including its 401 when a key is set) is raised as `HTTPError` (a `URLError`), mapped to a generic 502 with exception text (l.349-351) — the client cannot distinguish auth failure from outage; the exception text may carry internal detail (FR-021).
- **N-14 (M) CONFIRMED**: proxy mode drops the upstream's `x-llmctl-decide-truncated` header (gateway builds only its own, l.352-355). If the gateway cap is disabled/higher than the runtime's (both default 8192 but are separate settings; scheduler starts the runtime with no `--max-state-chars`) the runtime truncates and the client is never told (spec edge-case: "response must say so"). Token-level truncation (D-01) is never signalled at all.
- **N-15 (M) CONFIRMED**: hosted shape allows `state` to be a string **or JSON object** (per the research brief, VENDOR-stated, `docs/research/jev-ecosystem.md:19`; Laya's own example sends an object) — both servers reject non-string state with 400 (l.335). Also hosted `choice` allows up to 255 options (research claim, unverified) vs the 26-letter cap here; hosted response additionally carries `id`, `provider`, `usage.cost` (research, unverified). A documented wire-compat matrix is needed (US2 AC2).
- **N-16 (L) CONFIRMED-RUNTIME**: module-level `MAX_OPTIONS = int(os.environ[...])` (l.54) and `int(os.environ.get("LLMCTL_DECIDE_PORT"...))` (l.419) raise raw tracebacks on a bad env value; because `decide_build_prompt` shells out to `--render-prompt`, a bad `LLMCTL_DECIDE_MAX_OPTIONS` breaks `decide ask` with a Python traceback instead of a message.
- **N-17 (L) CONFIRMED**: `model` from the request is echoed back unvalidated (any JSON type) (l.399); no check it is a known alias.
- **N-18 (M) CONFIRMED**: number of questions per request is unbounded (each is a full llama pass over the full state) — D-09 only noted options; per-request cost budget (FR-016) must also cap questions x options.
- N-03/N-04/N-05 (letter matching, NaN, seed) apply to `shape_answer` (l.149, 171, 233).
- **N-19 (L) CONFIRMED**: unauthenticated `/healthz` performs a backend `/health` call on every hit (amplification) and leaks the profile name.

**Portability.** Pure stdlib; fine on macOS system Python >=3.7. No GNU-only anything. TLS needs `ssl` (present).

**Changes for clarified spec.** HTTPS (`ssl.SSLContext(PROTOCOL_TLS_SERVER)`, `minimum_version=TLSv1_2`, cert/key from the home cert dir, SAN validation, own-cert override validated at start); `LLMCTL_API_KEY` resolved in-process (env -> `.env`), compared with `hmac.compare_digest`, never from argv (drop `--api-key`), refuse to start without a key on every bind; gateway->runtime calls over HTTPS with cert verification **or** make the runtime loopback-plain-HTTP (decide per A-1 below); bounded worker pool + socket timeouts + max questions/options-cost budget; drain body / close on error; typed error bodies with no exception text; generic health body for unauthenticated callers; remove `--backend-*` env seams from production defaults (keep CLI flags, drop env fallbacks); per-instance multi-run (pass instance id, port, pidfile); validated numeric env parsing; fix N-03/N-04; forward upstream truncation info.

**DISPOSITION: IMPORT-WITH-CHANGES.** Recommended split: keep `derive_options` / `render_prompt` / `shape_answer` as an importable core module (fix N-03, N-04, N-16), and **REWRITE the server/handler layer** (TLS, auth, limits) once, shared with the onnx runtime (duplicated truncate/auth/handler code today).

---

### 1.3 `lib/onnx_server.py` (542 lines) — encoder (NLI) runtime

**Purpose.** HTTP server for encoder-class decision models (decide-nli = DeBERTa-v3-large zeroshot NLI, ONNX fp32): one forward pass per option; speaks `/v1/systemone` natively.

**Flags.** `--model-dir`(req), `--port`(req), `--host`(env `LLMCTL_BIND_HOST` else 127.0.0.1), `--api-key`, `--profile`(req), `--tokenizer`(default `spm.model`; `.json` -> `tokenizers`), `--max-state-chars`(env `LLMCTL_DECIDE_MAX_STATE_CHARS`, 8192).
**Env.** `LLMCTL_ONNX_FAKE=1` (synthetic logits), `LLMCTL_DECIDE_API_KEY`, `LLMCTL_BIND_HOST`, `LLMCTL_DECIDE_MAX_STATE_CHARS`. The scheduler passes `--host "$(catalog_bind_host)"` (default `0.0.0.0`) explicitly, so in production this server is on the network and keyless unless `LLMCTL_DECIDE_API_KEY` is set (D-04; contradicts FR-073 for engines behind a decision profile).
**Constants.** `MAX_BODY_BYTES`=4 MiB; encoder `MAX_LEN`=512 tokens hard-coded (l.246); 26 option cap; score 2..10; fake logits `ent = 2.0 - 0.5*option_index`, `neu = 0.0`, `con = -2.0`; canonical label order (entailment, neutral, contradiction) = indices (0,1,2) if config absent; hypothesis = `"<instructions> Option: <label>"` (labels: yes/no; `key - desc`; level text); input-token estimate `ceil((len(state)+len(hypothesis))/4)` per option.
**Deps.** stdlib; optional `onnxruntime` (CPUExecutionProvider), `numpy`, `sentencepiece` (spm.model), `tokenizers` (tokenizer.json). Missing package -> `die()` rc 1 at startup with pip hint (unpinned, D-16).
**Behaviours.** Label order from `config.json` (top-level first, then `onnx/`) `id2label` ("entail"/"contrad" substring match); logs `label_order` / `model_loaded` / `listening` / `request` as one-line JSON on stdout; `noul` = softmax([ent, logsumexp(neu,con)])[0] of the YES hypothesis; `choice`/`score` = softmax over per-option entailment logits; confidence formula as elsewhere. Success-path-only request log record (`questions`, `input_chars`, `truncated`) — no timestamp/profile/caller, nothing on 4xx.
**Known defects.** D-01 (CONFIRMED l.253/256 tail truncation of `[CLS] p [SEP] h [SEP]`, and `enc.ids[:MAX_LEN]`), D-02, D-03, D-04, D-07 (l.269 `die()` -> SystemExit inside request thread), D-08 (CONFIRMED-RUNTIME l.432: `[1,2]` body -> AttributeError -> empty reply), D-09, D-10 (l.317 only 26 cap), D-11 (fake seam l.512 selectable in production by env var; `/health` reports `"fake": true` but `/v1/systemone` responses do not), D-16, D-17 (only `input_ids`,`attention_mask` fed, l.266; spm `bos/eos` fallback ids 1/2 assumed), D-21 (l.346 evaluates the NO hypothesis for `noul` and discards it), D-23.
**NEW defects.**
- **N-20 (M) CONFIRMED**: catalog `defaults.ctx = 512` for decide-nli is **ignored**: `MAX_LEN = 512` is a literal; `LLMCTL_CTX_DECIDE_NLI` has no effect and the doc table advertises it (docs/decision-models.md:39).
- **N-21 (M) CONFIRMED**: `detect_label_order`: (a) root `config.json` is preferred over `onnx/config.json` although the ONNX export ships its own (1019 B vs 1036 B per `encoder-model-hashes.md`; catalog downloads only the root one); (b) labels without "entail"/"contrad" (e.g. `LABEL_0..2`) or 2-class heads silently fall back to the assumed canonical order and log the misleading source "assumed-canonical-order (no config.json id2label found)" although a config exists; (c) non-integer `id2label` keys raise `ValueError` uncaught at startup (`int(kv[0])` outside the try). FR-004/US3 AC3 require validation against the real files.
- **N-22 (M) CONFIRMED**: engine semantic drift vs gateway: noul `criteria` of non-object type is silently ignored here but a 400 in the gateway; `LLMCTL_DECIDE_MAX_OPTIONS` ignored (D-10); different error strings and no 502-class; wire answers are "identical" only for valid input.
- **N-23 (L) CONFIRMED**: `/health` returns 200 once the model object exists; it never runs an inference, so a broken tokenizer/model is "healthy".
- **N-24 (M) CONFIRMED**: NaN/inf logits are not handled (math domain/`NaN` in output); `answer_question` runs inside the handler with only `ValueError` caught (l.459) — any other exception drops the connection.
- N-12 keep-alive desync applies (l.417-426); N-03-class issue does not (no letter matching).
**Portability.** Python >=3.7; onnxruntime/sentencepiece wheels exist for macOS arm64/x86_64 and Linux x86_64/aarch64 (INFERRED, not checked here); system Python on macOS may lack them (D-27). The 1.74 GB fp32 model on a CPU: latency/footprint unmeasured (planner estimate size*1.5+512 MiB ≈ 3 GB, source-findings I-03).
**Changes for clarified spec.** Same server-layer changes as the gateway (HTTPS, `LLMCTL_API_KEY`, auth, limits). Decide per A-1 whether the runtime is *internal* (loopback plain HTTP behind the gateway; FR-073) or itself a decision endpoint (HTTPS+key, FR-018 says "gateway or runtime"). Move fake inference out of the production binary: `Server(args, infer_fn)` is already injectable, so tests can use a tiny test-only launcher that builds `Server` with `fake_infer` (no env switch in shipped code, FR-024). Fix D-01 (truncate the *state* tokens only, keep question+option; report truncation), D-07 (typed 500/502 error), D-17 (feed `token_type_ids` when the graph declares it — inspect `session.get_inputs()`), N-20 (honour ctx), N-21 (validate label order against real `config.json`; fail loudly if not resolvable), N-22 (share option/validation code with the gateway module), per-option cost cap + timeout, finite checks, request log with timestamp/profile/request-id without state text (FR-037).
**DISPOSITION: IMPORT-WITH-CHANGES.** Inference core (tokenizer load, `encode_pair`, label detection, NLI shaping) import with fixes; HTTP layer REWRITE (shared); `LLMCTL_ONNX_FAKE` seam DROP from production code.

---

### 1.4 `tests/fixtures/decide_server.py` (89 lines) — llama-server stand-in

**Purpose.** Deterministic stub of llama-server `GET /health`, `POST /v1/chat/completions` (scripted `top_logprobs` by prompt text). **Surface:** `argv[1]` = port (default 18092), binds `127.0.0.1`. **Constants:** prompt classes "2+2=4" -> (` A` -0.03, ` B` -3.5, ` the` -0.5); "invoices" -> (A -0.05, B -3.0, the -0.5); "Rate the quality" -> (C -0.04, B -2.8, A -4.0, the -0.5); default (A -0.1, B -2.3, the -0.5); winner message `content`. **Deps:** stdlib, single-threaded `HTTPServer`. **Defects:** none functional; it is a unit-level stand-in (FR-039: must be labelled so in any report, never counted as real-model proof); ignores `logprobs`/`top_logprobs`/`seed` request fields, so it cannot catch a payload regression; the scripted distributions are hand-made.
**Changes.** Keep; add a header marking it STAND-IN/unit-only; optionally `ThreadingHTTPServer`. **DISPOSITION: IMPORT-AS-IS** (with stand-in label comment).

### 1.5 `tests/fixtures/onnx_decide_server.py` (107 lines) — onnx runtime stand-in

**Purpose.** Stub of `GET /health` (200 `{"status":"ok"}`) and `POST /v1/systemone` with answers scripted by `instructions` content: "2+2=4" -> noul 0.97 else 0.9; "invoices"+billing -> choice 0.97/0.03 split; "Rate the quality"+3 levels -> probs .05/.25/.70 (score 1.65), else first/last option 0.9; usage fixed `input_tokens 42`. Port default 18096, binds 127.0.0.1, single-threaded. **Defects:** performs no validation (garbage in -> 200); returns `{"error":"unknown type"}` inside `answers` for an unknown type; ignores auth entirely, so it cannot model the gateway->runtime credential flow (D-02 has no test); **its confidence formula and shapes are re-implemented in the fixture** (second copy of the math). **Changes:** must speak whatever transport the gateway->runtime hop uses after A-1 (HTTPS+key or plain loopback); add a key-checking mode to test the credential flow. **DISPOSITION: IMPORT-WITH-CHANGES** (stand-in label; auth/transport mode).

---

### 1.6 `tests/test_decide.sh` (346 lines; 71 `assert_*` calls = the 71 reported in iter2 capture)

**Purpose.** In-process tests of `decide.sh`: prompt build (letters, noul, score), exact shaping math (expected values computed in-test with python, 1e-12), full `decide_ask` against `decide_server.py` and `onnx_decide_server.py`, caps (27 options -> rc 2), missing criteria, not-downloaded profile (rc 1), wizard refusal/happy/abort paths, `decide_capacity`/`decide_status` on `hw-baseline.json`, engine dispatch, unknown-engine error.
**Dependencies.** `tests/helpers.sh`, sources common/os_detect/hardware/catalog/decide/scheduler; python3, curl, `LLMCTL_FAKE_HW`, both fixtures, candidate `models/catalog.json` (`catalog_engine decide-nli` = onnx).
**Constants tied to other code (will break on merge):** `decide-tiny` baseline capacity `10444//1592=6`, `25904//2048=12`, `instances_gpu=6` (l.255-259) — depends on the planner/KV constants (real repo HEAD has corrected `KV_TYPE_RATIO` commits `55ddbec`,`48dbf5e` after the snapshot); `decide-nli` onnx scripted 0.97/1.65 values.
**Defects/gaps.** Uses the production test seam `LLMCTL_DECIDE_BACKEND_PORT` (D-11); asserts nothing about key/HTTPS/stop identity/multi-instance; encodes current (to-be-changed) behaviour e.g. `decide_ask` with `bad-eng` profile message; stand-in only (no real model). Static assertion count 71 == capture, so the doc's "55" is stale (I-/FR-043).
**Changes.** Re-derive capacity numbers from the merged planner; replace seam with injectable backend (function override) or fixture on HTTPS with trusted test cert; add tests for N-01 (large state via file), N-03, N-04, N-05, N-06, N-07 and D-xx; mark all stand-in results. **DISPOSITION: IMPORT-WITH-CHANGES.**

### 1.7 `tests/test_decide_download.sh` (95 lines; 10 static asserts, 9 run)

**Purpose.** `download_profile toy-decide` (capability `decide`, engine llama) against a local `python3 -m http.server` on **fixed port 18732**; asserts the decision smoke path (not the gguf one) is taken (`LLMCTL_SMOKE=0` evidence string), then `LLMCTL_SMOKE=1` without llama-server -> SKIP-with-reason rc 0; else an honest `assert_skip`. Uses `stat -c%s || stat -f%z` (portable GNU/BSD), `LLMCTL_HF_BASE`, `LLMCTL_CATALOG`.
**Defects.** fixed port (collision/parallel runs; use free-port like the gateway test); asserts D-12 behaviour as *desired* ("download ... SUCCESS" while smoke skipped, l.74); toy payload is not a GGUF so the real decision probes never run here. **Changes.** free port; after fix of D-12 assert the new "unverified/skipped" wording; add a real-model variant gated on availability. **DISPOSITION: IMPORT-WITH-CHANGES.**

### 1.8 `tests/test_decide_gateway.sh` (238 lines; 43 static asserts, 45 run = loop of 3)

**Purpose.** Gateway end to end over plain HTTP on free ports: `/v1/systemone` choice, mixed noul+score, `/v1/models` aliases, Bearer 401/200 matrix (key `test-secret-key` on argv, test-only), truncation header (64-char cap), `decide_serve` daemon + `--stop` + not-running rc 1 + dry-run, onnx-mode proxy against `onnx_decide_server.py` incl. 400 pre-proxy and `--backend-engine` in dry-run line.
**Defects/gaps.** All `http://`, key on argv, no HTTPS/negative-transport cases (FR-070), no client matrix (FR-069), no hostile-traffic scenario (SC-006), no stale-pidfile-vs-unrelated-process test (D-05), no gateway->runtime credential test (D-02), no concurrency, `trap` replaced mid-file (l.199) so earlier cleanup is re-spelled; `decide_serve --stop` in cleanup resolves via `LLMCTL_RUNTIME_DIR`.
**Changes.** Rewrite around HTTPS + `LLMCTL_API_KEY` (env), generated cert in a temp HOME, curl/python/node/go/browser clients (as available), negative transport cases; keep the endpoint-inventory idea (assert every path x method is covered). **DISPOSITION: IMPORT-WITH-CHANGES (effectively REWRITE of assertions; reuse structure/helpers).**

### 1.9 `tests/test_onnx_download.sh` (112 lines; 22 static, 21 run)

**Purpose.** `toy-onnx` profile (engine onnx, files `onnx/model.onnx`, `onnx/spm.model` fake payloads, revision `0123456789abcdef...`) through `download_profile` on **fixed port 18733**; with `LLMCTL_ONNX_FAKE=1` the real `onnx_server.py` is launched and 3 probes pass; second run skips; without fake and without deps, smoke SKIPs with reason and the script **asserts `download ... SUCCESS` is still logged** (l.106, encodes D-12).
**Defects.** Depends on the production fake seam; "onnx smoke test passed" is printed for a payload that is not an ONNX file (iter2 capture shows exactly this) — i.e. a download is "verified" without opening a model (D-11, FR-024). **Changes.** replace seam by test-only launcher; after D-12 fix assert unverified status; free port. **DISPOSITION: IMPORT-WITH-CHANGES.**

### 1.10 `tests/test_onnx_server.sh` (225 lines; 25 static, 28 run)

**Purpose.** Real `onnx_server.py` processes under `LLMCTL_ONNX_FAKE=1` on free ports: startup errors (rc 2 / rc 1), exact noul/choice/score math from the documented fake formula, usage estimate, label-order detection (permuted `id2label`), auth matrix (`--api-key test-onnx-key`), 4 MiB body bound (curl `--data-binary` 4 MiB+16: 8/8 repeats returned 400 here, flake risk INFERRED low), truncation header, 400s, stdout JSON log.
**Defects/gaps.** exercises only the fake core — tokenization, truncation (D-01), label validation against a real config, 3-class check (D-07) are untested; no hostile/slow client tests; no HTTPS. **Changes.** keep math assertions (they are good oracles for the shaping layer), move to test-only launcher, add real-model golden tests when available; HTTPS+key. **DISPOSITION: IMPORT-WITH-CHANGES.**

---

### 1.11 Documentation files (all dated Revision 2 / 2026-10-06; Linux-host-less "verified against the code")

Common problems: generated by the second team in `/mnt/agents`; counts stale (decide 55 vs 71, gateway 36 vs 45, onnx 28/21 ok); describe plain HTTP, loopback-default bind, `LLMCTL_DECIDE_API_KEY`, single fixed port per profile, test seams as normal config — all contradicted by the clarified spec; "Last verified date" lines assert verification that was stand-in only.

| File | Content | Facts that must be re-verified / rewritten | DISPOSITION |
|---|---|---|---|
| `docs/decision-models.md` | 6-profile table, mechanism, engines, onnx NLI semantics, Laya BYO, fake seam, ranking, calibration, pin procedure, limitations | pin sizes/hashes vs huggingface.co; benchmark numbers are vendor claims (`79.2%`, `64.13 #1 of 89`, `0.574->0.648`, Brier/ECE) -> label provenance or drop; "Laya: no laya-onnx sibling repo exists" rests on a mirror error reply (`encoder-model-hashes.md:520`) -> INFERRED not verified; `LLMCTL_CTX_<PROFILE>` for onnx is a no-op (N-20); "multi-instance capacity-report-only" must be replaced by FR-029; ranking `decide-tiny > decide-nli > ...` must be re-justified (D-12/D-18, SC-012); "decide-nli ... RAM = size*1.5+512" vs measured; fake seam section removed (FR-024); `llmctl-onnx@.service` template (not in this file set) re-check | DOCS-REWRITE |
| `docs/decide-gateway.md` | gateway reference, endpoints, auth, truncation, concurrency | HTTPS/key/bind default (FR-026); "36 assertions" stale (45); example response floats illustrative; `TYPESAFE_BASE_URL`/`TYPESAFE_API_KEY` SDK instructions are vendor-stated and untested here (research says SDK honors it via local-jev README); hosted-shape compat matrix (N-15); health body; 502 text | DOCS-REWRITE |
| `docs/scripts/decide.md` | per-lib doc | env table (retire `LLMCTL_DECIDE_API_KEY`), `decide_model_downloaded` name wrong (N-08), "Last verified" | DOCS-REWRITE (regenerate after code) |
| `docs/scripts/decide_gateway.md` | per-lib doc | same + endpoint list | DOCS-REWRITE |
| `docs/scripts/onnx_server.md` | per-lib doc | claim "any other logit count dies with an explicit error at first inference" — actually SystemExit in a request thread, connection dropped (D-07); `LLMCTL_ONNX_FAKE` row; "never set by any production path" is true only by convention (env switch exists) | DOCS-REWRITE |
| `docs/scripts/test_decide.md` | "55 passing assertions" (actual 71), numbers `10444//1592` | counts must be machine-generated (FR-043) | DOCS-REWRITE |
| `docs/scripts/test_decide_download.md` | "9 passing" (matches run count), port 18732 | port; D-12 wording | DOCS-REWRITE |
| `docs/scripts/test_decide_gateway.md` | "36 passing" (actual 45) | everything http | DOCS-REWRITE |
| `docs/scripts/test_onnx_download.md` | "21 passing" (ok), port 18733 | seam | DOCS-REWRITE |
| `docs/scripts/test_onnx_server.md` | "28 passing" (ok) | seam | DOCS-REWRITE |
| `docs/research/README.md` | index of 4 briefs; Revision 2, Last modified `2026-10-06T00:00:00Z` (midnight placeholder, I-11) | header; link targets | DOCS-REWRITE (small) |
| `docs/research/decision-model-hashes.md` | raw HF metadata (6 repos, incl. non-shipped `Mapika/decider-2b-GGUF` Q4_K_M 1,274,396,800 B, `chaoliangUNSW/Jev-Style-Qwen3.5-2B-Decision-GGUF` Q4_K_M/Q8_0, rizzo 1.7B q8_0, JevK5 4B v0.3 Q8_0) | says "Verified 2025" (I-05); data came only from hf-mirror.com and "hashes were not re-checked by download" (l.182) -> this is *unverified mirror data*; must be re-fetched from huggingface.co and byte-checked (FR-003) | IMPORT-WITH-CHANGES (keep as research input; correct header; mark UNVERIFIED until re-pinned) |
| `docs/research/encoder-model-hashes.md` | raw HF metadata (deberta-v3-large-zeroshot-v2.0, laya, JevK5), laya-serve README quote (binds `0.0.0.0`, no auth unless `LAYA_API_KEY`), "CONFIRMED" JevK5 pins | "CONFIRMED ... exact match" compares against the *same mirror's* earlier answer, not an independent source (INFERRED); item 4 "NOT FOUND/UNVERIFIED" is a mirror auth-error, not proof of absence; safetensors 870 MB vs ONNX 1.74 GB (I-03) | IMPORT-WITH-CHANGES (same as above) |
| `docs/research/jev-ecosystem.md` | vendor + ecosystem survey with labels [VERIFIED]/[SECONDARY]/[VENDOR]/[UNVERIFIED] | I-01 (`v2` tag does not exist), I-02, I-03 (0.87 GB vs 1.74 GB ONNX), I-04; every dated/benchmark/pricing/star-count claim is search-derived; hosted Jev, TypeSafe, arXiv `2609.37647`, JevBench numbers are unverified by us (source-findings E); useful as a *candidate list* (FR-007) and wire-format notes (`state` string-or-object, up to 255 options, response `id`/`provider`/`cost`) | DOCS-REWRITE → keep only as `specs/009/research` input, not shipped as a product doc; any shipped statement re-sourced and provenance-labelled (FR-052) |
| `docs/research/llmctl-architecture.md` | implementer map of the pre-feature repo | contains false-now statements: "no interactive prompts" (I-08), engine enum only llama/colibri, typo `LLMCTX_CTX_<PROFILE>` (I-10), "tree sha `a9ebefe…`" (a9ebefe is the commit id; INFERRED mislabel), `bin/llmctl` "277 lines" matches real HEAD (verified), real repo has 38 `tests/test_*.sh` (+helpers.sh, run_tests.sh, fixtures/) vs spec's "41 files" — recount | DROP as a shipped doc (stale duplicate of `docs/architecture.md`); keep copy under specs/009 as historical input |
| `docs/qa/decision-models-validation/README.md` | evidence index (mode 0600) | claims "two consecutive passes" for stage12: capture has ONE run (I-07, CONFIRMED: no `=== RUN` markers, one `PASS: 33  FAIL: 7`); counts 55/36 stale; says feature design doc not in repo | DOCS-REWRITE (replace by real-model evidence index) |

**The three `*-test-output.txt` captures (all from `/mnt/agents/llmctl`, i.e. not this host; stand-in based; no real model).**
- `stage12-test-output.txt` (1469 lines): one `bash tests/run_tests.sh` run (preceded by `make test` wrapper); summary `PASS: 33  FAIL: 7`; 813 `ok:` lines, 5 `SKIP` hits (GPU throughput/VRAM-delta skips, one "already published" line); suites present: `test_decide`, `test_decide_download` (no gateway yet). Catalog shows `profiles: 13`.
- `stage34-test-output.txt` (3061 lines): two runs (`=== RUN 1 ===`/`=== RUN 2 ===`, each `PASS: 34  FAIL: 7`, each ends `EXIT: 2` from make); 1726 `ok:` lines; adds `test_decide_gateway`.
- `iter2-test-output.txt` (3359 lines): `make test` x2, each `PASS: 36  FAIL: 7`; 1956 `ok:` lines, 44 SKIP-related hits; `profiles: 16`; suites `test_decide` (71 ok), `test_decide_download` (9), `test_decide_gateway`, `test_onnx_download` (21), `test_onnx_server`. Shows `test_onnx_download` reporting `onnx smoke test passed` on a fake payload (`LLMCTL_ONNX_FAKE=1`) and the scheduler suite asserting the *argv* key passing (`--api-key` when `LLMCTL_DECIDE_API_KEY` set; D-03). The 7 FAILs (same every run, `RESULT: FAIL (7 assertion failure(s))` only in `test_setup_e2e`): `test_apikey_lifecycle`, `test_cluster_join_leave`, `test_tenant_list_quota` (no Go), `test_constitution_inheritance` (empty submodule), `test_engine`, `test_engine_cpu_regression` (exit 128), `test_setup_e2e` — environmental, therefore **unproven**, not "passing".
- Grep counts (whole files, not per suite): PASS/FAIL/SKIP substrings = iter2 276/44/12, stage12 131/22/5, stage34 266/44/10 (substring hits, includes per-test `PASS`/`FAIL` summary lines and words in test titles; not a verdict count).
**DISPOSITION of the three captures: DROP from the shipped tree** (foreign environment, stand-in evidence, hard-coded `/mnt/agents` paths, superseded by FR-042 machine-produced evidence); retain a copy under `specs/009/research` as historical input only.

---

## 2. Disposition summary

| File | Disposition | Core reason |
|---|---|---|
| lib/decide.sh | IMPORT-WITH-CHANGES (heavy) | key/HTTPS/stop/seams/multi-instance/argv-state |
| lib/decide_gateway.py | IMPORT-WITH-CHANGES (core module kept; server layer REWRITE) | TLS/auth/limits/errors; split core vs server |
| lib/onnx_server.py | IMPORT-WITH-CHANGES (inference core kept; HTTP layer REWRITE; fake seam DROP) | D-01, D-07, D-17, N-20..24; FR-024 |
| tests/fixtures/decide_server.py | IMPORT-AS-IS (+stand-in label) | unit stand-in |
| tests/fixtures/onnx_decide_server.py | IMPORT-WITH-CHANGES | transport/auth mode |
| tests/test_decide.sh | IMPORT-WITH-CHANGES | planner numbers, seams, new cases |
| tests/test_decide_download.sh | IMPORT-WITH-CHANGES | fixed port, D-12 wording |
| tests/test_decide_gateway.sh | IMPORT-WITH-CHANGES (assertions rewritten) | HTTPS + key + client matrix |
| tests/test_onnx_download.sh | IMPORT-WITH-CHANGES | seam, D-12, port |
| tests/test_onnx_server.sh | IMPORT-WITH-CHANGES | seam, HTTPS/key |
| docs/decision-models.md | DOCS-REWRITE | spec contradictions + unverified numbers |
| docs/decide-gateway.md | DOCS-REWRITE | HTTP/keyless/loopback |
| docs/scripts/*.md (8) | DOCS-REWRITE | regenerate from final code; counts machine-checked |
| docs/research/README.md | DOCS-REWRITE (small) | placeholder header |
| docs/research/decision-model-hashes.md | IMPORT-WITH-CHANGES | re-pin from real host; header |
| docs/research/encoder-model-hashes.md | IMPORT-WITH-CHANGES | re-pin; "CONFIRMED" not independent |
| docs/research/jev-ecosystem.md | DOCS-REWRITE (research input only) | unverified search-derived claims |
| docs/research/llmctl-architecture.md | DROP (shipped) / keep under specs | stale, duplicates architecture.md |
| docs/qa/.../README.md | DOCS-REWRITE | replace with real evidence index |
| docs/qa/.../*-test-output.txt (3) | DROP (shipped) / keep under specs | foreign env, stand-in |
| 4 x `__pycache__/*.pyc` | GENERATED -> never import | compiled cache (FR-045, D-25) |

Spec ambiguity to resolve in planning (**A-1**): FR-018 calls "gateway or runtime" decision endpoints, FR-073 says engine servers behind a decision profile are internal/loopback. `onnx_server.py` natively speaks the wire shape, so it is both. Choose: (i) runtime internal on loopback plain HTTP, gateway is the only HTTPS facade for decide-nli too; or (ii) runtime itself HTTPS+key. The candidate fixtures/tests and the gateway proxy mode assume (i)-like plain HTTP.

---

## 3. Interfaces other new files depend on (call graph)

```
bin/llmctl `decide)` ---> cmd_decide (lib/decide.sh)
  ask ------> decide_options_json (python3 -, argv)      \ option/legend derivation (dup of decide_gateway.derive_options and onnx_server.derive_options - 3 copies)
          |-> decide_resolve_profile -> _decide_profile_downloaded
          |-> decide_ensure_server -> sched_is_running / sched_start  (lib/scheduler.sh; admission control; onnx arm launches lib/onnx_server.py with --host catalog_bind_host --port --profile [--api-key $LLMCTL_DECIDE_API_KEY])
          |-> llama: decide_build_prompt -> python3 lib/decide_gateway.py --render-prompt  (ONLY prompt template)
          |          decide_query_logprobs -> curl POST http://127.0.0.1:<port>/v1/chat/completions  (llama-server)
          |          decide_shape_response (python3, env RAW/OPTS/LEGEND/TEMP) -> typed JSON  (2nd copy of math = gateway.shape_answer)
          |-> onnx: decide_query_onnx -> curl POST http://127.0.0.1:<port>/v1/systemone -> answers.q
          '-> attaches {"model","evidence":{"server_port","latency_ms"}}
  capacity -> hw_probe_json | catalog_plan_json -> ["tier","budgets","decision_instances"]
  status   -> catalog_profiles/capability/port + sched_is_running/sched_is_enabled
  interactive -> prompts (stderr) -> decide_ask
  serve    -> decide_ensure_server (or seam) -> python3 lib/decide_gateway.py --port --backend-host --backend-port --profile --model-id llmctl-<p> --backend-engine <catalog_engine> [--api-key]
              nohup + ${LLMCTL_RUNTIME_DIR}/decide-gateway.pid ; log ${LLMCTL_LOG_DIR}/decide-gateway.log ; --foreground exec ; --stop kill pid
decide_gateway.py (server) -> llama: POST backend /v1/chat/completions per question ; GET backend /health
                           -> onnx : POST backend /v1/systemone (body {model,state(trunc),questions}) verbatim, response verbatim
onnx_server.py             -> onnxruntime session (CPU) + sentencepiece/tokenizers ; config.json id2label
lib/download.sh (not in this file set): download_profile -> capability decide ? _dl_smoke_test_decision (llama-server on :$LLMCTL_SMOKE_PORT(18090) + probes calling decide_build_prompt/query_logprobs/shape_response)
                                         : engine onnx ? _dl_validate_onnx (structure) -> _dl_smoke_test_onnx (python3 lib/onnx_server.py --host 127.0.0.1 --port $LLMCTL_SMOKE_PORT; NO --tokenizer, NO trap cleanup D-14; LLMCTL_ONNX_FAKE=1 bypasses dependency check)
lib/scheduler.sh: sched_rank_for_capability decide = "decide-tiny decide-nli decide-2b decide decide-pro decide-max" ; onnx arm (l.408-427) ; footprint onnx branch in catalog.sh (RAM size*1.5+512 MiB, VRAM 0)
tests: test_decide*.sh -> fixtures decide_server.py / onnx_decide_server.py ; test_onnx_server.sh -> onnx_server.py (fake) ; *_download.sh -> python -m http.server + download.sh
```
Catalog contract used: profile fields `engine` (llama|onnx), `capability` contains `decide`, `port` (8092 decide-tiny, 8093 decide, 8094 decide-pro, 8096 decide-nli, 8098 decide-2b, 8099 decide-max; gateway 8095 and 8097 are not catalog ports, so the unique-port test does not protect 8095), `defaults` (decide-tiny ctx 4096 ngl 99 parallel 4 kv q8_0; decide/pro/2b/max ctx 8192 parallel 2 kv q8_0; decide-nli ctx 512 ngl 0 parallel 1 flash_attn off), `files[].role` in {model, tokenizer, config}; decide-nli files: `onnx/model.onnx` 1,741,985,401 B, `onnx/spm.model` 2,464,616 B, root `config.json` 1,019 B (sha null), `tokenizer_config.json` 1,256 B (null), root `tokenizer.json` 8,656,646 B (null; unused, D-22).

---

## 4. Environment variables and CLI flags (all files, with defaults)

**Environment variables**

| Name | Default | Read by | Notes |
|---|---|---|---|
| LLMCTL_DECIDE_PROFILE | unset (decide-tiny if downloaded else decide) | decide.sh | |
| LLMCTL_DECIDE_PORT | 8095 | decide.sh, gateway | gateway default port |
| LLMCTL_DECIDE_TEMPERATURE | 1.0 | decide.sh, gateway | softmax divisor; <=0/invalid -> 1.0 |
| LLMCTL_DECIDE_NO_INTERACTIVE | 0 | decide.sh | 1 -> wizard rc 2 |
| LLMCTL_DECIDE_MAX_OPTIONS | 20 | decide.sh, gateway (import-time) | hard cap 26; ignored by onnx_server (D-10) |
| LLMCTL_DECIDE_TIMEOUT | 30 | decide.sh, gateway, download.sh probes | seconds |
| LLMCTL_DECIDE_API_KEY | unset | decide.sh, gateway, onnx_server, scheduler onnx arm | RETIRE -> LLMCTL_API_KEY (FR-057) |
| LLMCTL_DECIDE_MAX_STATE_CHARS | 8192 (0 disables) | gateway, onnx_server | head+tail |
| LLMCTL_DECIDE_BACKEND_HOST | 127.0.0.1 | decide.sh, gateway | TEST SEAM -> remove |
| LLMCTL_DECIDE_BACKEND_PORT | unset / 0 | decide.sh, gateway | TEST SEAM -> remove |
| LLMCTL_SEED | unset | decide.sh, gateway | int; invalid -> traceback (N-05) |
| LLMCTL_BIND_HOST | unset in Python (shell default 0.0.0.0 not exported) | gateway `--bind-host`, onnx `--host` defaults | gateway falls back to 127.0.0.1 |
| LLMCTL_ONNX_FAKE | unset | onnx_server, download.sh, tests | TEST SEAM -> remove from production |
| LLMCTL_DRY_RUN | 0 | decide_serve | prints `DRY-RUN: python3 ...` |
| LLMCTL_RUNTIME_DIR / LLMCTL_LOG_DIR / LLMCTL_MODELS_DIR | repo defaults | decide.sh | pidfile `decide-gateway.pid`, log `decide-gateway.log` |
| LLMCTL_SMOKE / LLMCTL_SMOKE_PORT(18090) / LLMCTL_SMOKE_TIMEOUT(120) | 1 / 18090 / 120 | download.sh | context |
| LLMCTL_HF_BASE, LLMCTL_CATALOG, LLMCTL_FAKE_HW | — | tests | existing repo seams |
| Doc-only/override names | | | `LLMCTL_PORT_<PROFILE>`, `LLMCTL_CTX_<PROFILE>` (no-op for onnx, N-20), `LLMCTL_KVTYPE_<PROFILE>`, `LLMCTL_BIND_HOST_<PROFILE>` |

**CLI flags**
- `llmctl decide ask|interactive`: `--profile P --type {noul|choice|score} --state S --state-file F --instructions I --criteria JSON [--json] [--interactive]`.
- `llmctl decide capacity|status`: `[--json]`. `llmctl decide serve`: `[--profile P] [--port N] [--api-key K] [--foreground] [--stop]`.
- `decide_gateway.py`: `--render-prompt --type --state --instructions --criteria --port --bind-host --backend-host --backend-port --profile --backend-engine {llama,onnx} --model-id --api-key --max-state-chars`.
- `onnx_server.py`: `--model-dir --port --host --api-key --profile --tokenizer --max-state-chars`.
- Fixtures: `decide_server.py [port=18092]`, `onnx_decide_server.py [port=18096]`.

---

## 5. HTTP surface found in the code (for contract drawing)

**Gateway (`decide_gateway.py`, plain HTTP/1.1, default 127.0.0.1:8095)**
- `GET /healthz` (no auth): `200 {"status":"ok","profile":"<p>"}` | `503 {"status":"backend unavailable"}`.
- `GET /v1/models` (auth when key set): `200 {"object":"list","data":[{"id":"jev-latest"|"jev-preview"|"llmctl-<p>"|<model_id>,"object":"model","owned_by":"llmctl"}]}` (deduplicated).
- `POST /v1/systemone` (auth when key set). Request: `{"model": <any, optional>, "state": <non-empty string>, "questions": {<name>: {"type":"noul|choice|score","instructions":<non-empty>,"criteria":<noul: {"true","false"} optional | choice: object >=2 keys | score: array 2..10>}}}`. Response 200: `{"model": <request model or "llmctl-<p>">, "answers": {<name>: <answer>}, "usage": {"input_tokens":int,"output_tokens":int,"total_tokens":int}}`; header `x-llmctl-decide-truncated: true` when state was cut. Answers: noul `{"type":"noul","noul":p}`; choice `{"type":"choice","choice":key,"probabilities":{key:p},"confidence":c}`; score `{"type":"score","score":float,"legend":{"0":desc,...},"probabilities":{"0":p,...},"confidence":c}`.
- Errors (all `{"error": <string>}`): 400 (`missing or oversized request body`, `request body is not valid JSON`, `body.state (string) is required`, `body.questions (object) is required`, `question '<n>' must be an object`, `question '<n>': type must be noul|choice|score`, `question '<n>': instructions is required`, `question '<n>': invalid criteria for type <t>`), 401 `unauthorized`, 404 `not found`, 502 (`backend query failed: <exc>` / `onnx backend query failed: <exc>` / ValueError text such as `no option letters found in backend top_logprobs`). Non-object JSON body -> no response (N/D-08). Other methods -> BaseHTTPRequestHandler 501.
- Auth: header `Authorization: Bearer <key>` exact-string compare; applies to `/v1/*` only.

**onnx runtime (`onnx_server.py`, default 127.0.0.1 via arg; scheduler passes catalog_bind_host)**
- `GET /health` (no auth): `200 {"status":"ok","profile":"<p>","fake":bool}`.
- `GET /v1/models` (auth): `{"object":"list","data":[{"id":"llmctl-<p>","object":"model","owned_by":"llmctl"}]}`.
- `POST /v1/systemone`: same request/response/usage/header as gateway; validation errors 400 (`question '<n>': <msg>` where msg from derive_options: `choice criteria must be an object with at least 2 options`, `score criteria must be an array of 2-10 ordered level descriptions`, `type must be noul|choice|score`, `<n> options exceeds the hard cap of 26`); 401; 404 (path checked before auth for POST, after nothing for GET). No 502/500 class.

**Backend llama-server use.** `GET /health`; `POST /v1/chat/completions` `{"messages":[{"role":"user","content":<prompt>}],"max_tokens":1,"temperature":0,"logprobs":true,"top_logprobs":max(n,5)[,"seed":int]}`; reads `choices[0].logprobs.top_logprobs[0][].{token,logprob}`.

**CLI machine output.** `decide ask --json`: the answer object plus `"model":"<profile>"` and `"evidence":{"server_port":int,"latency_ms":int}`; `decide capacity --json`: `{"tier","budgets","decision_instances":{<profile>:{"instances_gpu","instances_cpu","per_instance":{"slots","ram_mb","vram_mb"},"reason"?}}}`; `decide status --json`: `[{"profile","port","running":bool,"enabled":bool}]`.

---

## 6. NEW defect register (this pass; not in source-findings.md)

| Id | Sev | Status | Where | One line |
|---|---|---|---|---|
| N-01 | H | CONFIRMED-RUNTIME | decide.sh:107,184-186 | state as argv: >128 KiB fails rc 126; state visible in `ps` |
| N-02 | M | CONFIRMED | decide_ask | no state length handling/truncation signalling in CLI path |
| N-03 | M | CONFIRMED-RUNTIME | decide.sh:263; gateway:149 | `" a"`/`"I"` lower/upper-case collisions with option letters |
| N-04 | M | CONFIRMED-RUNTIME | decide.sh:273-287; gateway:158-172 | missing-A noul = 0.0; all -inf -> NaN + invalid JSON |
| N-05 | M | CONFIRMED-RUNTIME | decide.sh:208; gateway:233 | bad `LLMCTL_SEED` traceback / dropped connection |
| N-06 | M | CONFIRMED-RUNTIME | decide.sh:680 | wizard EOF kills calling shell silently (set -e) |
| N-07 | L | CONFIRMED | decide.sh:533,567 | capacity/status ignore unknown args |
| N-08 | L | CONFIRMED | docs/scripts/decide.md:175 | wrong function name |
| N-09 | L | INFERRED | docs/scripts/decide.md:102 | `read -p` prompt only on a TTY |
| N-10 | M | INFERRED/UNCONFIRMED | readout design | first-token assumption per model must be measured |
| N-11 | M | INFERRED | SC-001 | byte-identical repeats not guaranteed by temp 0 alone |
| N-12 | M | CONFIRMED (hang observed) | gateway:313-327; onnx:417-426 | unread body on error -> HTTP/1.1 keep-alive desync |
| N-13 | M | CONFIRMED | gateway:349-351 | upstream 401/4xx collapsed into 502 + exception text |
| N-14 | M | CONFIRMED | gateway:352-355 | proxy drops upstream truncation header |
| N-15 | M | CONFIRMED (+vendor claim) | gateway:335; onnx:434 | non-string `state` rejected; hosted allows object (vendor-stated) |
| N-16 | L | CONFIRMED-RUNTIME | gateway:54,419 | bad numeric env -> traceback at import/argparse |
| N-17 | L | CONFIRMED | gateway:399; onnx:470 | request `model` echoed unvalidated |
| N-18 | M | CONFIRMED | gateway/onnx | unbounded number of questions per request |
| N-19 | L | CONFIRMED | gateway:289-293 | unauthenticated /healthz probes backend each hit, leaks profile |
| N-20 | M | CONFIRMED | onnx_server.py:246 | catalog `ctx` ignored (MAX_LEN literal 512) |
| N-21 | M | CONFIRMED | onnx_server.py:118-150 | label-order detection weak (root config preferred, misleading source text, uncaught int()) |
| N-22 | M | CONFIRMED | onnx vs gateway | engine semantic drift (noul criteria, option cap, errors) |
| N-23 | L | CONFIRMED | onnx:399-401 | /health does not exercise inference |
| N-24 | M | CONFIRMED | onnx:459 | non-ValueError exceptions/NaN drop the connection |
| N-25 | M | CONFIRMED | tests/test_*_download.sh | fixed ports 18732/18733 |
| N-26 | M | CONFIRMED | test_onnx_download.sh:106; test_decide_download.sh:74 | tests assert D-12 "SUCCESS while skipped" as correct |
| N-27 | L | CONFIRMED | docs | test counts stale (55/36 vs 71/45) — static asserts 71/43(+loop=45)/10(9 run)/22(21)/25(+loop=28) |
| N-28 | L | INFERRED | research docs | mirror-derived "CONFIRMED"/"no sibling repo" claims not independent |
| N-29 | L | CONFIRMED | spec "41 test files" | real repo has 38 `tests/test_*.sh`; recount before SC-008 baseline |

Cross-check notes: D-08 reproduced for both servers (empty reply, curl rc 52, traceback in log). D-07 not reproduced (needs real model; `die()` at onnx_server.py:269 is read-confirmed). D-01 not reproduced (needs real tokenizer).

## 7. Candidates visible in the moved research files, for the FR-007 register

Verified-metadata-only (mirror data, not re-fetched) but **not named in source-findings H**: `Mapika/decider-2b-GGUF` (Q4_K_M 1,274,396,800 B, Q8_0 2,012,012,672 B), `chaoliangUNSW/Jev-Style-Qwen3.5-2B-Decision-GGUF` (Q4_K_M 1,312,156,768 B, Q8_0 2,076,666,976 B), `rizzoaiacademy/rizzo-flow` 1.7B Q8_0 (1,820,112,768 B) and 4B Q4_K_M (2,600,224,416 B), `alibiserikbay/JevK5-GGUF` 4B v0.3 Q4_K_M/Q5_K_M/Q8_0 and 9B Q5_K_M, `convaiinnovations/laya` (safetensors only), plus survey-only names in `jev-ecosystem.md` §2.6 (Open-Jev, SemIf, opendecider, Julia 1, GLiNER2.5-Decide, RSI-Jev, fern, Winnow-12B, AnyJev, CLM-8B, Bosun, Jev-Japanese-Judgment, Argos1111/jev_local, ekzhang/openjev, kev). Each needs a recorded outcome; none verified by us.
