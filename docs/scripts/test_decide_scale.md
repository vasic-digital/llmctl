## Overview

`tests/test_decide_scale.sh` (T135 / T071, OD-23, FR-027..FR-029) covers `llmctl decide scale <profile> <N>`: validation, all-or-nothing admission, instance keys, scale up and down, deterministic versus throughput mode, rollback on a failed switch, and port allocation through the registry. Measured with `scripts/doc_counts.sh --check decide_scale`: **78 passing assertions** (no failures, no skips).

## Prerequisites

* `tests/helpers.sh`, `python3`; runs with `LLMCTL_DRY_RUN=1` (no systemd call, no engine, no server) and hardware from `tests/fixtures/hw-baseline.json`. Nothing is downloaded.
* The port registry is driven through a recording stand-in for `llmctl-decide` (unit tier). The admission arithmetic is not re-implemented: the expected refusal numbers are those pinned by `tests/test_decision_capacity.sh` for the same fixture.

## Usage

* Standalone: `bash tests/test_decide_scale.sh`; also run by `make test`.
* Check the documented count: `bash scripts/doc_counts.sh --check decide_scale`.

## What it proves

* Usage errors exit 2 (no args, no N, non-numeric, negative); an unknown profile or a chat profile exits 1; validation failures start nothing.
* Scaling past the admission bound exits 3 with the exact RAM/VRAM figures, and writes no reservation and no service env.
* Scale to 2 creates reservations `decide` and `decide.2`, the primary keeps port 8093, the second port is distinct, each instance has its own internal key file, and the deterministic mode is stated. Re-running is an idempotent no-op; running instances' reservations are subtracted from admission.
* Scale down stops the highest instance first and leaves no env behind. Throughput mode is named and the `x-llmctl-decide-mode: throughput` marking is stated; an invalid mode is refused.
* A failed `switch` restores scaled instances (rollback keeps `decide` and `decide.2`; `status` shows `decide #2`; `status --json` lists the base profile and the instance key). A secondary that cannot restart never costs the primary (rc 75, the unrestorable instance is named).
* A profile the plan marks as not fitting is refused with exit 3 and the real reason.
* With the registry active, ports come from `port allocate`; an allocator failure, a start failure and a failed `svc_stop` all roll back, release the port hold and leave no stray env; best-effort restore cleans the failed secondary. Without the allocator a real run refuses to guess a port.

## Mutations / control needles

Failure injection hooks (`LLMCTL_FAKE_START_FAIL`, `LLMCTL_FAKE_STOP_FAIL`, `STUB_FAIL_ALLOC`) provide the negative paths; each failure case asserts both the rc and the absence of side effects (empty reservation list, absent env files), so a silent no-op cannot pass.

## What it does NOT prove

* No real engine start, no systemd unit behaviour, no real port allocator (it has its own Go tests), no real model memory use.

## Related

[test_decision_capacity](test_decision_capacity.md), [test_decide_service](test_decide_service.md), [scheduler](scheduler.md).
