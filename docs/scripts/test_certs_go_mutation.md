# `test_certs_go_mutation.sh`

## Overview

Source: `tests/test_certs_go_mutation.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_certs_go_mutation.sh - paired mutation check for internal/certs (Constitution §1.1).

Each mutant breaks ONE security-relevant behaviour in a throw-away COPY of the
package (a temp module; the working tree is never touched, so there is nothing
to restore) and the package's own tests MUST then fail. A mutant that survives
means a guard is decoration. A baseline (unmutated) run must pass first, so a
failure is attributable to the mutation alone.
Not mutated: the byte-compare inside exportOffline (a defensive check with no
injectable fault: a copy written by this process always equals its source).
```

Run: `bash tests/test_certs_go_mutation.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh certs_go_mutation` (see [doc_counts](doc_counts.md)).
