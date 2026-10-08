# `test_tls_server.sh`

## Overview

Source: `tests/test_tls_server.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_tls_server.sh - transport tier for internal/server (T023, spec FR-019, FR-022, FR-066, FR-070):
  1. the in-process end-to-end Go test (real sockets, real TLS) must pass;
  2. a real server process (test-only helper, throw-away CA) is driven by the REAL curl binary and
     judged on status, headers, certificate chain and the plain-HTTP refusal.
Nothing is written into the repository tree (the helper binary and its CA/key live in a temp dir).
```

Run: `bash tests/test_tls_server.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh tls_server` (see [doc_counts](doc_counts.md)).
