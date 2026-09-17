## Overview

`tests/test_services.sh` is the general (non-crash-loop) test for
service-unit / launchd-plist generation across both supported OS
backends — `lib/service_linux.sh` (systemd `--user` template units) and
`lib/service_macos.sh` (launchd `LaunchAgents`). It proves the generated
unit/plist content matches this project's documented operational model:
restart policy, resource-ceiling directives, environment-file wiring,
log-file paths, and dry-run behavior for lifecycle actions
(`enable`/`start`).

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Sets `LLMCTL_DRY_RUN=1` and
  `LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"` for
  the whole file.
* Sources, in isolated subshells, `lib/common.sh`, `lib/os_detect.sh`,
  `lib/hardware.sh`, and either `lib/service_linux.sh` or
  `lib/service_macos.sh`, calling their `svc_install` /
  `svc_write_env` / `svc_enable` functions directly.
* Relies on `test_setup_env`'s isolated `LLMCTL_UNIT_DIR`,
  `LLMCTL_PLIST_DIR`, `LLMCTL_SERVICES_DIR` (per-profile `.env` files),
  and `LLMCTL_LOG_DIR`.
* Requires `python3` for one assertion: parsing the generated plist with
  `plistlib.load(...)` to confirm it is valid, well-formed XML.

## Usage examples

```bash
bash tests/test_services.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test`.

## Edge cases

* **Linux systemd `--user` template units**: after `svc_install`, asserts
  the llama unit (`llmctl-llama@.service`) contains `Restart=always`,
  `RestartSec=5`, `StartLimitBurst=5` (FR-044 bounded restarts),
  `StartLimitIntervalSec=60` (FR-044), an `EnvironmentFile=` line
  pointing at the per-profile `.env` template, an
  `ExecStart=${LLMCTL_EXEC} ${LLMCTL_ARGS}` line sourced from that env
  file, and an `append:${LLMCTL_LOG_DIR}/%i.log` log-append directive.
* **Full-hardware `MemoryMax`/`MemoryHigh` (operator decision, Phase 6
  T035, 2026-09-15)**: on the baseline fixture (32768 MiB total RAM),
  asserts `MemoryMax=32768M` and `MemoryHigh=32768M` — i.e. served-model
  resource limits carry **no artificial ceiling below hardware
  capacity**: a served profile gets the full probed hardware and maximal
  performance, and `MemoryHigh` equals `MemoryMax` (no soft-throttle zone
  below the hard cap). This is explicitly called out as distinct from,
  and not the same mechanism as, the planner's RAM/VRAM admission-control
  budgets — see `docs/architecture.md`'s memory-model note.
* **Colibri unit installed too**: asserts
  `llmctl-colibri@.service` exists and contains the expected
  description text.
* **Env-file generation for a llama profile**: after `svc_write_env fast
  llama <exec> --model ... --port 8080 --ctx-size 8192 --n-gpu-layers 99
  --flash-attn auto --parallel 1 --jinja`, asserts the generated
  `fast.env` file contains `LLMCTL_ENGINE=llama`, `--port 8080`, and
  `--n-gpu-layers 99` among its args.
* **Dry-run lifecycle prints instead of executes**: `svc_enable fast`
  under `LLMCTL_DRY_RUN=1` produces the literal captured lines
  `"[dry-run] systemctl --user enable llmctl-llama@fast.service"` and
  `"[dry-run] systemctl --user start llmctl-llama@fast.service"` —
  proving no real `systemctl` invocation occurs.
* **macOS launchd plist generation**: after `svc_write_env` via
  `lib/service_macos.sh`, asserts the generated
  `com.llmctl.fast.plist` contains the correct `<string>com.llmctl.fast</string>`
  label, a `<key>KeepAlive</key>` entry, a `<key>ThrottleInterval</key>`
  entry with value `<integer>60</integer>` (bounded restart rate,
  FR-044), the port argument rendered as separate `<string>--port</string>`
  and `<string>8080</string>` array elements, and the correct
  `${LLMCTL_LOG_DIR}/fast.log` path.
* **Plist is genuinely valid XML**: parses the generated plist with
  Python's `plistlib.load` and asserts the parse succeeds (`rc == 0`) —
  not merely that the expected substrings are textually present, which
  would not catch a malformed-XML regression.
* **macOS dry-run enable**: `svc_enable fast` on the macOS backend
  produces the captured line
  `"[dry-run] launchctl bootstrap"`.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`;
   export `LLMCTL_DRY_RUN=1` and the baseline `LLMCTL_FAKE_HW` fixture.
2. In a subshell: source `common.sh`, `os_detect.sh`, `hardware.sh`,
   `service_linux.sh`; call `svc_install`.
3. Assert the llama and colibri unit files' contents (restart policy,
   `StartLimitBurst`/`IntervalSec`, `MemoryMax`/`MemoryHigh`,
   `EnvironmentFile`, `ExecStart`, log path, colibri description).
4. In a fresh subshell: source `common.sh`, `service_linux.sh`; call
   `svc_write_env fast llama ...` with a representative llama launch
   command line; assert the resulting `fast.env`'s contents.
5. In a fresh subshell (its stdout captured): source `common.sh`,
   `os_detect.sh`, `hardware.sh`, `service_linux.sh`; call
   `svc_enable fast`; assert the captured dry-run enable/start lines.
6. In a fresh subshell (its stdout captured): source `common.sh`,
   `service_macos.sh`; call `svc_write_env fast llama ...`; assert the
   generated plist's contents, then separately invoke `python3
   -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))'`
   against the plist path and assert exit code `0`.
7. In a fresh subshell (its stdout captured): source `common.sh`,
   `service_macos.sh`; call `svc_enable fast`; assert the captured
   `launchctl bootstrap` dry-run line.
8. `test_finish` tears down the temp environment and exits non-zero iff
   any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately).
* Exercises `lib/service_linux.sh` (`svc_install`, `svc_write_env`,
  `svc_enable`) and `lib/service_macos.sh` (`svc_write_env`,
  `svc_enable`), on top of `lib/common.sh`, `lib/os_detect.sh`,
  `lib/hardware.sh`.
* Reads `tests/fixtures/hw-baseline.json`.
* Sibling test `tests/test_services_crashloop.sh` covers the
  crash-loop-specific restart-limit and `sched_status` surfacing
  behavior on top of the same two service backends.
* Sibling test `tests/test_tenant_service_isolation.sh` covers the
  per-tenant systemd-slice extension to `lib/service_linux.sh`'s unit
  naming/drop-in mechanism this file does not exercise.
* Cited by `docs/architecture.md`'s "Service backends" section.
* Discovered and run automatically by `tests/run_tests.sh`; syntax and
  shebang/strict-mode covered by `tests/test_syntax.sh`.

## Last verified date

2026-09-17
