## Overview

`tests/test_decision_capacity.sh` proves SC-010 / FR-027 / FR-028 of spec
009 offline: the `decision_instances` capacity report in `plan --json` equals
what the scheduler's admission logic actually accepts. For every decision
profile on every hardware fixture (`tests/fixtures/hw-*.json`) and both
placements it calls the real `sched_decision_probe` (lib/scheduler.sh),
which counts how many instances `_sched_admission_fits` - the predicate
`llmctl start` uses - accepts one at a time on an otherwise idle budget,
and requires that count to equal `instances_gpu` / `instances_cpu`, and the
refusal of the next instance to carry the exact numbers (or the tier-gate /
not-applicable reason). No admission arithmetic is re-implemented in the
test.

## Prerequisites

* `bash`, `python3`; sources `lib/common.sh`, `os_detect.sh`, `hardware.sh`,
  `catalog.sh`, `scheduler.sh`. Hermetic: `LLMCTL_FAKE_HW` fixtures, temp
  state dirs from `tests/helpers.sh`; no network, no services.

## Usage examples

```bash
bash tests/test_decision_capacity.sh
```

## Edge cases

* The probe is read-only: the test asserts no `.run` reservation or service
  file appears.
* Paired mutations: a report one instance too generous or too small is
  detected by the same comparison.
* The tier gate: a tier-gated profile accepts 0 instances (as the report
  says) while a plain `llmctl start <profile>` stays allowed when it fits
  (tested in `tests/test_scheduler.sh`).
* A fixture file that is absent is an explicit SKIP, never a silent pass.

## Internal behaviour

Mismatch lines name the fixture, profile, placement, report value and
admission value. The assertion count is produced by a real run; use
`scripts/doc_counts.sh --check decision_capacity` rather than a hand-typed
number.

## Related scripts

`lib/scheduler.sh`, `lib/catalog.sh`, `tests/test_planner.sh`,
`docs/hardware-tiers.md`, `scripts/doc_counts.sh`.

## Last verified date

2026-10-07
