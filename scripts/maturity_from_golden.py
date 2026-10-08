#!/usr/bin/env python3
"""Derive the per-profile x per-type maturity labels of the decision catalog from REAL golden-run output.

Spec 009 T138 / OD-24: every admitted decision profile ships; a TYPE (noul | choice | score) whose measured
Wilson lower bound does not clear the baseline is labelled `experimental`.  Nothing is typed by hand: the
status is computed here from the `golden-stats.txt` that `scripts/golden/stats.py` printed for a live run.

Rule (the only one): lower_bound > baseline  =>  "measured"; otherwise "experimental"
(equal does NOT clear: the interval must lie strictly above the majority / chance baseline).  A profile
with no live golden run gets status "unmeasured" (reason "not yet measured") for all three types; user-facing
tables show it as experimental.

Evidence lookup (deterministic, first hit wins), relative to the repository root:
  specs/009-jev-decision-models/evidence/live/<profile>/golden-stats.txt
  specs/009-jev-decision-models/evidence/live/nezha/<profile>/golden-stats.txt

Catalog shape written to  profiles.<name>.maturity:
  {"noul": {"status": "measured|experimental", "evidence": <path>, "lower_bound": f, "baseline": f, "n": N},
   "choice": {...}, "score": {...}}                 or, with no run:  {"status": "unmeasured", "reason": "not yet measured"}

Usage:
  maturity_from_golden.py [--catalog models/catalog.json] [--root DIR] --check     exit 1 + diff when the catalog differs
  maturity_from_golden.py [--catalog models/catalog.json] [--root DIR] --write     rewrite the catalog (indent 2)
  maturity_from_golden.py [--catalog models/catalog.json] [--root DIR] --print     print the derived table (markdown)

--check also recomputes every type from <dir>/golden/results.json with scripts/golden/stats.py (when that file
exists) and fails when the recomputed Wilson lower bound / baseline / n / verdict disagree with golden-stats.txt.
"""
import argparse
import json
import os
import re
import sys

TYPES = ("noul", "choice", "score")
LIVE_REL = "specs/009-jev-decision-models/evidence/live"
SEARCH = ("{live}/{p}/golden-stats.txt", "{live}/nezha/{p}/golden-stats.txt")
LINE = re.compile(r"^(noul|choice|score)\s+n=(\d+)\s+acc=([0-9.]+)\s+CI95=\[([0-9.]+),([0-9.]+)\]\s+"
                  r"baseline=([0-9.]+)\s+\((\w+)\)\s+lower>baseline=(True|False)\s*$")
UNMEASURED = {"status": "unmeasured", "reason": "not yet measured"}


def status_for(lower_bound, baseline):
    return "measured" if lower_bound > baseline else "experimental"


def parse_stats(text):
    """-> {type: {n, lower_bound, baseline}} from stats.py's text output.  Raises ValueError when a type is
    missing or when the printed verdict disagrees with the printed numbers (a corrupted or hand-edited file)."""
    out = {}
    for ln in text.splitlines():
        m = LINE.match(ln)
        if not m:
            continue
        t, n, _acc, lo, _hi, base, _kind, printed = m.groups()
        lo, base = float(lo), float(base)
        if (printed == "True") != (lo > base):
            raise ValueError("golden-stats line disagrees with its own numbers (lower %s vs baseline %s, printed %s): %r"
                             % (lo, base, printed, ln))
        out[t] = {"n": int(n), "lower_bound": lo, "baseline": base}
    missing = [t for t in TYPES if t not in out]
    if missing:
        raise ValueError("golden-stats has no line for: %s" % ", ".join(missing))
    return out


def is_decision(p):
    return "decide" in (p.get("capability") or [])


def find_stats(root, profile):
    for pat in SEARCH:
        rel = pat.format(live=LIVE_REL, p=profile)
        if os.path.isfile(os.path.join(root, rel)):
            return rel
    return None


def recompute_diffs(root, rel, parsed):
    """Cross-check the printed text against the run's own results.json: recompute every type with the SAME
    stats.py (Wilson interval + baseline) and report any number that differs from golden-stats.txt (to the three
    decimals it prints) or any verdict that flips.  [] when they agree or when there is no results.json."""
    res = os.path.join(root, os.path.dirname(rel), "golden", "results.json")
    if not os.path.isfile(res):
        return []
    sys.path.insert(0, os.path.join(root, "scripts", "golden"))
    import stats  # noqa: E402  (stdlib-only sibling script)
    with open(res) as f:
        by_type = stats.report(json.load(f)["records"])["by_type"]
    diffs = []
    for t in TYPES:
        r = by_type.get(t)
        if r is None:
            diffs.append("%s: %s has no %s records" % (rel, res, t))
            continue
        for key, have, want in (("n", parsed[t]["n"], r["n"]), ("lower_bound", parsed[t]["lower_bound"], round(r["wilson_low"], 3)),
                                ("baseline", parsed[t]["baseline"], round(r["baseline"], 3))):
            if have != want:
                diffs.append("%s: %s %s is %s in golden-stats.txt but %s when recomputed from golden/results.json" % (rel, t, key, have, want))
        if status_for(parsed[t]["lower_bound"], parsed[t]["baseline"]) != status_for(r["wilson_low"], r["baseline"]):
            diffs.append("%s: %s verdict flips when recomputed from golden/results.json" % (rel, t))
    return diffs


def derive(cat, root):
    out = {}
    for name, p in sorted(cat["profiles"].items()):
        if not is_decision(p):
            continue
        rel = find_stats(root, name)
        if rel is None:
            out[name] = {t: dict(UNMEASURED) for t in TYPES}
            continue
        with open(os.path.join(root, rel)) as f:
            parsed = parse_stats(f.read())
        out[name] = {t: {"status": status_for(parsed[t]["lower_bound"], parsed[t]["baseline"]), "evidence": rel,
                         "lower_bound": parsed[t]["lower_bound"], "baseline": parsed[t]["baseline"], "n": parsed[t]["n"]}
                     for t in TYPES}
    return out


def check(cat, root):
    want = derive(cat, root)
    diffs = []
    for name in want:
        rel = find_stats(root, name)
        if rel is not None:
            with open(os.path.join(root, rel)) as f:
                diffs.extend(recompute_diffs(root, rel, parse_stats(f.read())))
    for name, m in want.items():
        have = cat["profiles"][name].get("maturity")
        if have != m:
            diffs.append("%s: maturity differs from the golden-run derivation\n    have: %s\n    want: %s"
                         % (name, json.dumps(have, sort_keys=True), json.dumps(m, sort_keys=True)))
    for name, p in cat["profiles"].items():
        if name not in want and "maturity" in p:
            diffs.append("%s: has a maturity object but is not a decision profile" % name)
    return diffs


def apply(cat, root):
    want = derive(cat, root)
    for name, m in want.items():
        cat["profiles"][name]["maturity"] = m
    return cat


def table(cat, root):
    rows = ["| profile | noul | choice | score |", "|---|---|---|---|"]
    for name, m in derive(cat, root).items():
        def cell(t):
            e = m[t]
            if e["status"] == "unmeasured":
                return "experimental (not yet measured)"
            lab = "measured" if e["status"] == "measured" else "experimental"
            return "%s (LB %.3f vs %.3f, n=%d)" % (lab, e["lower_bound"], e["baseline"], e["n"])
        rows.append("| `%s` | %s | %s | %s |" % (name, cell("noul"), cell("choice"), cell("score")))
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
        print("maturity: %s" % ("OK (catalog == golden-run derivation)" if not diffs else "%d profile(s) differ" % len(diffs)))
        return 1 if diffs else 0
    if a.write:
        apply(cat, a.root)
        with open(path, "w") as f:
            f.write(json.dumps(cat, indent=2, ensure_ascii=False) + "\n")
        print("maturity: wrote %s" % path)
        return 0
    print(table(cat, a.root))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
