## Overview

`tests/test_systemd_cleanliness.sh` (G-088) proves that the suites which talk to the `systemd --user` manager leave
no `llmctl*` unit behind: it snapshots the names `systemctl --user list-units --all 'llmctl*'` reports, runs
`tests/test_unit_hardening.sh` and (with go) `llmctld/internal/isolation` `TestWrapCommand_RealSystemdRunInvocation`
(which creates `llmctl.slice` / `llmctl-tenant.slice` / `llmctl-tenant-cgrouptest.slice`), snapshots again and asserts
`after - before` is empty. Only `llmctl*` names are compared.

The detector is proven with a control needle first: a deliberately leaking failed transient unit
`llmctl-cleanliness-leak-<pid>` must be reported, then is removed by that exact name.

## Prerequisites

`bash`, `systemd-run`/`systemctl` with a reachable user manager (otherwise `SKIP-SUITE: ...`), `go` for the slice part.

## Usage examples

```bash
bash tests/test_systemd_cleanliness.sh
```

## Edge cases

* If `llmctl*.slice` units were already active before the run (a real tenant, an earlier leak) the "created by this
  run" part of the slice teardown is not provable: it prints an honest SKIP naming that, never a pass.
* The Go test stops only the slices that were NOT active before it ran, by exact name, deepest first.

## Internal behaviour

Fixes: `tests/test_unit_hardening.sh` names its transient units, starts them `--collect`, and its EXIT trap stops +
reset-fails exactly those names; `TestWrapCommand_RealSystemdRunInvocation` registers a `t.Cleanup` that stops the
tenant slices it created.

## Related scripts

`tests/test_unit_hardening.sh`, `docs/scripts/test_unit_hardening.md`.

## Last verified date

2026-10-07
