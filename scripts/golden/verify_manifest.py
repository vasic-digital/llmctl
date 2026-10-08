#!/usr/bin/env python3
"""Verify tests/fixtures/golden/MANIFEST.json against the files on disk (stdlib only).

Re-hashes every listed file and re-derives the counts from the JSONL content; fails (exit 1)
on any drift: changed bytes, missing or unlisted file, counts that no longer match, items
missing the honesty/licence fields, or fewer items than the minimums required by spec 009 SC-003.

Usage: verify_manifest.py [DIR]      (default tests/fixtures/golden)
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DEFAULT_DIR = os.path.join(ROOT, "tests", "fixtures", "golden")
DATA_FILES = ("questions.jsonl", "probes.jsonl")
MANIFEST = "MANIFEST.json"
MINIMUMS = {"noul": 50, "choice": 40, "score": 30}
REQUIRED_OPTION_COUNTS = (2, 3, 4, 5, 8, 12, 20)
REQUIRED_FIELDS = ("id", "type", "state", "instructions", "criteria", "expected", "difficulty",
                   "source", "license", "labeled_by", "language")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_items(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def _bump(d, k):
    d[str(k)] = d.get(str(k), 0) + 1


def compute_counts(items):
    c = {"items": len(items), "by_type": {}, "by_class": {}, "by_difficulty": {},
         "choice_by_option_count": {}, "score_by_scale": {}, "expected_distribution": {}, "class_balance": {}}
    for it in items:
        _bump(c["by_type"], it["type"])
        _bump(c["by_class"], it.get("class") or it.get("probe_class"))
        _bump(c["by_difficulty"], it.get("difficulty"))
        if it["type"] == "choice":
            _bump(c["choice_by_option_count"], it.get("option_count"))
        if it["type"] == "score":
            _bump(c["score_by_scale"], it.get("scale"))
        if it.get("expected") is not None:
            _bump(c["expected_distribution"].setdefault(it["type"], {}), it["expected"])
            fam = it.get("class") or it.get("probe_class")
            _bump(c["class_balance"].setdefault(fam, {}), it["expected"])
    for k in ("by_type", "by_class", "by_difficulty", "choice_by_option_count", "score_by_scale"):
        c[k] = dict(sorted(c[k].items()))
    c["expected_distribution"] = {t: dict(sorted(v.items())) for t, v in sorted(c["expected_distribution"].items())}
    c["class_balance"] = {t: dict(sorted(v.items())) for t, v in sorted(c["class_balance"].items())}
    return c


def verify(d):
    problems = []
    mp = os.path.join(d, MANIFEST)
    if not os.path.isfile(mp):
        return ["%s missing" % MANIFEST]
    with open(mp) as f:
        man = json.load(f)
    listed = man.get("files", {})
    for name in sorted(listed):
        p = os.path.join(d, name)
        if not os.path.isfile(p):
            problems.append("missing file: %s" % name)
        elif sha256_file(p) != listed[name]["sha256"]:
            problems.append("hash drift: %s" % name)
    present = {n for n in os.listdir(d) if n.endswith(".jsonl")}
    for extra in sorted(present - set(listed)):
        problems.append("unlisted data file: %s" % extra)
    for name in DATA_FILES:
        p = os.path.join(d, name)
        if not os.path.isfile(p):
            continue
        items = read_items(p)
        if man.get("counts", {}).get(name) != compute_counts(items):
            problems.append("counts drift: %s" % name)
        ids = [i["id"] for i in items]
        if len(set(ids)) != len(ids):
            problems.append("duplicate ids in %s" % name)
        for it in items:
            miss = [k for k in REQUIRED_FIELDS if k not in it]
            if miss:
                problems.append("%s %s missing fields %s" % (name, it.get("id"), miss))
            elif "human-review-pending" not in it["labeled_by"] and "human-reviewed" not in it["labeled_by"]:
                problems.append("%s %s has no honest labeled_by" % (name, it["id"]))
    q = os.path.join(d, "questions.jsonl")
    if os.path.isfile(q):
        cc = compute_counts(read_items(q))
        for t, m in MINIMUMS.items():
            if cc["by_type"].get(t, 0) < m:
                problems.append("questions.jsonl has fewer than %d %s items" % (m, t))
        for n in REQUIRED_OPTION_COUNTS:
            if cc["choice_by_option_count"].get(str(n), 0) < 1:
                problems.append("no choice item with %d options" % n)
        for s in range(2, 11):
            if cc["score_by_scale"].get(str(s), 0) < 1:
                problems.append("no score item with scale %d" % s)
    return problems


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    d = argv[0] if argv else DEFAULT_DIR
    problems = verify(d)
    for p in problems:
        print("FAIL: " + p)
    if not problems:
        print("manifest ok: %s" % d)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
