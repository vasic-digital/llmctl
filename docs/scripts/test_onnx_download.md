## Overview

`tests/test_onnx_download.sh` proves the `onnx`-engine path through the
verified download pipeline in `lib/download.sh`, mirroring
`tests/test_decide_download.sh`: a synthetic single-profile catalog
(`toy-onnx`, engine `onnx`) pointing at a local `python3 -m http.server`
fixture on an ephemeral port (no fixed port, no real Hugging Face traffic).
It asserts: (1) structural validation runs and passes; (2) with stub
`onnxruntime`/`sentencepiece` modules on `PYTHONPATH`
(`tests/fixtures/onnx_stubs/` — the only stand-ins; there is no env seam) the
REAL `lib/onnx_server.py` launches on the smoke port, becomes `/readyz`-ready,
and the entail/contradict/batch probes pass against `POST /v1/score`; (3)
with the deps hidden the smoke SKIPs with a recorded reason, the download
still exits 0, **no "downloaded and verified" claim is made** and the
evidence log says `FILES-VERIFIED, smoke not run` instead of
`download toy-onnx: SUCCESS` (D-12/N-26); (4) a SIGTERM to the smoke shell
leaves no orphaned runtime (D-14; proven RED when the cleanup traps are removed).

## Prerequisites

`tests/helpers.sh`, `lib/common.sh`, `lib/catalog.sh`, `lib/download.sh`,
`python3` with `numpy` (else a printed SKIP), `curl`, `LLMCTL_HF_BASE` /
`LLMCTL_CATALOG` pointed at the fixtures. The toy `model.onnx` is the JSON
behaviour spec of the stub onnxruntime (NOT a real ONNX protobuf); the
catalog also lists `onnx/config.json` so the label order is a pinned file.

## Usage examples

`bash tests/test_onnx_download.sh` (also via `make test`).

## Edge cases

Subdirectory layout (`onnx/model.onnx`) is preserved; a runtime whose
`label_source` carries no semantics (`generic-config`/`none`) fails the
semantic probes rather than guessing.

## Internal behaviour

Section 1 downloads + smokes; section 2 re-runs (marker-based skip); section
3 shadows `onnxruntime` with an ImportError module; section 4 runs
`_dl_smoke_test_onnx` in a child shell with a slowed probe and SIGTERMs it.

## Related scripts

`lib/download.sh`, `lib/onnx_server.py`, `tests/test_decide_download.sh`,
`tests/test_onnx_runtime.sh`.

## Last verified date

2026-10-07
