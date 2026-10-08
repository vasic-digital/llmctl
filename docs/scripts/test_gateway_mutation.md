# `test_gateway_mutation.sh`

## Overview

Source: `tests/test_gateway_mutation.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_gateway_mutation.sh - T042 paired mutations (FR-038..040): each guard of the gateway wiring is
broken in a COPY of the sources (nothing in the repo tree is touched) and the Go tests MUST go RED;
an unmutated control copy MUST stay GREEN first (a mutation test with a red baseline proves nothing).
```

Run: `bash tests/test_gateway_mutation.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh gateway_mutation` (see [doc_counts](doc_counts.md)).
