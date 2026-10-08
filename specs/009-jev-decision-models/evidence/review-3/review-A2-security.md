# Independent review 3, scope A2: re-review of the security fixes

| Field | Value |
|---|---|
| Reviewer | independent adversarial reviewer, round 2 (did not write the code, did not do round 1) |
| Date | 2026-10-07 |
| Tree | `main`, HEAD `a9ebefe` plus the uncommitted work tree |
| Input | `evidence/review-2/review-A-security.md`, including the fixer's "Fix status" section |
| Verdict (source) | **NO-GO**: 0 BLOCKING, 2 IMPORTANT, 7 MINOR source defects |
| Verdict (tests/docs) | 1 IMPORTANT test-instrumentation finding (a reviewer mutation survives), 1 MINOR test gap |

## How the review was done

1. **Static review first.** I read every file in scope, plus their callers. The make-test marker (`p4-make-test.done`) did not exist at that point, so nothing ran.
2. **After the marker appeared:**
   - I copied the module (`go.mod`, `go.sum`, `internal/`, `cmd/`, `submodules/containers`, `models/catalog.json`) into a scratchpad `mktemp -d` directory and ran everything there. That directory has been deleted by its exact name. The repository was never modified.
   - **Baseline:** `go test -count=1 -race -timeout 300s` on `internal/server`, `internal/keyring`, `internal/gateway`, `internal/certs`, `internal/placement`, `internal/audit` and `cmd/llmctl-decide` (go1.26.0 linux/amd64). Every package printed `ok`. `internal/server` took 29.7 s.
   - **Five reviewer probes,** written as throw-away tests (P1, P2, P2b, P3, P4 below). Their output is quoted with each finding.
   - **Four reviewer-authored mutations** (M1–M4, at the end). After each run the mutated file was restored from the repository, and `diff -r -q` showed no difference.
3. **Not done:** a live multi-host load test, IPv6 tests on real addresses (the host has only `::1`), a vfat or exFAT mount (that needs root), and anything on macOS or MIPS.

## Round-1 findings: verification

| Id | Status after the fix | Evidence |
|---|---|---|
| A-01 | **Fixed for the round-1 scenario.** Residual hardening gaps: A2-03, A2-04. | `server/slots.go:95-122` evicts the oldest unauthenticated connection of the heaviest source instead of refusing. `conn.go:83-108`: a pre-auth timer, and promotion on the valid key. `limits.go:44`: 32 of 64 slots are unauthenticated, the rest are reserved. `TestValidKeyClientIsServedWhileHostileSourcesHoldTheSlots` passes. |
| A-02 | **Fixed.** Portability residual: A2-07. | `gateway/proc.go:175-213`: `serve` must be `argv[1]` by position. With identity in the pidfile, the check is executable device and inode plus start ticks (`216-235`). Signalling is pidfd-pinned before verification, with re-verification when there is no pidfd (`280-300`). Tests: `review2_test.go:448` (carrier), `:491`, `:552`. |
| A-03 | **PARTIAL: not fixed in the operational case.** See **A2-01**. | `keyring.go:489-498` judges "accepted" from the environment of the process running `key rotate`, not the gateway's environment. Probe P1 shows the widening still happens. |
| A-04 | **Fixed.** | `placement/placement.go:131-180`: fail-closed, with `GIT_*` variables, `LC_ALL` and `LANGUAGE` scrubbed (`50-72`). Shared by keyring, certs and audit. |
| A-05 | **Fixed.** | `audit/logkey.go:78-88`: the guard runs before the log key is created. |
| A-06 | **Fixed.** | `keyring.go:228-273`: entropy floor. A Monte Carlo of 2,000,000 random 128-bit hex keys gave a false-reject rate of 3e-6, which matches the "about 1 in 200,000" comment in order of magnitude. `throttle.go:78-116`: throttled entries are never evicted, and there is a progressive delay. |
| A-07 | **Fixed.** Negligible residual: A2-09. | `keyring.go:521-541`: fixed-length HMAC digests. `handlers.go:229`: the length gate equals `MaxKeyLen`. |
| A-08 | **Fixed.** | `gateway/driver.go:182-208`: `noRedirect` on the shared client and also forced onto any client a caller supplies. `postOnce` is the only engine request path. Test: `review2_test.go:693`. |
| A-09 | **Fixed.** | `server.go:210-221` re-applies `hardenTLS` to the config returned by `GetConfigForClient`. |
| A-10 | **Fixed.** Residual: A2-08. | `certs/certs.go:272-285`, `secfile.go:26-93`: owner, mode and no-symlink checks on the descriptor; a weak BYO key is refused; CA and EKU problems give warnings. |
| A-11 | **Fixed for overwrite and symlinks.** New portability regression: A2-06. | `secfile.go:104-154`: `O_EXCL\|O_NOFOLLOW` temporary file, then `link(2)` (or `rename(2)` with `--force-overwrite-ca-export`). |
| A-12 | **Fixed.** | `keyring/env.go:93-165`, `certs/secfile.go:26-60`, `audit/logkey.go:32-63`: `O_NOFOLLOW\|O_NONBLOCK`, the checks run on the fd, then `fchmod`. |
| A-13 | **Fixed as designed, but the fail-closed rule introduced an availability regression.** See **A2-02**. | `cmd/llmctl-decide/serve_hardening.go:46-84`. |
| A-14 | **Fixed.** | `handlers.go:192-203`: a bounded counter, plus one stderr line. |
| A-15 | **Fixed.** | `serve_hardening.go:94-122`, `cmd_serve.go:482`, `:544`. |
| A-16 | **Documented,** in `docs/tls-and-keys.md`, section "Loopback engines and port squatting". | Unix-domain sockets are honestly marked as not implemented. |
| A-17, A-18 | **Tests exist and pass.** | They are listed in the fix status. I confirmed that every one of the 20 named tests exists by name. |

## New findings

### A2-01: IMPORTANT, source-defect. `key rotate --grace` still widens the accepted set when the rotating shell lacks the gateway's environment key (A-03 not really fixed)

- **Location:**
  - `internal/keyring/keyring.go:489-498`: `Rotate` decides whether the old key was "accepted" by comparing it with `env[KeyVar]` of **the CLI process**.
  - `keyring.go:411-439`: `AcceptedKeys` (the gateway side) still adds the file's PREVIOUS key whatever `res.Source` is.
- **Scenario,** the operationally normal case and the one round 1 described:
  1. The gateway runs with `LLMCTL_API_KEY=E` in its environment, for example from a systemd unit or a supervisor.
  2. The operator runs `llmctl decide key rotate --grace 3600` from an ordinary login shell that does not export `LLMCTL_API_KEY`.
  3. `Rotate` sees `effective == old == F` and writes F as PREVIOUS.
  4. Within about 1 s the gateway accepts both E and F. F may be exactly the leaked key being rotated away.
- **Proof (probe P1, this session):** `PROBE P1: before=1 after=2 F_accepted_after=true graceSkipped=false prevExpires=13600`.
- **Why the guard test misses it:** `TestRotateGraceUnderEnvShadowDoesNotWidenTheAcceptedSet` (`keyring/hardening_test.go:14`) passes the same `env` map to `Rotate` and to `AcceptedKeys`, so the case where the two processes differ is never tested.
- **Fix:** enforce the rule where keys are accepted. `AcceptedKeys` adds PREVIOUS only when `res.Source == "file"`, and only when PREVIOUS also passes `WeakKey`. Today a hand-written weak PREVIOUS is accepted, because only `keyRE` is checked. Keep the `Rotate` check as a second layer. Add a RED test in which `Rotate` gets `Environ{}` and `AcceptedKeys` gets `{E}`.

### A2-02: IMPORTANT, source-defect. Delayed total lockout. With an environment-sourced key, an unusable `.env` lets the gateway start and then refuses every valid key after 5 s

- **Location:**
  - `cmd/llmctl-decide/cmd_serve.go:285`: `Resolve` with an environment key never reads the file, so the start succeeds.
  - `cmd_serve.go:424-428`, `keyring.go:411-421`: `AcceptedKeys` reads `.env` every second for PREVIOUS, and any error makes the whole call fail.
  - `serve_hardening.go:79-84`: after `keyStaleGrace` (5 s) the cache returns `nil`.
- **Scenario:**
  1. The key comes from the environment (a service unit). The `<root>/.env` file is any of:
     - a symlink (a common dotfiles pattern);
     - owned by another user (a root-owned install root with the gateway running as a service user);
     - a non-regular file;
     - unparseable;
     - holding a malformed or weak `LLMCTL_API_KEY`.
  2. The gateway prints its banner and listens.
  3. 5 s later every request carrying the valid key gets 401.
  4. Every failure is also charged to the client's source in the throttle, so the client soon gets 429 and the progressive delay.
  5. This persists until someone repairs a file that the effective key does not even come from.
- **Proof (probes P2 and P2b, this session):**
  - `PROBE P2: Resolve(start) err=<nil> source=env ; AcceptedKeys(per-second) n=0 err=env file …/.env is a symlink; refusing to follow it …`
  - `PROBE P2b: start ok (source env); accepted keys at t=0: 1, at t=6s: 0 (valid env key refused)`.
  - Round 1's behaviour, keeping the last good set, did not have this outage. The fix for A-13 introduced it.
- **Fix:** both of the following.
  1. When the source is `env`, do not consult the file at all. This is the same change as A2-01; PREVIOUS is file-only by design.
  2. At serve start, call `AcceptedKeys` once and refuse to start, with exit 4, if it errors. A configuration that cannot keep serving must fail at start, not 5 s into production.
- **Test:** an environment key plus a symlinked `.env` must either refuse at start or keep accepting the environment key after the grace.

### A2-03: MINOR, source-defect. Eviction ranks victims by /64 count only; the /48 aggregate is ignored

- **Location:** `internal/server/slots.go:124-137` (`pickVictim`).
- **Scenario:**
  1. An attacker with two /48s opens one unauthenticated connection from each of 32 /64s, 16 per /48, which stays within the aggregate cap.
  2. Every holder ties at `perU = 1` with a lone legitimate client, so the oldest is evicted.
  3. **Probe P3:** the legitimate connection was evicted after 32 attacker admissions.
- **Context:** the code comment admits that "more distinct /64 than maxUnauth can churn", but the aggregate the fix introduced plays no part in choosing the victim.
- **Fix:** rank by `aggU[e.agg]` first, then by `perU[e.src]`, then by age. The attacker then needs 32 distinct /48s instead of 32 /64s.

### A2-04: MINOR, source-defect. The per-source and per-aggregate caps still refuse the newcomer rather than evicting that source's own oldest pre-auth connection

- **Location:** `slots.go:97-100`.
- **Scenario:**
  1. A neighbour behind the same NAT IPv4 address, or in the same carrier /48 (mobile IPv6 commonly hands each device a /64 out of a shared /48), holds 8 (or 16) unauthenticated connections and renews them every 3 s.
  2. Every other client behind that address or prefix is RST at Accept, although the global pool has room.
  3. **Probe P4:** `9th connection from the shared source admitted=false (global unauth in use 8 of 32)`.
- **Impact:** low for a LAN-oriented gateway, but it is the round-1 A-01 shape ("refuse the newcomer") one level down.
- **Fix:** when the source or aggregate cap is hit, evict that source's (or that aggregate's) oldest unauthenticated connection instead of refusing.

### A2-05: MINOR, source-defect. The certificate placement guard runs on every start, renew and SIGHUP reload, not only on creation; fail-closed turns a transient git fault into a failed start

- **Location:** `internal/certs/placement.go:28-43` (`prepareDir`, called unconditionally), reached from `certs.go:375` (`Ensure`: serve start and `cert reload`) and `:484` (`Renew`).
- **Contrast:** keyring (`keyring.go:333`) and audit (`logkey.go:78`) check only before **creating** the secret, which is what FR-087 says ("never created inside").
- **Scenario:** `$HOME/llmctl` already holds certificates. `git` then times out (more than 5 s, for example on a busy NFS home) or reports "dubious ownership" for an enclosing repository owned by another uid. `serve` now refuses to start, and SIGHUP reloads fail, although nothing is being created.
- **Fix:** run `CheckPlacement` only when `<home>/cert` does not exist yet.

### A2-06: MINOR, source-defect (UNCONFIRMED by run). The offline CA key export depends on `link(2)` and strict POSIX modes, so it fails on vfat or exFAT, the usual "offline" medium

- **Location:** `internal/certs/secfile.go:137-145` (`os.Link` unless `--force-overwrite-ca-export`) and `ca.go:255` (`readPrivate(dest, strict=true)`).
- **Scenario,** exporting to a USB stick:
  1. `link()` on vfat returns `EPERM`, so `cert ensure --offline-ca-key` fails with a raw error. That nudges the operator toward the `--force…` flag, whose purpose is overwriting.
  2. With force, the export succeeds. But vfat reports mount-derived modes (often 0755), so the strict mode check fails. The command says "verification failed; the key was NOT removed from the host" but leaves a full copy of the CA private key on the stick without mentioning it.
- **Status:** `UNCONFIRMED:` I could not mount vfat without root. The statement rests on documented `link(2)` and vfat semantics.
- **Fix:**
  - Publish with `open(dest, O_CREAT|O_EXCL|O_NOFOLLOW)` and write in place. That is already an atomic no-overwrite that never follows a symlink, and it needs no hard links.
  - Verify the copy by content only; the mode check on the medium is not meaningful there.
  - On any verification failure, remove the destination copy or name it in the message.

### A2-07: MINOR, source-defect. pidfd syscall numbers are hard-coded with no Linux build constraint

- **Location:** `internal/gateway/proc.go:324-346`. `syscall.Syscall(434, …)` and `424` are called **before** verification (`:280`).
- **Problem:**
  - These numbers are right on amd64 and arm64.
  - On linux/mips, mips64 and mipsle they are wrong: 434 is another syscall there (the MIPS tables are offset by 4000 or 5000).
  - The file has no `//go:build linux`, and llmctl supports macOS. There, `syscall.Syscall` goes through libc `syscall(2)`, and 434 is a different BSD syscall, UNCONFIRMED but recalled as `pid_resume`, applied to the target pid.
  - The fallback logic itself (re-verify immediately before `kill`) is correct.
- **Fix:**
  - Use `golang.org/x/sys/unix.PidfdOpen` and `unix.PidfdSendSignal` (already an indirect dependency) in a `_linux.go` file.
  - Elsewhere, use a stub that returns `ENOSYS`.
  - Keep the verification before signalling.

### A2-08: MINOR, source-defect. The private key served by TLS is re-read by path after `load()` validated it on a descriptor

- **Location:** `cmd/llmctl-decide/cmd_serve.go:383-393`. `tls.LoadX509KeyPair(chain, info.LeafKey)` opens the key by path, following symlinks, after `certs.load` → `parseKeyFile(…, enforce)` checked a **different** open.
- **Impact:** the A-10 and A-12 guarantees (owner-only, not a symlink, regular file) do not bind to the bytes actually served. A same-uid swap between the two opens bypasses them, both at start and on SIGHUP. The risk is low because it needs the same uid.
- **Fix:** have `certs` return the validated key bytes, or a `tls.Certificate` built from them, and use those.

### A2-09: MINOR, source-defect (negligible). Comparison timing still depends on the accepted key's SHA-256 block count and on how many keys are accepted

- **Location:** `keyring.go:531-541`.
- **The leak:** `digest(k.Reveal())` is recomputed per request. A key longer than 55 bytes costs an extra compression block, and a second key during a grace period costs another HMAC. A-07's leak is reduced to 64-byte granularity plus a one-bit "grace window active" signal.
- **Fix (optional):** precompute the accepted-key digests when the cache refreshes.

## Test-instrumentation findings

### A2-T1: IMPORTANT, test-instrumentation. A reviewer mutation that permanently locks out IPv4 clients survives the whole suite

- **The mutation (M4):** in `slots.go` `removeLocked`, delete the `aggU` decrement (lines 155-157).
- **Effect:** for IPv4 the aggregate is the address itself. Every connection that closes unauthenticated then leaks one unit of the aggregate budget: every `/healthz` probe connection, every failed handshake, every client that drops before its first keyed request.
- **Consequence:** after 16 such connections the address is refused at Accept forever, until restart. That includes a monitoring host or the valid-key client itself.
- **Coverage gap:** `go test ./internal/server/` stays `ok`. `tests/test_decide_security_mutation.sh` mutates only the aggregate **cap** (line 74), not the bookkeeping.
- **Fix:** add a test that admits and releases more than `maxUnauthAgg` unauthenticated connections from one source, sequentially, and asserts that the next one is still admitted. Add the same cycle for eviction, so that both `release` and `removeLocked` on the eviction path are covered.

### A2-T2: MINOR, test-instrumentation. The A-03 guard test cannot fail on the real defect

- **Gap:** see A2-01. The test uses one shared `env` for the CLI and the gateway.
- **Fix:** add the case with separate environments as the RED test for A2-01.

## Reviewer-authored mutations (this session, scratch copy, `go test -count=1 -timeout 300s`)

| # | Mutation | Result |
|---|---|---|
| M1 | `slots.go` `pickVictim`: invert the age tie-break (evict the newest instead of the oldest) | killed (`slots_test.go:42`) |
| M2 | `conn.go` `markAuthed`: never call `entry.promote()` | killed (`server_test.go:1038`, `:1092`) |
| M3 | `slots.go` `admit`: drop the `aggU >= maxUnauthAgg` refusal | killed (`slots_test.go:112`) |
| M4 | `slots.go` `removeLocked`: drop the `aggU` decrement | **SURVIVED** (see A2-T1) |

## Attacker questions from the brief: answers

- **Can the new eviction starve authenticated clients?**
  - No: eviction only ever picks unauthenticated entries (`slots.go:128`), and at least `MaxConns - MaxUnauthConns` slots are reserved.
  - It can evict legitimate pre-auth clients, including clients on slow links (3 s covers the TCP and TLS handshake plus the request headers). This needs more distinct /64s or addresses than `maxUnauth`, which the code honestly states, or a shared source (A2-03, A2-04).
- **Can a hostile source keep authenticated slots with a leaked key?**
  - Yes, up to `MaxConnsPerSource` per source, held until `IdleTimeout` and renewable with keep-alive. Enough sources can fill every slot.
  - That is inherent once the key leaks. The remedy is `key rotate` without `--grace`, which A2-01 currently undermines when the key source is the environment.
- **Does the A-01 redesign add a timing or oracle signal?**
  - None found. Authentication status changes only slot bookkeeping, and the progressive delay applies only to failures.
- **Can a transient filesystem error lock out every client?**
  - A single failed read cannot: the cache retries every second and serves the old set for 5 s.
  - A persistent, unrelated `.env` fault can, and silently after a clean start. That is A2-02.
- **Does the weak-key rejection brick an existing installation?**
  - No. A weak file key refuses the start with exit 4 and a named remedy, and `key rotate` explicitly accepts a well-formed weak old key (`keyring.go:473-480`).
  - A weak environment key needs "unset it", and the message says so.
  - Clients still configured with the weak key break. That is the intended, documented consequence (CHANGELOG, `docs/tls-and-keys.md:30`).
- **TOCTOU and symlink races in the descriptor-based checks:**
  - These are sound for `.env`, `log.key` and certificate keys, except A2-08.
  - The `link(2)` export does not follow a symlink at the destination (`link` fails with EEXIST on any existing name), and the temporary file is `O_EXCL|O_NOFOLLOW` with a random name.
- **pidfd fallback:**
  - The logic is correct (re-verify, then `kill`). Portability: A2-07.
- **Races under `-race`:** none reported in the 7 packages run.

## Honest boundaries (§11.4.6)

- **Not run:**
  - **A2-06:** no vfat mount was possible.
  - **A2-07:** no macOS or MIPS host.
  - **A2-03 and A2-04 are unit-level probes** against `slotTable`. No live multi-address load test was run.
- **A2-02:**
  - **Shown:** the start succeeds, then `keyCache` serves zero keys after 6 s.
  - **Not exercised:** the full HTTP 401 against a running gateway. That last step follows directly from `handlers.go:237` (`len(keys) > 0 &&`).
- **Not re-reviewed:** `metrics` cardinality and the docs prose beyond the lines cited.

## Verdict

- **SOURCE: NO-GO.**
  - There are two IMPORTANT source defects:
    - **A2-01:** A-03 is still exploitable in the normal operating case.
    - **A2-02:** an availability regression introduced by the A-13 fix.
  - Both are fixed by one coherent change: PREVIOUS only for a file-sourced key, plus a start-time `AcceptedKeys` check.
  - The seven MINOR items (A2-03 to A2-09) should be fixed or tracked.
- **Tests and docs: NO-GO for the guard suite until A2-T1 is closed.**
  - The `aggU` bookkeeping mutation surviving means an outage-class regression is unguarded.
  - A2-T2 must become the RED test for A2-01.
  - The docs are accurate for what they claim.
