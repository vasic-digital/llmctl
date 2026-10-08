# Captured QA evidence (index)

Evidence directories kept in the repository (Constitution 11.4.83). Each is a point-in-time record of a real run, not a promise about today's behaviour.

| Directory | What it holds |
|---|---|
| [phase12-final-validation](phase12-final-validation/README.md) | bash + Go test-suite run of Phase 12 |
| [decision-models-validation](decision-models-validation/README.md) | first-candidate decision-models validation (history; superseded by the Go gateway) |
| [dynamic-ports-validation](dynamic-ports-validation/README.md) | live systemd `--user` run of dynamic ports and the registry |
| [006-cli-daemon-wiring](006-cli-daemon-wiring/environment_finding_http3.md) | the HTTP/3 environment finding for the cluster CLI |
| `005-cuda-gpu-inference`, `007-claude-toolkit-test-fixes`, `008-full-test-coverage` | raw logs and observations (plain text; no narrative page) |

Release-3.1.0 evidence (gap register, review reports, engine advance, portability run) lives under `specs/009-jev-decision-models/evidence/`; the honest summary of what it does and does not prove is [limitations](../limitations.md).
