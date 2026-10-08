# `test_engine_cpu_regression.sh`

## Overview

Source: `tests/test_engine_cpu_regression.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_engine_cpu_regression.sh - 005-cuda-gpu-inference T013: permanent
regression guard proving the CUDA engine.sh change (the cuda) branch's
CMAKE_CUDA_FLAGS compiler-compatibility flag, if/when one is added by
T005) is genuinely ADDITIVE - with nvcc absent from PATH,
engine_detect_backend still returns exactly "cpu", and
engine_build_llama's emitted cmake command line for the cpu) branch
still contains -DGGML_NATIVE=ON and does NOT contain -DGGML_CUDA=ON nor
any CMAKE_CUDA_FLAGS entry. This is User Story 3 (spec.md) / FR-003 /
FR-004 / SC-005: a host without a capable GPU (or, as tested here, a
host that simply has no nvcc on PATH) must be completely unaffected by
this feature.

This test intentionally PASSES against BOTH the pre-005 lib/engine.sh
and the post-005 lib/engine.sh (per tasks.md T013: "though it should
currently PASS ... this task's job is to LOCK that guarantee in as a
permanent regression test, not discover a new defect"). The paired
mutation that proves this gate is not a bluff lives in
docs/qa/005-cuda-gpu-inference/meta_test_evidence.txt (T014).
```

Run: `bash tests/test_engine_cpu_regression.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh engine_cpu_regression` (see [doc_counts](doc_counts.md)).
