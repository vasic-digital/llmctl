# `similarity.py`

## Overview

Source: `scripts/golden/similarity.py` (script). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
Near-duplicate finder for golden-set JSONL files (stdlib only).

Similarity of two items = Jaccard index of their character 4-gram sets over the
normalised "state" text (lower-cased, whitespace collapsed). Items of different
types are never compared. Two thresholds:

  --max-same-label S   (default 0.80) pairs with the SAME expected answer must stay below S
  --max-any A          (default 0.92) no pair may reach A, whatever the labels

Pairs with DIFFERENT expected answers and high similarity are legitimate
minimal contrast pairs (for example the same requirement with correct and
broken code); they are listed, not failed, unless they reach --max-any.

Usage: similarity.py questions.jsonl [probes.jsonl ...] [--json]
Exit 0 = ok, 1 = a threshold was breached, 2 = usage / read error.
```

Usage and options: see the header above and run the script with `--help` where it supports it.
