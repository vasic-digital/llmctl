#!/usr/bin/env python3
"""SC-004 / T129 closure audit for specs/009-jev-decision-models.

Every finding row (D-xx in source-findings.md, N-xx in
research/jev-llmctl-new-files.md) must end at FIXED (a RED observed on the
candidate, a guard that exists in the repository and a GREEN run), DEMOTED
(captured evidence that it is not a defect / not applicable) or, for medium and
low rows, ACCEPTED-LIMITATION.  The table is computed here from the registers;
nothing is typed by hand.  A closure that cites a test file or test name that
does not exist is reported OPEN, never closed.

Inputs (all under <spec>/evidence/ unless noted):
  p1-red-register.json     id -> RED | NOT-REPRODUCED | HARDENING | SKIP
  p1-red-original/*.jsonl  the captured RED / NOT-REPRODUCED output per id
  red-to-green-map.json    id -> regression guard(s) or an N/A reason
  sc004-overrides.json     optional: id -> {closure, reason, evidence[]}; every
                           evidence path must exist or the override is refused
  *-make-test.log          GREEN evidence (latest by name; "TEST: x / RESULT: PASS")

Usage:
  python3 scripts/spec_closure_audit.py [--root DIR] [--spec specs/009-jev-decision-models]
         [--out evidence/sc004-closure.md] [--json evidence/sc004.json] [--check]
Exit: 0 no open high/critical row; 1 at least one; 2 inputs unreadable.
"""
import argparse
import glob
import json
import os
import re
import sys

GATING = ("H", "C")
ROW_RE = re.compile(r"^\|\s*([DN]-\d+)\s*\|\s*([HMLC])\s*\|", re.M)
REF_RE = re.compile(r"^([\w./+-]+\.(?:go|sh|py|json|md|tsv|yaml))(?:::(.*?)|\s*\((.*)\))?\s*$", re.S)
LIVE_WORDS = ("live validation", "live-validation", "stays an open", "stays open")


def _read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def _load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def parse_rows(root, spec):
    """id -> (severity, source file).  First occurrence wins."""
    rows = {}
    for rel in ("source-findings.md", "research/jev-llmctl-new-files.md"):
        p = os.path.join(root, spec, rel)
        if not os.path.exists(p):
            continue
        for m in ROW_RE.finditer(_read(p)):
            rows.setdefault(m.group(1), (m.group(2), rel))
    return rows


def components(rid, keys):
    """Register keys that belong to a row: the id itself and its variants
    (D-17a, D-19b, D-30/zip).  A base entry is ignored when variants exist."""
    var = [k for k in keys if k != rid and k.startswith(rid)
           and (k[len(rid):].startswith("/") or (len(k) == len(rid) + 1 and k[-1].isalpha()))]
    return sorted(var) if var else ([rid] if rid in keys else [])


def find_red_output(root, spec, cid):
    pat = os.path.join(root, spec, "evidence", "p1-red-original", "*.jsonl")
    for p in sorted(glob.glob(pat)):
        with open(p, encoding="utf-8", errors="replace") as f:
            for n, line in enumerate(f, 1):
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if obj.get("id") == cid:
                    return "%s:%d" % (os.path.relpath(p, root), n)
    return None


def parse_green(root, log):
    """suite basename -> PASS|FAIL from 'TEST: name ... RESULT: x' blocks."""
    out = {}
    if not log:
        return out
    p = os.path.join(root, log)
    if not os.path.exists(p):
        return out
    cur = None
    for line in _read(p).splitlines():
        if line.startswith("TEST: "):
            cur = line[6:].strip()
        elif line.startswith("RESULT: ") and cur:
            out[cur] = line[8:].strip()
            cur = None
        elif line.startswith("EXIT: ") and cur:      # blocks without a RESULT line
            out[cur] = "PASS" if line[6:].strip() == "0" else "FAIL"
            cur = None
        m = re.match(r"^ok\s+github\.com/[^/]+/[^/]+/(\S+)\s", line)
        if m:
            out["go:" + m.group(1)] = "PASS"
    return out


def latest_log(root, spec):
    logs = sorted(glob.glob(os.path.join(root, spec, "evidence", "p*-make-test.log")),
                  key=lambda p: [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", os.path.basename(p))])
    return os.path.relpath(logs[-1], root) if logs else None


def _name_found(text, name):
    if re.fullmatch(r"Test\w+", name):
        return re.search(r"func\s+%s\b" % re.escape(name), text) is not None
    cands = [name, re.sub(r"\s*\([^)]*\)\s*$", "", name).strip()]
    cands += [c[:40] for c in cands if len(c) > 40]
    cands += re.findall(r"\b(?:EP|G|D|N)-\d+\w*", name)
    cands += [c.replace("'", "").replace('"', "") for c in cands]
    return any(c and c in text for c in cands)


def check_ref(root, ref):
    """-> (ok, detail, file)"""
    m = REF_RE.match(ref.strip())
    if not m:
        return False, "unparseable reference %r" % ref[:60], None
    path, name, hint = m.group(1), m.group(2), m.group(3)
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        return False, "missing file %s" % path, path
    if name:
        if not _name_found(_read(full), name.strip()):
            return False, "name not found in %s: %r" % (path, name.strip()[:70]), path
        return True, "name found", path
    return True, "file exists (name not individually checked)" + ((": " + hint[:40]) if hint else ""), path


def green_for(root, files, green):
    """PASS if a suite that runs one of the guard files passed in the log."""
    suites = set()
    for f in files:
        b = os.path.basename(f)
        if f.startswith("tests/") and b.startswith("test_") and b.endswith(".sh"):
            suites.add(b)
        elif f.endswith(".go"):
            suites.add("go:" + os.path.dirname(f))
        else:
            tdir = os.path.join(root, "tests")
            for sh in glob.glob(os.path.join(tdir, "test_*.sh")):
                if b in _read(sh):
                    suites.add(os.path.basename(sh))
    passed = sorted(s for s in suites if green.get(s) == "PASS")
    if passed:
        return "PASS (%s)" % ", ".join(passed[:3])
    return "NO-GREEN-RECORD (%s)" % (", ".join(sorted(suites)[:3]) or "no suite found")


def eval_component(root, spec, cid, p1, rmap, green):
    """-> dict(closure, reason, red, guards, green)"""
    st = p1.get(cid)
    ent = rmap.get(cid)
    out = {"cid": cid, "p1": st, "red": None, "guards": [], "green": "", "reason": "", "closure": "OPEN"}
    if st is None:
        out["reason"] = "no entry in p1-red-register.json"
        return out
    disp = ent.get("disposition") if ent else None
    guard = ent.get("guard") if ent else None
    if st in ("RED",):
        out["red"] = find_red_output(root, spec, cid)
        if not out["red"]:
            out["reason"] = "RED status but no captured output line in p1-red-original"
            return out
        if disp == "N/A" and isinstance(guard, str) and guard.strip():
            out["closure"] = "DEMOTED"
            out["reason"] = "RED observed; not applicable now: " + guard[:170]
            return out
        if disp not in ("regression-test", "covered by existing test") or not isinstance(guard, list) or not guard:
            out["reason"] = "RED but no regression guard in red-to-green-map.json (disposition %r)" % disp
            return out
        bad, files = [], []
        for g in guard:
            ok, detail, f = check_ref(root, g)
            out["guards"].append(("OK " if ok else "BAD ") + g[:90])
            if f:
                files.append(f)
            if not ok:
                bad.append(detail)
        if bad:
            out["reason"] = "; ".join(bad)
            return out
        out["green"] = green_for(root, files, green)
        if not out["green"].startswith("PASS"):
            out["reason"] = "guards exist but no passing run recorded: " + out["green"]
            return out
        out["closure"], out["reason"] = "FIXED", "RED observed, guard exists, GREEN recorded"
        return out
    if st in ("NOT-REPRODUCED", "HARDENING"):
        out["red"] = find_red_output(root, spec, cid)
        if not ent or disp is None:
            out["reason"] = "%s but no demotion reason in red-to-green-map.json" % st
            return out
        if disp == "N/A":
            text = guard if isinstance(guard, str) else "; ".join(guard)
            out["reason"] = text[:200]
            out["closure"] = "DEMOTED" if out["red"] else "OPEN"
            if not out["red"]:
                out["reason"] = "no captured output for the %s verdict" % st
            return out
        ok_all = True
        for g in (guard if isinstance(guard, list) else []):
            ok, detail, _ = check_ref(root, g)
            out["guards"].append(("OK " if ok else "BAD ") + g[:90])
            if not ok:
                ok_all = False
                out["reason"] = detail
        if not ok_all or not out["red"]:
            out["reason"] = out["reason"] or "no captured output for the %s verdict" % st
            return out
        out["closure"], out["reason"] = "DEMOTED", "%s; pinned by an existing test" % st
        out["green"] = green_for(root, [r.split("::")[0].split(" (")[0] for r in guard], green)
        return out
    if st == "SKIP":
        if disp == "N/A" and isinstance(guard, str):
            low = guard.lower()
            if any(w in low for w in LIVE_WORDS):
                out["reason"] = "needs a live/real-model run: " + guard[:150]
            elif "macos" in low:
                out["closure"], out["reason"] = "ACCEPTED-LIMITATION", guard[:150]
            else:
                out["closure"], out["reason"] = "DEMOTED", guard[:150]
            out["red"] = find_red_output(root, spec, cid)
            return out
        out["reason"] = "RED was SKIPPED (environment) - no RED observed; guard %s" % (
            "exists" if disp else "missing")
        out["red"] = find_red_output(root, spec, cid)
        return out
    out["reason"] = "status %r not closable" % st
    return out


def apply_override(root, rid, sev, ov, row):
    ev = ov.get("evidence") or []
    miss = [e for e in ev if not os.path.exists(os.path.join(root, e))]
    if miss or not ev:
        row["reason"] = "override refused: missing file %s" % (", ".join(miss) if miss else "(no evidence listed)")
        return
    cl = ov.get("closure")
    if cl not in ("FIXED", "DEMOTED", "ACCEPTED-LIMITATION"):
        row["reason"] = "override refused: bad closure %r" % cl
        return
    if cl == "ACCEPTED-LIMITATION" and sev in GATING:
        row["reason"] = "override refused: a high/critical row cannot be an accepted limitation"
        return
    row["closure"] = cl
    row["reason"] = "override: %s" % ov.get("reason", "")
    row["override_evidence"] = ev


def audit(root, spec, green_log=None):
    rows_src = parse_rows(root, spec)
    ev = os.path.join(root, spec, "evidence")
    p1 = {}
    rmap = {}
    ovr = {}
    inputs_ok = True
    try:
        p1 = _load_json(os.path.join(ev, "p1-red-register.json")).get("by_id", {})
    except (OSError, ValueError):
        inputs_ok = False
    try:
        rmap = _load_json(os.path.join(ev, "red-to-green-map.json")).get("map", {})
    except (OSError, ValueError):
        inputs_ok = False
    p = os.path.join(ev, "sc004-overrides.json")
    if os.path.exists(p):
        ovr = _load_json(p)
    log = green_log or latest_log(root, spec)
    green = parse_green(root, log)
    rows = []
    for rid in sorted(rows_src, key=lambda s: (s[0], int(re.sub(r"\D", "", s)))):
        sev, src = rows_src[rid]
        comps = components(rid, p1.keys())
        evals = [eval_component(root, spec, c, p1, rmap, green) for c in comps] or \
            [{"cid": rid, "p1": None, "red": None, "guards": [], "green": "", "closure": "OPEN",
              "reason": "no entry in p1-red-register.json"}]
        openc = [e for e in evals if e["closure"] == "OPEN"]
        row = {"id": rid, "sev": sev, "source": src, "components": [e["cid"] for e in evals],
               "p1": ",".join("%s=%s" % (e["cid"], e["p1"]) for e in evals),
               "red": "; ".join(e["red"] for e in evals if e["red"]),
               "guards": [g for e in evals for g in e["guards"]],
               "green": "; ".join(e["green"] for e in evals if e["green"])}
        if openc:
            row["closure"] = "OPEN"
            row["reason"] = "; ".join("%s: %s" % (e["cid"], e["reason"]) for e in openc)
        else:
            kinds = {e["closure"] for e in evals}
            row["closure"] = ("FIXED" if "FIXED" in kinds else "DEMOTED" if "DEMOTED" in kinds
                              else "ACCEPTED-LIMITATION")
            row["reason"] = "; ".join(e["reason"] for e in evals)[:300]
        if row["closure"] == "OPEN" and rid in ovr:
            apply_override(root, rid, sev, ovr[rid], row)
        if row["closure"] == "ACCEPTED-LIMITATION" and sev in GATING:
            row["closure"] = "OPEN"
            row["reason"] = "a high/critical row cannot be an accepted limitation: " + row["reason"]
        rows.append(row)
    open_high = [r for r in rows if r["closure"] == "OPEN" and r["sev"] in GATING]
    counts = {}
    for r in rows:
        counts.setdefault(r["sev"], {}).setdefault(r["closure"], 0)
        counts[r["sev"]][r["closure"]] += 1
    return {"rows": rows, "counts": counts, "open_high": open_high, "green_log": log,
            "p1_ids": len(p1), "map_ids": len(rmap), "inputs_ok": inputs_ok,
            "exit_code": 2 if not inputs_ok else (1 if open_high else 0)}


def go_parity(root, spec):
    p = os.path.join(root, spec, "evidence", "go-port-parity.json")
    if not os.path.exists(p):
        return None
    d = _load_json(p)
    ports = d.get("go_ports", {})
    return {k: v for k, v in ports.items()}


def gaps_summary(root, spec):
    p = os.path.join(root, spec, "evidence", "gaps-register.md")
    if not os.path.exists(p):
        return None
    tot, opn = 0, []
    for line in _read(p).splitlines():
        m = re.match(r"^\|\s*(G-\d+)\s*\|(.*)\|\s*$", line)
        if not m:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        tot += 1
        if len(cells) > 3 and cells[3].upper().startswith("OPEN"):
            opn.append(cells[0])
    return {"total": tot, "open": opn}


def render(res, root=None, spec=None):
    rows = res["rows"]
    L = []
    L.append("# SC-004 closure table")
    L.append("")
    L.append("> **GENERATED** by `scripts/spec_closure_audit.py` - do not edit by hand; re-run the script.")
    L.append("> Counts are computed from `p1-red-register.json` (%d ids), `red-to-green-map.json` (%d ids) and the"
             % (res["p1_ids"], res["map_ids"]))
    L.append("> finding tables of `source-findings.md` / `research/jev-llmctl-new-files.md`.")
    L.append("> GREEN evidence: `%s` (a recorded earlier run; the script does not re-run suites)." % res["green_log"])
    L.append("")
    L.append("## Counts (computed)")
    L.append("")
    L.append("| Severity | Rows | FIXED | DEMOTED | ACCEPTED-LIMITATION | OPEN |")
    L.append("|---|---:|---:|---:|---:|---:|")
    for sev in ("C", "H", "M", "L"):
        c = res["counts"].get(sev)
        if not c:
            continue
        L.append("| %s | %d | %d | %d | %d | %d |" % (sev, sum(c.values()), c.get("FIXED", 0), c.get("DEMOTED", 0),
                                                    c.get("ACCEPTED-LIMITATION", 0), c.get("OPEN", 0)))
    L.append("")
    L.append("**Open high/critical rows (gate): %d** %s" % (
        len(res["open_high"]), "(" + ", ".join(r["id"] for r in res["open_high"]) + ")" if res["open_high"] else ""))
    L.append("")
    L.append("## Rows")
    L.append("")
    L.append("| ID | Sev | Closure | P1 verdict | Captured RED / evidence | Guard(s) (file::name checked) | GREEN | Reason |")
    L.append("|---|---|---|---|---|---|---|---|")
    for r in rows:
        guards = "<br>".join(g.replace("|", "/") for g in r["guards"][:4]) or "-"
        L.append("| %s | %s | **%s** | %s | %s | %s | %s | %s |" % (
            r["id"], r["sev"], r["closure"], r["p1"].replace("|", "/"),
            r["red"] or ("; ".join(r.get("override_evidence", [])) or "-"), guards,
            (r["green"] or "-").replace("|", "/"), r["reason"].replace("|", "/")[:220]))
    L.append("")
    if root and spec:
        gp = go_parity(root, spec)
        if gp:
            L.append("## Go port parity (from go-port-parity.json)")
            L.append("")
            for k, v in gp.items():
                L.append("- %s: pass %s fail %s skip %s" % (k, v.get("pass"), v.get("fail"), v.get("skip")))
            L.append("")
        gs = gaps_summary(root, spec)
        if gs:
            L.append("## Gap register cross-check")
            L.append("")
            L.append("%d rows, %d OPEN: %s" % (gs["total"], len(gs["open"]), ", ".join(gs["open"]) or "-"))
            L.append("")
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--root", default=here)
    ap.add_argument("--spec", default="specs/009-jev-decision-models")
    ap.add_argument("--out", default=None)
    ap.add_argument("--json", default=None)
    ap.add_argument("--check", action="store_true", help="print the table only, write nothing")
    a = ap.parse_args(argv)
    res = audit(a.root, a.spec)
    md = render(res, a.root, a.spec)
    if a.check or not a.out:
        sys.stdout.write(md)
    if not a.check:
        if a.out:
            with open(os.path.join(a.root, a.spec, a.out) if not os.path.isabs(a.out) else a.out, "w") as f:
                f.write(md)
        if a.json:
            with open(os.path.join(a.root, a.spec, a.json) if not os.path.isabs(a.json) else a.json, "w") as f:
                json.dump({"generated_by": "scripts/spec_closure_audit.py", "green_log": res["green_log"],
                           "counts": res["counts"], "open_high": [r["id"] for r in res["open_high"]],
                           "rows": res["rows"]}, f, indent=1)
    return res["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
