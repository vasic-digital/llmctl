# `test_py_unit.sh`

## Overview

Source: `tests/test_py_unit.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_py_unit.sh - runs the stdlib-unittest tier for the lib/llmctl_decide package.
Stand-ins are allowed ONLY in this unit tier (spec FR-039); every other tier
drives the real system. Bytecode is never written into the work tree.
```

Run: `bash tests/test_py_unit.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh py_unit` (see [doc_counts](doc_counts.md)).
