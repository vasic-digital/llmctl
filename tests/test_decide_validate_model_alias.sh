#!/usr/bin/env bash
# Regression: the validator's decide question body must carry a model id the production driver
# (llmctl-decide smoke) serves. It sent "validate", the smoke serves only "smoke" -> every decide-*
# profile validated UNDETERMINED ("Unknown model."). Drives the REAL driver binary + the REAL
# validate_judge body builder; a TCP listener satisfies the pre-connect check, the request is
# parsed (and refused or accepted) before any HTTP is sent.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${LLMCTL_DECIDE_BIN:-$ROOT/build/llmctl-decide}"
[ -x "$BIN" ] || { echo "SKIP-SUITE: no built llmctl-decide at $BIN"; exit 0; }
fail=0
body=$(python3 -I - "$ROOT/lib" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
import validate_judge as vj, subprocess
cap = {}
def fake(cmd, **kw):
    cap["q"] = open(cmd[cmd.index("--question-file") + 1]).read()
    class P: returncode = 99; stdout = ""; stderr = "x"
    return P()
subprocess.run = fake
class A: endpoint = "http://127.0.0.1:1"; decide_bin = "x"; decide_protocol = "letter-logit"; decide_key_file = None
case = {"question": {"type": "choice", "state": "s", "instructions": "i", "criteria": {"a": "x", "b": "y"}}}
try: vj.decide_ask(A, case, 5)
except Exception: pass
print(cap["q"])
PY
)
[ -n "$body" ] || { echo "FAIL: could not capture validator question body"; echo "RESULT: FAIL"; exit 1; }
ask() { # <question body> : run the real driver against a listener that only satisfies the pre-connect check; prints its output
  local f port lp out
  f=$(mktemp); printf '%s' "$1" > "$f"
  python3 -I -c 'import socket,sys,time;s=socket.socket();s.bind(("127.0.0.1",0));s.listen(5);print(s.getsockname()[1],flush=True);time.sleep(8)' > "$f.port" &
  lp=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$f.port" ] && break; sleep 0.2; done
  port=$(cat "$f.port")
  out=$("$BIN" smoke --url "http://127.0.0.1:$port" --protocol letter-logit --question-file "$f" --json --timeout 2s 2>&1) || true
  kill $lp 2>/dev/null; rm -f "$f" "$f.port"
  printf '%s' "$out"
}
# positive control: the OLD body (model "validate") really is refused by this driver, so the check below can see the defect
old_body="${body//\"smoke\"/\"validate\"}"
[ "$old_body" != "$body" ] || { echo "  FAIL: the captured body has no \"smoke\" model to swap for the control"; fail=1; }
if grep -q 'Unknown model' <<<"$(ask "$old_body")"; then echo "  ok: control: the old \"validate\" body is refused with 'Unknown model'"
else echo "  FAIL: control: the old body was not refused with 'Unknown model' (the test cannot see the defect)"; fail=1; fi
out=$(ask "$body")
if grep -q 'Unknown model' <<<"$out"; then echo "  FAIL: driver refused validator body: $out"; fail=1
else echo "  ok: driver accepted the validator body (not an Unknown-model refusal)"; fi
if [ $fail = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi; exit $fail
