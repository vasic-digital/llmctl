#!/usr/bin/env python3
"""Wrapper (NOT part of the llmctl tree): runs scripts/golden/run_golden.py unchanged, but records every response's
status + x-llmctl-* headers (incl. x-llmctl-decide-reason) + body head for non-200 into HDRLOG (jsonl). No keys are logged."""
import json, os, sys, time
REPO = os.environ["REPO"]; sys.path.insert(0, REPO)
from scripts.golden import run_golden as rg
LOG = os.environ["HDRLOG"]; orig = rg.post_json
def wrapped(url, ctx, key, payload, timeout):
    t0 = time.monotonic()
    try:
        status, headers, body = orig(url, ctx, key, payload, timeout)
    except BaseException as e:
        with open(LOG, "a") as f: f.write(json.dumps({"exc": type(e).__name__, "ms": int((time.monotonic()-t0)*1000)}) + "\n")
        raise
    h = {k.lower(): v for k, v in headers.items() if k.lower().startswith("x-llmctl") or k.lower() in ("retry-after", "content-type")}
    rec = {"status": status, "ms": int((time.monotonic()-t0)*1000), "headers": h}
    if status != 200: rec["body"] = body[:400].decode("utf-8", "replace")
    with open(LOG, "a") as f: f.write(json.dumps(rec) + "\n")
    return status, headers, body
rg.post_json = wrapped
sys.exit(rg.main())
