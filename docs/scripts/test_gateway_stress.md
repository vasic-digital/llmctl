## Overview

`tests/test_gateway_stress.sh` (T083, FR-078) is a bounded load scenario against the real `llmctl-decide serve` process, in front of the in-repo fake engine (`internal/gateway/internal/fakebackends`; no model, no real inference), over real HTTPS on loopback. Measured with `scripts/doc_counts.sh --check gateway_stress`: **12 passing assertions** (no failures, no skips).

## Prerequisites

* `go`, `curl`, `python3` (otherwise `SKIP-SUITE`); `tests/helpers.sh`.
* Builds the real gateway and the fake backend, uses an isolated HOME/state, a generated key and certificate, a two-profile fixture catalog and concurrency 1, queue 1, drain grace 10 s. The request count is fixed (6 + 1); nothing is downloaded and nothing outside loopback is touched.

## Usage

* Standalone: `bash tests/test_gateway_stress.sh`; also run by `make test`.
* Check the documented count: `bash scripts/doc_counts.sh --check gateway_stress`.

## What it proves

* `/readyz` is 200 when idle.
* Backpressure: a burst of 6 slow requests is answered only with 200 or 529; every 529 carries `Retry-After`; at least one request is shed and at least two complete; `/healthz` stays 200 while saturated; `/readyz` recovers to 200.
* Bounded memory: the gateway's resident set is above 0 and below 200 MB.
* Graceful stop: with a request in flight, `serve --stop` flips readiness (503, or 000 while the process is still alive and draining), the in-flight request completes with 200 inside the grace period, the process exits, and the listener is closed.

## Mutations / control needles

The shed and completion counts are asserted as lower bounds (a burst that was never shed would FAIL "backpressure not exercised"), and the readiness flip requires the process to still be alive, so a crash cannot pass as a drain. The 503 body itself is not observable over HTTPS after the listener closes; it is asserted in-process by the Go test `TestGracefulDrain`.

## What it does NOT prove

* Throughput, latency percentiles or behaviour with a real engine and model; the exact 200/529 split depends on timing (only the bounds are asserted).
* Behaviour beyond a 6-request burst or on a non-loopback interface.

## Related

[test_decide_cli](test_decide_cli.md), [test_decide_service](test_decide_service.md), [test_doctor_decide](test_doctor_decide.md).
