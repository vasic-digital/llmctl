# `test_certs_go_cli.sh`

## Overview

Source: `tests/test_certs_go_cli.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_certs_go_cli.sh - builds the REAL Go binary (into a temp dir, nothing in
the repo tree) and drives `cert` end to end; the independent `openssl`
binary judges what the Go implementation produced (FR-066..FR-068, FR-087).
```

Run: `bash tests/test_certs_go_cli.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh certs_go_cli` (see [doc_counts](doc_counts.md)).
