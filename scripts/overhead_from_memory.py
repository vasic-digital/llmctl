#!/usr/bin/env python3
"""Derive the measured memory overhead of every decision profile from its recorded evidence.

Spec 009 T139 (G-137, G-138).  The planner books  weights + KV + defaults.overhead_mb  of host RAM and, on a host
with a GPU, defaults.overhead_vram_mb of VRAM (the CUDA build offloads large-batch ops even in "cpu mode").  The
numbers are never typed by hand; this script computes them from the evidence files named by the catalog.

THE RULES (also stated in docs/hardware-tiers.md "How the planner estimates memory"):
  overhead_mb       = ceil(1.10 x (peak VmHWM - model file size))              [RAM above the weights, +10% margin]
  overhead_vram_mb  = ceil(1.10 x highest VRAM the engine pid held)            [+10% margin]
  window_tokens     = the context window the peak was measured at (the largest state that fits it was sent)
The rule is NEZHA-LIVE-REPORT's recommended rule (peak HWM - model file size, +10%).  The peak is the highest
VmHWM of the run: the kernel's own high-water mark, taken after states filling the window were sent.  All
arithmetic is exact (fractions); sizes in MiB (1048576 bytes), peak kB / 1024.

Catalog shape (profiles.<name>.memory; the source declaration is provenance, the numbers are derived):
  "memory": {
    "ram":  {"status": "measured", "format": "memory-summary-json" | "ctx-peak-txt", "evidence": "<repo path>",
             "host": "<machine>", ["ctx": N  (ctx-peak-txt only)]   + derived: "peak_hwm_mib", "weights_mib"},
    "vram": {"status": "measured", "format": "pid-vram-txt", "evidence": "<repo path>", "host": "<machine>",
             + derived: "peak_mib"}
  }
  or  {"status": "unmeasured", "reason": "<why>"}  for either half.  An unmeasured half declares NO number
  (the planner then books 0 for it, exactly as before) and is listed by --check as an open measurement.

Evidence formats:
  memory-summary-json  nezha/<profile>/memory-summary.json  {"ctx", "model_bytes", "memory": [{"VmHWM_kB": ..}, ..]}
  ctx-peak-txt         ctx-peak-memory-experiment.txt       "model=<file> ctx=<N> idleHWM_kB=.. peakHWM_kB=.."
  pid-vram-txt         <profile>/memory.txt                 "vram(MiB) pid=<pid>: <MiB>" lines (max taken)

Usage:  overhead_from_memory.py [--catalog F] [--root DIR] (--check | --write | --print)
"""
import argparse
import json
import math
import os
import re
import sys
from fractions import Fraction

MARGIN = Fraction(11, 10)
MIB = 1048576


def overhead_from_peak(peak_mib, weights_mib):
    """ceil(1.10 x (peak - weights)), never negative.  Exact rational arithmetic."""
    d = (Fraction(peak_mib) - Fraction(weights_mib)) * MARGIN
    return max(0, math.ceil(d))


def vram_overhead(peak_vram_mib):
    return math.ceil(Fraction(peak_vram_mib) * MARGIN)


def parse_summary_json(text):
    d = json.loads(text)
    kbs = [m["VmHWM_kB"] for m in d["memory"] if "VmHWM_kB" in m]
    if not kbs:
        raise ValueError("memory-summary has no VmHWM_kB sample")
    return Fraction(max(kbs), 1024), int(d["ctx"])


def parse_ctx_peak(text, model_file, ctx):
    pat = re.compile(r"^model=(\S+)\s+ctx=(\d+)\s+.*?peakHWM_kB=(\d+)", re.M)
    for m in pat.finditer(text):
        if m.group(1) == model_file and int(m.group(2)) == ctx:
            return Fraction(int(m.group(3)), 1024)
    raise ValueError("no 'model=%s ctx=%d' line in the ctx-peak evidence" % (model_file, ctx))


def parse_pid_vram(text):
    v = [int(x) for x in re.findall(r"^vram\(MiB\) pid=\d+:\s*(\d+)\s*$", text, re.M)]
    if not v:
        raise ValueError("no 'vram(MiB) pid=N: V' line in the evidence")
    return max(v)


def is_decision(p):
    return "decide" in (p.get("capability") or [])


def model_bytes(p):
    return sum(int(f["size"]) for f in p.get("files", []) if f.get("role", "model") == "model")


def _read(root, rel):
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        raise ValueError("evidence file does not exist: %s" % rel)
    with open(path) as f:
        return f.read()


def _round1(fr):
    return float(round(float(fr), 1))


def derive(cat, root):
    """-> {profile: {"defaults": {...numbers...}, "memory": {...with derived numbers...}}} for every decision profile.
    Raises ValueError when a measured half's evidence is missing/unparseable."""
    out = {}
    for name, p in sorted(cat["profiles"].items()):
        if not is_decision(p):
            continue
        mem = json.loads(json.dumps(p.get("memory") or {}))
        defaults = {}
        ram, vram = mem.get("ram") or {}, mem.get("vram") or {}
        weights = Fraction(model_bytes(p), MIB)
        if ram.get("status") == "measured":
            text = _read(root, ram["evidence"])
            fmt = ram.get("format")
            if fmt == "memory-summary-json":
                peak, ctx = parse_summary_json(text)
            elif fmt == "ctx-peak-txt":
                files = [f["name"] for f in p.get("files", []) if f.get("role", "model") == "model"]
                ctx = int(ram["ctx"])
                peak = parse_ctx_peak(text, files[0], ctx)
            else:
                raise ValueError("%s: unknown ram evidence format %r" % (name, fmt))
            defaults["overhead_mb"] = overhead_from_peak(peak, weights)
            defaults["window_tokens"] = ctx
            ram["peak_hwm_mib"], ram["weights_mib"] = _round1(peak), _round1(weights)
        if vram.get("status") == "measured":
            if vram.get("format") != "pid-vram-txt":
                raise ValueError("%s: unknown vram evidence format %r" % (name, vram.get("format")))
            peak_v = parse_pid_vram(_read(root, vram["evidence"]))
            defaults["overhead_vram_mb"] = vram_overhead(peak_v)
            vram["peak_mib"] = peak_v
        if mem:
            mem["ram"], mem["vram"] = ram, vram
        out[name] = {"defaults": defaults, "memory": mem}
    return out


DERIVED_KEYS = ("overhead_mb", "overhead_vram_mb", "window_tokens")


def check(cat, root):
    diffs = []
    try:
        want = derive(cat, root)
    except ValueError as e:
        return ["evidence: %s" % e]
    for name, w in want.items():
        p = cat["profiles"][name]
        if not p.get("memory"):
            diffs.append("%s: decision profile has no `memory` object (declare ram/vram as measured with evidence, or unmeasured with a reason)" % name)
            continue
        for half in ("ram", "vram"):
            h = (p["memory"].get(half) or {})
            if h.get("status") not in ("measured", "unmeasured"):
                diffs.append("%s: memory.%s.status must be measured or unmeasured" % (name, half))
            elif h["status"] == "unmeasured" and not h.get("reason"):
                diffs.append("%s: memory.%s is unmeasured and gives no reason" % (name, half))
        have_d = {k: p.get("defaults", {}).get(k) for k in DERIVED_KEYS if k in p.get("defaults", {})}
        if have_d != w["defaults"]:
            diffs.append("%s: defaults differ from the evidence derivation\n    have: %s\n    want: %s" % (name, have_d, w["defaults"]))
        if p["memory"] != w["memory"]:
            diffs.append("%s: memory object differs from the evidence derivation\n    have: %s\n    want: %s"
                         % (name, json.dumps(p["memory"], sort_keys=True), json.dumps(w["memory"], sort_keys=True)))
    return diffs


def open_measurements(cat):
    out = []
    for name, p in sorted(cat["profiles"].items()):
        if not is_decision(p):
            continue
        for half in ("ram", "vram"):
            h = (p.get("memory") or {}).get(half) or {}
            if h.get("status") != "measured":
                out.append((name, half, h.get("reason", "no memory object")))
    return out


def apply(cat, root):
    want = derive(cat, root)
    for name, w in want.items():
        p = cat["profiles"][name]
        d = p.setdefault("defaults", {})
        for k in DERIVED_KEYS:
            d.pop(k, None)
        d.update(w["defaults"])
        if w["memory"]:
            p["memory"] = w["memory"]
    return cat


def table(cat, root):
    rows = ["| profile | window (tokens) | overhead RAM (MiB) | overhead VRAM (MiB) | RAM evidence | VRAM evidence |", "|---|---|---|---|---|---|"]
    for name, w in derive(cat, root).items():
        d, m = w["defaults"], w["memory"]
        ram, vram = m.get("ram", {}), m.get("vram", {})
        rows.append("| `%s` | %s | %s | %s | %s | %s |" % (
            name, d.get("window_tokens", "unmeasured"), d.get("overhead_mb", "unmeasured"), d.get("overhead_vram_mb", "unmeasured"),
            ("`%s`" % ram["evidence"]) if ram.get("status") == "measured" else "unmeasured",
            ("`%s`" % vram["evidence"]) if vram.get("status") == "measured" else "unmeasured"))
    return "\n".join(rows)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--catalog", default=None)
    ap.add_argument("--root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--write", action="store_true")
    g.add_argument("--print", dest="show", action="store_true")
    a = ap.parse_args(argv)
    path = a.catalog or os.path.join(a.root, "models", "catalog.json")
    with open(path) as f:
        cat = json.load(f)
    if a.check:
        diffs = check(cat, a.root)
        for d in diffs:
            print("DIFF:", d)
        for name, half, why in open_measurements(cat):
            print("OPEN: %s memory.%s unmeasured: %s" % (name, half, why))
        print("memory: %s" % ("OK (catalog == evidence derivation)" if not diffs else "%d difference(s)" % len(diffs)))
        return 1 if diffs else 0
    if a.write:
        apply(cat, a.root)
        with open(path, "w") as f:
            f.write(json.dumps(cat, indent=2, ensure_ascii=False) + "\n")
        print("memory: wrote %s" % path)
        return 0
    print(table(cat, a.root))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
