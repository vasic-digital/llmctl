#!/usr/bin/env bash
# Fixture real-run executor (golden-bad): determinism check fails.
set -euo pipefail
printf '{"status":"FAIL","evidence":"fixture real run failed for %s","subchecks":[{"check":"loadability","status":"PASS","evidence":"loaded"},{"check":"determinism_repeats","status":"FAIL","evidence":"2/3 identical"}]}\n' "$1"
