#!/usr/bin/env bash
#!/bin/bash
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
f=$(mktemp); printf '%s' "$body" > "$f"
python3 -I -c 'import socket,sys,time;s=socket.socket();s.bind(("127.0.0.1",0));s.listen(5);print(s.getsockname()[1],flush=True);time.sleep(8)' > "$f.port" &
lp=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$f.port" ] && break; sleep 0.2; done
port=$(cat "$f.port")
out=$("$BIN" smoke --url "http://127.0.0.1:$port" --protocol letter-logit --question-file "$f" --json --timeout 2s 2>&1) && rc=0 || rc=$?
kill $lp 2>/dev/null; rm -f "$f" "$f.port"
if grep -q 'Unknown model' <<<"$out"; then echo "FAIL: driver refused validator body: $out"; fail=1
else echo "PASS: driver accepted the validator body (rc=$rc, not an Unknown-model refusal)"; fi
if [ $fail = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi; exit $fail
