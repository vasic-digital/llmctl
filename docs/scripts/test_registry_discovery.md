## Overview

`tests/test_registry_discovery.sh` drives service discovery end to end with the
real scheduler, the real `llmctl-decide` binary and the real decision gateway
(started through the unit hook `lib/svc_hook.sh run-gateway`). Engines are the
harmless `tests/fixtures/fake_engine.py`; the service manager is
`tests/fixtures/svc_backend_direct.sh`. Ports and paths come from the live host.

## What it checks

1. a service is published **only once it answers** (an engine that is alive but
   still "loading" is sampled every 100 ms: no row ever precedes `/health` 200);
   the row carries the real pid, health path and URL;
2. the row is removed on stop;
3. after `kill -9`, `registry reconcile` removes the dead service (liveness from
   the real process identity) and leaves live ones alone;
4. registry == live set in both directions through `portreg_diff_report` and
   `llmctl doctor` ("a live service without a row" / "a row without a live
   service" are reported and make doctor FAIL);
5. 20 random start/stop/kill steps (fixed seed, dynamic strategy) never leave
   the registry different from the live set (SC-015);
6. the gateway: its own port under the fixed strategy and under the dynamic one,
   self-registration (`kind=gateway`, `https`), the exact `exec`ed command line
   `llmctl-decide serve --foreground`, registry-based backend resolution (the
   gateway's own `/v1/models` view of `decide-tiny` goes `ready` -> `absent`
   when the engine leaves the registry, no gateway restart), and the measured
   peak RSS (`VmHWM`, FR-083). With `LLMCTL_QA_EVIDENCE=1` a host-derived record
   is written to `docs/qa/dynamic-ports-validation/`.
