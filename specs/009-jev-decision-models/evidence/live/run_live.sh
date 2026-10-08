#!/usr/bin/env bash
# run_live.sh <profile> - the live matrix for ONE native decision profile, through the real stack:
#   bin/llmctl start <profile>  (scheduler admission + systemd user unit)  ->  HTTPS gateway (llmctl decide serve)
#   -> golden questions + probes (scripts/golden/run_golden.py) -> determinism -> memory -> latency -> edge cases.
# Output: specs/009-jev-decision-models/evidence/live/<profile>/ sealed with MANIFEST.json + SHA256SUMS.
#
# Needs a sourced $LIVE_ENV (exports LLMCTL_HOME / LLMCTL_ENV_FILE / LLMCTL_DECIDE_BIN / LLMCTL_DECIDE_NATIVE /
# LLMCTL_DECIDE_BIND, see NATIVE-REPORT.md) and LIVE_KEYFILE (a 0600 file holding ONLY the access key).
# The access key is never printed, passed as an argument or written anywhere by this script.
# One model at a time: the engine is stopped by `llmctl stop` (never a signal) before the script ends.
set -uo pipefail
P="${1:?usage: run_live.sh <profile>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${ROOT}" || exit 1
: "${LIVE_ENV:?}" "${LIVE_KEYFILE:?}"
# shellcheck source=/dev/null
. "${LIVE_ENV}"
OUT="${ROOT}/specs/009-jev-decision-models/evidence/live/${P}"
mkdir -p "${OUT}"
GW="https://127.0.0.1:8095"; CA="${LLMCTL_HOME}/cert/ca/ca.crt"
PORT="$(python3 -c 'import json,sys;print(json.load(open("models/catalog.json"))["profiles"][sys.argv[1]]["port"])' "${P}")"
IKEY="${LLMCTL_STATE_DIR:-$HOME/.local/state/llmctl}/keys/llama-${P}.key"
UNIT="llmctl-llama@${P}.service"
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

{
  echo "profile=${P} port=${PORT} date=$(date -u +%FT%TZ) host=$(hostname)"
  echo "engine: $(env -u LD_LIBRARY_PATH submodules/llama.cpp/build/bin/llama-server --version 2>&1 | head -1)"
  echo "llama.cpp submodule: $(git -C submodules/llama.cpp rev-parse HEAD) $(git -C submodules/llama.cpp describe --tags 2>/dev/null)"
  echo "model: $(python3 -c 'import json,sys;p=json.load(open("models/catalog.json"))["profiles"][sys.argv[1]];print(p["hf_repo"],p["hf_revision"],[(f["name"],f["size"],f["sha256"]) for f in p["files"]])' "${P}")"
  echo "--- memory before"; free -m | sed -n 1,3p; nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
  echo "--- plan row"; bin/llmctl plan --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps({"budgets":d["budgets"],"profile":d["profiles"][sys.argv[1]]},indent=1))' "${P}"
} > "${OUT}/context.txt" 2>&1

# ---- 1. verified download (idempotent: re-verifies sha256 + size and runs the native decision smoke) ----------------
say "verify ${P}"
bin/llmctl models verify "${P}" > "${OUT}/verify.txt" 2>&1; echo "rc=$?" >> "${OUT}/verify.txt"

# ---- 2. start through the scheduler (admission with numbers) ------------------------------------------------------------
say "start ${P}"
bin/llmctl start "${P}" > "${OUT}/start.txt" 2>&1; rc=$?
echo "rc=${rc}" >> "${OUT}/start.txt"
if ! systemctl --user is-active --quiet "${UNIT}"; then
  say "NOT STARTED (scheduler refusal or failure) - recorded in start.txt"
  echo "NOT-STARTED" > "${OUT}/RESULT.txt"
  python3 tests/evidence/manifest.py build "${OUT}" >/dev/null
  exit 3
fi
PID="$(systemctl --user show "${UNIT}" -p MainPID --value)"
tr '\0' ' ' < "/proc/${PID}/cmdline" | sed 's#--api-key-file [^ ]*#--api-key-file <path>#' > "${OUT}/engine-cmdline.txt"
for _ in $(seq 1 120); do curl -fsS -m 2 -H "Authorization: Bearer $(cat "${IKEY}")" "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && break; sleep 1; done
sleep 2
grep -o '[^ ]*libggml[^ ]*\.so[^ ]*' "/proc/${PID}/maps" | sort -u > "${OUT}/engine-libs.txt"
mem() { # <label>
  { echo "## $1 $(date -u +%T)"; grep -E 'VmRSS|VmHWM|VmSwap' "/proc/${PID}/status"
    systemctl --user show "${UNIT}" -p MemoryCurrent -p MemoryPeak -p MemoryMax | tr '\n' ' '; echo
    echo "vram(MiB) pid=${PID}: $(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits | awk -F', *' -v p="${PID}" '$1==p{print $2}')"
    nvidia-smi --query-gpu=memory.used --format=csv,noheader; } >> "${OUT}/memory.txt"
}
: > "${OUT}/memory.txt"; mem "after-start-idle"

# gateway must see the profile ready
for _ in $(seq 1 60); do bin/llmctl decide models 2>/dev/null | awk -v p="${P}" '$1==p && $2=="ready"{f=1} END{exit !f}' && break; sleep 1; done
bin/llmctl decide models > "${OUT}/gateway-models.txt" 2>&1

# ---- 3. engine smoke (direct) + CLI ask through the gateway ----------------------------------------------------------------
say "smoke + ask"
{ bin/llmctl decide smoke --url "http://127.0.0.1:${PORT}" --protocol systemone-native --key-file "${IKEY}" --options 2 --json; echo "rc=$?"
  bin/llmctl decide smoke --url "http://127.0.0.1:${PORT}" --protocol systemone-native --key-file "${IKEY}" --options 4 --json; echo "rc=$?"; } > "${OUT}/smoke.txt" 2>&1
bin/llmctl decide ask --profile "${P}" --type choice --state "Customer: I was charged twice for my order and nobody has replied." \
  --instructions "Which team should handle this?" --criteria '{"billing":"payments and invoices","shipping":"delivery of parcels","technical":"software bugs"}' --json \
  > "${OUT}/cli-ask.txt" 2>&1; echo "rc=$?" >> "${OUT}/cli-ask.txt"

# ---- 4. golden set + probes through the HTTPS gateway ---------------------------------------------------------------------
say "golden questions"
python3 scripts/golden/run_golden.py --base-url "${GW}" --cacert "${CA}" --key-file "${LIVE_KEYFILE}" --profile "${P}" \
  --permute-groups --run-id "${P}-golden" --out-dir "${OUT}/golden" > "${OUT}/golden.log" 2>&1; echo "rc=$?" >> "${OUT}/golden.log"
mem "after-golden-questions"
say "golden probes"
python3 scripts/golden/run_golden.py --base-url "${GW}" --cacert "${CA}" --key-file "${LIVE_KEYFILE}" --profile "${P}" \
  --set probes --run-id "${P}-probes" --out-dir "${OUT}/probes" > "${OUT}/probes.log" 2>&1; echo "rc=$?" >> "${OUT}/probes.log"
[[ -f "${OUT}/golden/results.json" ]] && python3 scripts/golden/stats.py "${OUT}/golden/results.json" > "${OUT}/golden-stats.txt" 2>&1
[[ -f "${OUT}/probes/results.json" ]] && python3 scripts/golden/stats.py "${OUT}/probes/results.json" > "${OUT}/probes-stats.txt" 2>&1
mem "after-probes"

# ---- 5. determinism (8 identical repeats, byte-identical) + latency + edge cases ------------------------------------------
say "determinism + latency + edges"
python3 - "${GW}" "${CA}" "${LIVE_KEYFILE}" "${P}" "http://127.0.0.1:${PORT}" "${IKEY}" "${OUT}" <<'PYEOF'
import hashlib, json, ssl, statistics, sys, time, urllib.error, urllib.request
gw, ca, keyf, prof, eng, ikeyf, out = sys.argv[1:8]
key = open(keyf).read().strip(); ikey = open(ikeyf).read().strip()
ctx = ssl.create_default_context(cafile=ca)
def post(url, body, k, tls=True, n=1):
    h = {"Content-Type": "application/json", "Authorization": "Bearer " + k} if k else {"Content-Type": "application/json"}
    r = urllib.request.Request(url, data=body, headers=h, method="POST")
    t = time.perf_counter()
    try:
        with urllib.request.urlopen(r, timeout=120, context=ctx if tls else None) as f:
            return f.status, f.read(), (time.perf_counter() - t) * 1000
    except urllib.error.HTTPError as e:
        return e.code, e.read(), (time.perf_counter() - t) * 1000
req = {"model": prof, "state": "Customer message: I was charged twice for my order last week and nobody has replied.",
       "questions": {"route": {"type": "choice", "instructions": "Which team should handle this?", "criteria": {"billing": "payments, invoices, refunds", "shipping": "parcel delivery", "technical": "software defects"}},
                     "angry": {"type": "noul", "instructions": "Is the customer angry?"},
                     "urgency": {"type": "score", "instructions": "How urgent is this?", "criteria": ["can wait", "this week", "today", "right now"]}}}
body = json.dumps(req).encode()
res = {"profile": prof}
runs = [post(gw + "/v1/systemone", body, key) for _ in range(8)]
res["gateway_status"] = [r[0] for r in runs]
res["gateway_bodies_sha256"] = sorted({hashlib.sha256(r[1]).hexdigest() for r in runs})
res["gateway_byte_identical_8of8"] = len(res["gateway_bodies_sha256"]) == 1 and all(r[0] == 200 for r in runs)
res["gateway_latency_ms"] = [round(r[2], 1) for r in runs]
res["gateway_sample_body"] = runs[0][1].decode()[:1500]
ebody = json.dumps({"state": req["state"], "questions": req["questions"]}).encode()
eruns = [post(eng + "/v1/systemone", ebody, ikey, tls=False) for _ in range(8)]
res["engine_status"] = [r[0] for r in eruns]
res["engine_bodies_sha256"] = sorted({hashlib.sha256(r[1]).hexdigest() for r in eruns})
res["engine_byte_identical_8of8"] = len(res["engine_bodies_sha256"]) == 1 and all(r[0] == 200 for r in eruns)
res["engine_model_field_is_a_local_path"] = json.loads(eruns[0][1]).get("model") if eruns[0][0] == 200 else None
res["gateway_model_field"] = json.loads(runs[0][1]).get("model") if runs[0][0] == 200 else None
# edge cases through the gateway
def edge(name, d, k=key):
    s, b, ms = post(gw + "/v1/systemone", json.dumps(d).encode(), k)
    res.setdefault("edges", {})[name] = {"status": s, "ms": round(ms, 1), "body": b.decode()[:300]}
edge("single_option_choice", {"model": prof, "state": "s", "questions": {"c": {"type": "choice", "instructions": "Pick", "criteria": {"only": "x"}}}})
edge("no_key", req, k="")
edge("wrong_key", req, k="not-the-key")
edge("unknown_model", dict(req, model="no-such-model"))
big = "The quarterly report shows revenue growth in every region except the north. " * 140   # 10,920 chars
import random
rnd = random.Random(7); dense = "".join(rnd.choice("0123456789abcdef") for _ in range(7500))   # high token density: ~1 token per 1-2 chars
edge("state_6500_chars", dict(req, state=big[:6500]))
edge("state_8000_chars", dict(req, state=big[:8000]))
edge("state_9000_chars_over_gateway_cap", dict(req, state=big[:9000]))
# expected: valid = 200 within the deadline OR 502 + x-llmctl-decide-reason: deadline_exceeded (slow prefill of an input that fits the ctx);
# 422 only where the estimate exceeds the profile budget (small-ctx profiles); never a crash
edge("state_dense_7500_hex_chars_slow_prefill", dict(req, state=dense))
edge("twenty_options", {"model": prof, "state": "Where does this belong?", "questions": {"c": {"type": "choice", "instructions": "Pick the department", "criteria": {("opt%02d" % i): ("department number %d" % i) for i in range(20)}}}})
res["note"] = "state text above is synthetic filler; no golden-set text; keys never recorded"
open(out + "/determinism-edges.json", "w").write(json.dumps(res, indent=1))
lat = sorted(res["gateway_latency_ms"]);
print("det gateway:", res["gateway_byte_identical_8of8"], "det engine:", res["engine_byte_identical_8of8"], "edges:", {k: v["status"] for k, v in res["edges"].items()})
PYEOF
mem "after-edges"

# ---- 6. latency (p50/p95) from the golden records ------------------------------------------------------------------------------
python3 - "${OUT}" <<'PYEOF'
import json, os, sys
out = sys.argv[1]; lat = {}
for run in ("golden", "probes"):
    p = os.path.join(out, run, "results.json")
    if not os.path.exists(p): continue
    xs = sorted(r["latency_ms"] for r in json.load(open(p))["records"] if r.get("status") == 200 and r.get("latency_ms") is not None)
    if not xs: continue
    q = lambda f: xs[min(len(xs) - 1, int(round(f * (len(xs) - 1))))]
    lat[run] = {"n": len(xs), "p50_ms": q(0.5), "p95_ms": q(0.95), "max_ms": xs[-1], "min_ms": xs[0]}
json.dump(lat, open(os.path.join(out, "latency.json"), "w"), indent=1); print("latency:", lat)
PYEOF

# ---- 7. gateway/engine logs (no state text, no keys by construction) + stop the engine + seal ---------------------------
journalctl --user -u "${UNIT}" --no-pager -n 60 2>/dev/null | sed -E 's#(Bearer )[A-Za-z0-9._~+/=-]+#\1<redacted>#g' > "${OUT}/engine-journal-tail.txt"
say "stop ${P}"
bin/llmctl stop "${P}" > "${OUT}/stop.txt" 2>&1; echo "rc=$?" >> "${OUT}/stop.txt"
systemctl --user is-active "${UNIT}" > "${OUT}/after-stop-active.txt" 2>&1 || true
echo "COMPLETED" > "${OUT}/RESULT.txt"
python3 tests/evidence/manifest.py build "${OUT}" >/dev/null && python3 tests/evidence/manifest.py verify "${OUT}" | tail -1
