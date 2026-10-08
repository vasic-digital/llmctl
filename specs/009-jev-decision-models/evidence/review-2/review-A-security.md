# Independent review 2, scope A: security-critical Go

| Field | Value |
|---|---|
| Reviewer | independent adversarial reviewer (did not author the code) |
| Date | 2026-10-07 |
| Tree | `main`, HEAD `a9ebefe` plus the uncommitted work tree |
| Scope | `internal/keyring`, `internal/certs`, `internal/server`, `internal/audit`, `internal/metrics`, `internal/gateway/keyfile.go` (plus the engine-key hop in `driver.go` and `proc.go`), `cmd/llmctl-decide/cmd_key.go`, `cmd_cert.go`, `cmd_serve.go` |
| Spec anchors | FR-019, FR-022, FR-057..FR-073, FR-087 |
| Verdict (source) | **NO-GO**: 0 BLOCKING, 5 IMPORTANT, 11 MINOR source defects |
| Verdict (tests/docs) | 2 MINOR test-instrumentation findings (A-17, A-18); 1 process-doc item folded into A-16 |

## How the review was done

What was run in this session (§11.4.5):

- **Read every file in scope.** Every finding was checked against the code it cites.
- **Baseline run of the targeted tests:** `go test -race -count=1 ./server/ ./keyring/ ./certs/ ./audit/ ./metrics/` (in `internal/`). All 5 packages passed.
- **Mutations I wrote myself (§11.4.194(6)(d)).** I ran them on a copy of the module in a scratchpad `mktemp -d` directory, deleted afterwards by its exact name. Results are in A-17.
- **Three reviewer probes, run against that copy.** None was left in the repository:
  1. A carrier process is accepted as the gateway by `VerifyServeProcess` (A-02).
  2. `key rotate --grace` under an environment-shadowed key widens the accepted key set (A-03).
  3. The certs placement guard fails open when `git` errors (A-04).
- **A standalone Go program** (scratch module, deleted afterwards) showed that a default `http.Client` follows a 307 redirect. It forwards `Authorization` and the POST body to another port on 127.0.0.1 (A-08).

What I did not do: the full suite was not run (as instructed), there was no live TLS cipher scan, no fuzzing, and no network tests. The `contract`, `registry` and `client` packages are out of scope and were not reviewed.

## Findings

### A-01: IMPORTANT, source-defect. A handful of sources can take every connection slot (FR-022 "without affecting others")

- **Location:**
  - `internal/server/limits.go:33`: defaults `MaxConns 64`, `MaxConnsPerSource 8`.
  - `internal/server/conn.go:26-39`: Accept-time shedding.
  - `internal/server/conn.go:73`: the slot is held for `HandshakeTimeout`, 3 s.
  - `internal/server/slots.go:24-44` and `slots.go:60-77`: an IPv6 source is a /64.
- **Scenario:**
  1. Eight IPv4 hosts each open 8 bare TCP connections and send nothing. Each holds a slot for 3 s, and they reconnect in a loop.
  2. Alternatively, each sends one unauthenticated `GET /healthz` and then idles. The slot is then held for `IdleTimeout`, 60 s.
  3. All 64 global slots are now held. Every further connection, including one that carries the valid key, is RST at Accept.
  4. An attacker with a single IPv6 /48 controls 65,536 "sources", so the per-source cap gives no protection at all.
- **The existing test pins this behaviour as correct.** `TestGlobalCapShedsEveryoneBeyondIt` (`server_test.go:940`) asserts that 3 sources holding raw connections shed a 4th.
- **Fix:** do not refuse a new connection while slots are held by connections that have not authenticated or are idle. Options:
  - When the global cap is reached, evict the oldest connection that is still pre-handshake or in `StateIdle`, instead of RST-ing the newcomer.
  - Keep a reserve, or shorten idle and handshake hold times, as occupancy rises.
  - Add a test: N hostile sources hold slots and a valid-key client from another source is still served.

### A-02: IMPORTANT, source-defect. `serve --stop` can SIGTERM an unrelated same-uid process (carrier match, PID reuse)

- **Location:** `internal/gateway/proc.go:71-99` (`VerifyServeProcess`) and `proc.go:126-158` (`StopGateway`).
- **Defect 1, the match accepts a carrier.** Every cmdline argument is split on whitespace. Any word whose base name is `llmctl-decide`, plus any word `serve`, satisfies the check.
  - **Proof (probe, this session):** `bash -c "sleep 30; : watch llmctl-decide serve --status"` gives `VerifyServeProcess(pid, "llmctl-decide") = nil`, although the executable is `bash`.
  - Real processes that would match: an operator's `watch llmctl-decide serve --status`, `journalctl ... llmctl-decide serve`, `less ...`, and so on.
- **Defect 2, the pidfile start time is never checked.** The pidfile records `<pid> <start>` (`WritePidfile`), but nothing compares it with the process start time in `/proc/<pid>/stat`.
- **How the two combine:**
  1. The gateway is SIGKILLed or OOM-killed, which leaves a stale pidfile.
  2. The PID is reused by a matching carrier.
  3. `serve --stop` then sends it SIGTERM.
  4. There is also a smaller race between verify and kill.
- **Why this matters:** it violates the spirit of §11.4.174 (verify a process is ours) and §11.4.201(7)(a) (match the thing, not a carrier).
- **Fix:**
  - Require `/proc/<pid>/exe` to be the gateway binary, compared by device and inode with the executable, not by base name.
  - Require the process start time to equal the pidfile start time, within one second.
  - Signal through `pidfd_open` and `pidfd_send_signal` to close the reuse race.
  - Drop the whitespace-split matching. The `exec -a "name serve"` case is a test artefact.

### A-03: IMPORTANT, source-defect. `key rotate --grace` under an environment-shadowed key starts accepting a key that was never accepted

- **Location:** `internal/keyring/keyring.go:396-411` (`Rotate` copies the old FILE key to `LLMCTL_API_KEY_PREVIOUS`) and `keyring.go:348-361` (`AcceptedKeys` accepts the file's PREVIOUS key regardless of the key source).
- **Scenario:**
  1. The operator runs the gateway with `LLMCTL_API_KEY=E` in the environment. The `.env` file holds an older key F, perhaps kept because F leaked.
  2. The operator runs `key rotate --grace 3600`.
  3. F becomes PREVIOUS. Within about 1 s (`keyFunc` caches for 1 s) the running gateway accepts both E and F, until the grace expires.
- **Proof (probe, this session):** before rotation `E=true F=false (n=1)`; after `rotate --grace` `E=true F=true (n=2)`.
- **The CLI warning does not cover this.** It says only that the new key is shadowed. It says nothing about the old file key being re-armed.
- **Fix:** when the key source is `env`, do not write PREVIOUS, or refuse `--grace` with an explanation. Alternatively, `AcceptedKeys` accepts PREVIOUS only when the current key's source is `file`.

### A-04: IMPORTANT, source-defect. The certificate placement guard fails open on any `git` error (FR-087)

- **Location:** `internal/certs/placement.go:27-34`.
- **The defect:** `if err != nil || strings.TrimSpace(string(out)) != "true" { return nil }`. A git error, a timeout (10 s), "dubious ownership" (exit 128) or a corrupt repository therefore all mean creation is **allowed**.
  - `GIT_DIR`, `GIT_WORK_TREE` and the other git variables are not scrubbed, so an ambient `GIT_DIR` makes git answer about a different repository.
- **Contrast with the access-key guard.** `internal/keyring/placement.go` fails closed on a timeout or an unexpected answer, and it scrubs those variables.
- **Proof (probe, this session):** with a `git` on PATH that prints "dubious ownership" and exits 128, `CheckPlacement(...)` returns `<nil>`.
- **Fix:** mirror the keyring logic. Allow only on "not a git repository" or git missing, refuse everything else, and scrub the `GIT_*` variables. Ideally share one implementation (§11.4.251).

### A-05: IMPORTANT, source-defect. The log key has no placement guard (FR-087 names "the log key")

- **Location:**
  - `internal/audit/logkey.go:68-82` (`LoadOrCreateLogKey`), called from `cmd_serve.go:373`.
  - The only placement-guard call sites are the keyring and certs call sites listed under A-04.
- **Scenario:**
  1. `LLMCTL_STATE_DIR` points inside a repository that does not ignore it, for example a developer checkout.
  2. `decide/log.key` is created there without refusal.
  3. If it is committed, anyone holding the request logs can run a dictionary attack on low-entropy `state_hash` values offline.
- **Exploitability is low:** the default is `~/.local/state`. **UNCONFIRMED:** whether another layer, such as the archive builder's tracked-only rule or `.gitignore`, covers every placement.
- **Fix:** run the shared placement guard before creating `log.key`.

### A-06: MINOR, source-defect (and process-doc). The failed-auth throttle never limits guessing, and operator keys need no entropy

- **Location:** `internal/server/handlers.go:216-238`; `internal/keyring/keyring.go:43` and `keyring.go:189-197`; `internal/server/throttle.go:60-75`.
- **The throttle does not slow guessing.** The key comparison runs before the throttle, so a throttled source still has every guess evaluated, and a correct guess succeeds. 429 is only a label; the guessing rate is not limited.
  - This follows from FR-022's "never throttle the valid key", so security rests entirely on key entropy.
- **Generated keys are safe:** 256 bits, so this is not exploitable for them.
- **Operator-supplied keys are not:** they pass `^[A-Za-z0-9_-]{32,}$`, so 32 copies of `a` is accepted.
- **The throttle table can be evicted:** past 4096 sources, for example with IPv6 /64s, an entry is evicted, which resets a source's count.
- **Fix:**
  - Reject low-entropy operator keys, for example by requiring at least N distinct characters or an estimated entropy of 128 bits or more.
  - Document plainly that the throttle labels failures and does not slow guessing.

### A-07: MINOR, source-defect. The key length leaks through comparison timing (FR-019)

- **Location:** `internal/keyring/keyring.go:423-433`.
- **The defect:** `subtle.ConstantTimeCompare` returns immediately when the lengths differ, and the 512-byte gate in `handlers.go:221` adds a second length-dependent branch.
- **Impact:** low. The key length (43 for generated keys) is public. A custom key's length is still "key information" in FR-019's wording.
- **Fix:** compare `SHA-256` (or HMAC) digests of the candidate and each key.

### A-08: MINOR, source-defect. The engine HTTP client follows redirects, bypassing the loopback guard

- **Location:** `internal/gateway/driver.go:88-92` (`sharedClient`, default `CheckRedirect`); the guard is `checkLoopback` in `postJSON` (`driver.go:96-99`).
- **Proof (Go 1.26 program, this session):** a 307 from the "engine" to another port on 127.0.0.1 gives `SINK got method=POST auth_present=true body_len=18`.
  - The internal key and the decision state follow the redirect.
  - The final 200 is accepted as the engine's answer.
  - A redirect to a non-loopback host carries the body (state) but not the key.
- **Precondition:** whatever answers on the engine port. See A-16; a port squatter already receives the key and the body directly, so this is defence-in-depth.
- **Fix:** `CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }`.

### A-09: MINOR, source-defect (latent). A TLS config supplied as `GetConfigForClient` bypasses the enforced TLS settings

- **Location:** `internal/server/server.go:172` and `server.go:193-199`.
- **The defect:** `New` accepts a config whose only certificate source is `GetConfigForClient`. The `*tls.Config` that callback returns replaces the clone, so the enforced settings no longer apply:
  - `MinVersion >= TLS1.2`
  - ALPN `http/1.1`
  - `SessionTicketsDisabled`
- **Production is not affected:** `cmd_serve.go:474` passes `GetCertificate` only.
- **Fix:** reject `GetConfigForClient`, or wrap it and re-apply the floor to the config it returns.

### A-10: MINOR, source-defect. The start does not enforce private-key file modes; BYO validation is shallow (FR-066, FR-067)

- **Location:** `internal/certs/certs.go:229-316` (`load`, the path used by `Ensure` at serve start and by SIGHUP reload).
- **What is missing:**
  - A group- or world-readable `v-N/leaf.key` or `byo/key.pem` is accepted. Only `cert doctor` reports it, although FR-066 says the private key MUST be readable only by its owner.
  - A BYO key that is a symlink is followed.
  - The BYO certificate is not checked for `CA:FALSE`, for the serverAuth EKU, or for minimum key strength. An RSA-1024 pair loads.
- **Fix:** in `load(..., enforce=true)`, refuse (or tighten) key files with group or other bits, and refuse symlinks for the BYO key. Optionally warn on weak BYO keys and on CA or EKU mismatch.

### A-11: MINOR, source-defect. The offline CA key export follows symlinks and truncates an existing destination

- **Location:** `internal/certs/ca.go:44-61` (`writeSecret`: `O_CREATE|O_TRUNC`, no `O_EXCL`, no `O_NOFOLLOW`) and `ca.go:238-258` (`exportOffline`).
- **Scenario:**
  1. The destination already exists with mode 0644: the CA private key is written into it and stays world-readable until the final `Chmod`.
  2. The destination is a symlink: it is followed.
  3. An existing file, perhaps a previous backup, is overwritten silently.
- **Fix:** for the operator destination, use `O_CREATE|O_EXCL|O_NOFOLLOW` (and refuse if it exists), then `fsync` the file and its directory.

### A-12: MINOR, source-defect. Check-then-use races on the secret files

- **Location:**
  - `internal/keyring/env.go:90-148`: `EnsurePrivate` runs `Lstat` and then `chmod(path)`, which follows a symlink swapped in between.
  - `internal/keyring/env.go:150-167`: `readFileNoFollow` has no `fstat` owner or regular-file re-check after `open`, so a FIFO swapped in blocks the reader forever.
  - `internal/audit/logkey.go:30-36`: `readKey` opens before the type check, so a FIFO hangs the gateway start.
- **Precondition:** write access to the owner-only directory, meaning the same uid. Low risk.
- **Fix:**
  - Open with `O_NOFOLLOW|O_NONBLOCK`, then `fstat` (owner, regular file), then `fchmod`.
  - `gateway/keyfile.go:46-62` already follows this pattern.

### A-13: MINOR, source-defect. Revocation by editing the file is silently ignored (fail-open)

- **Location:** `cmd/llmctl-decide/cmd_serve.go:433-450` (`keyFunc`).
- **The defect:** on any read error, or when `AcceptedKeys` returns an empty set, the last good key set stays accepted. No message is printed.
- **Scenario:** an operator removes a compromised key from `.env`, or the file becomes unsafe (owned by another user, a symlink). The old key keeps working until restart.
- **Fix:** on an error, keep serving but report once on stderr and in metrics. Document that revocation means `key rotate` (without `--grace`) or a restart.

### A-14: MINOR, source-defect. Audit write failures are invisible

- **Location:** `internal/server/handlers.go:190` (`_ = s.cfg.Audit.Write(...)`).
- **Impact:** a full disk, `EACCES` after rotation, or a symlinked log path stops the FR-079 log with no signal.
- **Fix:** count failures in a bounded metric (for example `llmctl_decide_audit_write_failures_total`) and report the first failure on stderr.

### A-15: MINOR, source-defect. The detached child keeps the legacy key variable; `--foreground` deletes the pidfile unconditionally

- **The legacy variable stays in the gateway's environment.**
  - Location: `cmd/llmctl-decide/cmd_serve.go:564` (`cmd.Env = os.Environ()`) together with `scrubLegacyKeyEnv` (`cmd_serve.go:605-618`), which scrubs only the parsed map.
  - Effect: the detached gateway still carries `LLMCTL_DECIDE_INTERNAL_KEY` in its `/proc/<pid>/environ`, which is exactly the exposure the message claims has been removed (G-040).
  - Fix: build `cmd.Env` from the scrubbed map, or filter that variable out of it.
- **The pidfile is removed even when it no longer names this process.**
  - Location: `cmd_serve.go:500` (`defer os.Remove(p.dirs.pidfile)`).
  - Effect: an instance that exits removes a pidfile that another instance may have rewritten. Combined with A-02, this hurts `--status` and `--stop` correctness.
  - Fix: remove the pidfile only if it still names this pid.

### A-16: MINOR, source-defect and process-doc. Engine-port squatting by another local user

- **Location:** design of FR-073 and `gateway/driver.go:126-149`.
- **Scenario:** while an engine is down, any local uid can bind its loopback port. The gateway then sends that process the internal Bearer key and every decision state routed to the engine. Loopback HTTP has no way to authenticate the server.
- **Fix:** document the multi-user-host threat in the security notes. Optionally, use Unix-domain sockets with peer-credential checks (`SO_PEERCRED`) for the engine hops.

## Test-instrumentation findings

### A-17: MINOR, test-instrumentation. Reviewer-authored mutations: some survive the suite

All mutations ran on a scratch copy of the module, with `go test -count=1` on the package.

| # | Mutation (reviewer-authored) | Result |
|---|---|---|
| M1 | `handlers.go`: remove the multiple-`Authorization`-headers guard (`if len(vs) != 1` becomes `if false`) | **SURVIVED** (server package `ok`). No test sends duplicate `Authorization` headers. |
| M2 | `server.go`: `SessionTicketsDisabled = false` | **SURVIVED**. Nothing asserts that tickets are off. |
| M3 | `proc.go`: drop the `hasServe` requirement | **SURVIVED** (the Verify, Stop, Status and Pidfile tests pass). Nothing asserts that a binary-named process without `serve` is refused. |
| M4 | `keyring.go`: ignore the PREVIOUS expiry | caught (`keyring_test.go:291 at expiry: 2`) |
| M5 | `handlers.go`: never reach the throttle for a present-but-wrong key | caught (`server_test.go:377`) |
| M6 | `sans.go`: drop `100.64.0.0/10` from the name constraints | caught (`certs_test.go:374`, openssl oracle) |
| M7 | `proc.go`: drop the cmdline binary-name match | the suite **hangs** until my 300 s `timeout` kills it. It does not fail with a clear message. UNKNOWN whether an assertion would eventually fire. |

Recommended tests to close the gaps:
- A duplicate-`Authorization` request is answered 401.
- `ConnectionState().DidResume == false` across two connections presented with a session cache.
- A `/proc` cmdline that has the binary name but no `serve` is refused.
- A carrier such as `bash -c '... llmctl-decide serve'` is refused (it fails today; see A-02).
- A bounded wait in the Stop tests, so a wrong match fails fast instead of hanging.

### A-18: MINOR, test-instrumentation. The transport tests pin the DoS behaviour rather than FR-022's "affecting others"

- **Location:** `internal/server/server_test.go:940` (`TestGlobalCapShedsEveryoneBeyondIt`).
- **The gap:** the test asserts that a new source is shed when other sources hold every slot. No test shows that a valid-key client survives hostile slot holders from several sources (see A-01).
- **Fix:** add that test as the RED guard for A-01.

## Verified as sound (with evidence)

- **Auth runs before routing.** Only `/healthz` and `/readyz` are exact-match unauthenticated paths (`isProbe`, `handlers.go:48`).
  - `ForwardedByClientIP=false` with no trusted proxies, so `X-Forwarded-For` cannot spoof the source.
  - The source key comes from `RemoteAddr` only (`slots.go:60`).
- **The key is not read from the query string.** `X-API-Key` is honoured only when enabled.
- **Client request ids are echoed only in the exact `[0-9a-f]{16}` shape,** so headers cannot be injected.
- **Panics produce a generic 500;** the panic text and stack are never written.
- **`ErrorLog` goes to `io.Discard`.**
- **Bodies are bounded:** a declared length over the cap gets 413 with a close, chunked bodies are capped, and lingering drain is bounded to 1 MiB and 1 s.
- **Metric labels come from allow-lists only.** Unknown paths map to `other` (`metrics.go:118-137`), so a hostile client cannot create unbounded series.
- **Audit records are built from a fixed `Fields` struct:**
  - closed vocabularies;
  - the path is stripped of query and fragment, control characters are replaced, and it is capped;
  - the output is ASCII-escaped;
  - the file is opened with `O_NOFOLLOW` and mode 0600, and reopened after rotation.
- **`Secret`, `KeyResult`, `RotateResult` and `CertInfo` redact under every fmt verb, JSON and slog.** No key value appears in any error path that I read.
- **Generated keys are 256 bits from `crypto/rand`,** with no fallback.
- **The `.env` write is safe:** it goes to an `O_EXCL|O_NOFOLLOW` temporary file at mode 0600, followed by `fsync`, `rename` and a directory `fsync`, and runs under a directory `flock`.
- **`gateway/keyfile.go` is sound:** `O_NOFOLLOW` open, then `fstat`, then owner, mode and size checks, with a `stat` stamp cache that includes the inode. The engine key never appears in errors or logs. `checkLoopback` runs before every engine call; the redirect caveat is A-08.
- **The `--stop` path never signals pid <= 1 or a process group.** `syscall.Kill(pid, …)` is only reached with a pid > 1 (`proc.go:134`). The weakness is in identity verification (A-02), not in signal targeting.
- **The CA is P-256** with pathlen 0, keyCertSign and cRLSign, and critical DNS name constraints. The IP ranges cover loopback, RFC 1918, ULA, CGNAT and the extra IPs. `.local` (mDNS) is permitted.
  - Leaves are serverAuth only, `CA:FALSE`, valid for 397 days, with 5 minutes of skew.
  - Each new leaf is verified against the CA before it is published.
  - `current` is swapped atomically, and SIGHUP reload uses an atomic pointer.
- **The detached child uses `Setsid`,** and secrets are not put in argv.

## Honest boundaries (§11.4.6)

- **A-01 is supported by code reading plus the existing test's semantics.** I did not run a multi-source load test against the default limits.
- **A-05:** whether another layer prevents committing a log key placed in a repository is UNCONFIRMED.
- **TLS cipher list:** no `CipherSuites` are pinned, so Go defaults apply. On Go 1.26 these include ECDHE-CBC suites for TLS 1.2. I did not scan this, and did not judge it against FR-070's "weak ciphers" test.
- **Memory zeroisation of keys:** keys are Go strings, so they are not zeroised. This is documented here as an expectation, not demanded.
- **The full test suite was not run.**

## Verdict

- **SOURCE: NO-GO.**
  - Five IMPORTANT source defects remain: A-01, A-02, A-03, A-04 and A-05.
  - There are no BLOCKING findings, and none of them needs a valid key.
  - A-01 is remotely triggerable. The others need operator-specific configuration or a local process.
  - The MINOR source findings A-06 to A-16 should be fixed or recorded as tracked items before the next review round.
- **Tests and docs:**
  - A-17: three of my seven mutations survive, and a fourth hangs instead of failing.
  - A-18: the transport tests pin the DoS behaviour.
  - Together these mean the auth-header ambiguity, the session-ticket and `serve`-word checks, and the stop-identity logic are not guarded today. Add the listed tests, each RED first.

## Fix status (FIX-A, 2026-10-07)

Every finding below was fixed test-first and each fix is guarded by a test that fails when the fix is reverted
(`tests/test_decide_security_mutation.sh`: 42 mutants incl. the reviewer's R-M1..R-M7, all killed; `tests/test_certs_go_mutation.sh`: 21 mutants, all killed).
A-02 and A-08 are delegated to FIX-B (their R-M3 / R-M7 mutants are included in the script and are killed by FIX-B's tests).

- A-01: FIXED. Unauthenticated/authenticated pools (`internal/server/slots.go`), eviction of the heaviest source's oldest unauthenticated connection, 3 s pre-auth reset (`conn.go`), IPv6 /48 aggregate, env-tunable validated limits. Tests: `TestValidKeyClientIsServedWhileHostileSourcesHoldTheSlots`, `TestGlobalCapEvictsUnauthenticatedHoldersInsteadOfRefusingTheNewcomer`, `TestPreAuthTimeoutReapsUnauthenticatedConnections`, `TestAuthenticatedConnectionsKeepReservedCapacity`, `TestSlots*`, `TestSourceKeysAggregateIPv6At48`, `TestAdmissionLimits*`. The /48 rule is unit-tested only (the host has a single ::1 address).
- A-02: DELEGATED to FIX-B.
- A-03: FIXED. `Rotate` keeps a PREVIOUS key only if it was an accepted key. Tests: `TestRotateGraceUnderEnvShadowDoesNotWidenTheAcceptedSet`, `TestRotateGraceIsAppliedWhenTheOldKeyWasAccepted`, `TestCLIRotateExplainsASkippedGrace`.
- A-04: FIXED. Shared fail-closed `internal/placement`. Tests: `internal/placement` suite, `TestPlacementFailsClosedOnGitErrors`, `TestPlacementIgnoresAmbientGitDir` (certs).
- A-05: FIXED. `audit.LoadOrCreateLogKey` runs the guard. Tests: `TestLogKeyPlacementGuard`, `TestLogKeyPlacementFailsClosedOnGitError`.
- A-06: FIXED. Entropy floor (`keyring.WeakKey`), progressive delay, throttle eviction/fail-closed. Tests: `TestWeakOperatorKeysAreRefused`, `TestRotateReplacesAWeakFileKeyAndNeverKeepsItAsPrevious`, `TestFailDelayIsProgressiveAndCapped`, `TestWrongKeysAreSleptOnAndTheValidKeyNever`, `TestThrottleKeepsThrottledSourcesAndFailsClosedWhenFullOfThem`, `TestThrottleEvictsNonThrottledBeforeThrottled`.
- A-07: FIXED. Fixed-length HMAC digests; credential gate = `keyring.MaxKeyLen`. Tests: `TestKeyMatchesComparesFixedLengthDigests`, `TestCredentialLengthGateEqualsTheLongestValidKey`, `TestKeyRegexHasAnUpperBound`.
- A-08: DELEGATED to FIX-B.
- A-09: FIXED. `hardenTLS` re-applied to the `GetConfigForClient` result. Test: `TestGetConfigForClientCannotBypassTheTLSFloor`.
- A-10: FIXED. Owner/mode/symlink enforcement, weak-BYO refusal, CA/EKU warnings. Tests: `TestLeafKeyModeOwnerAndSymlinkAreEnforcedAtStart`, `TestBYOValidationWeakKeysRefusedCAAndEKUWarned`.
- A-11: FIXED. `exportSecret` (O_EXCL temp + link/rename, `--force-overwrite-ca-export`). Tests: `TestOfflineExportRefusesExistingDestinationAndSymlinks`, `TestExportSecretLosesNoRaceAgainstAConcurrentCreate`, `TestCLIForceOverwriteFlagIsWired`.
- A-12: FIXED. `keyring.openPrivate`/`readPrivateText`, `certs.readPrivate`, `audit.readKey` (O_NOFOLLOW|O_NONBLOCK, checks on the fd, fchmod). Tests: `TestOpenPrivateRefusesFIFOWithoutBlocking`, `TestOpenPrivateRefusesSymlink`, `TestTightenChmodsTheCheckedDescriptorNotWhateverIsAtThePathNow`, `TestReadPrivateDoesNotHangOnAFIFO`, `TestLogKeyFIFONeverHangs`.
- A-13: FIXED. `keyCache` fails closed after 5 s, reports once, counts `llmctl_decide_key_source_errors_total`. Tests: `TestKeyCacheFailsClosedAfterTheGraceAndReports`, `TestKeyCacheEmptySetIsTreatedAsAFailure`, `TestRevokingTheFileKeyStopsItBeingAccepted`.
- A-14: FIXED. `llmctl_decide_audit_write_failures_total` + one stderr line. Tests: `TestAuditWriteFailuresAreCountedAndReportedOnce`, `TestEventCountersRenderAndAreBounded`.
- A-15: FIXED. `childEnviron`/`detachedCmd`, `removeOwnPidfile`. Tests: `TestDetachedChildEnvironmentLacksTheLegacyKeyVariable`, `TestRemoveOwnPidfileOnlyWhenItNamesThisProcess`.
- A-16: FIXED (documentation, honest residual risk stated). `docs/tls-and-keys.md`, `docs/decide-gateway.md`. Unix-domain sockets with peer credentials are not implemented.
- A-17: FIXED. Tests for M1 (`TestDuplicateAuthorizationHeadersAreRefused`) and M2 (`TestSessionTicketsAreDisabledNoResumption`); M3/M7 are FIX-B's tests; the mutation script runs every mutant under `go test -timeout`, so a hang fails cleanly.
- A-18: FIXED. `TestValidKeyClientIsServedWhileHostileSourcesHoldTheSlots` replaces the test that pinned the starvation.
