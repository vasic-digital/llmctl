#!/usr/bin/env bash
# Regenerates the REAL-JUDGE captures used by tests/test_livetest_watchdog.sh.
# Source: the validate worktree's own lib/validate_judge.py run against ITS tests/fixtures/validation/fake_openai.py
# (a local deterministic answer-table server on 127.0.0.1, not a model). Nothing here starts a model or a service.
# Usage: regenerate.sh <validate-worktree> <out-dir>
set -euo pipefail
W="${1:?validate worktree}"; OUT="${2:?out dir}"
SUITE="$W/validation/suites/vision-golden-v1"; FIX="$W/tests/fixtures/validation"
mkdir -p "$OUT/vision-golden-v1"; T="$(mktemp -d)"; PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null || true; rm -rf "$T"' EXIT
cp "$SUITE/expectations.json" "$OUT/vision-golden-v1/expectations.json"
run() {  # run <name> <answers-file> [fake args...]
  local name="$1" ans="$2"; shift 2
  python3 -I "$FIX/fake_openai.py" --suite "$SUITE" --answers "$ans" --port-file "$T/$name.port" \
    --model-id /m/vision/gemma-3-4b-it-Q4_K_M.gguf --max-seconds 120 "$@" >/dev/null 2>&1 & PIDS+=($!)
  for _ in $(seq 1 100); do [ -s "$T/$name.port" ] && break; sleep 0.1; done
  LLMCTL_VALIDATE_TIMEOUT=30 python3 -I "$W/lib/validate_judge.py" run --suite "$SUITE" \
    --endpoint "http://127.0.0.1:$(cat "$T/$name.port")" --expect-model gemma-3-4b-it-Q4_K_M.gguf --json >"$OUT/real_judge_$name.json" || true
}
run pass "$FIX/answers_good.json"
python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));d["01_text_large/read"]="PURPLE ELEPHANT 7";json.dump(d,open(sys.argv[2],"w"))' "$FIX/answers_good.json" "$T/wrong.json"
run wrong "$T/wrong.json"
run truncate "$FIX/answers_good.json" --mode truncate
run malformed "$FIX/answers_good.json" --mode malformed-message
echo "git_head_of_validate_worktree=$(git -C "$W" rev-parse HEAD)" >"$OUT/PROVENANCE.txt"
