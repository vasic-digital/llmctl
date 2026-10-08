## Overview

`tests/test_service_ops_hardening.sh` covers the operational shell layer around the service units
(review-2 scope C). Stand-ins, on purpose and only for the OS service manager: a small `systemctl`
script that answers `is-active` / `show MainPID` for named units and records every call. The registry,
the Go binary, the hook scripts and the generated unit text are the real ones.

| Section | What it proves |
|---|---|
| C-05 | tenant mode: `svc_known_profiles` yields this tenant's profile names, the unit name carries the tenant prefix once (no `acme--acme--` in any `systemctl` call), `portreg_live_set` reports the registered instance key, `registry diff` says `registry == live set` — and still reports a live service without a row (control) |
| C-12 | `decide_service_disable` under `LLMCTL_DRY_RUN=1` leaves the real unit file / macOS plist alone; a real disable removes it |
| C-18 | units generated with a state dir containing a space, `%` and `"` quote `Environment=` as one word, double `%`, escape `"`, quote the hook path; a live transient systemd unit reads the quoted value back byte for byte; `systemd-analyze verify` accepts the unit |
| G-067 | a stale installed unit (`StartLimit*` in `[Service]`) is named by `svc_stale_units`, `llmctl doctor` WARNs, `llmctl install` regenerates it and the WARN disappears |
| G-074 | an https row with no CA is `unknown`, `llmctl doctor` WARNs naming it and the `--prune-unknown-after` remedy; the option keeps it before the window, removes it after, with the reason |
| C-13 | `svc_hook.sh run-engine` registers the exec'd engine under its real pid, the row survives `registry reconcile` (identity + start-time fingerprint hold after `exec`), and a respawn (the same ProgramArguments again) re-registers; the macOS plist is wrapped by the hook |
| C-14 | the hook never chmods the existing parent of an operator-supplied key path; directories it creates, and llmctl's own `keys/` directory, are 0700 |

Each assertion was shown to fail against a mutation of the corresponding fix.

## Prerequisites

`go`, `python3`, `bash` (SKIP-SUITE otherwise); `systemd-run` / `systemd-analyze` are used when present.

## Usage examples

```sh
bash tests/test_service_ops_hardening.sh
```

## Edge cases

No real user unit is touched: the transient unit used for the quoting read-back is removed by systemd when
it exits; all state lives under a temp dir.

## Internal behaviour

See the table; the Go binary is built into the temp dir once.

## Related scripts

`lib/service_linux.sh`, `lib/service_macos.sh`, `lib/svc_hook.sh`, `lib/portreg.sh`, `lib/doctor.sh`,
`internal/registry`.

## Last verified date

2026-10-07

Round 3 adds: a second tenant's and a non-tenant registry row do not fail a tenant's diff while an own stale row still does
(C2-03); a unit lacking directives the generator now writes is stale, values-only differences are not (C2-11); `$` is
doubled in ExecStart words but not in `Environment=` (C2-12).
