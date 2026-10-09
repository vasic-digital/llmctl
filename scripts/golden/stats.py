#!/usr/bin/env python3
"""Statistics for the golden question set (stdlib only; spec 009 SC-003, FR-080).

Input: a list of result records (see run_golden.py), each a dict with
  id, type (noul|choice|score), family, expected, predicted (None = malformed),
  well_formed (bool), variant ("orig" or "perm"), perm_group (choice only),
  option_count (choice) / scale (score), p_pred (probability the answer gave to its
  own prediction, or None). Records may also carry confidence / confidence_raw / calibration
  (what a calibrating gateway served); they are recorded, NEVER used for ECE.

What is computed (all from the same records, by the same code, so the interval and
the baseline can never come from different tools):

  * accuracy with a Wilson 95% interval, per type
  * the trivial baselines per type: the majority-class share of the EXPECTED answers
    and the chance level (mean of 1/options); the baseline used for the verdict is
    the larger of the two
  * verdict "lower bound of the interval > baseline" (SC-003)
  * per-class accuracy (class = the expected answer) and per-family accuracy with the
    family's own majority baseline (imbalanced families make the majority baseline strong)
  * option-order flip rate over permutation groups
  * accuracy-vs-option-count (choice) and accuracy-vs-scale (score) tables
  * ECE / MCE / Brier, ONLY when at least 200 labelled items exist, otherwise the
    literal text "insufficient for calibration"

Usage: stats.py RESULTS.json [--json]     (RESULTS.json = {"records": [...]})
"""
import json
import math
import sys

Z95 = 1.959963984540054
CAL_MIN = 200
CAL_BINS = 10
INSUFFICIENT = "insufficient for calibration"


def wilson(k, n, z=Z95):
    """Wilson score interval for k successes in n trials; (0.0, 1.0) when n == 0."""
    if n <= 0:
        return (0.0, 1.0)
    p = k / float(n)
    denom = 1.0 + z * z / n
    centre = (p + z * z / (2.0 * n)) / denom
    half = z * math.sqrt(p * (1.0 - p) / n + z * z / (4.0 * n * n)) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))


def majority(labels):
    """(label, share) of the most frequent label; (None, 0.0) for an empty list.
    Ties break on the sorted repr so the result is deterministic."""
    if not labels:
        return (None, 0.0)
    counts = {}
    for x in labels:
        counts[repr(x)] = counts.get(repr(x), [0, x])
        counts[repr(x)][0] += 1
    best = sorted(counts.items(), key=lambda kv: (-kv[1][0], kv[0]))[0]
    return (best[1][1], best[1][0] / float(len(labels)))


def lower_exceeds_baseline(lower, baseline):
    return lower > baseline


def _correct(rec):
    if not rec.get("well_formed") or rec.get("predicted") is None:
        return False
    return rec["predicted"] == rec["expected"]


def _acc_row(recs):
    n = len(recs)
    k = sum(1 for r in recs if _correct(r))
    lo, hi = wilson(k, n)
    return {"n": n, "correct": k, "accuracy": (k / float(n)) if n else None,
            "wilson_low": lo, "wilson_high": hi}


def calibration(pairs):
    """pairs = [(p_pred, correct 0/1)]. Returns ECE, MCE, Brier (confidence Brier:
    mean (p_pred - correct)^2) or the insufficiency marker when fewer than CAL_MIN pairs."""
    n = len(pairs)
    if n < CAL_MIN:
        return {"status": INSUFFICIENT, "n": n, "required": CAL_MIN}
    bins = [[0, 0.0, 0.0] for _ in range(CAL_BINS)]  # count, sum conf, sum correct
    brier = 0.0
    for p, c in pairs:
        b = min(int(p * CAL_BINS), CAL_BINS - 1)
        bins[b][0] += 1
        bins[b][1] += p
        bins[b][2] += c
        brier += (p - c) ** 2
    ece = 0.0
    mce = 0.0
    for cnt, sc, sk in bins:
        if cnt:
            gap = abs(sk / cnt - sc / cnt)
            ece += cnt / float(n) * gap
            mce = max(mce, gap)
    return {"status": "ok", "n": n, "ece": ece, "mce": mce, "brier": brier / n, "bins": CAL_BINS}


def flip_rate(records):
    """Option-order flip rate: of the permutation groups that have >= 2 well-formed answers
    (original order plus at least one permuted order), the fraction whose answers disagree."""
    groups = {}
    for r in records:
        g = r.get("perm_group")
        if g and r.get("well_formed") and r.get("predicted") is not None:
            groups.setdefault(g, []).append(r["predicted"])
    considered = [v for v in groups.values() if len(v) >= 2]
    flipped = sum(1 for v in considered if len(set(v)) > 1)
    return {"groups": len(considered), "flipped": flipped,
            "flip_rate": (flipped / float(len(considered))) if considered else None}


def pair_consistency(records):
    """Irrelevant-state probes: share of pair_ids whose base and distractor answers agree."""
    pairs = {}
    for r in records:
        pid = r.get("pair_id")
        if pid and r.get("well_formed") and r.get("predicted") is not None:
            pairs.setdefault(pid, []).append(r["predicted"])
    considered = [v for v in pairs.values() if len(v) >= 2]
    agree = sum(1 for v in considered if len(set(v)) == 1)
    return {"pairs": len(considered), "agree": agree,
            "agreement": (agree / float(len(considered))) if considered else None}


def report(records):
    orig = [r for r in records if r.get("variant", "orig") == "orig"]
    perm = [r for r in records if r.get("variant") == "perm"]
    out = {"records": len(records), "orig_items": len(orig), "perm_items": len(perm)}
    # G-160: a gateway limit refusal (record["refused"] true; absent in old results = not refused) is
    # not a model error; it leaves the well-formed ratio and is reported on its own, never dropped.
    refused = [r for r in orig if r.get("refused")]
    scored = [r for r in orig if not r.get("refused")]
    wf = sum(1 for r in scored if r.get("well_formed"))
    out["well_formed"] = {"n": len(scored), "ok": wf, "rate": (wf / float(len(scored))) if scored else None}
    reasons = {}
    for r in refused:
        k = r.get("refusal_reason") or "unspecified"
        reasons[k] = reasons.get(k, 0) + 1
    out["refused"] = {"n": len(refused), "reasons": reasons}

    by_type = {}
    for t in ("noul", "choice", "score"):
        recs = [r for r in orig if r.get("type") == t and r.get("expected") is not None]
        if not recs:
            continue
        row = _acc_row(recs)
        maj_label, maj_share = majority([r["expected"] for r in recs])
        sizes = [r.get("option_count") or r.get("scale") or (2 if t == "noul" else None) for r in recs]
        sizes = [s for s in sizes if s]
        chance = (sum(1.0 / s for s in sizes) / len(sizes)) if sizes else 0.0
        base = max(maj_share, chance)
        row.update({"majority_label": maj_label, "majority_share": maj_share,
                    "chance_level": chance, "baseline": base,
                    "baseline_kind": "majority" if maj_share >= chance else "chance",
                    "lower_bound_exceeds_baseline": lower_exceeds_baseline(row["wilson_low"], base)})
        if t == "score":
            near = sum(1 for r in recs if r.get("well_formed") and r.get("predicted") is not None
                       and abs(r["predicted"] - r["expected"]) <= 1)
            row["within_one_level"] = near / float(len(recs))
        by_type[t] = row
    out["by_type"] = by_type

    per_class = {}
    for t in ("noul", "choice", "score"):
        keys = sorted({repr(r["expected"]) for r in orig if r.get("type") == t and r.get("expected") is not None})
        for k in keys:
            recs = [r for r in orig if r.get("type") == t and repr(r.get("expected")) == k]
            per_class["%s:%s" % (t, k.strip("'"))] = _acc_row(recs)
    out["per_class"] = per_class

    fams = {}
    for fam in sorted({r.get("family") for r in orig if r.get("family") and r.get("expected") is not None}):
        recs = [r for r in orig if r.get("family") == fam and r.get("expected") is not None]
        row = _acc_row(recs)
        _, share = majority([r["expected"] for r in recs])
        row["majority_share"] = share
        row["lower_bound_exceeds_majority"] = row["wilson_low"] > share
        fams[fam] = row
    out["per_family"] = fams

    out["flip"] = flip_rate(records)
    by_count = {}
    for n in sorted({r["option_count"] for r in orig if r.get("type") == "choice" and r.get("option_count")}):
        rows = [r for r in orig if r.get("type") == "choice" and r.get("option_count") == n
                and r.get("expected") is not None and not r.get("refused")]
        if rows:   # refused items are reported under "refused" only (G-160)
            by_count[str(n)] = _acc_row(rows)
    out["accuracy_by_option_count"] = by_count
    by_scale = {}
    for n in sorted({r["scale"] for r in orig if r.get("type") == "score" and r.get("scale")}):
        by_scale[str(n)] = _acc_row([r for r in orig if r.get("type") == "score" and r.get("scale") == n
                                     and r.get("expected") is not None])
    out["accuracy_by_scale"] = by_scale

    cal = [(r["p_pred"], 1 if _correct(r) else 0) for r in orig
           if r.get("expected") is not None and r.get("well_formed") and r.get("p_pred") is not None]
    out["calibration"] = calibration(cal)
    out["calibration_input"] = CAL_INPUT
    out["calibrated_records"] = sum(1 for r in orig if r.get("calibration"))
    out["pair_consistency"] = pair_consistency(records)
    return out


CAL_INPUT = ("p_pred = the winner's own raw probability; the gateway's served `confidence` "
             "(calibrated when a profile is applied) and `confidence_raw` are never used")


def _f(x):
    return "n/a" if x is None else "%.3f" % x


def render(rep):
    lines = ["records=%d orig=%d perm=%d well_formed=%s/%s" % (
        rep["records"], rep["orig_items"], rep["perm_items"], rep["well_formed"]["ok"], rep["well_formed"]["n"])]
    if rep.get("refused", {}).get("n"):
        lines.append("refused (limit): %d %s" % (rep["refused"]["n"], sorted(rep["refused"]["reasons"].items())))
    for t, r in rep["by_type"].items():
        lines.append("%-6s n=%d acc=%s CI95=[%s,%s] baseline=%s (%s) lower>baseline=%s" % (
            t, r["n"], _f(r["accuracy"]), _f(r["wilson_low"]), _f(r["wilson_high"]), _f(r["baseline"]),
            r["baseline_kind"], r["lower_bound_exceeds_baseline"]))
    lines.append("per-class:")
    for k, r in rep["per_class"].items():
        lines.append("  %-22s n=%d acc=%s" % (k, r["n"], _f(r["accuracy"])))
    lines.append("per-family (own majority baseline):")
    for k, r in rep["per_family"].items():
        lines.append("  %-26s n=%d acc=%s CI=[%s,%s] majority=%s lower>majority=%s" % (
            k, r["n"], _f(r["accuracy"]), _f(r["wilson_low"]), _f(r["wilson_high"]), _f(r["majority_share"]),
            r["lower_bound_exceeds_majority"]))
    fl = rep["flip"]
    lines.append("option-order flip rate: %s (%d of %d groups)" % (_f(fl["flip_rate"]), fl["flipped"], fl["groups"]))
    lines.append("accuracy by option count:")
    for k, r in rep["accuracy_by_option_count"].items():
        lines.append("  %3s options n=%d acc=%s CI=[%s,%s]" % (k, r["n"], _f(r["accuracy"]), _f(r["wilson_low"]), _f(r["wilson_high"])))
    cal = rep["calibration"]
    if cal["status"] == INSUFFICIENT:
        lines.append("calibration: %s (n=%d, need %d)" % (INSUFFICIENT, cal["n"], cal["required"]))
    else:
        lines.append("calibration: n=%d ECE=%s MCE=%s Brier=%s" % (cal["n"], _f(cal["ece"]), _f(cal["mce"]), _f(cal["brier"])))
    if rep.get("calibrated_records"):
        lines.append("calibrated gateway: %d records carry a calibration profile; served confidence is not used "
                     "(%s)" % (rep["calibrated_records"], CAL_INPUT))
    return "\n".join(lines)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    as_json = "--json" in argv
    argv = [a for a in argv if a != "--json"]
    if len(argv) != 1:
        print("usage: stats.py RESULTS.json [--json]", file=sys.stderr)
        return 2
    with open(argv[0]) as f:
        data = json.load(f)
    rep = report(data["records"] if isinstance(data, dict) else data)
    print(json.dumps(rep, indent=2, sort_keys=True) if as_json else render(rep))
    return 0


if __name__ == "__main__":
    sys.exit(main())
