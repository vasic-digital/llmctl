#!/usr/bin/env bash
# test_candidate_files_n01_n29.sh - failing-first (RED) tests for the file-review
# defects N-01..N-29 (specs/009-jev-decision-models/research/jev-llmctl-new-files.md).
#
# NOT auto-run by `make test` (lives in tests/red/, not tests/test_*.sh).
# Exercises the REAL code (bin/llmctl, lib/decide.sh, lib/decide_gateway.py,
# lib/onnx_server.py); only model backends are stand-ins. Servers bind
# 127.0.0.1 on ephemeral ports; only PIDs we spawned are killed.
# Outcomes -> tests/red/results/n01_n29.jsonl
#   {id,status RED|NOT-REPRODUCED|SKIP|ERROR|HARDENING,command,exit_code,key_output_excerpt}
# Exit: 1 if any RED or ERROR (defects present / instrument problem), else 0.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RED_RESULTS_FILE="${RED_RESULTS_FILE:-${HERE}/results/n01_n29.jsonl}"
RED_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/red-n-XXXXXX")"
export RED_SCRATCH
trap 'rm -rf "${RED_SCRATCH}"' EXIT
mkdir -p "$(dirname "${RED_RESULTS_FILE}")"
: > "${RED_RESULTS_FILE}"
export PYTHONDONTWRITEBYTECODE=1
python3 -I "${HERE}/py/n_tests.py" >"${RED_SCRATCH}/unittest.log" 2>&1 || {
  echo "unittest runner failed:" >&2; tail -20 "${RED_SCRATCH}/unittest.log" >&2; }
python3 -I - "${RED_RESULTS_FILE}" <<'PY'
import json, sys, collections
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
c = collections.Counter(r["status"] for r in rows)
for r in sorted(rows, key=lambda r: r["id"]):
    print("%-5s %-15s %s" % (r["id"], r["status"], r["key_output_excerpt"][:110]))
print("TOTAL %d: %s" % (len(rows), dict(c)))
sys.exit(1 if c.get("RED") or c.get("ERROR") else 0)
PY
