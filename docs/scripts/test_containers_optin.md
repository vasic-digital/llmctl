# `test_containers_optin.sh`

## Overview

Source: `tests/test_containers_optin.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_containers_optin.sh - meta-check (review round 5, I-2): a tests/*.sh suite that runs the Go toolchain on a package which
imports digital.vasic.containers (internal/gateway, internal/registry, cmd/llmctl-decide, ./...) FAILS with a misleading
"FAIL: control run passes" or a 600 s timeout when the containers dependency is unresolvable, unless it calls
`require_containers_or_skip` (tests/helpers.sh) at the top. This test scans every tests/test_*.sh: a NON-COMMENT line holding
`go build|test|list|vet|run` requires an un-commented `require_containers_or_skip` line, or an entry (with its reason) in
tests/containers_optin_exempt.txt for suites whose go packages do not depend on containers. Stale exemptions fail.
The scanner is control-needled first: a planted suite without the opt-in MUST be flagged, one with it and a comment-only
mention MUST NOT be.
```

Run: `bash tests/test_containers_optin.sh`.
