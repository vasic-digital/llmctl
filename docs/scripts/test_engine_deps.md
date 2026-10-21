# `test_engine_deps.sh`

## Overview

Source: `tests/test_engine_deps.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_engine_deps.sh - B1 (review round 2): the RUNTIME build path (`llmctl setup`, `llmctl build decide|all`,
and through them scripts/install.sh) must make the go.mod replace target (submodules/containers) exist, or STOP with
the resolver's actionable message - never fall through to a misleading "Go toolchain / module cache" error.
Every case runs the REAL bin/llmctl or lib/engine.sh from a throw-away fresh-clone FIXTURE (no link, no go build).
```

Run: `bash tests/test_engine_deps.sh`.
