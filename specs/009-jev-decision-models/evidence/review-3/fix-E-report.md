# FIX-E report: round-2 security review findings (A2-01 .. A2-09, A2-T1, A2-T2) plus B2-07, B2-11, B2-15 R2

Date 2026-10-07. Tree: uncommitted work on `main`; nothing staged, committed or pushed.
Method: test first (RED observed), fix (GREEN), then a mutation proving the test is load-bearing.
Mutations run in a scratch copy via `tests/test_decide_security_mutation.sh` (copy in a mktemp dir; the repo is untouched).

## Per finding

### A2-01 + A2-T2 (PREVIOUS key widening) - fixed
- Files: `internal/keyring/keyring.go` (`AcceptedKeys`), tests `internal/keyring/hardening_test.go`, `keyring_test.go`.
- `AcceptedKeys` takes PREVIOUS only when `res.Source == "file"`, and PREVIOUS must pass `WeakKey`. The `Rotate` check stays as a second layer.
- RED (before fix):
  - `TestRotateGraceWithDifferentCLIAndGatewayEnvironmentsDoesNotWidenTheAcceptedSet`: "the gateway's accepted set widened to 2 keys" (CLI env `{}`, gateway env `{E}` - two different environments, so the test can fail on the real defect).
  - `TestAcceptedKeysIgnoresAWeakPrevious`: "a weak PREVIOUS was accepted: 2 keys".
- GREEN: `go test ./internal/keyring/` ok.
- Superseded test: `TestEnvKeyAcceptedAlongsidePrevious` encoded the defect (env key + file PREVIOUS = 2 keys). Renamed `TestEnvKeyIsAcceptedAloneEvenWithAFilePrevious`, expectation 1 key.
- Mutation: `res.Source != "file"` -> `false` killed (3 tests); dropping `WeakKey(prev)` killed. Both are in the mutation script.

### A2-02 (delayed total lockout) - fixed
- Files: `internal/keyring/keyring.go`; `cmd/llmctl-decide/cmd_serve.go` (`acceptedKeys` var, `readKeys`, start check in `prepare`); tests `keyring/hardening_test.go`, `cmd/llmctl-decide/hardening_test.go`.
- With an env-sourced key the `.env` file is never read, so its health is irrelevant.
  - RED: `TestAcceptedKeysWithEnvKeyNeverReadsTheEnvFile`: "env key must keep working with an unusable .env: 0 keys, err env file ... is a symlink".
- At serve start `prepare` calls the accepted-key reader once and refuses with exit 4 (`keyring.ExitCode`) if it errors or yields no key.
  - RED: compile failure (`p.readKeys` undefined), then behavioural.
  - Mutation: disabling the start check -> `TestPrepareRefusesToStartWhenTheAcceptedKeySetCannotBeRead` FAILs. `TestEnvKeyKeepsWorkingWithAnUnusableEnvFile` covers env key + symlinked `.env`.

### A2-03 (victim ranking) - fixed
- File: `internal/server/slots.go` (`pickVictim` ranks by `aggU`, then `perU`, then age).
- RED: `TestSlotsVictimRankingUsesTheAggregateFirst`: "attacker newcomer 1 refused" on the old code, since the old code had no per-aggregate eviction at all. After the fix the lone legit client survives 71 attacker admissions.
- `TestSlotsVictimWithinAnAggregateIsTheHeaviestSource` pins the `perU` tie-break.
- Mutations (ranking ignores aggregate; lightest aggregate; lightest source) all killed.

### A2-04 (own-oldest eviction) - fixed
- File: `internal/server/slots.go` (`admit`, `oldestUnauth`): a per-source / per-source-unauth / per-/48 cap evicts that source's (or aggregate's) own oldest unauthenticated connection; authenticated ones are never victims. The newcomer is refused only when the capped source holds nothing evictable (all authenticated).
- RED: `TestSlotsPerSourceCapEvictsTheSourcesOwnOldestNotTheNewcomer`: "9th connection from the shared source must be admitted ..."; `TestSlotsUnauthenticatedBudgetsAreSeparate`: "per-source cap must evict the source's own oldest, not refuse".
- Old tests that pinned refusal were rewritten: `TestSlotsGlobalAndPerSource`, `TestSlotsPromotionReleasesTheUnauthenticatedShare`, and `server_test.go` `TestPerSourceCapShedsBeforeHandshakeAndSparesOthers` -> `TestPerSourceCapEvictsTheSourcesOwnOldestAndSparesOthers` (end-to-end over TLS: the oldest connection is reset, the newcomer is not shed).
- Mutations killed: refuse-instead-of-evict, authenticated may be a victim, aggregate cap off, per-source unauth cap off.

### A2-T1 (IPv4 locked out after 16 closed pre-auth connections) - fixed (test and mutants)
- Tests: `TestSlotsReleasedConnectionsDoNotLeakTheAggregateBudget` (80 sequential admit/release from one address), `TestSlotsEvictedConnectionsDoNotLeakTheAggregateBudget` (eviction path), `TestSlotsPromotedAndReleasedConnectionsLeaveNoCounters` (promote path, counters at zero).
- Mutants added to `tests/test_decide_security_mutation.sh`: the `aggU` decrement removed from `removeLocked` (the reviewer's M4) and from `promote`. Both killed.
- In the reviewer's M4 the suite stayed `ok`; now `TestSlotsUnauthenticatedBudgetsAreSeparate` and the new leak test FAIL on it.

### A2-05 (placement guard on every start) - fixed
- File: `internal/certs/placement.go` (`prepareDir`). The guard runs only when `Lstat(<home>/cert)` fails, i.e. at creation. A restart, SIGHUP reload (`Ensure`) or `Renew` over an existing directory does not consult git. Any Lstat error keeps the guard armed (fail closed).
- Definition: FR-087 forbids creating the keys inside a work tree; an already existing cert dir was created under the guard (or by the operator on purpose). The residual gap is a cert dir created by hand inside an unignored work tree: it is no longer re-refused at each start.
- RED: `TestPlacementGuardRunsOnlyWhenTheCertDirIsCreated`: "restart/reload with an existing cert dir must not be stopped by a git fault: git gave an unexpected answer (exit 128)". The test also checks that creation under a git fault is still refused and creates no directory.
- Mutation (`if true`) killed.

### A2-06 (offline CA export on vfat/exFAT) - fixed
- Files: `internal/certs/secfile.go` (`linkFn`, `linkUnsupported`, `createExclusive`), `internal/certs/ca.go` (`readBack`, `exportOffline`).
- When `link(2)` fails with EPERM/ENOTSUP/EXDEV/ENOSYS/EMLINK the export falls back to creating `DEST` with `O_EXCL|O_NOFOLLOW`, 0600, fsync (still no overwrite, still no symlink following; a partial file is removed). Other link errors (EACCES) surface unchanged.
- Verification is by content only (`readPrivate(dest, false)`), not by the medium's mode bits.
- On verification failure the copy on the medium is removed and the message says so ("the copy was removed from ..."), or says it could not be removed and must be deleted by hand. The source key stays on the host.
- Tests (RED was a compile error: `linkFn`/`readBack` undefined): `TestExportSecretFallsBackWhereLinkIsUnsupported`, `...DoesNotFallBackOnOtherLinkErrors`, `...FallbackStillRefusesAnExistingDestination` (a racing symlink is not written through), `TestExportOfflineRemovesTheCopyWhenVerificationFails`, `TestExportOfflineVerifiesByContentNotByMediumMode`.
- Mutations killed: no fallback, every error falls back, copy left behind, mode-based verification. `tests/test_certs_go_mutation.sh` updated (M19 anchor text, M22 made unique, new M22b); it reports ALL MUTANTS KILLED.
- UNCONFIRMED by a real vfat mount (no root). The behaviour is covered by errno injection only.

### A2-07 + B2-07 (pidfd) - fixed
- Files: `internal/gateway/proc.go` (raw syscalls and numbers removed), new `proc_linux.go` (`//go:build linux`, `unix.PidfdOpen` / `unix.PidfdSendSignal`, `/proc` cmdline), new `proc_other.go` (`//go:build !linux`: `pidfdOpen`/`pidfdSendSignal` return ENOSYS and issue no syscall; `procCmdline` via `ps -o args= -p`).
- Off Linux the stop path therefore cannot pin: it verifies via ps, re-verifies right before `kill(2)` (the existing no-pidfd branch), and never issues a raw syscall. Caveat: an executable path containing a space is not recognised, so the stop is refused (safe direction).
- `go.mod`: only `golang.org/x/sys v0.45.0` lost its `// indirect` comment (it is now imported directly). `go.sum` unchanged (the entries are already there); `go mod verify` ok. Note `go.mod`/`go.sum` are untracked in this tree.
- Build checks: `GOOS=darwin GOARCH=arm64 go build ./...` ok, `GOOS=linux GOARCH=arm64 go build ./...` ok, plus darwin/amd64 and linux/mips for `./internal/gateway`; `GOOS=darwin go vet ./internal/gateway` ok.
- RED: `TestNoRawSyscallOutsideLinuxOnlyFiles` listed `proc.go: contains "syscall.Syscall" / "sysPidfd" / "= 434" / "= 424" but has no linux build constraint` and `proc_linux.go missing`.
- Also added `TestPidfdRoundTripOnLinux` and a `!linux` test file (`proc_other_test.go`, compile-checked on darwin only).
- Mutations: raw `syscall.Syscall(434...)` in `proc_linux.go` killed; `proc_other.go` without its build tag no longer builds for linux (killed in the script); a check that the darwin build does not include `proc_linux.go`.
- HONEST LIMIT: the original bug (wrong numbers on mips/BSD) cannot be reproduced on amd64, so the RED is a static scan, not a behaviour failure.

### A2-08 (TLS key bytes) - fixed
- Files: `internal/certs/ca.go` (`parseKeyFileRaw`), `internal/certs/certs.go` (`CertInfo.keyPEM`, `TLSCertificate()`), `cmd/llmctl-decide/cmd_serve.go` (`loadPair` -> `info.TLSCertificate()`).
- `load` keeps the exact bytes read from the checked descriptor (unexported field, never printed by the redacting `Format`); TLS is built from them with `tls.X509KeyPair`, which re-verifies key/cert pairing.
- Test `TestTLSCertificateUsesTheValidatedKeyBytesNotARereadByPath` swaps the key file after validation; RED was a compile error, and the mutation (re-read by path) FAILs it.

### A2-09 - documented only (docs/tls-and-keys.md "Honest limits"); no code change, as the review called it negligible.

### B2-11 (instance header) - fixed
- `internal/server/handlers.go`: `ctx, instance := contract.WithInstanceNote(ctx)` next to `WithTruncationNote`, `x-llmctl-decide-instance` set when `instance()` is non-empty.
- Test `TestInstanceHeaderIsSetOnlyWhenTheBackendNotedAnInstance` (absent without a note, present = `engine-7.b` with one). Mutation (`false && inst != ""`) FAILs it: `instance header = "", want engine-7.b`.

### B2-15 R2 (legacy pidfile older than the process) - test added
- `TestLegacyPidfileOlderThanTheProcessIsRefusedAndNewerAccepted` (`internal/gateway/review2_test.go`): a legacy pidfile (no identity) older than the live `serve` helper is refused, nothing is signalled and the helper stays alive; a pidfile newer than the process is accepted.
- Note: the check at `proc.go` compares the pidfile CONTENT start time (`info.Start`, field 2), not the file mtime.
- Mutation: disabling the `started.After(info.Start+2s)` check -> FAIL ("an older legacy pidfile must be refused: res=still running ... signalled=1"). The code was not changed; this proves the existing check is load-bearing.

### Gateway guard test (from FIX-F)
- `TestNoCodeReadsTheInternalKeyFromTheEnvironment` (`internal/gateway/keyfile_test.go`) now exempts `tests/test_no_retired_vars.sh` with the reason in a comment. It passes.
- `TestUnpublishDoesNotEvictASuccessor` is NOT mine and is unchanged. It fails intermittently with "pid N is not (yet) running "successor": register after the process has exec'd the program" (the new fingerprint logic in `internal/registry/process.go`, a race with exec in the test helper). `TestGatewayReconcilesItselfAndPublishesItsCA` in `cmd/llmctl-decide` hits the same message intermittently (3 runs: fail, fail, pass). Owner: the registry change (FIX-G).

## Other changes
- `tests/test_decide_security_mutation.sh`: anchors updated for the new `slots.go`; the copied work tree now includes `specs/009-jev-decision-models/contracts` (a new `cmd` test reads it); new mutants for A2-01/02/03/04/05/06/07/08/T1, B2-11 and B2-15 R2; cross-build controls.
- `docs/tls-and-keys.md`: updated for every behaviour above.

## Verification (this session, after the last edit)
- `go vet ./...` clean. `gofmt -l` clean for my files (it flags a BOM in `internal/contract/b2_prompt_test.go`, FIX-F's file).
- `go test -race -count=1 ./internal/server ./internal/keyring ./internal/certs ./internal/placement ./internal/audit ./cmd/llmctl-decide`: ok. `./internal/gateway`: only `TestUnpublishDoesNotEvictASuccessor` fails (flake above, not mine).
- `tests/test_keyring_go_cli.sh` PASS; `tests/test_certs_go_cli.sh` ALL PASS; `tests/test_certs_go_mutation.sh` ALL MUTANTS KILLED; `make lint` clean (shellcheck).
- `tests/test_decide_security_mutation.sh`: the full run before the B2-11/B2-15 mutants were added (about 12 minutes) showed 59 "killed", 0 survivors. Its control step FAILs because of the registry flake above, which also makes a few gateway mutants "killed" by that flake instead of by their own tests. I confirmed the A2 mutants individually (the test names are in the output). The two B2 mutants added last were verified by hand, not by a full run of the script. `bash -n` on the script is clean.
- Not run: the full `make test`. No binaries were left in the repo root.

## Not fixed / partial
- A2-09 documented only.
- A2-06 not tried on a real vfat/exFAT mount.
- A2-07 not run on macOS or MIPS, only cross-compiled.
- The macOS stop path is verification via `ps` and `kill(2)`; the pidfile carries no identity there (Linux only).
