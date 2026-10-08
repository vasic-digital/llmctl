# `test_scheduler_bind_host.sh`

## Overview

Source: `tests/test_scheduler_bind_host.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_scheduler_bind_host.sh - configurable engine bind host
(LLMCTL_BIND_HOST / LLMCTL_BIND_HOST_<PROFILE>), exercised for real
against sched_build_launch (the FUNCTIONAL path every start/enable/switch
actually launches its engine through).

Root cause this covers: sched_build_launch hardcoded "--host 127.0.0.1"
at BOTH engine-construction sites (the llama.cpp path and the `colibri
serve` path), so a genuinely-running, healthy systemd-managed llmctl
service was never reachable from anywhere but the local machine - not
even another device on the same LAN - confirmed live via `ss -tlnp`
showing every llama-server socket bound to 127.0.0.1 with no override
path anywhere in the codebase (grep for LLMCTL_BIND_HOST found nothing
pre-fix).

Per explicit operator mandate ("Everything must be fully accessible from
local network"), the new default is LAN-accessible (0.0.0.0), not
localhost-only - the opposite polarity from the port-override precedent
this test otherwise mirrors (tests/test_port_override.sh), because the
operator asked for the *host to change its default*, not merely to gain
an opt-in escape hatch. LLMCTL_BIND_HOST (global) and
LLMCTL_BIND_HOST_<PROFILE> (per-profile, same name-derivation rule as
LLMCTL_PORT_<PROFILE> - see catalog_bind_host_override_env_name) let an
operator lock a specific profile - or the whole host - back to
127.0.0.1-only.

Both engine paths are exercised here (llama via "fast", colibri via
"colibri-qwen36"); a fix touching only one would look complete but leave
the other engine unreachable from the LAN.
```

Run: `bash tests/test_scheduler_bind_host.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh scheduler_bind_host` (see [doc_counts](doc_counts.md)).
