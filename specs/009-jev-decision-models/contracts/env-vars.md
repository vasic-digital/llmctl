# Environment variables — decision layer

**Status**: draft contract. "Default" values marked *(proposed)* are design targets to be measured in P4 and may change; all others are existing llmctl behaviour or a hard rule from the spec. Every variable listed here appears in `docs/` and is checked by the documentation audit (SC-009).

## Credentials and locations

| Variable | Default | Meaning |
|---|---|---|
| `LLMCTL_API_KEY` | resolved (see below) | The single access key for the decision gateway and llmctl's own clients. **Never** printed except by `llmctl key show --yes-print`. Scope: decision endpoints only; chat servers are unaffected (Clarification 2). |
| `LLMCTL_API_KEY_PREVIOUS` | unset | Optional rotation-overlap value (`key rotate --grace N`) with an expiry; lives **only** in the `.env` file beside the key (FR-057), is never read from or exported to the process environment. |
| `LLMCTL_HOME` | `$HOME/llmctl` | Holds `cert/` (operator-requested location, Clarification 4). **It does not hold `.env`.** Creation inside a git work tree is refused unless version control ignores the path (FR-087). Existing XDG dirs are unchanged. |
| `LLMCTL_ENV_FILE` | `<llmctl installation root>/.env` | The `.env` file as `.env.example` documents it (gitignored; mode 0600). Override for tests and multi-user setups. Refused if the path is inside a git work tree and not ignored. |

**Key resolution order**: (1) process environment; (2) `LLMCTL_ENV_FILE` (the installation-root `.env`); (3) generate on first start and persist to (2) with mode 0600. The per-installation **log key** (FR-079) is a separate random value stored in `${LLMCTL_STATE_DIR}/decide/log.key` (0600) and is never the access key. A blank, whitespace-only or malformed value at (1) or (2) is an error (exit 4), not "no key". `.env` is parsed by a safe reader – it is never `source`d.

## Transport and certificates

| Variable | Default | Meaning |
|---|---|---|
| `LLMCTL_TLS_MODE` | `ca-leaf` | `ca-leaf` (default), `selfsigned` (single certificate fallback), `byo` (operator-supplied pair in `cert/`). |
| `LLMCTL_TLS_SAN` | empty | Extra names/addresses for the leaf, e.g. `dns:nas.example.org,ip:203.0.113.7`. llmctl never discovers the public IP itself. |
| `LLMCTL_TLS_MIN` | `1.2` | Minimum protocol (`1.2` or `1.3`). |
| `LLMCTL_CA_NAME_CONSTRAINTS` | `on` | Name constraints on the CA (FR-066): host names, `localhost`, `*.local`, loopback, RFC 1918, ULA, CGNAT/overlay ranges plus `LLMCTL_TLS_SAN` extras. `off` is a deliberate, logged opt-out for operators who must issue names outside the constraints. |
| `LLMCTL_CACERT` | `$LLMCTL_HOME/cert/ca/ca.crt` | CA used by llmctl's own clients **and by `registry reconcile`** (one shared resolver, `registry.ResolveCA`; `registry reconcile --home DIR` overrides `LLMCTL_HOME`). A reconciler prefers the https entry's `ca_file` label (honoured only if the file is owned by the current user and not world-writable), then this. With no CA found https entries are reported `unknown` (kept, not routable), never removed; `--strict` exits 1. |
| `LLMCTL_ENDPOINT` | `https://127.0.0.1:8095` | Gateway URL used by llmctl's own clients. |

## Gateway

| Variable | Default | Meaning |
|---|---|---|
| `LLMCTL_DECIDE_PORT` | `8095` | HTTPS port of the gateway. |
| `LLMCTL_DECIDE_BIND` | the global `LLMCTL_BIND_HOST` if set, else `0.0.0.0` (all interfaces; Clarification 1) | Gateway bind address; set `127.0.0.1` to restrict to this machine. The global `LLMCTL_BIND_HOST` therefore also restricts the gateway when `LLMCTL_DECIDE_BIND` is unset (least surprise: an operator who made all servers local keeps the gateway local); the per-profile `LLMCTL_BIND_HOST_<PROFILE>` apply to chat profiles only. A test asserts both behaviours. |
| `LLMCTL_DECIDE_PROFILE` | auto (`decide-tiny` if verified, else best that fits) | Default profile for requests that name none. |
| `LLMCTL_DECIDE_MODE` | `deterministic` | `deterministic` or `throughput` (opt-in). Every decision answers `x-llmctl-decide-mode: <mode>` and the client's `evidence.mode` repeats it. |
| `LLMCTL_DECIDE_MAX_BODY` | `262144` *(proposed)* | Body cap in bytes, rejected before reading. |
| `LLMCTL_DECIDE_MAX_STATE_CHARS` | `8192` | State budget (characters) for every profile. A longer state is **rejected with 422** by default. It is additionally bounded, per profile, by the engine context in tokens (`LLMCTL_CTX_<PROFILE>` when set, else catalog `defaults.ctx`, and the smaller per-slot context the engine reports on `GET /props`; see `limits.max_context_tokens` in `GET /v1/models`): a state that cannot fit is a 422 before any completion is requested (the `/props` read is the only engine contact first, and the budget of every question of a request is checked before the first completion). |
| `LLMCTL_DECIDE_TRUNCATE` | `0` | `1` = opt-in: shorten an over-budget state (head and tail kept), set `x-llmctl-decide-truncated: true`, log it; the header is also set when an encoder (`nli-onnx`) runtime reports that it truncated the premise of any pair (without the opt-in that is a 422). Question and option text are never shortened under any setting; encoder profiles shorten only the state. |
| `LLMCTL_DECIDE_MAX_OPTIONS` | `20` | Practical option cap for decoder profiles (hard cap 26); the hosted maximum 255 applies to native/encoder profiles. |
| `LLMCTL_DECIDE_MAX_QUESTIONS` | `32` *(proposed)* | Questions per request. |
| `LLMCTL_DECIDE_MAX_CONNS` | `64` *(proposed)* | Global concurrent connections (non-blocking semaphore). |
| `LLMCTL_DECIDE_MAX_CONNS_PER_SOURCE` | `8` *(proposed)* | Concurrent connections per source address, well below the global cap; excess connections are closed **before** the TLS handshake so one host cannot exhaust the pool. Behind NAT or a tunnel all clients share one source, so the value is documented as operator-tunable. |
| `LLMCTL_DECIDE_MAX_UNAUTH_CONNS` | `32` | Of `LLMCTL_DECIDE_MAX_CONNS`, how many connections may be **unauthenticated** (no request with the valid key completed yet) at one time. The remaining `MAX_CONNS - MAX_UNAUTH_CONNS` slots are reserved for connections that already proved the key, so hostile sources can never take them (FR-022, review A-01). A new connection that finds the unauthenticated pool full is **not** refused: the oldest unauthenticated connection of the source that holds the most of them is reset and the newcomer takes its place. Must not exceed `MAX_CONNS`; a smaller explicit `MAX_CONNS` clamps the default. |
| `LLMCTL_DECIDE_MAX_UNAUTH_PER_SOURCE` | `8` | Unauthenticated connections per source (an IPv4 address, an IPv6 `/64`). Must not exceed `MAX_CONNS_PER_SOURCE` nor `MAX_UNAUTH_CONNS`. |
| `LLMCTL_DECIDE_MAX_UNAUTH_PER_PREFIX` | `16` | Unauthenticated connections shared by one IPv6 `/48` (rotating addresses inside one allocation does not multiply a source's share). For IPv4 the aggregate is the address itself. At least `MAX_UNAUTH_PER_SOURCE`, at most `MAX_UNAUTH_CONNS`. |
| `LLMCTL_DECIDE_PREAUTH_TIMEOUT` | `3` s | A connection that has not completed a request with the valid key within this time of being accepted is reset (bare TCP, stalled handshakes, an unauthenticated probe followed by idling). Positive seconds, at most 86400. An authenticated connection is not subject to it. |
| `LLMCTL_DECIDE_IDLE_TIMEOUT` | `60` s | Keep-alive idle time of an authenticated connection. Positive seconds, at most 86400. |
| `LLMCTL_DECIDE_AUTH_FAIL_LIMIT` | `10` per minute *(proposed)* | Failed authentications per source before 429 + `Retry-After`. Applies only to attempts with a wrong or missing key; a request carrying the valid key is never throttled. Memory bounded (time-evicted table). |
| `LLMCTL_DECIDE_CONCURRENCY` | `4` *(proposed)* | Simultaneous backend `Decide` calls in the gateway; further requests wait in the bounded queue (`LLMCTL_DECIDE_QUEUE`), then 529. |
| `LLMCTL_DECIDE_QUEUE` | `64` *(proposed)* | Bounded wait queue; full ⇒ 529 + `Retry-After`. |
| `LLMCTL_DECIDE_HANDSHAKE_TIMEOUT` | `3` s | Total TLS handshake budget per connection. |
| `LLMCTL_DECIDE_READ_DEADLINE` | `10` s *(proposed)* | Absolute deadline for reading the request; slow-drip clients are cut. |
| `LLMCTL_DECIDE_TIMEOUT` | `8` s (the gateway default in `internal/server/limits.go`; the `llmctl decide ask` client and `lib/decide.sh` default to 30 s) | End-to-end budget per request (queue wait + all engine calls), kept below the hosted SDK's 10 s default timeout. When it expires the gateway answers `502 backend_failed` with `x-llmctl-decide-reason: deadline_exceeded` + `x-llmctl-decide-deadline-ms`; other backend-call 502s carry `x-llmctl-decide-reason: engine_error`. On CPU engines size it per request (sum over the request's questions + queue wait): see `docs/decide-gateway.md` "The end-to-end budget and slow (CPU) engines". |
| `LLMCTL_DECIDE_DRAIN_GRACE` | `15` s *(proposed)* | Grace for in-flight requests on stop. |
| `LLMCTL_DECIDE_RESOLVER` | `auto` | Where the gateway finds engines: `registry` (the service registry; follows registry changes without a restart, per-instance internal key from the entry's `key_file` label, else the internal key files), `static` (`LLMCTL_DECIDE_ENDPOINT_<PROFILE>` / catalog ports, TCP-probed), `auto` (default) = decided **per profile on every request**: the registry when it holds a healthy engine for that profile, else the static endpoint (a profile served only statically keeps working next to a registered one). See `docs/registry-discovery.md`. |
| `LLMCTL_DECIDE_INTERNAL_KEY_FILE` | unset | Path of a **0600 regular file** (not a symlink, owned by the gateway's user, 1..4096 bytes) holding the key the gateway presents to every engine. It replaces the removed env variable of the same name without the `_FILE` suffix (an environment value is visible in `/proc/<pid>/environ`; the gateway now ignores it, says so once and never prints it). A configured file that is missing or unacceptable refuses the start. A **per-profile** file `$LLMCTL_STATE_DIR/keys/<kind>-<profile>.key` (same rules; `kind` = `onnx` for `nli-onnx` profiles - the file `lib/scheduler.sh` creates - and `llama` for the others) takes precedence; a per-profile file that exists but is unacceptable makes that instance unhealthy rather than falling back. Files are re-checked on every use, so a rotation needs no restart, and an engine answering `401` triggers one re-read and exactly one retry with the new key (none if the key did not change). Registry entries keep their own `key_file` label. |
| `LLMCTL_DECIDE_REGISTRY_INTERVAL` | `1s` | Poll interval at which the gateway follows registry changes (a changed registry is routed by within one interval). |
| `LLMCTL_DECIDE_RECONCILE_INTERVAL` | `5` | Seconds between the gateway's in-process registry reconcile passes (G-057; one reconciler per registry, an `flock` owner). A positive plain decimal number, at most 3600 - `0`, negatives, units, exponents, hex, `inf`/`nan` refuse the start. |
| `LLMCTL_DECIDE_RECONCILE_GRACE` | `30` | Seconds an unhealthy registry entry is kept before the gateway's reconciler removes it. A non-negative plain decimal number, at most 86400. |
| `LLMCTL_PORT_STRATEGY` | `fixed` | `fixed` (each profile's documented port; a taken port fails loudly) or `dynamic` (bind-tested port from `LLMCTL_PORT_RANGE`). |
| `LLMCTL_PORT_RANGE` | the user's block, derived from the numeric uid (below) | `LO-HI` for the dynamic strategy. Default: 1000-port block `20000 + ((uid-1000) mod 12) * 1000`, so uid 1000 keeps `20000-20999`, uid 1001 gets `21000-21999`, ... uid 1011 `31000-31999`, all below the Linux ephemeral range; users sharing a host therefore get disjoint ranges. More than 12 users, or uids congruent modulo 12, must set an explicit range. |
| `LLMCTL_PORT_<PROFILE>` | unset | One explicit port (always wins, under either strategy) or `auto` (this profile only is dynamic). The scheduler resolves every start/enable port through the registry allocator (`lib/portreg.sh`); the plan keeps the documented port as ordering key and `plan --json` adds `assigned_port` for a running service. |
| `LLMCTL_PORT_GATEWAY` | unset | The same switch for the decision gateway's own port (`numeric` or `auto`; documented port `LLMCTL_DECIDE_PORT`, default 8095). Applied by the unit/agent wrapper `lib/svc_hook.sh run-gateway`. |
| `LLMCTL_DECIDE_BIN` | `<root>/build/llmctl-decide`, then `PATH` | The registry/allocator/gateway binary the scheduler and the unit hooks call. Without it the scheduler keeps the catalog ports and a request for dynamic ports is refused. |
| `LLMCTL_PORTREG` | `auto` | `0` turns the allocator/registry adapter off (hermetic tests), `1` forces it on even in a dry run, `auto` = on when the binary exists and the run is not a dry run. |
| `LLMCTL_REGISTER_WAIT` / `LLMCTL_REGISTER_POLL` | `600` / `1` (seconds) | How long the unit's `ExecStartPost` waiter polls a starting engine's health endpoint before giving up on publishing it, and the poll interval. `llmctl-decide registry reconcile` keeps an allocated-but-unbound port hold at least this long (default `--port-grace` 600 s), so an engine that loads a large model before binding does not lose its port. |
| `LLMCTL_ONNX_VENV` | `$LLMCTL_DATA_DIR/venv-onnx` | Where `llmctl build onnx` creates the hash-locked venv. Must be an absolute path. The build only ever deletes a directory that carries llmctl's own `.llmctl-onnx-venv` marker naming exactly that path (or the marker-less legacy venv at the default location) and refuses `/`, `$HOME`, the data dir, the install root, symlinks and any ancestor of them. |
| `LLMCTL_SMOKE_PORT` | `auto` | Port of the post-download smoke tests: `auto` = a free ephemeral port per test; a number pins it (refused when in use). Readiness is proven against the launched process (it must hold the listening socket), never just "something answers". |
| `LLMCTL_AGENTS_NPM` / `LLMCTL_AGENTS_UV` / `LLMCTL_AGENTS_PYPI_BASE` / `LLMCTL_AGENTS_ALLOW_SCRIPTS` | `npm` / `uv` / `https://pypi.org/pypi` / `0` | `scripts/install_agents.sh`: executables, PyPI JSON base (tests use `file://`), and `1` to let npm run lifecycle scripts (default `--ignore-scripts`). Pins live in `scripts/agents.lock`. |
| `BA_PUBLIC_ALLOWLIST` | the two manifests in the repo | `scripts/release/build_archive.sh` (tests): colon-separated exact-path allow manifests replacing `scripts/release/public_allowlist.txt` + `tests/fixtures/PUBLIC_FIXTURES.txt`. |
| `LLMCTL_SERVICE_BACKEND_FILE` | unset | **Test seam, never set in production**: source this file instead of the OS service backend (used by `tests/test_dynamic_ports.sh` with `tests/fixtures/svc_backend_direct.sh`). |
| `LLMCTL_DECIDE_LOG` | `$LLMCTL_LOG_DIR/decide-requests.jsonl` | Structured request log (mode 0600): ts, request id, method, path, status, ms, bytes, auth result, client IP, profile id, TLS version, **keyed state hash** – never state text or key material. |
| `LLMCTL_DECIDE_LOG_STATE` | `0` | `1` = **consent** to keep the state and question text in the opt-in **decision log** (FR-080, 2-I05): it also enables that log at `$LLMCTL_LOG_DIR/decide-decisions.jsonl` when `LLMCTL_DECIDE_DECISION_LOG` is not set. `0`/unset = no text. Any other value is refused at start (exit 2). The decision log is a **separate file** from the request log (mode 0600, parents 0700, `O_NOFOLLOW`, created through the FR-087 placement guard: refused inside an unignored git work tree); it is the only log that may carry text, and the banner says so. |
| `LLMCTL_DECIDE_DECISION_LOG` | unset | Path of the decision log. Setting it alone enables the log **without** text (per request: UTC time, request id, profile, type counts, answer summary - winner **index**, noul/score value, served and raw confidence, flags - latency, status, model sha256, template hash, calibration profile); with `LLMCTL_DECIDE_LOG_STATE=1` the records also carry the state, question text, question names and the chosen option key. Must differ from `LLMCTL_DECIDE_LOG` (exit 2). Never contains key material or the Authorization header (no field exists for them). No size cap or rotation of its own: the file is reopened if an external rotation renames it. Only requests that were authenticated and parsed appear (rejected requests are in the request log only); a write failure never fails a request and is counted in `llmctl_decide_audit_write_failures_total`. |

## Readout and calibration

| Variable | Default | Meaning |
|---|---|---|
| `LLMCTL_DECIDE_MASS_THRESHOLD` | `0.5` *(proposed)* | Combined letter-probability mass below which a decoder readout fails with `readout_failed` (never a renormalised guess). **Validated at start**: a number above 0 and at most 1, else `serve` exits 2. |
| `LLMCTL_DECIDE_TEMPERATURE` | `1.0` | Global readout scalar (it divides the letter logits before the softmax). It is part of every letter-logit profile's `decision.template_hash`, so a calibration profile fitted at one temperature is **refused** at another. A calibration profile (bound to model sha + template hash) is separate: it recalibrates only the `confidence` of the answer (`calibration`/`confidence_raw` fields), never the probabilities. **Validated at start**: finite and above 0 (NaN, Inf, 0 and negative values exit 2). |
| `LLMCTL_SEED` | unset (seed 1) | Fixed sampler seed where a sampler is involved. **Validated at start**: a whole number of 0 or more (a negative seed means "random" to llama-server and would break determinism; 0 is a valid fixed seed and is sent as 0; unset or blank means 1). |
| `LLMCTL_CTX_<PROFILE>` | catalog `defaults.ctx` | Per-slot context of a profile, honoured by the engine launcher (`lib/catalog.sh`) **and** by the gateway's token budget (same variable, same validation: a whole number >= 512, read like Python's `int()` in the launcher - blanks, a sign and single underscores between digits such as `4_096` are accepted; non-ASCII decimal digits, which Python also accepts, are refused by the gateway at start naming the variable; the gateway also caps the value at 2^24, the launcher has no upper bound). The gateway additionally prefers the per-slot context the engine reports on `GET /props`. |
| `LLMCTL_DECIDE_SLOTS` | `1` | Concurrent requests per instance. **Exactly 1 in deterministic mode** (more is refused at start: batching changes the logits); raise it only with `LLMCTL_DECIDE_MODE=throughput`. |
| `LLMCTL_DECIDE_MAX_PAIRS` | `64` | Encoder profiles: the most premise/hypothesis pairs (questions x options) one request may cost (FR-016); over it is a 422 before any pass is spent. 1..4096; advertised as `limits.max_pairs`. |

## Existing variables (unchanged)

`LLMCTL_PORT_<PROFILE>`, `LLMCTL_CTX_<PROFILE>`, `LLMCTL_KVTYPE_<PROFILE>`, `LLMCTL_BIND_HOST`, `LLMCTL_BIND_HOST_<PROFILE>`, `LLMCTL_CONFIG_DIR`, `LLMCTL_DATA_DIR`, `LLMCTL_STATE_DIR`, `LLMCTL_RUNTIME_DIR`, `LLMCTL_MODELS_DIR`, `LLMCTL_LOG_DIR`, `LLMCTL_VERIFY_DIR`, `LLMCTL_SERVICES_DIR`, `LLMCTL_CATALOG`, `LLMCTL_HF_BASE`, `LLMCTL_FAKE_HW`, `LLMCTL_DRY_RUN`, `HF_TOKEN`.

## Hosted-SDK compatibility (set by the operator, not by llmctl)

| Variable | Use |
|---|---|
| `TYPESAFE_BASE_URL=https://<host>:8095` | Points the official hosted SDKs at the gateway. |
| `TYPESAFE_API_KEY=$LLMCTL_API_KEY` | The SDKs require a key; pass the llmctl key. |
| `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` / `NODE_EXTRA_CA_CERTS` | CA trust for Python (httpx / requests), Node. **Which of these each SDK honours is verified empirically in P6** (the vendor documents no CA option; a custom `http_client`/`fetch` is the supported hook). |

## Retired / forbidden in production paths

| Variable | Disposition |
|---|---|
| `LLMCTL_DECIDE_API_KEY` | **Retired** (never released) – replaced by `LLMCTL_API_KEY`; must not appear anywhere (test greps). |
| `LLMCTL_DECIDE_BACKEND_HOST`, `LLMCTL_DECIDE_BACKEND_PORT` | **Removed** from production paths (they redirect user state to another host); unit tests inject backends through the Python API instead. |
| `LLMCTL_ONNX_FAKE` | **Removed** from production paths; fake logits exist only inside the unit-test tier and can never mark a download "verified". |

### Calibration profile loading (T137)

The gateway reads `$LLMCTL_STATE_DIR/decide/calibration/<profile>.json` (the file `llmctl-decide calibrate` writes) for every decision profile **at start and on `SIGHUP`** (the signal `cert reload` already sends; a profile written or removed later takes effect on the next `SIGHUP`, not on every request). A profile is applied only if it is a regular, non-symlink file owned by the gateway's user and not writable by group/others, is bound (`bound: true`) to the catalog's single model sha256 (`files[role=model].sha256`) **and** to the live `decision.template_hash` (computed by the gateway; see `/v1/models`), and its parameters are well-formed. Otherwise the answers keep their uncalibrated confidence, `/v1/models` reports `calibration.applied=false` with a closed `reason` (`mismatch`, `unbound`, `invalid`, `insecure`, `model_unresolved`) and the reason is written once to the gateway's stderr (again only when it changes). `<profile>.unbound.json` is never read. No new variables are needed; the directory is `$STATE/decide/calibration` with the same `$STATE` resolution as `serve`.
