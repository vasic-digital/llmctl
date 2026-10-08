# `stats.py`

## Overview

Source: `scripts/golden/stats.py` (script). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
Statistics for the golden question set (stdlib only; spec 009 SC-003, FR-080).

Input: a list of result records (see run_golden.py), each a dict with
  id, type (noul|choice|score), family, expected, predicted (None = malformed),
  well_formed (bool), variant ("orig" or "perm"), perm_group (choice only),
  option_count (choice) / scale (score), p_pred (probability the answer gave to its
  own prediction, or None).

What is computed (all from the same records, by the same code, so the interval and
the baseline can never come from different tools):

  * accuracy with a Wilson 95% interval, per type
  * the trivial baselines per type: the majority-class share of the EXPECTED answers
    and the chance level (mean of 1/options); the baseline used for the verdict is
    the larger of the two
  * verdict "lower bound of the interval > baseline" (SC-003)
  * per-class accuracy (class = the expected answer) and per-family accuracy with the
    family's own majority baseline (imbalanced families make the majority baseline strong)
  * option-order flip rate over permutation groups
  * accuracy-vs-option-count (choice) and accuracy-vs-scale (score) tables
  * ECE / MCE / Brier, ONLY when at least 200 labelled items exist, otherwise the
    literal text "insufficient for calibration"

Usage: stats.py RESULTS.json [--json]     (RESULTS.json = {"records": [...]})
```

Usage and options: see the header above and run the script with `--help` where it supports it.
