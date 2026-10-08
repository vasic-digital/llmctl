#!/usr/bin/env bash
# test_defects_d16_d32.sh - RED (failing-first) reproductions of source-findings
# defects D-16..D-32 against the unmodified candidate. NOT auto-run by
# `make test` (lives outside tests/test_*.sh). Exit 1 while any defect is RED.
# Results: tests/red/results/d16_d32.jsonl
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "${HERE}/py/test_d16_d32.py" "${HERE}/results/d16_d32.jsonl"
