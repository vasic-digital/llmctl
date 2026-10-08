#!/usr/bin/env bash
# test_defects_d01_d15.sh - RED (failing-first) reproduction of defects D-01..D-15
# (specs/009-jev-decision-models/source-findings.md section B).
# NOT auto-run by `make test` (lives under tests/red/). Writes
# tests/red/results/d01_d15.jsonl. Exit: 0 = nothing reproduced, 1 = at least
# one RED, 2 = harness ERROR.  Usage: test_defects_d01_d15.sh [d01 d05 ...]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 -B "${HERE}/py/test_defects_d01_d15.py" "${HERE}/results/d01_d15.jsonl" "$@"
rc=$?
echo "--- results (${HERE}/results/d01_d15.jsonl)"
python3 - "${HERE}/results/d01_d15.jsonl" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    print("%-5s %-15s %s" % (r["id"], r["status"], r["key_output_excerpt"][:110]))
PY
exit "${rc}"
