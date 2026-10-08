#!/usr/bin/env bash
# test_py_unit.sh - runs the stdlib-unittest tier for the lib/llmctl_decide package.
# Stand-ins are allowed ONLY in this unit tier (spec FR-039); every other tier
# drives the real system. Bytecode is never written into the work tree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="${ROOT}/lib${PYTHONPATH:+:${PYTHONPATH}}"
shopt -s nullglob
files=("${ROOT}"/tests/py/test_*.py)
if [[ ${#files[@]} -eq 0 ]]; then echo "SKIP-SUITE: no python unit tests present (tests/py/test_*.py)"; exit 0; fi
cd "${ROOT}"
python3 -B -m unittest discover -s tests/py -p 'test_*.py' -t . -v 2>&1 | tail -n 400
rc=${PIPESTATUS[0]}
[[ ${rc} -eq 0 ]] || { echo "python unit tier FAILED (rc=${rc})"; exit "${rc}"; }
echo "  ok: python unit tier (stdlib unittest discover) passed"
echo "python unit tier OK"
