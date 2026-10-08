# Independent review 4, scope A3: verification of FIX-E (round-2 security findings) plus new-defect hunt

| Field | Value |
|---|---|
| Reviewer | independent adversarial reviewer, round 3 (did not write the code, did not do rounds 1 or 2) |
| Date | 2026-10-07 (UTC) |
| Tree | `main`, HEAD `a9ebefe` plus the uncommitted work tree (`go.mod`, `go.sum`, `internal/`, `cmd/` are untracked) |
| Inputs | `evidence/review-3/review-A2-security.md`, `evidence/review-3/fix-E-report.md` |
| Verdict (source) | **NO-GO**: 0 BLOCKING, 1 IMPORTANT, 2 MINOR source defects |
| Verdict (tests/docs) | **NO-GO**: 2 IMPORTANT test-instrumentation findings (two reviewer mutations survive), 2 MINOR test gaps, 2 MINOR process-doc findings |

## Method

- Read-only on the repository. Everything ran in a scratch copy (`mktemp -d` under the session scratchpad:
  `go.mod`, `go.sum`, `internal/`, `cmd/`, `submodules/containers`, `models/catalog.json`,
  `specs/009-jev-decision-models/contracts`, later `evidence/review-2`). go1.26.0 linux/amd64. Probe and mutation
  files were deleted from the copy after use; the copy itself was deleted by its exact name at the end.
- Baseline, this session (`-mod=readonly -race`):
  - `go test -race -count=1 ./internal/keyring ./internal/certs ./internal/placement ./cmd/llmctl-decide`:
    all `ok` (2.0 s, 5.0 s, 1.6 s, 5.7 s).
  - `go test -race -count=5 ./internal/server`: `ok` (154.7 s).
- Cross-builds (`go build ./...`): linux amd64/arm64/mips/mips64le/386/riscv64, darwin amd64/arm64,
  freebsd amd64/arm64, openbsd/amd64, netbsd/amd64: all OK. windows/amd64 and windows/arm64 FAIL in
  `internal/keyring/env.go:94` and `internal/audit/{audit,logkey}.go` (`syscall.O_NOFOLLOW`, `syscall.Stat_t`):
  pre-existing, unrelated to FIX-E, and Windows is not a supported platform (CLAUDE.md: Linux and macOS).
- `go vet` with GOOS=darwin, freebsd, linux (GOARCH=arm64) on `internal/gateway`, `internal/server`,
  `internal/keyring`, `internal/certs`: clean.
- Module: `GOPROXY=off go mod verify` -> `all modules verified`; `GOPROXY=off go build -mod=readonly ./...` -> rc 0;
  `go.sum` holds `golang.org/x/sys v0.45.0` (lines 82-83) and `golang.org/x/text v0.37.0` (lines 86-87), both h1 and go.mod.
  `go.mod`/`go.sum` were byte-identical to the repository after every build.
- Reviewer probes (throw-away tests) and 16 reviewer-authored mutations, listed at the end.

## Verification of the round-2 findings

| Id | Status | Evidence (file:line, test, this session) |
|---|---|---|
| A2-01 | **Fixed.** | `internal/keyring/keyring.go` `AcceptedKeys`: returns before reading the file when `res.Source != "file"`; PREVIOUS needs `keyRE`, `WeakKey(prev) == ""`, digits, unexpired. Test `TestRotateGraceWithDifferentCLIAndGatewayEnvironmentsDoesNotWidenTheAcceptedSet` (`keyring/hardening_test.go:221`) uses separate CLI/gateway environments; `TestEnvKeyIsAcceptedAloneEvenWithAFilePrevious` (`keyring_test.go:397`). |
| A2-T2 | **Fixed.** | Same test as above, two environments. |
| A2-02 | **Fixed.** | Env source never opens `.env`. Probe K1 (env key + `.env` that is a symlink / weak file key / garbage / world-writable / a directory): every case `n=1 ok=true err=<nil>`. Start check `cmd/llmctl-decide/cmd_serve.go:291-296` refuses with `keyring.ExitCode` (4). Tests `TestEnvKeyKeepsWorkingWithAnUnusableEnvFile` (`cmd/llmctl-decide/hardening_test.go:187`), `TestPrepareRefusesToStartWhenTheAcceptedKeySetCannotBeRead` (`:212`). Note: the `len(ks) == 0` half of the start check is unguarded (mutation N7), see A3-T3. |
| A2-03 | **Fixed** at slot-table level. | `internal/server/slots.go:177-201` ranks `aggU`, then `perU`, then age. Tests `TestSlotsVictimRankingUsesTheAggregateFirst` (`slots_test.go:175`), `TestSlotsVictimWithinAnAggregateIsTheHeaviestSource` (`:388`). **But** the production wiring of the aggregate is unguarded: see A3-T1. |
| A2-04 | **Fixed.** | `slots.go:113-129` own-source / own-aggregate oldest-unauth eviction; refusal only when nothing evictable. Tests `TestSlotsPerSourceCapEvictsTheSourcesOwnOldestNotTheNewcomer` (`slots_test.go:141`), `TestSlotsUnauthenticatedBudgetsAreSeparate` (`:103`), e2e `TestPerSourceCapEvictsTheSourcesOwnOldestAndSparesOthers` (`server_test.go:913`). Probe P-S1: 4 hostile IPv4 sources x 1000 admissions -> 0 evictions of 3 lone legitimate sources. |
| A2-T1 | **Fixed.** | `slots.go:204-223` (`removeLocked`) and `:235-254` (`promote`) each decrement every counter exactly once; `done` makes a second call a no-op. Tests `TestSlotsReleasedConnectionsDoNotLeakTheAggregateBudget` (`slots_test.go:201`), `TestSlotsEvictedConnectionsDoNotLeakTheAggregateBudget` (`:217`), `TestSlotsPromotedAndReleasedConnectionsLeaveNoCounters` (`:368`). Reviewer mutation N4 (authenticated close never returns `per`) killed. |
| A2-05 | **Fixed as worded, but the fix introduced A3-01** (IMPORTANT). | `internal/certs/placement.go:38-42`. `TestPlacementGuardRunsOnlyWhenTheCertDirIsCreated` (`certs/hardening_test.go:407`). |
| A2-06 | **Fixed** (errno injection only; no vfat mount, same honest limit as FIX-E). | `internal/certs/secfile.go:106-116` (`linkUnsupported`), `:162-169` fallback, `:188-206` `createExclusive` (`O_EXCL|O_NOFOLLOW`, 0600, fsync, remove-on-failure); `ca.go:265-277` content-only `readBack`, copy removed on mismatch. Tests `TestExportSecretFallsBackWhereLinkIsUnsupported` (`hardening_test.go:432`), `TestExportSecretFallbackStillRefusesAnExistingDestination`, `TestExportOfflineRemovesTheCopyWhenVerificationFails` (`:486`), `TestExportOfflineVerifiesByContentNotByMediumMode` (`:508`). Reviewer mutation N6 (fallback without `O_EXCL`) killed. |
| A2-07 / B2-07 | **Fixed.** | `internal/gateway/proc_linux.go` (`//go:build linux`, `unix.PidfdOpen`, `unix.PidfdSendSignal`), `proc_other.go` (`//go:build !linux`, ENOSYS, no syscall). Build tags are complementary: every one of the 12 non-Windows targets above built. `TestNoRawSyscallOutsideLinuxOnlyFiles` (`proc_test.go:195`), `TestPidfdRoundTripOnLinux` (`proc_linux_test.go:12`). |
| A2-08 | **Fixed.** | `certs/certs.go:141-158` builds TLS from `keyPEM` set at `:321` from the descriptor-validated bytes; `tls.X509KeyPair` re-checks pairing; `cmd_serve.go:395`. `TestTLSCertificateUsesTheValidatedKeyBytesNotARereadByPath` (`hardening_test.go:530`). The chain is still read by path (`certs.go:149`); a swapped chain can only fail closed or present a certificate for the same validated key (public material), so this is acceptable. |
| A2-09 | Documented only (as FIX-E states). Not re-measured. |
| B2-11 (instance header) | **Fixed; no disclosure concern.** | `server/handlers.go:483, 510-512`; `contract/instance.go:25-36` keeps only `[a-z0-9._-]{1,64}`. The label is the profile id / registry entry name (`gateway/resolver.go:77-81`, `registry_resolver.go:171-176`), never the URL or port; the header is set only on a 200 decision, which is behind `authMiddleware` (`handlers.go:229-258`), so only key holders see it. A label that includes a port only appears if an operator names an instance that way. |
| B2-15 R2 | Test present: `TestLegacyPidfileOlderThanTheProcessIsRefusedAndNewerAccepted` (`gateway/review2_test.go:771`). The `internal/gateway` package was not re-run here (FIX-E reports a registry flake owned by FIX-G). |

## New findings

### A3-01: IMPORTANT, source-defect. Pre-existing `<home>/cert` skips the FR-087 placement guard, and the CA and leaf private keys are then CREATED inside an unignored git work tree

- **Location:** `internal/certs/placement.go:38-42`. The guard runs only when `Lstat(<home>/cert)` fails. Key creation
  (`Ensure` generates the CA and the leaf when they are missing) is not tied to that condition.
- **Scenario:** `LLMCTL_HOME` (or `--home`) is inside a git work tree that does not ignore `cert/`, and `cert/` already
  exists: it was committed with a `.gitkeep` (a common layout), created with `mkdir` by an operator, left behind by
  an earlier tool, or is a symlink. The first `serve` / `cert ensure` generates `ca/ca.key` and `v-1/leaf.key`
  there without any refusal.
- **Proof (probe A3-P1, real `git init`, this session):**
  - Control, no `cert/` dir: `refusing to create .../llmhome/cert: it is inside a git work tree and not ignored by git ...`
  - With an empty pre-existing `cert/`: `Ensure err=<nil>; files created in work tree: [.lock ca current v-1]`, and
    `git status --porcelain -uall` lists `?? llmhome/cert/ca/ca.key`, `?? llmhome/cert/v-1/leaf.key`, ... So one
    `git add -A` commits the CA private key.
- **Why it is a regression:** before FIX-E the guard ran on every `prepareDir`, so this case was refused. FIX-E's
  residual note ("a cert dir created by hand ... is no longer re-refused at each start") understates it: the keys
  are never refused at all. `docs/tls-and-keys.md:79` ("A secret is never **created** inside a git work tree that
  git does not ignore") is now false for the certificate directory.
- **Fix:** key the guard on *key creation*, not on directory existence. For example, run `CheckPlacement` when the CA
  key (`<home>/cert/ca/ca.key`, or `current`) does not exist yet, i.e. whenever `Ensure` will generate material, and
  keep skipping it on a pure load of existing material (restart, SIGHUP). Add a RED test that pre-creates an empty
  `cert/` inside a real unignored work tree and expects refusal with no key file created. Correct the docs sentence.
  (Lstat vs Stat does not matter here: reviewer mutation N10 switching to `Stat` survives because a symlinked dir
  skips the guard either way.)
- **finding_layer:** source-defect.

### A3-02: MINOR, source-defect (latent). Data race between eviction and `sc.entry` assignment when one `Server` serves two listeners

- **Location:** `internal/server/conn.go:33-35` assigns `sc.entry` after `admit` returns; `admit` publishes the entry
  in the table first. Another `guardListener.Accept` on the same `slotTable` can pick it as a victim and run
  `sc.abort -> releaseSlot` (`conn.go:118-128`), which reads `c.entry` concurrently with the write.
- **Proof (probe P-S3, `-race`):** two `guardListener`s sharing one `slotTable`, pipe connections from one source:
  `WARNING: DATA RACE` at `conn.go:125` (read) vs `conn.go:35` (write). Counters stayed consistent (`inUse=2 unauth=2`)
  because `take` already removed the entry, but `relOnce` is consumed with a nil entry.
- **Reach:** `cmd_serve.go:510` calls `Serve` once, so production is not affected today; `Server.Serve` is exported and
  nothing forbids a second listener (dual-stack bind). FIX-E's own-source eviction makes victims far more frequent.
- **Fix:** construct `sc` with its entry before the entry becomes visible (pass `sc` into `admit` and set `e` and
  `sc.entry` under the table lock), or document and enforce one `Serve` per `Server`.
- **finding_layer:** source-defect.

### A3-03: MINOR, source-defect + process-doc. `key rotate` reports a grace window and a successful rotation that a gateway with an environment-sourced key never applies

- **Location:** `internal/keyring/cli.go:193-207`; `docs/tls-and-keys.md:39-49`.
- **Scenario:** the gateway runs from a service unit with `LLMCTL_API_KEY=E`. E leaks. The operator runs
  `llmctl decide key rotate` (with or without `--grace`) from a shell without the variable. Output:
  `new access key stored in ...`, possibly `previous key stays valid until epoch N`, plus "restart the decision
  gateway". After the restart the gateway still accepts exactly E (by FIX-E design `AcceptedKeys` never reads
  the file for an env source). E is not revoked, the new key is not accepted, and nothing in the output says so. The
  `EnvShadows` warning (`cli.go:205`) fires only when the CLI's own environment holds the key.
- **Why it matters now:** FIX-E made "an env key ignores the file" an explicit rule, so the CLI cannot know it rotated
  something that is not in use. The documented revocation path ("rotate without --grace and restart") does nothing in
  this, very common, deployment.
- **Fix:** always print a line such as "if the gateway takes LLMCTL_API_KEY from its own environment (service unit,
  supervisor), this rotation does not affect it: change the key there"; state the same in the docs' revocation
  bullet. Optionally, have the gateway log once at start when the env key differs from a file key (`Inspect` already
  computes `FileShadowed`).
- **finding_layer:** process-doc (output text and docs; no accept-path defect).

## Test-instrumentation findings

### A3-T1: IMPORTANT, test-instrumentation. The production wiring of the IPv6 /48 aggregate is unguarded: reviewer mutation N13 survives

- **Mutation N13:** `conn.go:35` `l.slots.admit(src, agg, sc.abort)` -> `_ = agg; l.slots.admit(src, src, sc.abort)`.
  `go test ./internal/server`: **ok** (survived).
- **Effect:** in production the /48 aggregate is never applied: the per-/48 unauthenticated cap and the A2-03
  aggregate-first victim ranking become dead code, and an IPv6 attacker rotating /64s inside one /48 gets a full
  per-source share per /64 again (the round-1 rotation defence). Every slot test calls `admit` directly with an
  explicit aggregate, and the e2e tests run only on 127.0.0.x / `::1`.
- **Fix:** a listener-level test with a fake `net.Listener` whose connections report chosen IPv6 `RemoteAddr`s (several
  /64s of one /48, as in probe P-S3's `pipeListener`), asserting the per-/48 cap is enforced through `guardListener.Accept`.

### A3-T2: IMPORTANT, test-instrumentation. "Edit the key out of the file" revocation with an unexpired PREVIOUS left in the file is unguarded: reviewer mutation N5 survives

- **Mutation N5:** `keyring.go` `if res.Source != "file" { return keys, nil }` -> `if res.Source == "env" { ... }`.
  `go test ./internal/keyring ./cmd/llmctl-decide`: **ok** (survived).
- **Effect:** with source `none` (the operator removed `LLMCTL_API_KEY` from `.env` to revoke, the documented path in
  `docs/tls-and-keys.md:48`) an unexpired `LLMCTL_API_KEY_PREVIOUS` would be accepted **alone** until it expires. The
  current code is correct (it returns no key and the cache fails closed); the guarantee simply has no test, and the
  mutated form is a natural refactor of the same line.
- **Fix:** test `.env` = `{PREVIOUS=<strong>, PREVIOUS_EXPIRES=<future>}` without `LLMCTL_API_KEY` -> `AcceptedKeys`
  returns 0 keys, and the gateway refuses that key after `keyStaleGrace`.

### A3-T3: MINOR, test-instrumentation. The empty-set half of the start check is unguarded (mutation N7 survives)

- `cmd_serve.go:291` `len(ks) == 0` -> `len(ks) < 0` survives. Reachable only if the file key disappears between
  `Resolve` and `readKeys`, so the mutant is near-equivalent; inject an empty `acceptedKeys` (the variable exists for
  that) to pin it.

### A3-T4: MINOR, test-instrumentation. The 64-character bound on the instance label is untested (mutation N12 survives)

- `contract/instance.go:27` `len(label) > 64` removed: survives in `./internal/contract` (the only failure was the
  copy-artifact `TestOpenAPIAndDocsStateTheRealBehaviour`, which also fails at baseline in my copy because `docs/` was not
  copied) and in `./internal/server ./internal/gateway`. The charset check is guarded (N15 killed by
  `TestInstanceNoteCarriesTheServingInstance`). Low impact: the header carries only `[a-z0-9._-]`.

## Process / docs findings

- **A3-P1 (MINOR, process-doc):** `docs/tls-and-keys.md:79` claims the guard is absolute; false per A3-01 (fix together).
- **A3-P2 (MINOR, process-doc):** `go.mod` is not tidy: `GOPROXY=off go mod tidy -diff` wants
  `gopkg.in/yaml.v3 v3.0.1 // indirect` (no package of this module imports it; only `submodules/containers` does) and adds 8
  `go.sum` lines (`kr/pretty`, `kr/text`, `rogpeppe/go-internal`, `gopkg.in/check.v1`). `go build`/`go test ./...` with
  `-mod=readonly` work offline; `go test all` would not. `golang.org/x/sys` and `golang.org/x/text` are correctly direct
  (`x/text` is imported by `internal/contract/prompt.go`). Also: `go.mod`/`go.sum` are untracked; they must land in the
  same commit as the code.

## Other attacker questions from the brief

- **Leak accounting:** every removal path goes through `removeLocked` (release, eviction via `take`) or `promote`, each
  guarded by `done`/`authed`; `srvConn.releaseSlot` is `sync.Once`. TLS handshake failure -> `shutdown` -> release
  (`conn.go:142-144`); pre-auth timeout and eviction -> `abort` -> `shutdown`; normal close -> `Close`. There is no
  `Hijack` anywhere in `internal/server`; a handler panic is recovered by net/http, which closes the conn (release).
  Context cancellation does not touch slots. A conn evicted while its valid-key request is between `keyMatch` and
  `promote` is reset mid-request (minor, by design of "unauthenticated until promoted").
- **Eviction loops:** each iteration removes one entry and lowers the very counter in the loop condition, so they
  terminate; the `break` paths cannot admit over a cap while counters are consistent (checked by hand, and N3 is killed).
  Each admit is O(entries) under the lock (pre-existing with `pickVictim`).
- **Can a hostile source evict others beyond its own cap?** No for distinct sources/aggregates (probe P-S1: 0). Inside one
  /48 (or one NAT IPv4 address) yes, by design: probe P-S2, a legitimate /64 sharing a /48 with two hostile /64s is evicted
  (`evicted=1`). Before FIX-E the same neighbour refused the legitimate newcomer instead; the denial is equivalent, the
  documented "pay among themselves" trade-off. Distinct-address flooding beyond `maxUnauth` still churns (P-S1b: 1
  eviction), the documented honest limit.
- **Keyring:** env key with a corrupt / weak / symlinked / foreign-mode / directory `.env` keeps working (K1). File key with
  a weak PREVIOUS -> 1 key (K2, PREVIOUS silently dropped; `Rotate` never writes one, and reports `GraceSkipped`). Overflowing
  expiry -> 1 key (K3). PREVIOUS equal to current -> 1 key (K4). Env `LLMCTL_API_KEY=""` -> error (K5), so `prepare` exits 4.
  `prepare` reads the accepted set once (`cmd_serve.go:291`), exits `keyring.ExitCode`.
- **Certs:** key bytes remain unexported, not printed by `String`; the fallback publish keeps no-overwrite and no-follow (N6
  killed). On a FAT medium the temporary `.ca.key.tmp-*` copy is deleted, not wiped, which leaves a recoverable copy on the
  same medium that already holds the intended copy: negligible.
- **Off-Linux stop path:** verification is argv-only (`ps`), no start-time or exe identity check, so a stale pidfile whose pid
  was reused by another `llmctl-decide serve` of the same user (other home) would be signalled. Pre-existing and stated in
  FIX-E's "macOS stop path" note; not new.

## Reviewer-authored mutations (scratch copy, `go test -mod=readonly -count=1`)

| # | Mutation | Result |
|---|---|---|
| N1 | `slots.go` aggregate-cap victim restricted to the newcomer's own source | killed (`TestSlotsUnauthenticatedBudgetsAreSeparate`) |
| N2 | `oldestUnauth` takes the newest | killed (`TestPerSourceCapEvictsTheSourcesOwnOldestAndSparesOthers`, `TestSlotsUnauthenticatedBudgetsAreSeparate`) |
| N3 | per-source cap: all-authenticated source admitted beyond `maxPer` (`return refuse()` -> `break`) | killed (`TestSlotsPerSourceCapEvictsTheSourcesOwnOldestNotTheNewcomer`) |
| N4 | `removeLocked` returns `per` only for unauthenticated entries | killed (`TestEarlyRejectWithUnreadBodyStillDeliversTheResponse`, `TestStatusInventory`) |
| N5 | `AcceptedKeys` early return only for `env` (source `none` reads PREVIOUS) | **SURVIVED** (A3-T2) |
| N6 | `createExclusive` without `O_EXCL` | killed (`TestExportSecretFallbackStillRefusesAnExistingDestination`) |
| N7 | start check ignores an empty accepted set | **SURVIVED** (A3-T3, near-equivalent) |
| N8 | key cache never fails closed | killed (`TestKeyCacheFailsClosedAfterTheGraceAndReports` and 2 more) |
| N9 | `TLSCertificate` re-reads the key by path when `keyPEM` is empty | survived; equivalent in reachable states (every load sets `keyPEM`) - no finding |
| N10 | placement guard keyed on `Stat` instead of `Lstat` | survived; equivalent for the A3-01 class (both skip on an existing/symlinked dir) |
| N11 | pre-auth timer not stopped on release | survived; equivalent (late `abort` re-closes a closed conn, `relOnce` consumed) - no finding |
| N12 | instance label length bound removed | **SURVIVED** (A3-T4) |
| N13 | listener passes the source as its own aggregate | **SURVIVED** (A3-T1) |
| N14 | `sourceKeys` IPv6 aggregate = /64 | killed (`TestSourceKeysAggregateIPv6At48`) |
| N15 | instance label charset check removed | killed (`TestInstanceNoteCarriesTheServingInstance`) |
| N16 | cert placement guard never runs | killed (`TestRefusedInsideUnignoredGitWorkTree`, `TestCLIPlacementRefusalExit5`, `TestPlacementFailsClosedOnGitErrors`) |

## Could not verify (honest boundaries)

- No vfat/exFAT mount (A2-06), no macOS/BSD/MIPS execution (A2-07 cross-compiled and vetted only).
- `internal/gateway` tests and `tests/test_decide_security_mutation.sh` were not re-run (the FIX-G registry flake is outside
  this scope); B2-15 R2 is verified by test existence only.
- No live IPv6 multi-prefix load test; A3-T1 and P-S2 are unit/listener-level.
- `internal/contract` cannot pass in my copy (it reads `docs/` and evidence files I did not copy), so contract-package
  mutation results exclude `TestOpenAPIAndDocsStateTheRealBehaviour`.
- A2-09 timing not re-measured.

## Verdict

- **SOURCE: NO-GO.** One IMPORTANT regression introduced by FIX-E: **A3-01** (the A2-05 fix lets the CA key be created inside
  an unignored work tree when `cert/` pre-exists). A3-02 and A3-03 are MINOR. All A2 findings are otherwise fixed as claimed.
- **TESTS/DOCS: NO-GO.** **A3-T1** (the /48 aggregate wiring can be deleted with the suite green) and **A3-T2** (an
  edit-out revocation bypass mutant survives) must gain tests; A3-T3/T4 are MINOR; the docs sentence in A3-P1 and the
  rotation caveat in A3-03 must be corrected.
