# `test_link_deps.sh`

## Overview

Source: `tests/test_link_deps.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_link_deps.sh - proves scripts/link_deps.sh creates the ignored convenience links from what
lib/resolve_deps.sh resolves, is idempotent, never clobbers a real directory, and reports an unresolved
dependency loudly (exit 1) while still linking the others. Runs the REAL script in a mktemp fixture.
```

Run: `bash tests/test_link_deps.sh`.
