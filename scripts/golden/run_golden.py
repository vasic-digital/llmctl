#!/usr/bin/env python3
"""Run the golden question set through POST /v1/systemone and measure it (stdlib only).

Spec 009 SC-003 / FR-080 / plan P4. Every item is sent as its own request carrying ONE
question named "q"; the answer is checked for a well-formed typed shape, compared with the
labelled expectation, and the results are passed to stats.py (Wilson interval, baselines,
per-class accuracy, option-order flip rate, accuracy-vs-option-count, gated calibration).

Safety rules enforced here:
  * the access key is read from an environment variable NAME (default LLMCTL_API_KEY) or a
    key file; it is never accepted as a literal argument, never printed, never written;
  * logs and stdout carry item ids, status codes and latency only - never state text;
  * raw responses are saved with their request ids; a response containing the key is redacted;
  * evidence is written with tests/evidence/writer.py (hash chain) and sealed with
    tests/evidence/manifest.py (MANIFEST.json + SHA256SUMS).

Typical use (real model):
  LLMCTL_API_KEY=... python3 scripts/golden/run_golden.py \
      --base-url https://127.0.0.1:8095 --cacert ~/.config/llmctl/ca.pem --profile llmctl-default \
      --permute-groups
Smoke run: add --limit 6 --types noul,choice.   Shape check without network: --dry-run.
"""
import argparse
import hashlib
import json
import math
import os
import random
import ssl
import sys
import time
import urllib.error
import urllib.request

# the repo-internal imports below must not leave __pycache__ in the work tree when run without -B (2026-10-09)
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)
try:
    from scripts.golden import stats
except ImportError:  # run as a plain script from another cwd
    sys.path.insert(0, HERE)
    import stats
from tests.evidence import manifest, writer

FIXTURES = os.path.join(ROOT, "tests", "fixtures", "golden")
RETRY_STATUSES = (429, 502, 503, 529)
SUM_TOL = 1e-4          # contract says 1e-6; JSON rounding of several terms needs slack
MAX_RETRY_AFTER = 30.0
QNAME = "q"


# ---------------------------------------------------------------- items and requests
def load_items(sets=("questions",), types=None, limit=None, fixtures=FIXTURES):
    items = []
    for name in sets:
        with open(os.path.join(fixtures, name + ".jsonl"), encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    it = json.loads(line)
                    it["_set"] = name
                    it.setdefault("class", it.get("probe_class"))
                    items.append(it)
    if types:
        items = [i for i in items if i["type"] in types]
    if limit is not None:
        items = items[:limit]
    return items


def permuted_keys(item, seed):
    """Deterministic option order for the order-flip probe (choice items only).

    The order always differs from the original, and when the item has a labelled answer
    that answer always moves to a different position, so a position-biased model cannot
    be right in both orders by accident of layout."""
    orig = list(item["criteria"].keys())
    keys = list(orig)
    h = hashlib.sha256(("%s:%s" % (seed, item["id"])).encode()).digest()
    rng = random.Random(int.from_bytes(h[:8], "big"))
    rng.shuffle(keys)
    exp = item.get("expected")
    same_pos = exp in orig and keys.index(exp) == orig.index(exp)
    if keys == orig or same_pos:
        keys = keys[1:] + keys[:1]      # rotation by one moves every option
    return keys


def build_question(item, order=None):
    q = {"type": item["type"], "instructions": item["instructions"]}
    if item["type"] == "choice":
        crit = item["criteria"]
        q["criteria"] = {k: crit[k] for k in (order or list(crit.keys()))}
    else:
        q["criteria"] = item["criteria"]
    return q


def build_request(item, profile, order=None):
    return {"model": profile, "state": item["state"], "questions": {QNAME: build_question(item, order)}}


# ---------------------------------------------------------------- answer checking
def _prob(x):
    return (not isinstance(x, bool) and isinstance(x, (int, float)) and not math.isnan(x) and 0.0 <= x <= 1.0)


def answer_confidence(body):
    """-> (confidence, confidence_raw, calibration) of the answer, each None when absent or malformed.

    `confidence` is what the gateway SERVED (the calibrated probability when a calibration profile was
    applied); `confidence_raw` is the shaped value before calibration; `calibration` is the gateway's
    {method,n,profile_id} object (or "mixed"). They are recorded for the record only: calibration and
    ECE are computed from p_pred, the winner's own raw probability, never from the served confidence,
    so a calibrated gateway cannot flatter its own evaluation. Never raises on hostile input."""
    try:
        ans = body["answers"][QNAME]
        conf = ans.get("confidence")
        raw = ans.get("confidence_raw")
        cal = ans.get("calibration")
    except (KeyError, TypeError, AttributeError):
        return (None, None, None)
    if not (isinstance(cal, dict) or cal == "mixed"):
        cal = None
    return (conf if _prob(conf) else None, raw if _prob(raw) else None, cal)


def parse_answer(item, body):
    """-> (well_formed, predicted, p_pred, reason). Never raises on hostile input."""
    try:
        ans = body["answers"][QNAME]
        if not isinstance(ans, dict) or ans.get("type") != item["type"]:
            return (False, None, None, "answer type mismatch")
        t = item["type"]
        if t == "noul":
            v = ans["noul"]
            if isinstance(v, bool) or not isinstance(v, (int, float)) or not (0.0 <= v <= 1.0) or math.isnan(v):
                return (False, None, None, "noul not a probability")
            return (True, v >= 0.5, max(v, 1.0 - v), None)
        probs = ans["probabilities"]
        if not isinstance(probs, dict) or not probs:
            return (False, None, None, "probabilities missing")
        vals = list(probs.values())
        if any(isinstance(x, bool) or not isinstance(x, (int, float)) or x < 0 or x > 1 for x in vals):
            return (False, None, None, "probability out of range")
        if abs(sum(vals) - 1.0) > SUM_TOL:
            return (False, None, None, "probabilities do not sum to 1")
        conf = ans.get("confidence")
        if isinstance(conf, bool) or not isinstance(conf, (int, float)) or not (0.0 <= conf <= 1.0):
            return (False, None, None, "confidence missing or out of range")
        if t == "choice":
            c = ans["choice"]
            if c not in item["criteria"] or c not in probs:
                return (False, None, None, "choice is not one of the options")
            if set(probs) != set(item["criteria"]):
                return (False, None, None, "probabilities do not cover the options")
            return (True, c, float(probs[c]), None)
        s = ans["score"]
        n = len(item["criteria"])
        if isinstance(s, bool) or not isinstance(s, (int, float)) or not (0.0 <= s <= n - 1) or math.isnan(s):
            return (False, None, None, "score outside 0..n-1")
        if not isinstance(ans.get("legend"), dict):
            return (False, None, None, "legend missing")
        lvl = int(math.floor(s + 0.5))
        return (True, lvl, float(probs.get(str(lvl), 0.0)), None)
    except (KeyError, TypeError, ValueError):
        return (False, None, None, "malformed response")


# ---------------------------------------------------------------- transport
def make_context(cacert):
    ctx = ssl.create_default_context(cafile=cacert) if cacert else ssl.create_default_context()
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


def post_json(url, ctx, key, payload, timeout):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method="POST", headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + key})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def ask(url, ctx, key, payload, timeout, retries, retry_sleep):
    """POST with bounded retries. -> (status|None, headers, body bytes, attempts, error|None)"""
    attempts = 0
    last = (None, {}, b"", None)
    while attempts <= retries:
        attempts += 1
        try:
            status, headers, body = post_json(url, ctx, key, payload, timeout)
            last = (status, headers, body, None)
            if status not in RETRY_STATUSES:
                break
            if status == 502 and {k.lower(): v for k, v in headers.items()}.get(
                    "x-llmctl-decide-reason") == "deadline_exceeded":
                # the gateway's own end-to-end budget ended a slow-but-alive engine: a retry cancels the
                # engine task and redoes the whole prefill, so it is recorded, never retried
                break
            err = "http %d" % status
            wait = retry_sleep * attempts
            ra = {k.lower(): v for k, v in headers.items()}.get("retry-after")
            try:
                if ra is not None:
                    wait = max(wait, min(float(ra), MAX_RETRY_AFTER))
            except ValueError:
                pass
        except (urllib.error.URLError, OSError, ssl.SSLError) as e:
            last = (None, {}, b"", "%s" % type(e).__name__)
            err = last[3]
            wait = retry_sleep * attempts
        if attempts <= retries and wait > 0:
            time.sleep(wait)
    return last[0], last[1], last[2], attempts, last[3]


def _redact(blob, key):
    if key and key.encode() in blob:
        return blob.replace(key.encode(), b"[REDACTED]")
    return blob


def classify_refusal(status, body, item, max_options):
    """G-160. -> "max_options" when the gateway refused the item because it has more options than the
    profile's catalog max_options, else None.

    The gateway signals that refusal as HTTP 422 with error_type "validation_failed" (internal/contract/
    request.go: len(options) > lim.MaxOptions -> errInvalid). That code is shared with every other
    schema violation, so the body alone is not enough: the refusal is only attributed to the limit when
    the caller states the profile's max_options AND the item is a choice item with more options than it.
    A 422 "readout_failed" (the model gave no usable answer) is a model error and never a refusal."""
    if status != 422 or not max_options or item.get("type") != "choice":
        return None
    try:
        if json.loads(body).get("error_type") != "validation_failed":
            return None
        n = len(item["criteria"])
    except (ValueError, AttributeError, KeyError, TypeError):
        return None
    return "max_options" if n > max_options else None


def catalog_max_options(profile, path=None):
    """decision.max_options of `profile` in models/catalog.json (resolved from this script's location,
    not the cwd), or None when the catalog/profile/field is absent or unreadable."""
    path = path or os.path.join(ROOT, "models", "catalog.json")
    try:
        with open(path) as f:
            v = json.load(f)["profiles"][profile]["decision"]["max_options"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return v if isinstance(v, int) and not isinstance(v, bool) else None


# ---------------------------------------------------------------- run
def run_items(items, base_url, ctx, key, profile, permute, seed, timeout, retries, retry_sleep,
              raw_path=None, out=None, max_options=None):
    out = out or sys.stdout
    url = base_url.rstrip("/") + "/v1/systemone"
    records = []
    jobs = []
    for it in items:
        jobs.append((it, "orig", None))
        if permute and it["type"] == "choice" and it.get("perm_group"):
            jobs.append((it, "perm", permuted_keys(it, seed)))
    rawf = open(raw_path, "ab") if raw_path else None
    try:
        for it, variant, order in jobs:
            rid = it["id"] if variant == "orig" else it["id"] + "~p"
            t0 = time.monotonic()
            status, headers, body, attempts, err = ask(
                url, ctx, key, build_request(it, profile, order), timeout, retries, retry_sleep)
            ms = int((time.monotonic() - t0) * 1000)
            request_id = {k.lower(): v for k, v in headers.items()}.get("x-llmctl-request-id")
            # the gateway's additive 502 reason (deadline_exceeded | engine_error); None when absent
            gw_reason = {k.lower(): v for k, v in headers.items()}.get("x-llmctl-decide-reason") if status == 502 else None
            wf, pred, p_pred, reason = (False, None, None, err or ("http %s" % status))
            parsed = None
            conf, conf_raw, cal = None, None, None
            refusal = classify_refusal(status, body, it, max_options)
            if refusal:
                reason = "refused: " + refusal
            if status == 200:
                try:
                    parsed = json.loads(body)
                    wf, pred, p_pred, reason = parse_answer(it, parsed)
                    conf, conf_raw, cal = answer_confidence(parsed)
                except ValueError:
                    reason = "response is not JSON"
            rec = {"id": rid, "item": it["id"], "set": it["_set"], "type": it["type"], "family": it.get("class"),
                   "difficulty": it.get("difficulty"), "expected": it.get("expected"), "predicted": pred,
                   "well_formed": wf, "refused": bool(refusal), "refusal_reason": refusal, "variant": variant, "perm_group": it.get("perm_group"),
                   "option_count": it.get("option_count"), "scale": it.get("scale"), "p_pred": p_pred,
                   "confidence": conf, "confidence_raw": conf_raw, "calibration": cal,
                   "status": status, "latency_ms": ms, "request_id": request_id, "attempts": attempts,
                   "reason": gw_reason, "error": reason, "pair_id": it.get("pair_id"), "pair_variant": it.get("pair_variant"),
                   "option_order": order}
            records.append(rec)
            if rawf:
                line = json.dumps({"id": rid, "status": status, "request_id": request_id, "attempts": attempts,
                                   "latency_ms": ms, "error": err, "reason": gw_reason,
                                   "body": body.decode("utf-8", "replace")[:20000]}).encode()
                rawf.write(_redact(line, key) + b"\n")
            print("%s %s %sms%s" % (rid, status if status is not None else "ERR", ms,
                                    "" if wf else (" REFUSED(%s)" % refusal if refusal else " MALFORMED(" + str(reason) + ")")), file=out)
    finally:
        if rawf:
            rawf.close()
    return records


def read_key(env_name, key_file):
    if key_file:
        with open(key_file) as f:
            return f.read().strip()
    return os.environ.get(env_name, "").strip()


def evidence(out_dir, run_id, key, key_env, rep, cls, vantage, argv_safe, wall_ms, max_options=None):
    w = writer.EvidenceWriter(out_dir, run_id, secrets=[key])
    summary = json.dumps({"report": rep}, sort_keys=True, default=str).encode()
    n_orig = rep["well_formed"]["n"]
    ok = rep["well_formed"]["ok"]
    # Limit refusals (G-160) are excluded from n; the pass row says so, so a reader of the evidence
    # alone can see the denominator shrank and why.
    nref = rep.get("refused", {}).get("n", 0)
    pass_reason = ("%d items refused by max_options=%s (excluded from the well-formed denominator)" % (nref, max_options)
                   if nref else None)
    common = dict(command=argv_safe, cwd=os.getcwd(), env_names=[key_env], exit_code=0,
                  stdout=summary, stderr=b"", duration_ms=wall_ms, cls=cls, vantage=vantage, client="python-urllib")
    w.append(requirement=["SC-003"], result="pass" if (n_orig and ok == n_orig) else "fail",
             reason=pass_reason if (n_orig and ok == n_orig) else "%d of %d original items returned a well-formed typed answer" % (ok, n_orig), **common)
    failing = [t for t, r in rep["by_type"].items() if not r["lower_bound_exceeds_baseline"]]
    w.append(requirement=["SC-003"], result="fail" if failing or not rep["by_type"] else "pass",
             reason=("Wilson lower bound does not exceed the baseline for: %s (profile must be labelled experimental)" % ", ".join(failing))
             if failing else ("no scored items" if not rep["by_type"] else None), **common)
    fl = rep["flip"]
    if fl["flip_rate"] is None:
        c2 = dict(common, cls="not-exercised")
        w.append(requirement=["FR-080"], result="not-exercised",
                 reason="no permutation groups answered (run with --permute-groups and choice items)", **c2)
    else:
        w.append(requirement=["FR-080"], result="pass", reason=None, **common)
    return w


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run the golden question set against /v1/systemone.")
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--cacert", help="PEM file trusted for the gateway certificate")
    ap.add_argument("--key-env", default="LLMCTL_API_KEY", help="NAME of the environment variable holding the key")
    ap.add_argument("--key-file", help="file containing the key (mode 0600 recommended)")
    ap.add_argument("--profile", required=True, help="value of the request 'model' field")
    ap.add_argument("--set", dest="sets", default="questions", help="questions, probes or questions,probes")
    ap.add_argument("--types", help="comma list of noul,choice,score")
    ap.add_argument("--limit", type=int)
    ap.add_argument("--permute-groups", action="store_true", help="re-ask each choice item with permuted options")
    ap.add_argument("--seed", default="20261007")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--max-options", type=int, help="the profile's catalog max_options; a 422 validation_failed on a "
                    "choice item with more options is then recorded as a limit refusal, not a malformed answer")
    ap.add_argument("--retries", type=int, default=2, help="bounded retries on 429/502/503/529/transport errors")
    ap.add_argument("--retry-sleep", type=float, default=1.0)
    ap.add_argument("--run-id", default=time.strftime("golden-%Y%m%dT%H%M%SZ", time.gmtime()))
    ap.add_argument("--out-dir")
    ap.add_argument("--evidence-class", default="real-model", choices=["real-model", "real-component", "stand-in"])
    ap.add_argument("--vantage", default="host", choices=list(writer.VANTAGES))
    ap.add_argument("--dry-run", action="store_true", help="print request shapes (no state text) and exit")
    a = ap.parse_args(argv)

    sets = [s for s in a.sets.split(",") if s]
    if any(s not in ("questions", "probes") for s in sets):
        print("error: --set takes questions and/or probes", file=sys.stderr)
        return 2
    types = set(a.types.split(",")) if a.types else None
    if types and not types <= {"noul", "choice", "score"}:
        print("error: --types takes noul,choice,score", file=sys.stderr)
        return 2
    items = load_items(sets, types, a.limit)
    if a.dry_run:
        for it in items[:5]:
            req = build_request(it, a.profile)
            print(it["id"], json.dumps({"model": req["model"], "question_type": it["type"],
                                         "criteria_size": len(it["criteria"]), "state_chars": len(it["state"])}))
        print("items=%d permuted_extra=%d" % (len(items), sum(1 for i in items if a.permute_groups and i["type"] == "choice")))
        return 0

    key = read_key(a.key_env, a.key_file)
    if not key:
        print("error: no access key (set %s or pass --key-file)" % a.key_env, file=sys.stderr)
        return 2
    out_dir = a.out_dir or os.path.join(ROOT, "docs", "qa", "009-jev-decision-models", a.run_id)
    os.makedirs(os.path.join(out_dir, "raw"), exist_ok=True)
    ctx = make_context(a.cacert)
    t0 = time.monotonic()
    records = run_items(items, a.base_url, ctx, key, a.profile, a.permute_groups, a.seed, a.timeout,
                        a.retries, a.retry_sleep, raw_path=os.path.join(out_dir, "raw", "responses.jsonl"),
                        max_options=a.max_options)
    wall_ms = int((time.monotonic() - t0) * 1000)
    rep = stats.report(records)
    cat_max = catalog_max_options(a.profile)
    mismatch = a.max_options is not None and cat_max is not None and a.max_options != cat_max
    if mismatch:
        print("warning: --max-options %d differs from catalog decision.max_options %d for profile %s"
              % (a.max_options, cat_max, a.profile), file=sys.stderr)
    meta = {"run_id": a.run_id, "profile": a.profile, "sets": sets, "seed": a.seed, "permute_groups": a.permute_groups,
            "max_options": a.max_options, "max_options_catalog": cat_max, "max_options_mismatch": mismatch,
            "fixture_sha256": {n: hashlib.sha256(open(os.path.join(FIXTURES, n + ".jsonl"), "rb").read()).hexdigest()
                               for n in sets},
            "labeled_by": "agent-authored; human-review-pending"}
    result_path = os.path.join(out_dir, "results.json")
    blob = json.dumps({"meta": meta, "report": rep, "records": records}, indent=2, sort_keys=True, default=str)
    if key in blob:
        print("error: refusing to write results: they contain the access key", file=sys.stderr)
        return 3
    with open(result_path, "w") as f:
        f.write(blob + "\n")
    argv_safe = "run_golden.py --base-url %s --profile %s --set %s%s%s" % (
        a.base_url, a.profile, a.sets, " --permute-groups" if a.permute_groups else "",
        " --types " + a.types if a.types else "")
    if a.max_options is not None:
        argv_safe += " --max-options %d" % a.max_options
    try:
        evidence(out_dir, a.run_id, key, a.key_env, rep, a.evidence_class, a.vantage, argv_safe, wall_ms,
                 max_options=a.max_options)
    except writer.EvidenceError as e:
        print("error: evidence refused: %s" % e, file=sys.stderr)
        return 3
    manifest.build(out_dir)
    print(stats.render(rep))
    print("results: %s" % result_path)
    # a limit refusal is the gateway working as specified, not a malformed answer: it does not fail the run
    bad = sum(1 for r in records if not r["well_formed"] and not r.get("refused"))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
