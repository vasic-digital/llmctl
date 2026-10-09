## Overview

`lib/decide_timeout.sh` is the launcher-side, CPU-adaptive default for the decision
gateway's per-request deadline (gap G-156). The Go default `LLMCTL_DECIDE_TIMEOUT` is 8 s,
deliberately below the hosted SDK's 10 s timeout, and that contract does not change. A
decision engine placed on CPU answers in 7-22 s on the measured reference host, so with
8 s a CPU host returned HTTP 502 `deadline_exceeded` for most requests. The launcher
therefore exports a longer deadline *only* when it can see a CPU-placed decision instance.

It is sourced by `lib/svc_hook.sh` (`run-gateway`: the systemd unit / launchd agent) and
`lib/decide.sh` (`decide_serve`: `llmctl decide serve`), the two ways the gateway starts.
Never invoked by users directly.

## Prerequisites

* `lib/common.sh` already sourced (`LLMCTL_SERVICES_DIR`, `LLMCTL_RUNTIME_DIR`).
* Instance env records under `$LLMCTL_SERVICES_DIR/*.env` (written by `svc_write_env`).

## Usage examples

```sh
source lib/decide_timeout.sh
decide_timeout_adapt          # always returns 0
echo "${LLMCTL_DECIDE_TIMEOUT:-unset} ${LLMCTL_DECIDE_TIMEOUT_SOURCE:-}"
```

Exports, only when the rule fires: `LLMCTL_DECIDE_TIMEOUT=120`,
`LLMCTL_DECIDE_TIMEOUT_SOURCE=cpu-adaptive`, `LLMCTL_DECIDE_TIMEOUT_NOTE=<profiles>`
(space-separated CPU-placed profiles, display only). The gateway banner prints the
effective value and its source (`default` | `cpu-adaptive` | `env`).

## Edge cases

* An explicit `LLMCTL_DECIDE_TIMEOUT` (environment, the `gateway.conf` EnvironmentFile,
  plist env) always wins and is left untouched; an inherited `SOURCE`/`NOTE` is dropped so
  the banner cannot mislabel it.
* A pure-GPU host exports nothing, so the Go default (8 s) applies.
* The `onnx` encoder (`decide-nli`) never triggers the rule (measured median 433 ms).
* Only instances that are running (reservation file) or enabled (autostart marker) count; a
  stale record of a stopped, never-enabled instance does not widen the deadline.
* CPU placement = the llama layer-offload flag (`--n-gpu-layers`, `--gpu-layers`, `-ngl`, with
  a space or `=`) whose last occurrence is `0`; a value above 0 or no flag is not CPU.
* The deadline is ONE global value: a single CPU llama instance raises it for all profiles.
  An instance started after the gateway does not change a running gateway; restart it.

## Internal behaviour

Reads the persistent instance env records (not only tmpfs reservations) so a gateway that
boots before any llmctl command still sees the placement. `_dta_get` reads a raw key,
`_dta_is_cpu` classifies one instance, `decide_timeout_adapt` applies the rule.

## Related scripts

`lib/svc_hook.sh`, `lib/decide.sh`, `docs/decide-gateway.md`, `docs/persistent-services.md`,
`tests/test_decide_timeout_adapt.sh`, `cmd/llmctl-decide/cmd_serve_timeout_banner_test.go`.

## Last verified date

2026-10-09
