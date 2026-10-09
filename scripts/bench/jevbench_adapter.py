#!/usr/bin/env python3
"""Thin wrapper that runs the upstream JevBench harness against an llmctl decide gateway and
post-processes its results into RUN/summary.json (spec 009 T065, idea 2-I04).  stdlib only.

What it adds on top of the upstream harness (it does NOT reimplement the harness):
  * the run is ALWAYS labelled  tier=public-tier, contamination=possible, official_score=false;
    --public-tier is mandatory (a refusal without it - the public items may be in training data and
    the licences of the easy/hard splits are unconfirmed, so a number from this tool is never a
    leaderboard score);
  * fail-closed provenance: the harness checkout must be at --expect-commit (git rev-parse HEAD, clean
    tree) and every dataset split used must hash (sha256 of the file bytes) to the value in the
    upstream datasets/manifest.json, otherwise exit 2 and nothing is run;
  * refusals (HTTP 422, 502, 503, 529, timeouts) are tallied separately from wrong answers, malformed
    answers separately again;
  * accuracy with a Wilson interval and the trivial baseline, using scripts/golden/stats.py;
  * calibration only when >= 200 items are licence-clean (provenance.license in the allowlist, expected
    not null, no exclude_reason) AND answered: below that the summary says "insufficient: N<200" and no
    CSV is written; at 200+ a CSV with the columns p_pred,correct (accepted by `llmctl-decide
    calibrate --labels`) is written next to the summary;
  * with --evidence-dir: ids + aggregates ONLY (never item text, never raw responses) plus a README
    stating that raw outputs stay outside git unless every item is MIT.

Run (real): see docs/golden-set.md "JevBench public tier".  HTTPS gateway with a private CA: the upstream
harness uses urllib, which honours SSL_CERT_FILE; pass --ssl-cert-file CA.pem (sets it for the child only).
The API key is read from the environment variable named by --key-env (default LLMCTL_API_KEY); it is
never an argument and never written.

Exit: 0 ok, 1 harness failed, 2 usage / provenance refusal, 3 run incomplete (summary still written).
"""
import argparse
import csv
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys

try:
    from scripts.golden import stats
except ImportError:  # run as a script: scripts/bench/jevbench_adapter.py
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    from scripts.golden import stats

CAL_MIN = 200
REFUSAL_CODES = (422, 502, 503, 529)
# Upstream Runner.run_all stops the whole run right after a record with one of these (access denied / rate
# limited); the adapter reports it (access_stop) and exits 3.  429 is deliberately NOT a gateway refusal: it is
# tallied as failed_other (the caller was throttled, the gateway did not decline the item).
ACCESS_STOP_CODES = (401, 403, 429)
HEX40 = re.compile(r"^[0-9a-fA-F]{40}$")
TIER = "public-tier"
CONTAMINATION = "possible"
DEFAULT_LICENCES = ("MIT",)
DEFAULT_SPLITS = ("original",)


class Refusal(Exception):
    """Fail-closed provenance / usage refusal (exit 2)."""


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _git(repo, *args):
    r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)
    if r.returncode != 0:
        raise Refusal("git %s failed in %s: %s" % (" ".join(args), repo, r.stderr.strip()[:200]))
    return r.stdout.strip()


def _ignored_unsafe(repo):
    """Ignored (gitignored) entries that are not bytecode caches: they could still alter the harness."""
    bad = []
    # ls-files lists every ignored FILE (status --ignored would collapse a wholly ignored directory into one entry)
    for path in _git(repo, "ls-files", "--others", "--ignored", "--exclude-standard").splitlines():
        if "__pycache__" in path.split("/") or path.endswith(".pyc"):
            continue
        bad.append(path)
    return bad


def check_commit(repo, expect):
    """Fail closed unless HEAD == expect (exactly 40 hex digits), the work tree is clean (tracked, untracked AND
    gitignored files; bytecode caches are tolerated and the child runs with PYTHONDONTWRITEBYTECODE=1)."""
    if not expect or not HEX40.match(expect):
        raise Refusal("--expect-commit must be the full 40-hex commit id")
    head = _git(repo, "rev-parse", "HEAD").lower()
    if head != expect.lower():
        raise Refusal("jevbench commit mismatch: HEAD %s != expected %s" % (head, expect))
    status = [ln for ln in _git(repo, "status", "--porcelain").splitlines() if ln.strip()]
    if status:
        raise Refusal("jevbench checkout has uncommitted or untracked changes; refusing to run a modified harness")
    ignored = _ignored_unsafe(repo)
    if ignored:
        raise Refusal("jevbench checkout has gitignored files that could alter the harness (%s); refusing"
                      % ", ".join(ignored[:5]))
    return head


def check_datasets(repo, splits):
    """sha256 of datasets/public/<split>.jsonl must equal the upstream manifest value."""
    mpath = os.path.join(repo, "datasets", "manifest.json")
    try:
        with open(mpath, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, ValueError) as e:
        raise Refusal("cannot read upstream %s: %s" % (mpath, e))
    want = {s.get("name"): s for s in manifest.get("splits", [])}
    out = {}
    for sp in splits:
        if sp not in want:
            raise Refusal("split %r is not in the upstream manifest" % sp)
        path = os.path.join(repo, "datasets", "public", sp + ".jsonl")
        if not os.path.isfile(path):
            raise Refusal("dataset file missing: %s" % path)
        got = sha256_file(path)
        if got != want[sp].get("sha256"):
            raise Refusal("dataset hash mismatch for %s: file %s != manifest %s" % (sp, got, want[sp].get("sha256")))
        out[sp] = {"path": path, "sha256": got, "manifest_n": want[sp].get("n")}
    return out


def load_tasks(paths):
    tasks = {}
    for p in paths:
        with open(p, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    t = json.loads(line)
                    if t["id"] in tasks:
                        raise Refusal("duplicate task id %r across/within the selected splits" % t["id"])
                    tasks[t["id"]] = t
    return tasks


def classify(rec):
    """-> 'refused' | 'failed_other' | 'malformed' | 'answered'."""
    if not rec.get("ok"):
        code = rec.get("status_code")
        err = (rec.get("error") or "").lower()
        if code in REFUSAL_CODES:
            return "refused"
        if code == 200:  # the gateway answered but the answer could not be parsed (typesafe adapter: ok=False)
            return "malformed"
        if code is None and ("timed out" in err or "timeout" in err):
            return "refused"
        return "failed_other"
    if not rec.get("valid") or rec.get("predicted") is None:
        return "malformed"
    return "answered"


def licence_clean(task, allow):
    prov = task.get("provenance") or {}
    lic = (prov.get("license") or "").strip().lower()
    return (lic in {a.lower() for a in allow} and task.get("expected") is not None
            and not prov.get("exclude_reason"))


def headline_item(task):
    prov = task.get("provenance") or {}
    return task.get("expected") is not None and not prov.get("exclude_reason")


def p_pred(rec):
    probs = rec.get("probs")
    pred = rec.get("predicted")
    if not isinstance(probs, dict) or pred is None or pred not in probs:
        return None
    p = probs[pred]
    if isinstance(p, bool) or not isinstance(p, (int, float)) or not (0.0 <= p <= 1.0):
        return None
    return float(p)


def write_calibration_csv(path, pairs):
    """Never writes below CAL_MIN pairs (idea 2-I04): the guard lives here, not only in the caller."""
    if len(pairs) < CAL_MIN:
        raise ValueError("refusing to write a calibration CSV with %d < %d pairs" % (len(pairs), CAL_MIN))
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["p_pred", "correct"])
        for p, c in pairs:
            w.writerow(["%.6f" % p, 1 if c else 0])


def summarize(tasks, records, run_dir, commit, datasets, allow, harness_rc=0, harness_override=False,
              unparseable=0):
    by_id = {}
    dups = 0
    for r in records:
        tid = r.get("task_id")
        if tid not in tasks:
            raise Refusal("result for unknown task id %r (results do not match the datasets)" % tid)
        if tid in by_id:
            dups += 1
        by_id[tid] = r
    stop_codes = sorted({r.get("status_code") for r in by_id.values() if r.get("status_code") in ACCESS_STOP_CODES})
    counts = {"n": 0, "answered": 0, "refused": 0, "malformed": 0, "failed_other": 0,
              "correct": 0, "wrong": 0, "excluded_from_headline": 0}
    refused_by = {}
    served, expected_all, labels_n, pairs = set(), [], [], []
    for tid, rec in by_id.items():
        task = tasks[tid]
        if rec.get("model"):
            served.add(rec["model"])
        if not headline_item(task):
            counts["excluded_from_headline"] += 1
            continue
        counts["n"] += 1
        expected_all.append(task["expected"])
        labels_n.append(len(task.get("labels") or []) or 1)
        kind = classify(rec)
        if kind == "refused":
            counts["refused"] += 1
            key = str(rec.get("status_code") if rec.get("status_code") is not None else "timeout")
            refused_by[key] = refused_by.get(key, 0) + 1
        elif kind == "malformed":
            counts["malformed"] += 1
        elif kind == "failed_other":
            counts["failed_other"] += 1
        else:
            counts["answered"] += 1
            ok = bool(rec.get("correct"))
            if ok:
                counts["correct"] += 1
            else:
                counts["wrong"] += 1
            if licence_clean(task, allow):
                p = p_pred(rec)
                if p is not None:
                    pairs.append((p, ok))
    n, ans, k = counts["n"], counts["answered"], counts["correct"]
    lo_all, hi_all = stats.wilson(k, n)
    lo_ans, hi_ans = stats.wilson(k, ans)
    _, maj = stats.majority(expected_all)
    chance = (sum(1.0 / m for m in labels_n) / len(labels_n)) if labels_n else 0.0
    baseline = max(maj, chance)
    summary = {
        "tier": TIER, "contamination": CONTAMINATION, "official_score": False,
        "jevbench_commit": commit,
        "datasets": {s: {"sha256": d["sha256"], "manifest_n": d["manifest_n"]} for s, d in datasets.items()},
        "served_model": (sorted(served)[0] if len(served) == 1 else None),
        "served_models": sorted(served),
        "counts": counts, "refused_by_status": refused_by,
        "planned": len([t for t in tasks.values()]), "attempted": len(by_id),
        "complete": len(by_id) == len(tasks) and not dups and not unparseable, "harness_rc": harness_rc,
        "harness_override": bool(harness_override),
        "results_unparseable_lines": unparseable, "results_duplicate_ids": dups,
        "access_stop": ({"status_codes": stop_codes,
                         "note": "the upstream harness stops the run after a 401/403/429 answer; remaining items unattempted"}
                        if stop_codes else None),
        "accuracy_all": {"value": (k / n) if n else None, "wilson_low": lo_all, "wilson_high": hi_all,
                         "note": "correct / scored items; refusals and malformed count as not-correct here"},
        "accuracy_answered": {"value": (k / ans) if ans else None, "wilson_low": lo_ans, "wilson_high": hi_ans,
                              "note": "correct / answered; refusals and malformed excluded from the denominator"},
        "baseline": {"majority_share": maj, "chance": chance, "used": baseline},
        "verdict_lower_exceeds_baseline": bool(n and stats.lower_exceeds_baseline(lo_all, baseline)),
        "licences_allowed": sorted(allow),
        "calibration": "insufficient: %d<%d" % (len(pairs), CAL_MIN),
        "calibration_csv": None,
        "caveat": ("Public-tier JevBench items may be in training data (contamination possible); the easy and hard "
                   "split licences are UNCONFIRMED; this is not an official score."),
    }
    if len(pairs) >= CAL_MIN:
        csv_path = os.path.join(run_dir, "calibration.csv")
        write_calibration_csv(csv_path, pairs)
        summary["calibration"] = "ok: %d licence-clean answered items" % len(pairs)
        summary["calibration_csv"] = "calibration.csv"
    return summary


EVIDENCE_README = """# JevBench public tier - evidence ({profile})

* tier: public-tier, contamination: possible, official_score: false. Not a leaderboard number.
* Tracked here: item ids with a status (correct / wrong / refused / malformed / failed) and aggregates only.
* NOT tracked here: item text (state), raw gateway responses, calibration CSV. They stay outside git (the run directory) unless EVERY item involved is MIT-licensed.
  The harness and the 72 original public items are MIT; the licences of the easy/hard splits are UNCONFIRMED; sealed items are not downloadable.
* Provenance asserted by the run: jevbench commit {commit}; dataset sha256 equal to upstream datasets/manifest.json.
* Calibration: {calibration}.
"""


def write_evidence(evidence_dir, profile, summary, tasks, records):
    os.makedirs(evidence_dir, exist_ok=True)
    with open(os.path.join(evidence_dir, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2, sort_keys=True)
    with open(os.path.join(evidence_dir, "items.jsonl"), "w", encoding="utf-8") as fh:
        for r in records:
            task = tasks.get(r.get("task_id"), {})
            kind = classify(r)
            status = ("correct" if r.get("correct") else "wrong") if kind == "answered" else kind
            fh.write(json.dumps({"id": r.get("task_id"), "status": status}, sort_keys=True) + "\n")
    with open(os.path.join(evidence_dir, "README.md"), "w", encoding="utf-8") as fh:
        fh.write(EVIDENCE_README.format(profile=profile, commit=summary["jevbench_commit"],
                                        calibration=summary["calibration"]))


def build_harness_cmd(args, tasks_arg, results, raw_dir, ledger):
    base = shlex.split(args.harness_cmd) if args.harness_cmd else [sys.executable, "-E", "-s", "-m", "jevbench.cli"]
    cmd = base + ["run", "--tasks", tasks_arg, "--adapter", "typesafe", "--endpoint", args.endpoint,
                  "--key-env", args.key_env, "--model", args.model, "--results", results,
                  "--raw-dir", raw_dir, "--ledger", ledger, "--cap-usd", str(args.cap_usd),
                  "--price-in-per-m", "0", "--price-out-per-m", "0",
                  "--cost-basis", "local_llmctl_gateway", "--delay-s", str(args.delay_s)]
    if args.limit:
        cmd += ["--limit", str(args.limit)]
    return cmd


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--public-tier", action="store_true", help="MANDATORY acknowledgement: public tier, contamination possible, not official")
    ap.add_argument("--jevbench-dir", required=True, help="checkout of fstandhartinger/jevbench (outside this repo)")
    ap.add_argument("--expect-commit", required=True, help="full 40-hex commit the checkout must be at")
    ap.add_argument("--splits", default=",".join(DEFAULT_SPLITS), help="comma list of datasets/public/<split>.jsonl (default original)")
    ap.add_argument("--run-dir", required=True, help="fresh output dir (results.jsonl is created exclusively); keep outside git")
    ap.add_argument("--endpoint", help="gateway base URL (http(s)://host:port)")
    ap.add_argument("--model", help="profile / model name sent to the gateway")
    ap.add_argument("--key-env", default="LLMCTL_API_KEY")
    ap.add_argument("--ssl-cert-file", help="CA bundle for an HTTPS gateway with a private CA (child process only)")
    ap.add_argument("--allow-licence", action="append", dest="licences", help="repeatable; default MIT")
    ap.add_argument("--cap-usd", type=float, default=1.0)
    ap.add_argument("--delay-s", type=float, default=0.0)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--harness-cmd", help="override of the harness launcher (default: python -m jevbench.cli); tests only")
    ap.add_argument("--evidence-dir", help="write ids + aggregates only (+ README) here, e.g. specs/009-jev-decision-models/evidence/jevbench/<profile>/")
    ap.add_argument("--profile", default=None, help="profile label for the evidence README (default --model)")
    ap.add_argument("--verify-only", action="store_true", help="check commit + dataset hashes and exit; runs nothing, needs no key")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        if not args.public_tier:
            raise Refusal("--public-tier is mandatory: this run is public-tier, contamination possible, never an official score")
        splits = [s.strip() for s in args.splits.split(",") if s.strip()]
        if not splits:
            raise Refusal("no splits given")
        for lic in (args.licences or []):
            if not lic or not lic.strip():
                raise Refusal("--allow-licence must not be empty (an empty entry would match items without a licence)")
        repo = os.path.realpath(args.jevbench_dir)
        run_dir = os.path.realpath(args.run_dir)
        if run_dir == repo or run_dir.startswith(repo + os.sep):
            raise Refusal("--run-dir must be outside the jevbench checkout (the harness refuses raw data inside it)")
        commit = check_commit(repo, args.expect_commit)
        datasets = check_datasets(repo, splits)
        if args.verify_only:
            print(json.dumps({"jevbench_commit": commit, "datasets": {s: d["sha256"] for s, d in datasets.items()}}, sort_keys=True))
            return 0
        if not args.endpoint or not args.model:
            raise Refusal("--endpoint and --model are required to run")
        if not os.environ.get(args.key_env):
            raise Refusal("environment variable %s (--key-env) is empty" % args.key_env)
        results = os.path.join(run_dir, "results.jsonl")
        if os.path.exists(results):
            raise Refusal("%s already exists; use a fresh --run-dir (the harness never overwrites results)" % results)
        os.makedirs(run_dir, exist_ok=True)
        raw_dir = os.path.join(run_dir, "raw")
        ledger = os.path.join(run_dir, "ledger.jsonl")
        tasks = load_tasks([d["path"] for d in datasets.values()])
        cmd = build_harness_cmd(args, ",".join(d["path"] for d in datasets.values()), results, raw_dir, ledger)
        env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}   # no inherited import path for the child
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if args.ssl_cert_file:
            env["SSL_CERT_FILE"] = args.ssl_cert_file                       # the child only; os.environ is untouched
        proc = subprocess.run(cmd, cwd=repo, env=env)
        records, unparseable = [], 0
        if os.path.exists(results):
            with open(results, encoding="utf-8") as fh:
                for line in fh:
                    if not line.strip():
                        continue
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        unparseable += 1
                        continue
                    if isinstance(rec, dict):
                        records.append(rec)
                    else:
                        unparseable += 1
        if not records:
            print("jevbench_adapter: the harness produced no results (rc=%d)" % proc.returncode, file=sys.stderr)
            return 1
        if args.limit:
            tasks = dict(list(tasks.items())[:args.limit])
        summary = summarize(tasks, records, run_dir, commit, datasets, args.licences or DEFAULT_LICENCES, proc.returncode,
                            harness_override=bool(args.harness_cmd), unparseable=unparseable)
        with open(os.path.join(run_dir, "summary.json"), "w", encoding="utf-8") as fh:
            json.dump(summary, fh, indent=2, sort_keys=True)
        if args.evidence_dir:
            write_evidence(args.evidence_dir, args.profile or args.model, summary, tasks, records)
        print("jevbench_adapter: %s n=%d answered=%d refused=%d malformed=%d correct=%d calibration=%s -> %s" % (
            TIER, summary["counts"]["n"], summary["counts"]["answered"], summary["counts"]["refused"],
            summary["counts"]["malformed"], summary["counts"]["correct"], summary["calibration"],
            os.path.join(run_dir, "summary.json")))
        if proc.returncode not in (0, 3):
            return 1
        # 3 = the run was cut short: items unattempted, unreadable / duplicate result lines, or an access /
        # rate-limit answer (401/403/429) stopped the harness (even when that answer was the last item).
        return 0 if (summary["complete"] and not summary["access_stop"]) else 3
    except Refusal as e:
        print("jevbench_adapter: REFUSED: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
