# test_onnx_real_tokenizer.sh

## Overview

`tests/test_onnx_real_tokenizer.sh` is the D-01 / G-017 regression guard that uses the **real** DeBERTa-v3 SentencePiece
tokenizer (`onnx/spm.model` of the `decide-nli` profile), where `tests/test_onnx_runtime.sh` only has a stub tokenizer.
It builds a `Scorer` from `lib/onnx_server.py` without onnxruntime (`encode()` needs only the tokenizer), feeds a
~600-token premise plus a 16-token hypothesis and asserts, through `tests/fixtures/onnx_real_tokenizer_check.py`: the
pair is exactly 512 tokens, `truncated` is true, `[CLS]` first, exactly two `[SEP]`, the whole hypothesis survives, only
the premise is cut, token types cover the hypothesis, and a short pair is not truncated. A paired mutation rewrites the
runtime so the pair is truncated from the end (the candidate's original defect); the mutant MUST fail the same check.

## Prerequisites

`bash`, `python3`. The tokenizer file (`LLMCTL_REAL_SPM`, or `$LLMCTL_DATA_DIR/models/decide-nli/onnx/spm.model` after
`llmctl models download decide-nli`) whose sha256 must equal the catalog pin, and a Python with `sentencepiece` and
`numpy` (`LLMCTL_ONNX_PY`, `$LLMCTL_DATA_DIR/venv-onnx/bin/python` from `llmctl build onnx`, or `python3`). Anything
missing prints `SKIP-SUITE: <reason>` before any assertion and exits 0 (a skip, never a pass).

## Usage examples

`bash tests/test_onnx_real_tokenizer.sh`

`LLMCTL_REAL_SPM=/path/spm.model LLMCTL_ONNX_PY=/path/venv/bin/python bash tests/test_onnx_real_tokenizer.sh`

## Edge cases

A tokenizer file that does not match the catalog sha256 is refused as a skip (never asserted on). The mutation anchor must
occur exactly once in `lib/onnx_server.py`; if the runtime code is refactored the mutation fails loudly instead of
becoming vacuous. The check proves only the pairing/truncation logic on the real tokenizer, not model accuracy.

## Internal behaviour

Bash resolves and verifies the tokenizer and Python, runs the check against the shipped runtime (expects rc 0), then
against a temp-dir mutant (expects rc 1 and a `FAIL hypothesis tokens intact` line). Evidence of the original RED/GREEN:
`specs/009-jev-decision-models/evidence/realcheck/d01/`.

## Related scripts

`lib/onnx_server.py`, `tests/test_onnx_runtime.sh`, `tests/fixtures/onnx_rt_contract.py`,
`tests/fixtures/onnx_real_tokenizer_check.py`.

## Last verified date

2026-10-08
