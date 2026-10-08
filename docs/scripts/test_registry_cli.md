# `test_registry_cli.sh`

## Overview

Source: `tests/test_registry_cli.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_registry_cli.sh - builds the REAL llmctl-decide binary (into a temp dir, nothing in the
repo tree) and drives `port`, `registry` and `discover` end to end with real listener
processes (FR-088..FR-090, SC-015). Exit status, stdout and the live process set are judged.
```

Run: `bash tests/test_registry_cli.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh registry_cli` (see [doc_counts](doc_counts.md)).
