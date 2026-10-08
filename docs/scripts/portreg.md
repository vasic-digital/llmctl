## Overview

`lib/portreg.sh` is the bash adapter over the Go port allocator and service
registry (`llmctl-decide port|registry|discover`, `internal/registry`, built on
the Containers submodule). It contains **no** allocation or registry logic of
its own: it finds the binary, asks it for a port, publishes a ready service,
removes it again and renders the registration metadata the service-manager
hooks need. Spec 009 FR-088..FR-091, OD-18, SC-015.

## Port strategy (what the operator controls)

| Variable | Meaning |
|---|---|
| *(nothing set)* | `fixed` strategy (OD-18 default): every service gets its documented catalog port; a taken port fails loudly naming the port and `LLMCTL_PORT_<PROFILE>`. |
| `LLMCTL_PORT_STRATEGY=dynamic` | every service takes a bind-tested free port from `LLMCTL_PORT_RANGE` (default `20000-20999`). |
| `LLMCTL_PORT_<PROFILE>=auto` | only that profile is dynamic. |
| `LLMCTL_PORT_<PROFILE>=<n>` | an explicit numeric port always wins, under either strategy. |
| `LLMCTL_PORT_GATEWAY` | the same switch for the decision gateway (`gateway` is its service name; documented port 8095, `LLMCTL_DECIDE_PORT`). |
| `LLMCTL_PORT_RANGE=LO-HI` | the dynamic range; give each user on a shared host a different range (or none: bind tests keep two users disjoint). |

A restarted service gets its previous dynamic port back when it is still free
(sticky hint). `stop`/`disable` release the hold and remove the registry row.

## Activation

The adapter is active when the `llmctl-decide` binary is found **and** the
scheduler is not in dry-run mode. Binary search order: `$LLMCTL_DECIDE_BIN`,
`<root>/build/llmctl-decide` (`llmctl build decide`), then `PATH`.
`LLMCTL_PORTREG=0` turns it off (the test harness does, for hermeticity),
`LLMCTL_PORTREG=1` turns it on even in a dry run. With no binary the scheduler
behaves exactly as before (catalog port, no registry) - except that a request
for dynamic ports it cannot honour is **refused**, never silently ignored.

## Functions

`portreg_bin`, `portreg_active`, `portreg_allocate <name> <profile> <documented>`,
`portreg_register ...`, `portreg_unregister <name>`, `portreg_release <name>`,
`portreg_env_lines ...` (metadata lines for the service env record: port,
process token, kind, health path, key-file **path**), `portreg_live_set` and
`portreg_diff_report` (registry rows versus the live service set, used by
`llmctl doctor`).

## Verification

`bash tests/test_dynamic_ports.sh` and `bash tests/test_registry_discovery.sh`
drive the real scheduler, this adapter and the real binary end to end.

## Tenant mode and the live set (C-05)

`portreg_live_set` reports every active service under its **registry row
name**, i.e. the backend's instance key (`<tenant>--<profile>` when
`LLMCTL_TENANT_ID` is set, the bare profile otherwise). `svc_known_profiles`
now yields profile names (only this tenant's), so the tenant prefix is applied
exactly once (it used to be applied twice - `acme--acme--small` - which left the
live set empty and made `llmctl doctor` FAIL on every registered row). Proof:
`tests/test_service_ops_hardening.sh` (fake `systemctl` + the real registry,
both directions).

## Round-3 hardening (C2-03, C2-07)

- `portreg_diff_report` scopes `registry diff` to the rows this backend owns: under `LLMCTL_TENANT_ID=<t>` it passes
  `--prefix <t>-- --include decide-gateway`, otherwise `--no-tenant-rows`; another tenant's row is no longer a false
  "row without a live service".
- `portreg_register` retries, for `LLMCTL_REGISTER_IDENTITY_WAIT` seconds (default 10), the one refusal "pid ... is not
  (yet) running ..." (the registry now proves process identity before taking the fingerprint, C2-07).
