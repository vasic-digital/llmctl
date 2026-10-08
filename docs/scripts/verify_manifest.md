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
