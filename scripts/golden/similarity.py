#!/usr/bin/env python3
"""Near-duplicate finder for golden-set JSONL files (stdlib only).

Similarity of two items = Jaccard index of their character 4-gram sets over the
normalised "state" text (lower-cased, whitespace collapsed). Items of different
types are never compared. Two thresholds:

  --max-same-label S   (default 0.80) pairs with the SAME expected answer must stay below S
  --max-any A          (default 0.92) no pair may reach A, whatever the labels

Pairs with DIFFERENT expected answers and high similarity are legitimate
minimal contrast pairs (for example the same requirement with correct and
broken code); they are listed, not failed, unless they reach --max-any.

Usage: similarity.py questions.jsonl [probes.jsonl ...] [--json]
Exit 0 = ok, 1 = a threshold was breached, 2 = usage / read error.
"""
import argparse
import json
import re
import sys


def norm(text):
    return re.sub(r"\s+", " ", str(text).lower()).strip()


def grams(text, n=4):
    t = norm(text)
    if len(t) < n:
        return {t} if t else set()
    return {t[i:i + n] for i in range(len(t) - n + 1)}


def jaccard(a, b):
    if not a and not b:
        return 1.0
    return len(a & b) / float(len(a | b))


def load(paths):
    items = []
    for p in paths:
        with open(p, encoding="utf-8") as f:
            for ln, line in enumerate(f, 1):
                if line.strip():
                    try:
                        items.append(json.loads(line))
                    except ValueError as e:
                        raise SystemExit("%s:%d: bad JSON (%s)" % (p, ln, e))
    return items


def pairs(items):
    """Yield (sim, a, b) for every comparable pair."""
    g = [grams(i.get("state", "")) for i in items]
    for x in range(len(items)):
        for y in range(x + 1, len(items)):
            if items[x].get("type") != items[y].get("type"):
                continue
            yield jaccard(g[x], g[y]), items[x], items[y]


def analyse(items, max_same=0.80, max_any=0.92):
    top = []
    max_all = 0.0
    max_same_label = 0.0
    breaches = []
    for sim, a, b in pairs(items):
        same = a.get("expected") == b.get("expected")
        max_all = max(max_all, sim)
        if same:
            max_same_label = max(max_same_label, sim)
        if sim >= 0.5:
            top.append((round(sim, 4), a["id"], b["id"], "same-label" if same else "contrast"))
        if sim >= max_any or (same and sim >= max_same):
            breaches.append((round(sim, 4), a["id"], b["id"], "same-label" if same else "contrast"))
    top.sort(reverse=True)
    return {"items": len(items), "max_similarity_any": round(max_all, 4),
            "max_similarity_same_label": round(max_same_label, 4),
            "pairs_ge_0.5": top[:25], "breaches": breaches}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--max-same-label", type=float, default=0.80)
    ap.add_argument("--max-any", type=float, default=0.92)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        items = load(a.files)
    except OSError as e:
        print("error: %s" % e, file=sys.stderr)
        return 2
    rep = analyse(items, a.max_same_label, a.max_any)
    if a.json:
        print(json.dumps(rep, indent=2))
    else:
        print("items=%d max_any=%.4f max_same_label=%.4f breaches=%d" % (
            rep["items"], rep["max_similarity_any"], rep["max_similarity_same_label"], len(rep["breaches"])))
        for row in rep["pairs_ge_0.5"]:
            print("  %.4f %s %s %s" % row)
    return 1 if rep["breaches"] else 0


if __name__ == "__main__":
    sys.exit(main())
