# FIX-H report: round-3 security review (review-A3-security.md)

The review file was complete on disk (222 lines, ends with the Verdict section); it was not truncated.
Discipline: test first (RED observed), fix, GREEN, then load-bearing proof by mutation. Nothing staged or committed.

| Finding | Files changed | RED | GREEN | Mutation proof |
|---|---|---|---|---|
| A3-01 (IMPORTANT) | `internal/certs/placement.go` (new `guardKeyCreation`), `internal/certs/certs.go` (called from `Ensure` non-BYO path and `Renew`), `internal/certs/hardening_test.go`, `docs/tls-and-keys.md` | `TestKeyCreationIsRefusedWhenCertDirPreExistsInAnUnignoredWorkTree` (empty dir, `.gitkeep` dir, symlinked dir; x Ensure and first-Renew): 6 subtests `expected a placement refusal, got <nil>`; `TestProvisionedInstallation...` `key creation under a git fault must be refused even with a pre-existing cert dir` | `go test -race ./internal/certs` ok | `A3-01 never armed` and `symlink not resolved` killed by the new test; "armed on every start" (early return removed): `TestPlacementGuardRunsOnlyWhenTheCertDirIsCreated` + `TestProvisionedInstallation...` FAIL |
| A3-02 | `internal/server/slots.go` (`admitInto` with an `set` hook run under the table lock, `admit` delegates), `internal/server/conn.go`, new `internal/server/listener_test.go` | `-race`: `DATA RACE conn.go:125 vs conn.go:35` with the old `sc.entry = admit(...)` form | `TestTwoListenersSharingOneSlotTableAreRaceFree` race-clean | assignment moved after unlock: killed |
| A3-03 | `internal/keyring/cli.go`, `docs/tls-and-keys.md`, `internal/keyring/hardening_test.go` | `TestRotateAlwaysStatesThat...` output lacked the statement | ok | wording mutated: killed |
| A3-T1 (N13) | `listener_test.go`: fake `net.Listener` + `net.Pipe` with chosen IPv6 `RemoteAddr`s; `TestAcceptEnforcesThePer48AggregateCapAcrossDifferent64s`, `TestAcceptVictimRankingUsesTheAggregate` | n/a (guard test) | ok | N13 (`admit(src, src)`): `inUse` 5 instead of 3 -> killed |
| A3-T2 (N5) | `keyring/hardening_test.go` `TestRevokedKeyWithAnUnexpiredPreviousAcceptsNothing` | n/a | ok (code was already correct) | N5 added to the mutation script |
| A3-T3 (N7) | `cmd/llmctl-decide/hardening_test.go` `TestPrepareRefusesToStartWhenNoKeyIsAccepted` | n/a | ok | `len(ks) == 0` -> `< 0`: `got p=true rc=0` |
| A3-T4 (N12) | NEW file `internal/contract/instance_bound_test.go` (internal/contract belongs to FIX-I; I added a new file only) | n/a | ok | bound removed: len 65 / 4096 kept -> FAIL; restored by exact sed (verified) |
| A3-P2 | `go.mod`, `go.sum` | `go mod tidy -diff` wanted yaml.v3 `// indirect` + 8 sum lines | `GOPROXY=off GOFLAGS=-mod=mod go mod tidy` worked offline; then `GOPROXY=off go build -mod=readonly ./...`, `go mod verify` ("all modules verified"), `go vet ./...` OK, `go mod tidy -diff` clean | - |

## Decisions
- A3-01 rule: the guard is armed whenever the installation is not yet provisioned (`current` does not resolve to a version dir) and Ensure/Renew would generate keys, independent of whether `<home>/cert` exists; it is skipped for a provisioned installation (reload, restart, renew), so the A2-05 goal holds. A symlinked cert dir is resolved with EvalSymlinks before asking git. The original "cert dir absent" check in `prepareDir` is kept.
- A3-T2 semantics: removing the current key from `.env` (source none) revokes; PREVIOUS is never accepted alone. Code was already so; now tested.
- A3-03: always prints `scope:` + revoke instructions (also when the CLI env has the key); docs updated.

## go.mod / go.sum
`gopkg.in/yaml.v3 v3.0.1` now `// indirect`; go.sum 93 -> 101 lines (kr/pretty, kr/text, rogpeppe/go-internal, gopkg.in/check.v1: h1 + go.mod lines). x/sys and x/text stay direct.

## Test runs
`go vet ./...` clean; `go test -race -count=1` ok for server (27 s), keyring, certs, placement, audit, contract, gateway (non-race); `cmd/llmctl-decide` ok after FIX-I's concurrent change (one earlier run failed in FIX-I's `TestFlaggedAnswerIsEvidencedAndHeldByTheGate`, not mine). `tests/test_keyring_go_cli.sh` PASS, `tests/test_certs_go_cli.sh` ALL PASS, `tests/test_certs_go_mutation.sh` ALL MUTANTS KILLED, `make lint` rc 0.
`tests/test_decide_security_mutation.sh`: first full run had a failing control (FIX-I's concurrent test failure in the copy), which made every cmd mutant look killed; I re-proved N7 locally and fixed it (the first N7 form did not compile). Final full-script result: see the line appended below.

## Honest gaps
- A3-T4 test lives in a new file inside FIX-I's package directory.
- A3-02 fixes the case of several listeners on one `Server`; `Serve` is still not forbidden from being called twice.
- The Windows build failure noted by the reviewer is untouched.

## Final mutation-script result
Second full run of `tests/test_decide_security_mutation.sh` (control GREEN): 69 mutants killed, 1 assertion failure = my N12 entry did not apply, because FIX-I changed `internal/contract/instance.go` (`SafeInstanceLabel` / `InstanceLabelMax`, over-long labels are now hashed, and FIX-I adapted my `instance_bound_test.go` accordingly). I updated the N12 entry to the new code (`if len(label) <= InstanceLabelMax {` -> `if true {`) and verified it locally: `TestInstanceNoteLabelLengthBound` FAILs on the mutant, passes restored. The full script was not re-run after that one-line edit (13 min); `bash -n` is clean. N13, N5, N7, A3-02, A3-01 (3 mutants), A3-03 were all killed in the full run (A3-01 "armed on every start" killed after I made the guard call unconditional in Ensure/Renew so the mutant is reachable).
