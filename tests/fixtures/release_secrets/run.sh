#!/usr/bin/env bash
# test_release_no_secrets.sh - RED proof for D-30 (specs/009-jev-decision-models/source-findings.md):
# scripts/release/build_archive.sh archives the WHOLE working tree, so a planted
# .env / cert/ca/ca.key / decide/log.key (FAKE random markers, never real
# credentials) can enter the release tar.gz and zip.
# Works on a COPY of the tracked non-submodule files in a scratch dir; builds with
# the real script, extracts BOTH archives and scans them. Includes a CONTROL NEEDLE
# (marker in tracked README.md must be found, else ERROR = blind instrument) and a
# never-planted negative control. Driven by tests/test_release_no_secrets.sh (the permanent D-30 guard).
# Outcomes -> tests/red/d30.jsonl. Exit 1 if RED, 2 if ERROR, 0 if NOT-REPRODUCED.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RED_RESULTS_FILE="${RED_RESULTS_FILE:-${HERE}/d30.jsonl}"
RED_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/red-d30-XXXXXX")"
export RED_SCRATCH
trap 'rm -rf "${RED_SCRATCH}"' EXIT
mkdir -p "$(dirname "${RED_RESULTS_FILE}")"
: > "${RED_RESULTS_FILE}"
export PYTHONDONTWRITEBYTECODE=1
rc=0
python3 -I "${HERE}/scenario.py" || rc=$?
exit "${rc}"
