## Overview

`tests/test_decide_service.sh` covers the decision gateway and encoder runtime
as boot-time user services on both operating systems (FR-031, FR-083, G-028,
G-041).

* **Linux**: the generated `llmctl-decide-gateway.service` and the three engine
  templates are inspected (restart limits in `[Unit]`, hooks, memory policy
  OD-14 = no cap below physical RAM, only verified hardening directives, no key
  material) and run through `systemd-analyze --user verify` with a control
  needle (a unit with the historical `StartLimitIntervalSec`-in-`[Service]`
  defect must be flagged, otherwise a clean result would prove nothing). The
  per-start key rotation hook runs for real.
* **macOS**: no Mac is available to this suite, so `launchctl` is never
  executed. The LaunchAgent files for the gateway and the encoder runtime are
  produced by the real backend code and validated structurally (`plistlib`,
  mode 0600, `ProgramArguments` array, `KeepAlive`, `ThrottleInterval`, no key
  in the file or its arguments) plus the dry-run `launchctl` command lines.
  The run prints an explicit SKIP for "launchd actually loads and runs them"
  (gap G-009; registry liveness on macOS uses `ps -o args=` and is only
  fixture-tested).
