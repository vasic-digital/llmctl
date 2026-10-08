# `test_engine_build_safety.sh`

## Overview

Source: `tests/test_engine_build_safety.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_engine_build_safety.sh - llama.cpp build safety (gaps G-115, host-safety build concurrency):
  * the job count is bounded by AVAILABLE MEMORY, not only by cores (a CUDA compile needs ~2 GiB per job),
  * HTTPS support (OpenSSL) is requested when the headers exist and VERIFIED after the build from the
    build's own evidence (CMakeCache + linked libssl) - `llama-server --help` listing --ssl-* flags is NOT proof.
```

Run: `bash tests/test_engine_build_safety.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh engine_build_safety` (see [doc_counts](doc_counts.md)).
