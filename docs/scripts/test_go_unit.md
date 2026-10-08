# `test_go_unit.sh`

## Overview

Source: `tests/test_go_unit.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_go_unit.sh - Go unit tier for the decision layer (Gin gateway, client, keyring, certs...).
Stand-ins are allowed only in this tier (spec FR-039). Uses the pinned go.sum; fails if the
module graph does not verify. Bytecode/binaries are never written into the work tree.
```

Run: `bash tests/test_go_unit.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh go_unit` (see [doc_counts](doc_counts.md)).
