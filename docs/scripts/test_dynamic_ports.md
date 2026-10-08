## Overview

`tests/test_dynamic_ports.sh` proves dynamic port assignment through the
**real** scheduler start path (`bin/llmctl start|stop|switch|enable|disable|
plan|status`), `lib/portreg.sh` and the real `llmctl-decide` binary (built into
a temp dir). The engine is `tests/fixtures/fake_engine.py` (a harmless listener
standing in for `llama-server`) and the service manager is
`tests/fixtures/svc_backend_direct.sh` (spawns the engine from the real env
record and tracks its pid) - selected with `LLMCTL_SERVICE_BACKEND_FILE`, so
the developer's systemd user manager is never touched. Every port and range is
found on the live host at run time.

## What it checks

1. fixed strategy: documented port recorded in the output, `.run` record, env
   record, `/proc/<pid>/cmdline`, registry and `plan --json` (`assigned_port`);
2. fixed + the port occupied by another program: non-zero exit naming the port
   and `LLMCTL_PORT_<PROFILE>`; no reservation, row or port hold left behind;
3. `LLMCTL_PORT_<PROFILE>=auto` with that port occupied: a free in-range port;
4. restart reuses the previous dynamic port; stop releases hold, row, record;
5. global `LLMCTL_PORT_STRATEGY=dynamic`: three distinct in-range ports, all
   registered, answering; decision profile registered `kind=decide`, loopback-only;
6. decision engine launch (FR-073/FR-074, G-030): `--host 127.0.0.1`,
   `--parallel 1` and per-slot context preserved in deterministic mode, catalog
   parallel (and scaled `--ctx-size`) in throughput mode, `--api-key-file`
   (0600 file, 0700 dir, value in neither cmdline nor environ), `--no-webui`;
   chat engines unchanged; the capacity report states its mode;
7. an explicit numeric port beats the dynamic strategy;
8. a second user (own state dirs) gets a disjoint port set, and honours its own range;
9. switch, enable, re-enable (keeps its port), disable;
10. `stop all` leaves registry and port holds empty;
11. dynamic requested with no usable binary is refused; registry off + fixed
    strategy keeps the previous behaviour.

Needs `go`, `python3`, `curl` (otherwise prints SKIP). Takes about a minute.
