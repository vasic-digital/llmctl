# `build_manifest.py`

## Overview

Source: `scripts/golden/build_manifest.py` (script). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
(Re)write tests/fixtures/golden/MANIFEST.json from the JSONL files (stdlib only, deterministic).

Run after ANY edit of questions.jsonl or probes.jsonl, then run verify_manifest.py.
Usage: build_manifest.py [DIR]
```

Usage and options: see the header above and run the script with `--help` where it supports it.

## Observed behaviour (2026-10-09)

Run against a scratch copy of `tests/fixtures/golden` (the tracked manifest was not rewritten):

```
$ python3 -I scripts/golden/build_manifest.py <scratch copy>
wrote <scratch copy>/MANIFEST.json: {'questions.jsonl': 132, 'probes.jsonl': 23}      (rc 0)
```

The written manifest was byte-identical (`cmp`) to the tracked one, which is what "deterministic" means here. Always follow it with `verify_manifest.py`. Context: [golden-set](../golden-set.md).
