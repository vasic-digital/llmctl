## Overview

`lib/svc_hook.sh` holds the small commands the generated systemd units call
(and the macOS gateway agent runs). They exist because a unit cannot allocate a
port, rotate a key or register a service by itself. Never invoked by users.

| Command | Called from | What it does |
|---|---|---|
| `prestart <instance>` | `ExecStartPre=` | Re-creates the engine's internal key file (0600 file, 0700 directory, 256 bits from `/dev/urandom`, atomic replace) on **every** start - a true per-start key (gap G-028). A service without a key file is a no-op that succeeds. |
| `register <instance>` | `ExecStartPost=-` | Detaches a waiter that registers the service in the registry once its health endpoint answers (bounded by `LLMCTL_REGISTER_WAIT`, default 600 s); returns at once so `systemctl start` is not held for a model load. |
| `unregister <instance>` | `ExecStopPost=-` | Removes the registry row; the port hold stays so a restart reuses the port. `unregister gateway` also clears the gateway's own row (`decide-gateway`). |
| `run-engine <instance> -- <cmd...>` | `ProgramArguments` of a macOS engine plist | launchd has no `ExecStartPre`/`ExecStartPost`, so the plist runs the engine through this wrapper: rotate the key (as `prestart`), start the detached registration waiter for **this shell's pid** (`hook register <instance> $$`), then `exec` the engine command - the pid is unchanged by `exec`, so the registry row proves the engine's real process. A launchd `KeepAlive` respawn re-runs the wrapper and therefore **re-registers the service** (C-13), exactly like a systemd `Restart=always`. Without `setsid(1)` (macOS) the waiter runs under `nohup`. |
| `run-gateway` | `ExecStart=` of the gateway unit / plist | Allocates the gateway port (fixed 8095 by default, dynamic on `LLMCTL_PORT_STRATEGY=dynamic` / `LLMCTL_PORT_GATEWAY=auto`), selects registry-based backend resolution (`LLMCTL_DECIDE_RESOLVER=registry`) and `exec`s `llmctl-decide serve --foreground`, which publishes itself (`kind=gateway`). |

The instance env record (`$LLMCTL_SERVICES_DIR/<instance>.env`) is **parsed**,
never sourced. Hook activity is appended to `$LLMCTL_LOG_DIR/svc_hook.log`.
Key directories (C-14): `prestart` tightens a directory to 0700 only when it
is under `$LLMCTL_STATE_DIR/keys` (llmctl's own) or was created by the hook
itself; the existing parent of an operator-supplied key path
(`LLMCTL_ONNX_KEY_FILE=~/onnx.key`) is never chmod-ed, so `$HOME` cannot be
turned into 0700. No key value is ever printed or passed on a command line: only key-file paths.

## Verification

`tests/test_decide_service.sh` (rotation, no-op cases, file modes),
`tests/test_service_ops_hardening.sh` (`run-engine` registration / respawn
re-registration against the real registry, key-directory modes) and the live
transcript in `docs/qa/dynamic-ports-validation/` (real systemd user manager).

## `run-engine` library path (G-129)

`run-engine` calls `hk_engine_libpath <exe>` just before the final `exec`: when the engine's directory ships `libggml*` (a
llama.cpp shared-library build, found through RUNPATH, which ranks below `LD_LIBRARY_PATH`) the directory is PREPENDED to
`LD_LIBRARY_PATH` (and `DYLD_LIBRARY_PATH` on Darwin), keeping the caller's other entries. Without it a caller whose
`LD_LIBRARY_PATH` names a system directory with another `libggml.so.0` makes the engine die with `undefined symbol
ggml_flash_attn_ext_set_n_kv_max` (reproduced: `specs/009-jev-decision-models/evidence/live/g129-ldd-repro.txt`). Engines
without `libggml*` beside them are untouched. The Linux unit already sets `LD_LIBRARY_PATH=<engine dir>` in its
EnvironmentFile (`svc_write_env`). Test: `tests/test_service_ops_hardening.sh` (G-129). The macOS path was verified
statically only (no Mac).

## Health path used by `register` and `run-gateway` (G-162 follow-up)

`register` waits for, and registers, a service at the path from `portreg_health_path` (llama `/health`, colibri `/v1/models`, onnx `/readyz`), read from the instance env record's `LLMCTL_REG_HEALTH`. A record written before the fix may still say `/health` for an onnx profile; re-run `llmctl enable <profile>` to rewrite it. `run-gateway` sources `lib/decide_timeout.sh` and applies the CPU-adaptive request deadline (`docs/scripts/decide_timeout.md`) before starting the gateway.
