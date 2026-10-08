# `test_gpu_vram_delta.sh`

## Overview

Source: `tests/test_gpu_vram_delta.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_gpu_vram_delta.sh - 005-cuda-gpu-inference T007/T008 (spec.md
Acceptance Scenario 2, SC-002): proves a real, GPU-eligible cataloged
profile's model load produces a MEASURED >= 500 MiB VRAM delta on this
host, observed independently of llama-server's own self-reported
success line, via a real `nvidia-smi --query-gpu=memory.used`
before/after/during-inference comparison (research.md R4).

This test launches llama-server DIRECTLY (mirroring
lib/download.sh's _dl_smoke_test_gguf() real-completion pattern,
per the task brief) rather than through the systemd-backed
lib/scheduler.sh path, so it can force a specific --n-gpu-layers value
per invocation without needing `llmctl install` units or disturbing
any already-running persistent llmctl services on this host.

Real requirements, no mocking (Constitution Principle IV / §11.4.27):
- a real, already-downloaded GGUF model file
- a real llama-server subprocess, real HTTP requests
- real `nvidia-smi` output, sampled from the live GPU
```

Run: `bash tests/test_gpu_vram_delta.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh gpu_vram_delta` (see [doc_counts](doc_counts.md)).
