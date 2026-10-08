# `test_scheduler_switch_safety.sh`

## Overview

Source: `tests/test_scheduler_switch_safety.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_scheduler_switch_safety.sh - RED-then-GREEN regression test for a
real, live-reproduced defect (2026-09-22): `llmctl switch <profile>`
stopped EVERY currently-running profile first, then tried to start the
requested one - and if that start failed for ANY reason (budget gate,
systemd refusing the unit, etc.), the host was left with ZERO running
llmctl services and NO automatic recovery. Live repro on the diagnosing
host: `llmctl switch fast` stopped small+vision (both healthy, verified,
serving real traffic), then failed to start fast with "needs 5716 MiB
RAM ... but only 0 MiB RAM ... remain" - and the error's OWN suggested
fix was "llmctl switch fast", the exact command that had just failed,
leaving the operator to manually run `llmctl start small` to restore
service. A switch that can strand the host with FEWER running services
than before it was attempted defeats the entire point of "switch on
demand" - the whole promise is that trying a different profile is safe.

This test exercises the SYSTEMD-REFUSAL failure path (svc_start
returning false, e.g. "llmctl install" was never run for that profile's
unit template) rather than the budget-gate path the live incident hit -
both are real _sched_start_impl failure modes and both must trigger the
SAME rollback wrapper in _sched_switch_impl, so covering one hermetically
is a faithful regression test for the wrapper itself; the budget-gate
path already has its own separate, real, live-captured evidence from
this session (see the commit message for the fix this test accompanies).
```

Run: `bash tests/test_scheduler_switch_safety.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh scheduler_switch_safety` (see [doc_counts](doc_counts.md)).
