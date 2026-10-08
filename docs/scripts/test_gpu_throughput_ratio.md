# `test_gpu_throughput_ratio.sh`

## Overview

Source: `tests/test_gpu_throughput_ratio.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_gpu_throughput_ratio.sh - 005-cuda-gpu-inference T009/T010
(spec.md Acceptance Scenario 3, SC-003): runs the SAME cataloged
profile + prompt once forced to `--n-gpu-layers 0` (CPU-only) and once
at the real catalog-planned `ngl` (GPU offload), measures REAL
wall-clock time to a real chat-completion response and derives REAL
tokens/sec from the response's own `usage.completion_tokens` field
(reusing lib/download.sh's `_dl_smoke_test_gguf()` real-completion
parsing pattern - message.content + finish_reason, per the task
brief), and asserts the GPU run's tok/s is at least 2x the CPU run's
tok/s (SC-003).

Real requirements, no mocking (Constitution Principle IV / §11.4.27):
real llama-server subprocesses, real HTTP completion requests, real
wall-clock timing, real token counts from the engine's own usage field.
```

Run: `bash tests/test_gpu_throughput_ratio.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh gpu_throughput_ratio` (see [doc_counts](doc_counts.md)).
