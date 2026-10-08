## Overview

`tests/test_engine_build_onnx.sh` covers `engine_build_onnx` (hash-locked
private venv for the encoder runtime): the committed
`lib/lock/requirements-onnx.lock` pins onnxruntime/numpy/sentencepiece/
tokenizers with sha256 hashes; an `UNPINNED`-marked, hashless or missing lock
is refused; `LLMCTL_DRY_RUN=1` prints the pins and creates no venv. With
`LLMCTL_TEST_NETWORK=1` it additionally performs the live install, imports
the pinned onnxruntime, and proves that a tampered hash fails the install and
leaves no venv.

## Prerequisites

`bash`, `python3`; live cases need PyPI and `uv` or `python3-venv`.

## Usage examples

`bash tests/test_engine_build_onnx.sh` ; `LLMCTL_TEST_NETWORK=1 bash tests/test_engine_build_onnx.sh`

## Edge cases

Without `LLMCTL_TEST_NETWORK=1` the live cases print an honest SKIP.

## Internal behaviour

Overrides `LLMCTL_ONNX_LOCK` / `LLMCTL_ONNX_VENV` / `LLMCTL_DATA_DIR`.

## Related scripts

`lib/engine.sh`, `lib/lock/requirements-onnx.lock`.

## Last verified date

2026-10-07
