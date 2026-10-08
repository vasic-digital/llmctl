#!/usr/bin/env bash
# coverage_rows.sh - T121 "Coverage closure": fails (exit 1) if any ADOPT / ADOPT-AFTER-VERIFICATION idea id in
# specs/<feature>/research/ideas-closure.md is not cited in that feature's tasks.md; exit 2 = BLIND (inputs
# unreadable / no ADOPT rows seen - never reported as clean). Usage: coverage_rows.sh [specdir]
# (default specs/009-jev-decision-models). Proven by tests/test_task_coverage.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "${ROOT}/tests/py/task_coverage.py" rows --specdir "${1:-${ROOT}/specs/009-jev-decision-models}"
