# `test_ctx_kvtype_override.sh`

## Overview

Source: `tests/test_ctx_kvtype_override.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_ctx_kvtype_override.sh - per-profile context-size and KV-cache-type
override mechanisms (LLMCTL_CTX_<PROFILE>, LLMCTL_KVTYPE_<PROFILE>),
exercised for real against the actual catalog.

Root cause this covers (2026-10-03, real repro on real hardware, not
guessed): models/catalog.json's "ctx" default had NO override anywhere
in the codebase (grep for LLMCTL_CTX found nothing pre-fix) - every
profile was permanently stuck at its catalog default context size
regardless of what a specific host could actually support. Confirmed
live: llmctl-small's model (Llama-3.2-3B) served a REAL 75000-token
context with q4_0 KV-cache quantization on a 12GB consumer GPU, far
past its 8192-token catalog default - but there was no way to configure
either the larger context OR the quantization without editing the
shared, portable catalog file. This mirrors test_port_override.sh's
exact convention for the identical class of fix.
```

Run: `bash tests/test_ctx_kvtype_override.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh ctx_kvtype_override` (see [doc_counts](doc_counts.md)).
