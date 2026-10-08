# `spec_closure_audit.py`

## Overview

Source: `scripts/spec_closure_audit.py` (script). The text below is the module's own docstring, reproduced so this page cannot drift from the code. Tests: `tests/py/test_spec_closure_audit.py` (run by `tests/test_py_unit.sh`).

```text
SC-004 / T129 closure audit for specs/009-jev-decision-models.

Every finding row (D-xx in source-findings.md, N-xx in
research/jev-llmctl-new-files.md) must end at FIXED (a RED observed on the
candidate, a guard that exists in the repository and a GREEN run), DEMOTED
(captured evidence that it is not a defect / not applicable) or, for medium and
low rows, ACCEPTED-LIMITATION.  The table is computed here from the registers;
nothing is typed by hand.  A closure that cites a test file or test name that
does not exist is reported OPEN, never closed.

Inputs (all under <spec>/evidence/ unless noted):
  p1-red-register.json     id -> RED | NOT-REPRODUCED | HARDENING | SKIP
  p1-red-original/*.jsonl  the captured RED / NOT-REPRODUCED output per id
  red-to-green-map.json    id -> regression guard(s) or an N/A reason
  sc004-overrides.json     optional: id -> {closure, reason, evidence[]}; every
                           evidence path must exist or the override is refused
  *-make-test.log          GREEN evidence (latest by name; "TEST: x / RESULT: PASS")

Usage:
  python3 scripts/spec_closure_audit.py [--root DIR] [--spec specs/009-jev-decision-models]
         [--out evidence/sc004-closure.md] [--json evidence/sc004.json] [--check]
Exit: 0 no open high/critical row; 1 at least one; 2 inputs unreadable.
```

## Behaviour notes

* A closure is computed, never typed: a row is `FIXED` only when (1) a captured RED line for its id exists in `evidence/p1-red-original/*.jsonl`, (2) `red-to-green-map.json` names at least one guard, (3) every named guard file exists and, where a test name is given, the name is found in that file, and (4) the latest `evidence/p*-make-test.log` records a passing suite (or Go package `ok` line) for the guard. Any failed step reports the row `OPEN` with the reason.
* `DEMOTED` needs a captured NOT-REPRODUCED / HARDENING / RED-then-removed verdict plus a written reason in the map; `ACCEPTED-LIMITATION` is allowed for medium/low rows only.
* `sc004-overrides.json` may close a row the automatic path cannot; every evidence path it lists must exist or the override is refused.
* The script reads recorded runs; it does not execute suites. The `GREEN` column therefore names the log it relied on.
* Control needle (test): a planted high-severity row with no evidence must be reported `OPEN` and make the exit status non-zero; a closure citing a missing test file or a name absent from the file must be `OPEN`.

## Edge cases

* Ids with variants (`D-17a/b`, `D-19a/b/c`, `D-30/tar.gz`) are evaluated per variant; the base entry is ignored when variants exist.
* A `SKIP` verdict whose map reason says it needs a live/real-model run stays `OPEN`; a `SKIP` needing macOS is an accepted limitation (medium/low only).
* Exit `0` no open high/critical row, `1` at least one open, `2` an input register is unreadable.
