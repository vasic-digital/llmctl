# `test_no_retired_vars.sh`

## Overview

Source: `tests/test_no_retired_vars.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_no_retired_vars.sh - retired decision-layer variables are gone from every PRODUCTION path (task T025, gap G-051).
  LLMCTL_DECIDE_BACKEND_HOST/PORT   redirected user state to another host (D-11)
  LLMCTL_ONNX_FAKE                  fake-model test seam that could mark a download "verified" (D-12)
  LLMCTL_DECIDE_API_KEY             replaced by the single LLMCTL_API_KEY (FR-057)
  LLMCTL_DECIDE_INTERNAL_KEY        engine key in the environment (visible in /proc/<pid>/environ, G-040) -> key FILES
Production code (bin, lib, scripts, templates, models, Makefile, non-test Go and Python) must not mention them at all.
Docs and tests may mention them only on a line that says they are retired/removed/ignored/historical (negative
assertions and migration notes), or in an allow-listed file up to a PINNED number of mentions. A control needle proves
the scanner sees a planted production hit.
C3-13: the production scan skips only the TOP-LEVEL docs/, tests/, specs/, build/, submodules/, constitution/ (and .git /
node_modules anywhere). A directory merely NAMED tests/, docs/ or build/ deeper in the tree (lib/tests/, scripts/build/)
is production and is scanned. An allow-list entry is "path:N": the file may mention a retired name at most N times, so a
NEW mention in an allow-listed file is still caught.
```

Run: `bash tests/test_no_retired_vars.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh no_retired_vars` (see [doc_counts](doc_counts.md)).
