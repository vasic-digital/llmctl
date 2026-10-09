# `verify_manifest.py`

## Overview

Source: `scripts/golden/verify_manifest.py` (script). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
Verify tests/fixtures/golden/MANIFEST.json against the files on disk (stdlib only).

Re-hashes every listed file and re-derives the counts from the JSONL content; fails (exit 1)
on any drift: changed bytes, missing or unlisted file, counts that no longer match, items
missing the honesty/licence fields, or fewer items than the minimums required by spec 009 SC-003.

Usage: verify_manifest.py [DIR]      (default tests/fixtures/golden)
```

Usage and options: see the header above and run the script with `--help` where it supports it.

## Observed behaviour (2026-10-09)

```
$ python3 -I scripts/golden/verify_manifest.py
manifest ok: <repo>/tests/fixtures/golden                         (rc 0)
```

Run against a scratch copy of the fixture directory with one line appended that is not JSON (`echo x >> questions.jsonl`), it exits **1** with a Python traceback
(`json.decoder.JSONDecodeError: Expecting value: line 1 column 1`) rather than a one-line problem message: the failure is detected, but the report is unfriendly (the script itself was not changed).
Drift in bytes or counts is reported as problems with exit 1 (header above). Used by the golden-set procedure in [golden-set](../golden-set.md); run it after every `build_manifest.py`.
