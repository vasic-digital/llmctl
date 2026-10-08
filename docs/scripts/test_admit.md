# `test_admit.sh`

## Overview

Source: `tests/test_admit.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_admit.sh - admission gate (lib/admit.sh, `llmctl admit`), T090.

Network-free: the Hugging Face API is served from tests/fixtures/admission/
by a local HTTP server (127.0.0.1, ephemeral port) selected through
LLMCTL_HF_BASE. Golden-good AND golden-bad fixtures: every gate that can
reject is shown rejecting (a gate never seen to FAIL is unvalidated).
```

Run: `bash tests/test_admit.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh admit` (see [doc_counts](doc_counts.md)).
