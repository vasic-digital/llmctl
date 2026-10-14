# Captured QA evidence (index)

Evidence directories kept in the repository (Constitution 11.4.83). Each is a point-in-time record of a real run, not a promise about today's behaviour.

| Directory | What it holds |
|---|---|
| [phase12-final-validation](phase12-final-validation/README.md) | bash + Go test-suite run of Phase 12 |
| [decision-models-validation](decision-models-validation/README.md) | first-candidate decision-models validation (history; superseded by the Go gateway) |
| [dynamic-ports-validation](dynamic-ports-validation/README.md) | live systemd `--user` run of dynamic ports and the registry |
| [006-cli-daemon-wiring](006-cli-daemon-wiring/environment_finding_http3.md) | the HTTP/3 environment finding for the cluster CLI |
| [vision-validate-live-2026-10-12](vision-validate-live-2026-10-12.md) | the model validation gate: what was UNKNOWN before the first live run (now partly answered by the page below) |
| [vision-live-2026-10-13](vision-live-2026-10-13/README.md) | the first real run, profile `vision`, one host: **PASS 21/0/0**, with the evidence files and the honest limits |
| [vision-live-2026-10-13-run2](vision-live-2026-10-13-run2/README.md) | run 2 of 2 on the same host: **PASS 21/0/0**, unit `MemoryPeak` 3005 MiB (calibration datum; cap floors unchanged) |
| [small-live-2026-10-14](small-live-2026-10-14/README.md) | the first run of profile `small`, one host: **PASS 6/0/0** (suite `chat-v1`), unit `MemoryPeak` 925 MiB; also records two pre-gate refusals and a `fast` attempt that ended UNDETERMINED (port held by another program; `fast` did not run) |
| `005-cuda-gpu-inference`, `007-claude-toolkit-test-fixes`, `008-full-test-coverage` | raw logs and observations (plain text; no narrative page) |

Release-3.1.0 evidence (gap register, review reports, engine advance, portability run) lives under `specs/009-jev-decision-models/evidence/`; the honest summary of what it does and does not prove is [limitations](../limitations.md).
