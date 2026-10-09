# Persistent decision services on anton (2026-10-09)

Host: 31 GB RAM (about 21 GB available), RTX 3060 12 GB (about 1.9 GB VRAM free after this), planner tier `below-minimum`.
Done with the working tree as is (uncommitted CPU-adaptive timeout changes); `build/llmctl-decide` was rebuilt
(it predated the banner change) under `bounded-run -m 4G`.

## Planner numbers (llmctl plan --json / decide capacity --json, before starting)
Budget: RAM 20892 MB, VRAM 4057 MB (live). decide-nli: cpu, 3006 MB RAM, tier_ok. decide-kev-08b: gpu, 2048 MB RAM + 2900 MB VRAM
(measured), 1 GPU instance, tier_ok. Left disabled: decide/decide-2b (tier_ok false, unmeasured), decide-pro 5260 MB cpu (tier_ok false),
decide-max 10174 MB cpu (tier_ok false), decide-kev-4b (does not fit, 4906 MB VRAM), decide-kev-9b (7088 MB RAM + tier gate),
decide-lev 3926 MB VRAM (tier gate), decide-julia/laya/tiny fit but were not requested.

## What runs (all enabled, WantedBy=default.target, Linger=yes)
| Unit | Limits (drop-in 10-hostsafety.conf) |
|---|---|
| llmctl-decide-gateway.service (https://127.0.0.1:8095, key in repo .env 0600, CA in ~/llmctl/cert/ca/ca.crt) | MemoryHigh 1.5G, MemoryMax 2G, TasksMax 512 |
| llmctl-onnx@decide-nli.service (127.0.0.1:8096) | 6G / 8G, TasksMax 1024 |
| llmctl-llama@decide-kev-08b.service (127.0.0.1:8104) | 3G / 4G, TasksMax 512 |
llmctl-llama@vision untouched (same MainPID 2842).

## Host-local deviations
* `~/.local/state/llmctl/decide/gateway.conf`: `LLMCTL_DECIDE_NATIVE=1` (needed to serve kev-08b), `LLMCTL_DECIDE_BIND=127.0.0.1`
  (without it the gateway binds 0.0.0.0).
* `services/decide-nli.env`: `LLMCTL_REG_HEALTH=/health` replaced by `/healthz` (host-local, historical; source now uses `/readyz`) (see findings).
* Gateway unit installed by calling `decide_service_enable` from lib/service_linux.sh directly.

## Findings (not fixed in source, no commits made)
1. `onnx` engines register with health path `/health` (lib/portreg.sh) but lib/onnx_server.py serves `/healthz`; the post-start waiter never registers decide-nli. Fixed host-locally only; a fresh `llmctl enable decide-nli` rewrites the env file and re-breaks it.
2. `decide_service_enable` has no CLI entry: `llmctl decide serve --enable` (named in the comment) does not exist.
3. The 120 s CPU-adaptive timeout fires here because decide-nli is CPU-only (gateway log line in gateway-timeout-banner.txt); kev-08b alone is GPU.

## Addendum 2026-10-09 (later): the three findings addressed in source, services re-verified (uncommitted tree)

Source changes (not committed): `portreg_health_path` in `lib/portreg.sh` (single source: llama `/health`, onnx `/readyz` (changed from `/healthz` after review: `/healthz` is liveness only),
colibri `/v1/models`) used by `portreg_env_lines`, `_sched_registry_publish` and the scheduler readiness waits for decision
profiles (`lib/scheduler.sh`); `llmctl decide serve --enable [--now] | --disable` in `lib/decide.sh` (`decide_serve`,
`decide_serve_service`); docs, CHANGELOG line; gaps-register: G-069 is FIXED-PENDING-VERIFY (not closed; open items listed there), G-162 opened.

* Finding 1 (onnx health path): RED, `tests/test_health_path_engines.sh` before the fix: 5 failures (`portreg_env_lines onnx` gave `/health`,
  the registration waiter never registered a stub that serves only `/healthz`, `portreg_health_path` missing). After: `OK`. Mutation (onnx branch
  reverted to `/health`): 3 failures. A fresh env record for an onnx engine, written into a scratch `LLMCTL_STATE_DIR` through `svc_write_env`,
  carried `LLMCTL_REG_HEALTH=/healthz` when this was first recorded (historical observation; superseded by the review fix below, the code now writes `/readyz` via `portreg_health_path`).
  The recorded host file `units/decide-nli.env` still has `LLMCTL_REG_HEALTH=/healthz` (verified by reading that file in this directory; the live host was not touched), so it is NOT identical to what a fresh enable writes now (`/readyz`); it keeps the old path until `decide-nli` is re-enabled.
* Finding 2 (`decide serve --enable`): `tests/test_decide_serve_enable.sh` (stubbed `systemctl`/`loginctl`, temp unit dir, no real unit created):
  enable, idempotent re-enable, disable, idempotent disable, stale-template refusal (mutation: refusal removed -> 6 failures), usage errors,
  help text; macOS is a dry run only (no Mac).
* Finding 3 (about 30 s with only kev-08b listed): cause UNCONFIRMED, recorded as G-162. Gateway-side caches are 1 s (registry Watch, probe TTL),
  `Models()` is uncached, `NLIDegradedFor` (30 s) only marks an instance `degraded` and it stays listed. The one 30 s in the path is the registry
  reconciler grace: reproduced read-only with the real `llmctl-decide registry` against a stub serving only `/healthz` (scratch state dir): an
  entry registered at `/health` shows `unhealthy` at the first two reconciles and is `removed ... (grace 3s): unhealthy status code: 404` at
  the third (default grace 30 s). That is the same wrong-health-path mechanism as finding 1; it was not re-observed live.
* Live re-verification (`addendum-2026-10-09b/`): `systemctl --user restart llmctl-decide-gateway.service`; banner now
  `timeout: 8s per request (default; set LLMCTL_DECIDE_TIMEOUT to change)` (`gateway-banner.txt`; was 120 s cpu-adaptive: the ONNX encoder no
  longer counts as CPU-placed); `llmctl decide models` listed decide-kev-08b and decide-nli both `ready` on the first poll, about 2 s after the
  restart (`models.txt`); three real asks, rc 0: decide-nli choice (degraded, 0.984, 308 ms), decide-kev-08b noul (0.320), decide-kev-08b score
  (1.519 on 5 levels). Two first attempts were my own malformed `--criteria` (HTTP 422 validation_failed) and were repeated with the right shape.
  No engine was started or restarted; the engines kept their processes.
* Regression runs (each under `bounded-run -m 4G`, one at a time): test_decide_service, test_decide_serve_enable, test_health_path_engines,
  test_service_ops_hardening, test_decide, test_dynamic_ports, test_decide_scale, test_docs_audit, test_doc_reachability, test_decide_timeout_adapt all pass.

## Addendum 2026-10-09 (review fixes)
* onnx health path changed from `/healthz` to `/readyz`: `/healthz` is liveness only (200 even when the load-time smoke failed, `/v1/score` then answers 503 `not_ready`); `/readyz` is 200/503 truthfully. The waiters use `curl -f`, so a 503 while the model loads just means "keep waiting"; nothing is registered before the first 200. (The recorded `units/decide-nli.env` on anton still says `/healthz`; the live record keeps it until re-enabled; a fresh enable writes `/readyz`. Not re-verified live after the change.)
* `decide serve --enable`: a re-enable over a changed unit now does `try-restart` (previously the old definition stayed in force); `--enable` under `LLMCTL_DRY_RUN=1` writes no unit/plist; macOS boots the label out (failure ignored) before bootstrap.
* Real round trip on this host: `addendum-2026-10-09b/serve-enable-real-roundtrip.txt`.
