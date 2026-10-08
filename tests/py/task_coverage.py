#!/usr/bin/env python3
"""task_coverage.py - T121 coverage instruments for specs/<feature>/.

  fr-sc  every FR-nnn / SC-nnn DEFINED in spec.md must be CITED by tasks.md
  rows   every ADOPT / ADOPT-AFTER-VERIFICATION idea id in research/ideas-closure.md must be CITED by tasks.md

Exit: 0 all covered | 1 gaps (listed, one per line, GAP <id>) | 2 BLIND (the instrument could not see the
inputs: no definitions found / files missing). A blind instrument never reports "clean" (a null from an
instrument that cannot see says nothing). The output always states `examined defined=<n> cited=<m>` so
a caller can prove the instrument saw something.

Citation forms understood in tasks.md: `FR-012`, ranges `FR-038..043` / `FR-038..FR-043` and a trailing
comma list of bare numbers after an FR/SC token (`FR-066..068, 087` = FR-066..068 and FR-087).
"""
import argparse
import os
import re
import sys

TOKEN = re.compile(r"\b(FR|SC)-(\d+)(?:\s*(?:\.\.|–|—)\s*(?:(?:FR|SC)-)?(\d+))?")
TAIL = re.compile(r"\s*,\s*(\d+)(?:\s*(?:\.\.|–|—)\s*(\d+))?")
DEF = re.compile(r"^\s*[-*]\s+\*\*(FR|SC)-(\d+)\*\*")


def defined_ids(spec_text):
    out = set()
    for ln in spec_text.splitlines():
        m = DEF.match(ln)
        if m:
            out.add("%s-%s" % (m.group(1), m.group(2)))
    return out


def cited_ids(tasks_text):
    out = set()
    for m in TOKEN.finditer(tasks_text):
        kind, a, b = m.group(1), m.group(2), m.group(3)
        width = len(a)
        lo = int(a)
        hi = int(b) if b else lo
        for n in range(lo, hi + 1):
            out.add("%s-%0*d" % (kind, width, n))
        pos = m.end()
        while True:
            t = TAIL.match(tasks_text, pos)
            if not t:
                break
            lo2 = int(t.group(1))
            hi2 = int(t.group(2)) if t.group(2) else lo2
            for n in range(lo2, hi2 + 1):
                out.add("%s-%0*d" % (kind, width, n))
            pos = t.end()
    return out


ROW = re.compile(r"^\|\s*(\d+-I\d+)\s*\|(.*)$")


def adopt_ids(closure_text):
    ids = []
    for ln in closure_text.splitlines():
        m = ROW.match(ln)
        if not m:
            continue
        cells = [c.strip() for c in m.group(2).split("|")]
        disp = cells[1] if len(cells) > 1 else ""
        if re.match(r"ADOPT(-AFTER-VERIFICATION)?\b(?!-LATER)", disp):
            ids.append(m.group(1))
    return ids


def cites_row(tasks_text, rid):
    return re.search(r"(?<![\d-])%s(?!\d)" % re.escape(rid), tasks_text) is not None


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=("fr-sc", "rows"))
    ap.add_argument("--specdir", required=True)
    a = ap.parse_args()
    tasks = read(os.path.join(a.specdir, "tasks.md"))
    if tasks is None:
        print("BLIND: tasks.md not readable under %s" % a.specdir)
        return 2
    if a.mode == "fr-sc":
        spec = read(os.path.join(a.specdir, "spec.md"))
        if spec is None:
            print("BLIND: spec.md not readable under %s" % a.specdir)
            return 2
        defined = defined_ids(spec)
        if not defined:
            print("BLIND: no FR-/SC- definitions found in spec.md")
            return 2
        cited = cited_ids(tasks)
        gaps = sorted(defined - cited)
        print("examined defined=%d cited=%d" % (len(defined), len(defined & cited)))
    else:
        clos = read(os.path.join(a.specdir, "research", "ideas-closure.md"))
        if clos is None:
            print("BLIND: research/ideas-closure.md not readable under %s" % a.specdir)
            return 2
        ids = adopt_ids(clos)
        if not ids:
            print("BLIND: no ADOPT rows found in ideas-closure.md")
            return 2
        gaps = sorted(i for i in ids if not cites_row(tasks, i))
        print("examined defined=%d cited=%d" % (len(ids), len(ids) - len(gaps)))
    for g in gaps:
        print("GAP %s" % g)
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main())
