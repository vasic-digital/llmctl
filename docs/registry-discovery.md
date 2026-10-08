# Registry, dynamic ports and gateway discovery

How `llmctl-decide` allocates ports, publishes services, probes their health and how the decision
gateway finds its engines. The implementation is `internal/registry` (ports, registry, health, CLI)
and `internal/gateway/registry_resolver*.go` (the gateway side); the mechanics come from the Containers
submodule (`pkg/network`, `pkg/serviceregistry`, `pkg/health`, `pkg/endpoint`) and are not
re-implemented. Gaps found in the submodule, and the upstream patch text for each, are in
`specs/009-jev-decision-models/evidence/containers-upstream/`.

## Ports

| Variable | Default | Meaning |
|---|---|---|
| `LLMCTL_PORT_STRATEGY` | `fixed` | `fixed` uses each profile's documented port and fails loudly if it is taken; `dynamic` picks a bind-tested free port from the range. |
| `LLMCTL_PORT_RANGE` | per user, see below | `LO-HI`, 1024-65535, for the dynamic strategy. |
| `LLMCTL_PORT_<PROFILE>` | unset | One explicit port (always wins) or `auto`. |
| `LLMCTL_STATE_DIR` | `~/.local/state/llmctl` | Holds `registry/` (services.json, ports.json, lock). |

### Per-user default range (G-008)

Two users on one host each have their own state directory, so their allocators cannot see each other's
not-yet-listening allocations. Their default ranges are therefore **disjoint by construction**:

* the span is `20000-31999` (below the kernel's ephemeral range `32768-60999`), cut into 12 blocks of 1000;
* a user owns block `(uid - 1000) mod 12`: uid 1000 -> `20000-20999` (the historical default),
  1001 -> `21000-21999`, ... 1011 -> `31000-31999`;
* uids 1000..1011 are collision-free; a host with more users, or uids congruent modulo 12 (e.g. 1000 and 1012,
  or a system user such as 0), must give the later user an explicit `LLMCTL_PORT_RANGE`.

Not done, deliberately: a system-wide shared reservation directory that would make users with overlapping
explicit ranges respect each other's allocated-but-not-listening ports. It needs a world-writable sticky
directory, stale-reservation reaping across uids and an owner check - more than the disjoint blocks are worth.
The remaining exposure is only: overlapping explicit ranges, or fixed documented ports, between users - the
bind test still refuses a port that is actually listening.

### Bind test (G-007)

A port is handed out only if it can be bound on `127.0.0.1` (the Containers allocator), on `0.0.0.0`,
on `::` and on every unicast address of every local interface. A listener on `192.168.x.y:P` or on a wildcard
is therefore seen. Only "address in use" / "permission denied" mean taken; an address the host cannot bind is
skipped.

## Registry and health

`llmctl-decide registry register|unregister|list|reconcile|diff` and `llmctl-decide discover`.
`discover` columns: `NAME URL HEALTH PID LOOPBACK KEY LABELS`; `--json` adds `loopback_only`,
`key_file_named` and `key_file_present`. `KEY` is `-` (no key file named), `ok` (named and present) or
`MISSING` (named but absent). Keys are never printed; the `key_file` label holds only the file path.

`reconcile` proves liveness from the real process and probes health. "The real process" is two checks (C-01):
the program identity (`argv[0]` is the token or a path ending in it, or `argv[0]` is an interpreter -
python, node, bash ... - and `argv[1]` is the script named by it, or an argument equals the token / is a
`--flag=token` form; a mere path ARGUMENT such as `tail -f /var/log/llama-server` is a carrier, not the
service), **and** the process fingerprint recorded at registration (kernel boot id + process start time +
a hash of argv, `proc_fp` in `registry list --json`): a pid the kernel hands to another process - even one
running the same program - no longer matches, so its stale row is removed instead of routed to.

| Entry | Probe |
|---|---|
| `http` with a health path | HTTP GET of the path (Containers `health.CheckHTTP`), 2xx-3xx healthy |
| `https` (G-006) | TLS handshake **verified against the llmctl CA** (chain, validity, host name/IP), then GET of the health path (2xx-3xx); with no health path the verified handshake alone decides. A wrong CA, an expired certificate, a plain-HTTP server and a TCP-only listener are all unhealthy. |
| `tcp`, `http` without a path | TCP connect |

### Which CA (G-068)

One function (`registry.ResolveCA`, shared with the gateway and the `ask` client) resolves the CA: `LLMCTL_CACERT`,
else `$LLMCTL_HOME/cert/ca/ca.crt` (`LLMCTL_HOME` defaulting to `~/llmctl`). `registry reconcile --home DIR`
overrides `LLMCTL_HOME` for one run. For an `https` entry the reconciler prefers, in order:

1. the entry's **`ca_file` label** - the gateway records the CA that certifies it there, so a reconciler run
   from cron or from a shell with another `LLMCTL_HOME` still verifies against the right CA. The label is data
   any local process can write, so it is honoured only when the file is a regular file **owned by the current
   user and not world-writable**; otherwise it is ignored (and the reason is reported);
2. `LLMCTL_CACERT`;
3. `$LLMCTL_HOME/cert/ca/ca.crt`.

With **no usable CA** an `https` entry cannot be certified. That is *not* the same as the service being
unhealthy, so the entry is **kept** (marked not routable, no unhealthy clock) and reported `unknown` with
`CA not found: set LLMCTL_CACERT`; it is never removed for it and never "trusted anyway". `reconcile` still
exits 0 unless `--strict` is given (then exit 1; `--json` carries an `unknown` array). A CA that is found but
does not verify the server (wrong CA, expired certificate) remains a real failure: unhealthy, then removed after
`--grace`.

`reconcile --prune-unknown-after D` (G-074, default off) removes an `https` row that has been `unknown` for
`D` or longer (the row records `unknown_since`; `llmctl doctor` WARNs about such rows). `--port-grace D`
(default 600 s, at least `LLMCTL_REGISTER_WAIT`) is how long an allocated-but-unbound port hold is kept: an
engine that loads a large model before binding (the onnx runtime) must not lose its port meanwhile (C-11).

**A corrupt registry is not forgotten (C-24).** The Containers registry moves a corrupt file aside and carries
on with an empty one, so only the first call errored. llmctl now leaves `<state>/registry/.corrupt-detected`
(and a dated copy of the aside file, as a second corruption overwrites the first); `registry list` warns,
`registry reconcile` warns on every pass (`--strict` exits 1), `registry diff` exits 1 and `llmctl doctor`
FAILs until `llmctl-decide registry ack-corrupt` acknowledges it.

`serve --resolver auto` (the default) decides **per profile, on every request**: a profile with at least one
**healthy** `kind=decide` registry entry is served from the registry, every other profile from its static
endpoint (`LLMCTL_DECIDE_ENDPOINT_<PROFILE>` or the catalog port). A stale `decide-gateway` row or an unhealthy
engine therefore never leaves the gateway with zero backends while the static endpoints would have worked
(C-23), a mixed deployment (profile X registered, profile Y configured only statically) keeps both, and an
engine that registers later wins for its profile from the moment it is healthy (C2-13). The status line
(`--status`, startup log) reports `registry` while ANY healthy decision engine is registered, else `static`.

### The gateway reconciles on its own (G-057)

Health flags are written only by the reconciler, so `serve --foreground` runs it in-process: every
`LLMCTL_DECIDE_RECONCILE_INTERVAL` seconds (default 5) it probes each entry, flags failures unhealthy and
removes entries unhealthy for `LLMCTL_DECIDE_RECONCILE_GRACE` seconds (default 30) or whose process is gone - no
external cron. There is **one reconciler per registry**: the role is an `flock(2)` on
`<state>/registry/.reconciler.lock`, so a second gateway (or process) stands by and takes over within one
interval when the owner exits or dies (the kernel drops the lock with the process; no pid file, no stale owner).
The reconciler stops when the gateway starts draining. The first pass is delayed (at most 2s) so the gateway is
serving before it probes its own `/healthz`. An external `llmctl-decide registry reconcile` stays valid.

## The gateway and the registry (G-046)

| Variable | Default | Meaning |
|---|---|---|
| `LLMCTL_DECIDE_RESOLVER` | `auto` | `registry`, `static` or `auto` (decided **per profile on every request**: the registry when it lists a healthy engine for that profile, else the static endpoint - see `docs/decide-gateway.md`). |
| `LLMCTL_DECIDE_REGISTRY_INTERVAL` | `1s` | How often the gateway follows registry changes. |
| `LLMCTL_DECIDE_RECONCILE_INTERVAL` | `5` | Seconds between in-process reconcile passes (positive plain number, at most 3600; anything else refuses the start). |
| `LLMCTL_DECIDE_RECONCILE_GRACE` | `30` | Seconds an unhealthy entry is kept before removal (non-negative plain number, at most 86400). |

In registry mode an engine is a registry entry labelled `kind=decide`, `profile=<id>`, optionally
`instance=<n>` and `key_file=<path>`:

* instances are ordered primary-first: instance number (label `instance`, else the `.N` suffix of the name,
  else 1), then start time, then name - so deterministic mode always uses the same primary;
* the internal key is read from the entry's `key_file` with the gateway's key-file rules (regular file, not a
  symlink, owned by the gateway's user, mode 0600, 1..4096 bytes; re-checked when the file changes, so rotation
  needs no restart); an entry naming no key file gets the per-profile / global key files
  (`LLMCTL_DECIDE_INTERNAL_KEY_FILE`, `$LLMCTL_STATE_DIR/keys/<kind>-<profile>.key`); a key file that is missing,
  empty, a symlink or readable by group/others makes that instance unhealthy and carries no key;
* only loopback engines are ever offered; an entry on any other address is ignored;
* a change in the registry (instance started, removed, marked unhealthy) is routed by within one interval,
  without restarting the gateway; with every instance gone the gateway answers `503 not_ready` and
  `/v1/models` lists nothing. A TCP connect probe still covers the gap between two `reconcile` runs.

The gateway publishes itself (`name decide-gateway`, `kind=gateway`, `https`, health path `/healthz`) once it is
listening and unregisters when the drain starts; `llmctl-decide discover --kind gateway` finds it, and
`reconcile` certifies it through the TLS probe above. A registry that cannot be written is a warning, not a
reason to refuse service.

Who writes health: `registry reconcile` (or `RunReconciler`). The gateway reads it; it does not run the
reconciler itself.
