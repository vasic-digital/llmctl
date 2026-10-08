#!/usr/bin/env python3
"""live_checks.py - encoder-specific live checks against the REAL decide-nli runtime + gateway.
usage: live_checks.py <gw> <ca> <access-keyfile> <profile> <engine-url> <engine-keyfile> <outdir> <spm.model>
Keys are read from files and never printed or written. State texts are synthetic filler."""
import hashlib, itertools, json, ssl, sys, time, urllib.error, urllib.request

gw, ca, keyf, prof, eng, ikeyf, out, spm_path = sys.argv[1:9]
key, ikey = open(keyf).read().strip(), open(ikeyf).read().strip()
ctx = ssl.create_default_context(cafile=ca)
res = {"profile": prof, "note": "synthetic state text; no golden-set text; keys never recorded"}


def post(url, body, k, tls=True, extra=None):
    h = {"Content-Type": "application/json"}
    if k:
        h["Authorization"] = "Bearer " + k
    r = urllib.request.Request(url, data=body if isinstance(body, bytes) else json.dumps(body).encode(), headers=h, method="POST")
    t = time.perf_counter()
    try:
        with urllib.request.urlopen(r, timeout=300, context=ctx if tls else None) as f:
            return f.status, f.read(), (time.perf_counter() - t) * 1000, dict(f.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), (time.perf_counter() - t) * 1000, dict(e.headers)


def score(pairs, k=ikey):
    return post(eng + "/v1/score", {"pairs": [{"premise": p, "hypothesis": h} for p, h in pairs]}, k, tls=False)


STATE = "Customer message: I was charged twice for my order last week and nobody has replied."
# --- 1. determinism: 8 identical repeats, byte-identical, gateway + engine -----------------------------------------------
req = {"model": prof, "state": STATE, "questions": {
    "route": {"type": "choice", "instructions": "Which team should handle this?", "criteria": {"billing": "payments, invoices, refunds", "shipping": "parcel delivery", "technical": "software defects"}},
    "angry": {"type": "noul", "instructions": "Is the customer angry?"},
    "urgency": {"type": "score", "instructions": "How urgent is this?", "criteria": ["can wait", "this week", "today", "right now"]}}}
runs = [post(gw + "/v1/systemone", req, key) for _ in range(8)]
res["gateway_status"] = [r[0] for r in runs]
res["gateway_bodies_sha256"] = sorted({hashlib.sha256(r[1]).hexdigest() for r in runs})
res["gateway_byte_identical_8of8"] = len(res["gateway_bodies_sha256"]) == 1 and all(r[0] == 200 for r in runs)
res["gateway_latency_ms"] = [round(r[2], 1) for r in runs]
res["gateway_sample_body"] = runs[0][1].decode()[:2500]
pairs = [(STATE, "The customer is billed incorrectly."), (STATE, "The customer wants a refund."), (STATE, "The parcel was delivered.")]
eruns = [score(pairs) for _ in range(8)]
res["engine_status"] = [r[0] for r in eruns]
res["engine_bodies_sha256"] = sorted({hashlib.sha256(r[1]).hexdigest() for r in eruns})
res["engine_byte_identical_8of8"] = len(res["engine_bodies_sha256"]) == 1 and all(r[0] == 200 for r in eruns)
res["engine_latency_ms_3pairs"] = [round(r[2], 1) for r in eruns]
base = json.loads(eruns[0][1])
res["engine_sample"] = {k: base[k] for k in ("labels", "label_source", "truncated", "model", "max_tokens")}
res["engine_sample"]["scores"] = base["scores"]

# --- 2. batch-composition invariance (encoder analogue of N-11: same pair alone vs inside a batch / other positions) -------
fillers = [("Server %d reported a disk warning overnight." % i, "Option %d: replace the disk." % i) for i in range(19)]
x = (STATE, "The customer was billed twice.")
alone = json.loads(score([x])[1])["scores"][0]
diffs = {}
for name, batch, idx in (("first_in_20", [x] + fillers, 0), ("last_in_20", fillers + [x], 19), ("middle_in_3", [fillers[0], x, fillers[1]], 1)):
    s = json.loads(score(batch)[1])["scores"][idx]
    diffs[name] = {"max_abs_diff": max(abs(a - b) for a, b in zip(alone, s)), "byte_identical": alone == s, "argmax_same": alone.index(max(alone)) == s.index(max(s))}
res["batch_composition"] = {"alone": alone, "variants": diffs, "interpretation": "padding to the longest row can change the last decimals; argmax must not change"}

# --- 3. D-01 over the real HTTP path: long state, hypothesis must survive, premise-only truncation reported -------------------
filler = ("Observation %d: the monitoring agent recorded a transient latency spike on node %d while the queue depth stayed within its configured limits and no operator action was pending. ")
long_state = "The payment service is down and customers cannot pay. " + "".join(filler % (i, i % 7) for i in range(20))
hyp = "The payment service is down."
s_long = json.loads(score([(long_state, hyp)])[1])
s_short = json.loads(score([("The payment service is down and customers cannot pay.", hyp)])[1])
s_neg = json.loads(score([(long_state, "The payment service is working normally.")])[1])
labels = s_long["labels"]
res["d01_http"] = {"labels": labels, "long_state_truncated": s_long["truncated"], "long_scores": s_long["scores"][0], "short_state_scores": s_short["scores"][0],
                   "long_state_contradicting_hypothesis_scores": s_neg["scores"][0], "label_source": s_long["label_source"]}
ent = labels.index("entailment") if "entailment" in labels else None
if ent is not None:
    res["d01_http"]["entailment_long_vs_contradicting"] = [s_long["scores"][0][ent], s_neg["scores"][0][ent]]
    res["d01_http"]["hypothesis_visible_to_model"] = s_long["scores"][0][ent] > s_neg["scores"][0][ent]
# gateway path, long state: header must announce truncation
lreq = {"model": prof, "state": long_state[:7000], "questions": {"q": {"type": "noul", "instructions": hyp}}}
st, body, ms, hdr = post(gw + "/v1/systemone", lreq, key)
res["d01_gateway_long_state"] = {"status": st, "x-llmctl-decide-truncated": hdr.get("x-llmctl-decide-truncated") or hdr.get("X-Llmctl-Decide-Truncated"), "body": body.decode()[:600]}
# hypothesis alone too long -> typed 422 from the runtime
st2, b2, _, _ = score([("short premise", "word " * 700)])
res["hypothesis_too_long_runtime"] = {"status": st2, "body": b2.decode()[:300]}

# --- 4. edge cases ------------------------------------------------------------------------------------------------------------
def edge(name, st_body):
    s, b, ms, _ = st_body
    res.setdefault("edges", {})[name] = {"status": s, "ms": round(ms, 1), "body": b.decode()[:300]}
edge("runtime_no_key", post(eng + "/v1/score", {"pairs": [{"premise": "a", "hypothesis": "b"}]}, "", tls=False))
edge("runtime_wrong_key", post(eng + "/v1/score", {"pairs": [{"premise": "a", "hypothesis": "b"}]}, "not-the-key", tls=False))
edge("runtime_empty_pairs", post(eng + "/v1/score", {"pairs": []}, ikey, tls=False))
edge("gateway_no_key", post(gw + "/v1/systemone", req, ""))
edge("gateway_unknown_model", post(gw + "/v1/systemone", dict(req, model="no-such-model"), key))
edge("gateway_twenty_options", post(gw + "/v1/systemone", {"model": prof, "state": "Where does this belong?", "questions": {"c": {"type": "choice", "instructions": "Pick the department", "criteria": {("opt%02d" % i): ("department number %d" % i) for i in range(20)}}}}, key))
edge("gateway_twentyone_options", post(gw + "/v1/systemone", {"model": prof, "state": "Where does this belong?", "questions": {"c": {"type": "choice", "instructions": "Pick the department", "criteria": {("opt%02d" % i): ("department number %d" % i) for i in range(21)}}}}, key))
open(out + "/live_checks.json", "w").write(json.dumps(res, indent=1))
print("det gateway:", res["gateway_byte_identical_8of8"], "det engine:", res["engine_byte_identical_8of8"])
print("batch argmax same:", {k: v["argmax_same"] for k, v in diffs.items()}, "max diff:", {k: v["max_abs_diff"] for k, v in diffs.items()})
print("d01 http truncated:", s_long["truncated"], "hypothesis_visible:", res["d01_http"].get("hypothesis_visible_to_model"))
print("edges:", {k: v["status"] for k, v in res["edges"].items()})
