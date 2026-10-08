## Overview

`tests/test_decide_security_mutation.sh` is the paired-mutation check (Constitution section 1.1) for the
review-2 scope-A security fixes (A-01..A-18, `specs/009-jev-decision-models/evidence/review-2/review-A-security.md`).
It copies `cmd/` and `internal/` into a scratch directory, first proves the unmutated copy is GREEN, then breaks
one guard at a time (eviction of unauthenticated holders, the authenticated reserve, the pre-auth timer, the
throttle table, the TLS floor through `GetConfigForClient`, the entropy floor, the digest comparison, the key
cache fail-closed rule, the fail-closed placement guard, the private-key file checks, the legacy-variable filter,
...) and requires the Go tests of that package to go RED. Its first block replays the seven mutations the
independent reviewer wrote (R-M1..R-M7); R-M7 used to hang the suite, so every mutant runs under
`go test -timeout` (`DECIDE_MUTATION_TIMEOUT`, default 300s) and a hang is reported as a clean failure.

Nothing in the repository tree is modified: every mutation is applied to the copy and reverted after its run.

## Prerequisites

`go`, `python3` (the suite prints SKIP-SUITE and exits 0 without them).

## Usage examples

```sh
bash tests/test_decide_security_mutation.sh
DECIDE_MUTATION_TIMEOUT=120s bash tests/test_decide_security_mutation.sh
```

## Edge cases

* A mutation whose search text no longer matches exactly once FAILS the suite ("mutation did not apply"), so
  a refactor cannot silently turn a mutant into a no-op.
* One equivalent mutant is documented in `tests/test_certs_go_mutation.sh` (the up-front existence check of
  the CA-key export is backed by the atomic `link(2)`; it is not counted as a surviving mutant).

## Internal behaviour

`kill NAME FILE OLD NEW PKG [go-test-args]` applies a single exact textual replacement with python3, runs
`go test PKG`, restores the file, and counts a green run as a surviving mutant.
