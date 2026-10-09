# TLS, keys and local-user threats of the decision gateway

| Field | Value |
|---|---|
| Scope | `llmctl decide serve`, `llmctl decide key`, `llmctl decide cert` |
| Spec anchors | FR-019, FR-022, FR-057..FR-073, FR-087 |
| Revision | 2 (2026-10-09) |

## Contents

- [Access key](#access-key)
- [Rotation and revocation](#rotation-and-revocation)
- [Certificates and private-key files](#certificates-and-private-key-files)
- [Placement guard](#placement-guard)
- [Connection admission](#connection-admission)
- [Request log](#request-log)
- [Loopback engines and port squatting](#loopback-engines-and-port-squatting)
- [Honest limits](#honest-limits)

Procedures (rotate, renew, back up, restore, upgrade) are in [runbooks](runbooks.md); serving other machines is [lan-exposure](lan-exposure.md).

## Access key

* Generated keys are 256 bits from `crypto/rand` (43 characters of URL-safe base64). Keys are Go strings and are **not** zeroised
  in memory.
* An operator-supplied `LLMCTL_API_KEY` must match `[A-Za-z0-9_-]{32,512}` **and** pass the entropy floor, because security rests
  on key entropy - the failed-authentication throttle labels and slows guessing but never refuses a correct guess:
  at least 8 distinct characters; no character used more than `max(8, ceil(length/3))` times; not a shorter block repeated; and about
  128 estimated bits (`length x log2(alphabet)`, the alphabet being the character classes present: `a-z`, `A-Z`, `0-9`, `-_`).
  `aaaa...` (32 times), `abab...` and `0123456789` repeated are refused with a message that names the rule, never the value.
  The floor is a cheap guard against the obviously weak, not a proof of randomness. `openssl rand -hex 16` (128 bits) passes.
  A weak key already stored in the key file refuses the gateway start (exit 4) with the rule named; `llmctl decide key rotate`
  replaces it (rotation accepts a well-formed weak key as the thing being replaced, and never keeps it as an overlap key).
* Comparison is constant time over fixed-length (32 byte) HMAC-SHA-256 digests of the candidate and of every accepted key, so
  neither the key length nor an early exit is observable through timing. Credentials longer than 512 bytes can never be a key and
  are refused before comparison.
* Several `Authorization` headers on one request are never a valid credential, even if every one carries the valid key.
* The key is never on a command line and never printed except by `llmctl decide key show --yes-print`.

## Rotation and revocation

* `llmctl decide key rotate [--grace N]` writes a new key. With `--grace N` the old file key stays valid for `N` seconds **only if it
  was an accepted key**. When a different `LLMCTL_API_KEY` is set in the environment it shadows the file key; the file key was
  never accepted, so keeping it as an overlap key would *widen* the accepted set (possibly re-arming the very key being rotated
  away from). In that case `--grace` is skipped, the old file key is dropped, and the command says so. The rule is also enforced
  where keys are **accepted**, not only where they are written: the gateway honours `LLMCTL_API_KEY_PREVIOUS` **only when the
  access key itself comes from the env file** (and only while it is unexpired and passes the entropy floor). With an
  environment-sourced key the file is not consulted at all, so a rotation run from a shell that lacks the gateway's environment
  can never widen what the gateway accepts, and an unusable `.env` cannot take an environment key down.
* `key rotate` always prints a `scope:` line: the rotation changes the key in the env file only and **does not affect a gateway that
  takes `LLMCTL_API_KEY` from its own environment** (a service unit, a supervisor). The CLI sees only its own environment, not the
  gateway's, so it cannot tell; such a gateway keeps accepting its environment key and ignores the file.
* Revocation: rotate **without** `--grace` and restart, or edit the key out of the file - **for a gateway whose key comes from the
  file**. For a gateway that gets `LLMCTL_API_KEY` from its own environment, revoke by changing or unsetting that variable where the
  gateway gets it (the service unit, the supervisor) and restarting the gateway; rotating the file does nothing to it. The gateway re-reads the key source about
  once a second. If the source becomes unreadable, unsafe (symlink, foreign owner, loose mode) or yields no key, the previous
  keys stay valid for **5 seconds**, the first occurrence of each problem is printed once on the gateway's stderr (no secret),
  `llmctl_decide_key_source_errors_total` counts every failed refresh, and after the grace **every request is refused** until the
  source is usable again. Nothing is silently kept alive. At start the gateway reads the accepted-key set once and refuses to
  start (exit 4) if that fails, so a configuration that cannot keep serving fails at start, not seconds into production.

Observed with the real binary on a scratch gateway (2026-10-09): `key rotate --grace 20` while the gateway ran -> the new key answered 200 within 2 s (the shortest wait tried) without a restart, the old key answered 200 inside the grace and **401 after it**.
The stored overlap lives in the env file as `LLMCTL_API_KEY_PREVIOUS` and `LLMCTL_API_KEY_PREVIOUS_EXPIRES` (epoch seconds); `key doctor` then adds `rotation overlap: a previous key is stored in the env file`.

## Certificates and private-key files

Checked every time the certificate is loaded - at start and on `SIGHUP` reload:

* `v-N/leaf.key` and a BYO `byo/key.pem` must be **regular files owned by the user running llmctl with no group/other permission
  bits** (`chmod 600`). A symbolic link is refused, not followed. Files are opened with `O_NOFOLLOW|O_NONBLOCK` and judged on the
  opened descriptor (no check-then-use window, no hang on a FIFO). The error names the file and the exact fix. `llmctl decide
  cert doctor` stays read-only and *reports* the same problems.
* A BYO key that is RSA below 2048 bits or an EC key below 256 bits is refused. A BYO certificate that is a CA (`CA:TRUE`, what
  `openssl req -x509` produces by default) or whose extended key usage lacks `serverAuth` is *warned about* (strict clients will
  refuse it), not refused.
* The offline CA key export (`ensure --offline-ca-key DEST`) never writes into an existing file and never follows a symlink: the key
  goes to a `0600` temporary file created with `O_EXCL|O_NOFOLLOW` next to `DEST`, is fsynced and published with `link(2)`
  (fails if `DEST` exists). An existing `DEST` is refused, and the CA key stays on the host, unless you pass
  `--force-overwrite-ca-export`, which replaces the directory entry itself (even a symlink, without writing through it).
  On a medium without hard links (vfat, exFAT: the usual USB stick) `link(2)` is refused by the filesystem; the export then creates
  `DEST` directly with `O_EXCL|O_NOFOLLOW` (same no-overwrite, no-symlink guarantee). The copy is verified by **content**, not by
  mode bits (a vfat mount reports mount-derived modes); if verification fails, the copy on the medium is removed again and the
  message says so (or says that it could not be removed and must be deleted by hand). The CA key stays on the host in that case.
* The TLS private key that is served is the one that was validated on the opened descriptor: its bytes are kept from that read and
  paired with the chain file, not re-opened by path afterwards.

## Placement guard

A secret is never **created** inside a git work tree that git does not ignore (FR-087): the access key (`.env`), the certificate
directory and the request-log key (`decide/log.key`) all use one shared implementation (`internal/placement`). It fails
**closed**: only "git is not installed", "not a git repository" and "git says the path is ignored" allow creation; a timeout,
"dubious ownership", a corrupt repository or any other git answer refuses, with the fix in the message. `GIT_DIR`,
`GIT_WORK_TREE`, `GIT_INDEX_FILE` and the other redirecting variables are scrubbed before git runs. The guard governs
**creation of private keys**: for the certificate directory it runs whenever `<home>/cert` does not exist yet **and** whenever the CA
or leaf key is about to be generated, even if `<home>/cert` already exists (an empty directory, one kept by a `.gitkeep`, or a symlink
into the work tree are all refused when git does not ignore them). It is skipped only for an installation that is already
provisioned (the `current` link resolves to a version directory): a restart, a `SIGHUP` reload or a renewal then creates no first
key, so a transient git fault (timeout, "dubious ownership" of an enclosing repository) cannot stop a gateway that is already
provisioned.

## Connection admission

See "Connection admission" in `docs/decide-gateway.md` for the model (unauthenticated vs authenticated budgets, eviction,
`/64` and `/48` aggregation, pre-authentication timeout) and `specs/009-jev-decision-models/contracts/env-vars.md` for every
tunable. A volumetric network attacker is out of scope: put a firewall or a rate-limiting reverse proxy in front of an exposed
gateway.

## Request log

Every write failure of the request log (full disk, `EACCES`, a refused symlinked path) is counted in
`llmctl_decide_audit_write_failures_total` and the first one is printed once on stderr; the request itself is not failed.

## Loopback engines and port squatting

The gateway reaches each engine over HTTP on `127.0.0.1` and presents a separate internal key (a `0600` file, never the
environment or argv). Loopback HTTP cannot authenticate the **server**: while an engine is down, any other local user can bind its
port, and the gateway would then send that process the internal key and the decision state routed to the engine. Mitigations in
place: engines bind loopback only; the key is per profile/instance and re-read on every use, so a rotation (restart the engine and
the key file changes) invalidates anything a squatter captured; registry entries are `loopback_only`; the gateway never follows
an HTTP redirect from an engine. **Residual risk:** on a *multi-user host*, a local user who wins the race for an engine's port
receives one request's state and the current internal key before the next rotation. Use a single-user host (or a container /
separate user namespace per user) when decision state is sensitive, rotate the internal key after any suspected squatting, and
prefer a per-user `LLMCTL_PORT_RANGE` (the default) so users do not compete for the same ports. Unix-domain sockets with
peer-credential checks would close the gap and are not implemented.

## Honest limits

* No cipher-suite list is pinned: Go's defaults apply (TLS 1.2 minimum; TLS 1.3 preferred; session tickets disabled).
* Keys are not zeroised in memory; a local user who can read the gateway's memory or `/proc/<pid>/environ` is out of scope.
* The entropy floor is an estimate, not proof of randomness.
* Connection admission bounds what one source can take; it cannot stop a distributed flood. When a per-source or per-`/48` cap is hit,
  the newcomer is admitted and that source's own oldest unauthenticated connection is evicted, so clients that share a NAT address or
  a carrier `/48` can push each other out of the unauthenticated pool among themselves (never an authenticated connection).
* The constant-time key comparison hashes every accepted key per request; its duration still depends weakly on the accepted key's
  SHA-256 block count (64-byte granularity) and on whether a grace-period key is active (one extra HMAC). This residual is negligible
  next to network jitter and is documented rather than removed.
* Stopping the gateway pins the process with a pidfd on Linux (through `golang.org/x/sys/unix`). Off Linux (macOS) there is no
  pidfd: the process is identified with `ps` (an executable path containing a space is not recognised and the stop is refused, the safe
  direction), re-verified immediately before `kill(2)`, and no raw system call is issued.
