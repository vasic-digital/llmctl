#!/usr/bin/env python3
"""make_report.py - render COVERAGE-REPORT.md from the raw stage outputs of report.sh.

Inputs (all optional; a missing stage is reported as NOT MEASURED, never as 0 or 100):
  <work>/go-root.out go-llmctld.out + *.func.txt   Go coverprofiles + `go tool cover -func`
  <work>/bash-report.json bash-targets.txt suites.tsv   bash line coverage + suite results
  <work>/py-cov.json                                coverage.py JSON
  tests/coverage_exclusions.txt                     CHECKED-IN exclusion list (validated here)
Coverage is MEASURED AND REPORTED ONLY (operator decision OD-15) - nothing here gates.
"""
import argparse
import collections
import datetime
import fnmatch
import glob
import json
import os
import re
import sys

CLASSES = {"generated-code", "vendored-third-party", "non-shipping-fixtures-and-golden-assets"}
FLOOR = 85.0
MOD = "github.com/vasic-digital/llmctl/"


def load_exclusions(path):
    ex = []
    with open(path) as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) != 4 or parts[0] not in CLASSES or not parts[1] or not parts[2]:
                sys.exit("make_report: %s:%d malformed exclusion (class must be one of %s, glob and reason required): %r"
                         % (path, n, sorted(CLASSES), line))
            ex.append(dict(cls=parts[0], glob=parts[1], reason=parts[2], tracked=parts[3], used=0))
    return ex


def excluded(ex, rel):
    for e in ex:
        if fnmatch.fnmatch(rel, e["glob"]):
            e["used"] += 1
            return True
    return False


def pct(c, t):
    return 100.0 * c / t if t else 0.0


# ---------------------------------------------------------------- Go
def go_funcs(functxt):
    """{relfile: [(startline, name)]} from `go tool cover -func` output."""
    out = collections.defaultdict(list)
    if not os.path.exists(functxt):
        return out
    for ln in open(functxt):
        m = re.match(r"^(\S+?):(\d+):\s+(\S+)\s+([\d.]+)%", ln)
        if m:
            out[m.group(1).replace(MOD, "")].append((int(m.group(2)), m.group(3)))
    for v in out.values():
        v.sort()
    return out


def go_stage(work, ex):
    res = {}
    for label, prof in (("root", "go-root.out"), ("llmctld", "go-llmctld.out")):
        p = os.path.join(work, prof)
        if not os.path.exists(p):
            continue
        funcs = go_funcs(os.path.join(work, prof.replace(".out", ".func.txt")))
        files = collections.defaultdict(lambda: [0, 0])
        fn = collections.defaultdict(lambda: [0, 0])
        for ln in open(p):
            m = re.match(r"^(.+?):(\d+)\.\d+,\d+\.\d+ (\d+) (\d+)$", ln)
            if not m:
                continue
            rel = m.group(1).replace(MOD, "")
            if label == "llmctld" and not rel.startswith("llmctld/"):
                rel = "llmctld/" + rel
            if excluded(ex, rel):
                continue
            n, c = int(m.group(3)), int(m.group(4))
            files[rel][0] += n
            files[rel][1] += n if c > 0 else 0
            start = int(m.group(2))
            name = None
            for s, nm in funcs.get(rel, []):
                if s <= start:
                    name = (s, nm)
            if name:
                k = (rel, name[1], name[0])
                fn[k][0] += n
                fn[k][1] += n if c > 0 else 0
        res[label] = dict(files=files, funcs=fn)
    return res


# ---------------------------------------------------------------- render helpers
def table(rows, header):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(x) for x in r) + " |")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--exclusions", required=True)
    ap.add_argument("--elapsed", default="?")
    a = ap.parse_args()
    ex = load_exclusions(a.exclusions)
    L = []
    below = []  # (lang, name, pct, detail)
    summary = {}

    L += ["# llmctl code-coverage report", "",
          "| Field | Value |", "|---|---|",
          "| Generated (UTC) | %s |" % datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
          "| Producer | `scripts/coverage/report.sh` (+ `make_report.py`), run took %ss |" % a.elapsed,
          "| Policy | Constitution 11.4.224; operator decision OD-15: **measure and report only, no gate** |",
          "| Floor | %.0f%% is a MINIMUM ON A PROXY (11.4.224(B)/(C)); a number here never proves the code correct |" % FLOOR, ""]

    # ---- Go
    go = go_stage(a.work, ex)
    L += ["## Go (statement coverage, `go test -coverprofile`)", ""]
    if not go:
        L += ["NOT MEASURED: no Go profile was produced.", ""]
    gtot = [0, 0]
    for label, d in sorted(go.items()):
        title = "root module (`github.com/vasic-digital/llmctl`)" if label == "root" else "llmctld module (unit packages; `test/integration` NOT run)"
        pk = collections.defaultdict(lambda: [0, 0])
        for f, (n, c) in d["files"].items():
            pk[os.path.dirname(f)][0] += n
            pk[os.path.dirname(f)][1] += c
        tn = sum(v[0] for v in pk.values())
        tc = sum(v[1] for v in pk.values())
        gtot[0] += tn
        gtot[1] += tc
        L += ["### %s - total %.1f%% (%d/%d statements)" % (title, pct(tc, tn), tc, tn), ""]
        L += table([(p, "%.1f%%" % pct(c, n), "%d/%d" % (c, n)) for p, (n, c) in sorted(pk.items())], ["package", "coverage", "covered/stmts"])
        L += ["", "Files below %.0f%% (%s):" % (FLOOR, label), ""]
        rows = []
        for f, (n, c) in sorted(d["files"].items()):
            if n and pct(c, n) < FLOOR:
                rows.append((f, "%.1f%%" % pct(c, n), "%d/%d" % (c, n)))
                below.append(("go", f, pct(c, n), "%d/%d stmts" % (c, n)))
        L += (table(rows, ["file", "coverage", "covered/stmts"]) if rows else ["(none)"]) + [""]
        fl = sorted(((n - c, f, nm, s, n, c) for (f, nm, s), (n, c) in d["funcs"].items() if n - c > 0), reverse=True)[:15]
        L += ["Largest uncovered functions (%s) - follow-up candidates, no tests written now:" % label, ""]
        L += table([(f, nm, "%d" % (n - c), "%.0f%%" % pct(c, n)) for _, f, nm, s, n, c in fl], ["file", "function", "uncovered stmts", "func coverage"]) + [""]
    if go:
        summary["go"] = "%.1f%% (%d/%d statements, root + llmctld unit packages)" % (pct(gtot[1], gtot[0]), gtot[1], gtot[0])

    # ---- bash
    L += ["## Bash (LINE coverage via PS4 xtrace, zero tooling)", ""]
    bp = os.path.join(a.work, "bash-report.json")
    if not os.path.exists(bp):
        L += ["NOT MEASURED: the bash stage did not run.", ""]
    else:
        rep = json.load(open(bp))
        rows, nm_rows, funcs = [], [], []
        te = tc = 0
        stray = rawh = 0
        for f, r in sorted(rep.items()):
            rel = os.path.relpath(f, a.root)
            if excluded(ex, rel):
                continue
            if not r["had_any_hit"]:
                nm_rows.append((rel, r["executable"]))
                continue
            te += r["executable"]
            tc += r["covered"]
            stray += len(r.get("stray_hits", []))
            rawh += r.get("raw_hit_lines", 0)
            p = pct(r["covered"], r["executable"])
            rows.append((rel, "%.1f%%" % p, "%d/%d" % (r["covered"], r["executable"])))
            if p < FLOOR:
                below.append(("bash", rel, p, "%d/%d lines" % (r["covered"], r["executable"])))
            for fn in r["functions"]:
                if fn["uncovered"]:
                    funcs.append((fn["uncovered"], rel, fn["name"], fn["executable"], fn["covered"]))
        L += ["Total over measured files: **%.1f%% (%d/%d executable lines)**." % (pct(tc, te), tc, te), ""]
        summary["bash"] = "%.1f%% (%d/%d lines, %d measured files; %d files NOT measured)" % (pct(tc, te), tc, te, len(rows), len(nm_rows))
        L += table(rows, ["file", "line coverage", "covered/executable"]) + [""]
        L += ["Classifier self-check: %d of %d distinct traced (file,line) records fell on lines the heuristic calls non-executable and were not credited to a statement start (%.2f%%; 0 = the executable-line heuristic never disagreed with what bash actually traced)." % (stray, rawh, pct(stray, rawh)), ""]
        L += ["### Files NOT measured (no included suite executed a single line of them)", ""]
        L += (table(nm_rows, ["file", "executable lines"]) if nm_rows else ["(none)"]) + ["",
              "These are exercised only by the suites listed as EXCLUDED/NOT-RUN below (podman, systemd service, GPU, "
              "engine-build and Go-mutation suites). Reporting them as 0% would be as false as reporting 100%: they are unmeasured.", ""]
        funcs.sort(reverse=True)
        L += ["### Largest uncovered bash functions (follow-up candidates)", ""]
        L += table([(rel, n, u, "%d/%d" % (c, e)) for u, rel, n, e, c in funcs[:15]], ["file", "function", "uncovered lines", "covered/executable"]) + [""]
        sp = os.path.join(a.work, "suites.tsv")
        if os.path.exists(sp):
            L += ["### Suites run under the tracer", ""]
            srows = []
            for ln in open(sp):
                p = ln.rstrip("\n").split("\t")
                if len(p) >= 4:
                    srows.append((p[0], p[1], p[2] + "s", p[3]))
            L += table(srows, ["suite", "result / status", "wall time", "note / reason"]) + [""]
            L += ["`rc=0` = suite exited 0 (a `SKIP-SUITE:` note means it skipped itself). A non-zero rc under the tracer is reported, not hidden: "
                  "tracing (and the blocked `systemctl`/`podman`/`docker`/`launchctl`/`loginctl` safety stubs, see `bash-blocked-calls.log`) can change a suite's outcome; "
                  "its lines still count as executed.", ""]

    # ---- python
    L += ["## Python (coverage.py in a scratch venv)", ""]
    pp = os.path.join(a.work, "py-cov.json")
    if not os.path.exists(pp):
        L += ["NOT MEASURED: the python stage did not run or produced no data.", ""]
    else:
        data = json.load(open(pp))["files"]
        rows, ts, tcov = [], 0, 0
        for f, d in sorted(data.items()):
            rel = os.path.relpath(f, a.root)
            if excluded(ex, rel):
                continue
            s = d["summary"]
            ts += s["num_statements"]
            tcov += s["covered_lines"]
            p = s["percent_covered"]
            rows.append((rel, "%.1f%%" % p, "%d/%d" % (s["covered_lines"], s["num_statements"])))
            if p < FLOOR:
                below.append(("python", rel, p, "%d/%d stmts" % (s["covered_lines"], s["num_statements"])))
        L += ["Total: **%.1f%% (%d/%d statements)**." % (pct(tcov, ts), tcov, ts), ""]
        summary["python"] = "%.1f%% (%d/%d statements)" % (pct(tcov, ts), tcov, ts)
        L += table(rows, ["file", "coverage", "covered/statements"]) + [""]
        L += ["Measured from the `tests/py` unit tier plus python subprocesses spawned by the included bash suites (`.pth` + `COVERAGE_PROCESS_START`). "
              "Files under the listed source dirs that no run imported appear as 0%.", ""]

    # ---- summary / below floor / exclusions / limits
    idx = L.index("## Go (statement coverage, `go test -coverprofile`)")
    head = ["## Headline numbers", ""] + table([(k, v) for k, v in summary.items()], ["language", "measured coverage"]) + [""]
    L[idx:idx] = head
    L += ["## Files below the %.0f%% floor (all languages)" % FLOOR, "",
          "The floor of 11.4.224(B) is a NECESSARY condition and a MINIMUM ON A PROXY; it is reported here for visibility only (no gate, OD-15).", ""]
    L += (table([(l, f, "%.1f%%" % p, d) for l, f, p, d in sorted(below, key=lambda x: (x[0], x[2]))], ["lang", "file", "coverage", "detail"]) if below else ["(none)"]) + [""]
    L += ["## Exclusion list applied (`tests/coverage_exclusions.txt`, checked in)", ""]
    L += table([(e["cls"], "`%s`" % e["glob"], e["reason"], e["tracked"], "%d" % e["used"]) for e in ex], ["class", "glob", "reason", "tracked item", "paths dropped"]) + ["",
          "Anything not listed above and not in a stage's `NOT MEASURED` section is inside the measured corpus. No first-party shipping code is excluded.", ""]
    L += ["## Instrument limits (honest boundary, 11.4.6 / 11.4.224(C)(E))", "",
          "- **Go**: statement coverage from the toolchain; only unit packages ran. `llmctld/test/integration` (~400 s) was NOT run, so packages it alone exercises are under-reported. "
          "Statement coverage is not branch coverage and says nothing about assertion strength: an assertion-free test raises it identically to a proving one.",
          "- **Bash**: LINE coverage, not branch coverage - a same-line `if/else` counts covered with one arm never taken. `set +x` regions and traps are unaccounted. "
          "The executable-line set is a documented heuristic (keyword-only lines, case patterns, function headers, heredoc bodies and continuation/quoted-string lines are not counted; hits on continuation lines are credited to the statement start). "
          "Only bash processes that inherit `BASH_ENV` are traced: a suite that runs `env -i`, `sh`/`dash` scripts, or a hook that resets the environment is invisible. Suites run under 3-10x xtrace overhead and a 600 s per-suite timeout.",
          "- **Python**: coverage.py line coverage only (no `--branch`); subprocess data merged via a `.pth` startup hook inside the scratch venv.",
          "- Coverage is **necessary, never sufficient**: nothing in this report proves any code correct; the real bar remains catch-its-own-negation (paired mutations) and captured runtime evidence.",
          "- The per-corpus calibration of the 85% threshold and the brownfield adoption policy are operator decisions and are NOT made here.", ""]
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "COVERAGE-REPORT.md"), "w") as fh:
        fh.write("\n".join(L) + "\n")
    with open(os.path.join(a.out, "coverage-summary.json"), "w") as fh:
        json.dump({"summary": summary, "below_floor": [dict(lang=l, file=f, pct=round(p, 1), detail=d) for l, f, p, d in below]}, fh, indent=1)
    print("wrote", os.path.join(a.out, "COVERAGE-REPORT.md"))


if __name__ == "__main__":
    main()
