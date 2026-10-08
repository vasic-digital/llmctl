#!/usr/bin/env python3
"""bash_line_coverage.py - zero-tooling bash LINE coverage (Constitution 11.4.224(E)).

Subcommands
  executable FILE...     print the executable-line classification of bash files
  collect --fifo F --out HITS.json [--root R] [--target T ...]
                         read `+COV:` xtrace records from a FIFO until SIGTERM, then
                         write {abs_path: [hit_lines]} (only files under --root)
  report --hits H.json --out R.json FILE...
                         executed/executable per file + per-function breakdown

Method: executed lines (from `bash -x` with PS4='+COV:${PWD}:${BASH_SOURCE}:${LINENO}:')
divided by executable lines (non-blank, non-comment lines that bash can emit a trace
record for). HONEST LIMITS: this is LINE coverage, not branch coverage (a same-line
if/else counts covered with one arm never taken); `set +x` regions and traps are
unaccounted; the executable-line set is a documented heuristic (keyword-only lines,
case patterns, function headers, heredoc bodies, continuation/quoted-string lines are
not counted; hits on continuation lines are credited to the statement's first line).
"""
import argparse
import json
import os
import re
import select
import signal
import sys

KEYWORD_ONLY = {"fi", "done", "esac", "else", "then", "do", "{", "}", ";;", ";&", ";;&", "(", ")"}
REST_OK = re.compile(r"^(?:$|[<>|;)&#]|\d+[<>])")
HEREDOC = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
FUNC_HDR = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_:.\-]*)\s*(?:\(\))?\s*\{?\s*(?:#.*)?$")
FUNC_DEF = re.compile(r"^(\s*)(?:function\s+)?([A-Za-z_][A-Za-z0-9_:.\-]*)\s*\(\)\s*\{\s*(?:#.*)?$")
FUNC_KW = re.compile(r"^(\s*)function\s+([A-Za-z_][A-Za-z0-9_:.\-]*)\s*(?:\(\))?\s*\{\s*(?:#.*)?$")
CASE_PAT = re.compile(r"^\(?[^\s()]+(?:\s*\|\s*[^\s()]+)*\)(?P<rest>.*)$")


def scan_line(line, in_sq, in_dq):
    """Return (code_without_comment, in_sq, in_dq, ends_with_backslash)."""
    out = []
    i, n = 0, len(line)
    cont = False
    while i < n:
        c = line[i]
        if in_sq:
            out.append(c)
            if c == "'":
                in_sq = False
        elif in_dq:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(line[i + 1])
                i += 1
            elif c == '"':
                in_dq = False
        else:
            if c == "\\":
                if i + 1 >= n:
                    cont = True
                else:
                    out.append(c)
                    out.append(line[i + 1])
                    i += 1
            elif c == "'":
                in_sq = True
                out.append(c)
            elif c == '"':
                in_dq = True
                out.append(c)
            elif c == "#" and (i == 0 or line[i - 1] in " \t;&|(") :
                break
            else:
                out.append(c)
        i += 1
    return "".join(out), in_sq, in_dq, cont


def classify(path):
    """Return (executable:set[int], owner:dict[int,int], nlines:int, warnings:list)."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    executable, owner, warnings = set(), {}, []
    in_sq = in_dq = False
    heredoc_end = None
    heredoc_dash = False
    cont_prev = False
    stmt_start = None
    in_array = False
    for idx, raw in enumerate(lines, 1):
        if heredoc_end is not None:
            owner[idx] = stmt_start
            cmp = raw.lstrip("\t") if heredoc_dash else raw
            if cmp == heredoc_end:
                heredoc_end = None
            continue
        if in_array:
            owner[idx] = stmt_start
            if raw.strip().startswith(")"):
                in_array = False
            continue
        was_quoted = in_sq or in_dq
        code, in_sq, in_dq, cont = scan_line(raw, in_sq, in_dq)
        stripped = code.strip()
        if was_quoted or cont_prev:
            cont_prev = cont
            if stmt_start is not None:
                owner[idx] = stmt_start
            continue
        cont_prev = cont
        if not stripped:
            continue
        first, _, rest = stripped.partition(" ")
        rest = rest.strip()
        if first in KEYWORD_ONLY or re.match(r"^(\}|\)|fi|done|esac)\b", first):
            tok = re.match(r"^(\}|\)|fi|done|esac|else|then|do|\{|;;&?|;&|\()", stripped)
            tail = stripped[len(tok.group(1)):].strip() if tok else rest
            if not tail or REST_OK.match(tail) or tok.group(1) in ("}", ")", "fi", "done", "esac"):
                continue
        if FUNC_DEF.match(code) or FUNC_KW.match(code):
            continue
        m = CASE_PAT.match(stripped)
        if m and not stripped.startswith("$(") and not re.match(r"^\w+=", stripped):
            if not m.group("rest").strip() or REST_OK.match(m.group("rest").strip()):
                continue
        executable.add(idx)
        stmt_start = idx
        h = HEREDOC.search(code)
        if h:
            heredoc_end = h.group(2)
            heredoc_dash = "<<-" in code[h.start():h.end()]
        elif stripped.endswith("=(") :
            in_array = True
    if in_sq or in_dq:
        warnings.append("unterminated quote at EOF (classifier desync possible)")
    return executable, owner, len(lines), warnings


def functions(path):
    """[(name, start, end)] by `name() {` ... first `}` at the same indent."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    out = []
    for i, raw in enumerate(lines, 1):
        m = FUNC_DEF.match(raw) or FUNC_KW.match(raw)
        if not m:
            continue
        indent = m.group(1)
        end = i
        for j in range(i, len(lines)):
            if lines[j].rstrip() == indent + "}":
                end = j + 1
                break
        out.append((m.group(2), i, end))
    return out


def cmd_executable(args):
    for f in args.files:
        ex, owner, n, warn = classify(f)
        print("%s: %d executable of %d lines %s" % (f, len(ex), n, warn or ""))
        if args.lines:
            print(" ".join(str(x) for x in sorted(ex)))
    return 0


TRACE = re.compile(rb"\++COV:([^:\n]*):([^:\n]*):(\d+):")


def cmd_collect(args):
    root = os.path.realpath(args.root)
    targets = None
    if args.target:
        targets = {os.path.realpath(t) for t in args.target}
    fd = os.open(args.fifo, os.O_RDWR)
    hits = {}
    stop = {"v": False}
    cache = {}

    def on_term(signum, frame):
        stop["v"] = True

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    buf = b""

    def feed(data):
        nonlocal buf
        buf += data
        parts = buf.split(b"\n")
        buf = parts.pop()
        for ln in parts:
            m = TRACE.match(ln)
            if not m:
                continue
            cwd, src, lineno = m.group(1), m.group(2), int(m.group(3))
            key = (cwd, src)
            p = cache.get(key)
            if p is None:
                s = src.decode("utf-8", "replace")
                c = cwd.decode("utf-8", "replace")
                if not s:
                    p = ""
                else:
                    p = os.path.realpath(s if os.path.isabs(s) else os.path.join(c, s))
                    if not p.startswith(root + os.sep) or (targets is not None and p not in targets):
                        p = ""
                cache[key] = p
            if p:
                hits.setdefault(p, set()).add(lineno)

    while True:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            data = os.read(fd, 1 << 16)
            if data:
                feed(data)
            continue
        if stop["v"]:
            break
    with open(args.out, "w") as fh:
        json.dump({k: sorted(v) for k, v in hits.items()}, fh)
    return 0


def cmd_report(args):
    with open(args.hits) as fh:
        hits = {os.path.realpath(k): set(v) for k, v in json.load(fh).items()}
    result = {}
    for f in args.files:
        rp = os.path.realpath(f)
        ex, owner, n, warn = classify(f)
        raw_hits = hits.get(rp, set())
        covered, stray = set(), []
        for ln in raw_hits:
            if ln in ex:
                covered.add(ln)
            elif ln in owner and owner[ln] in ex:
                covered.add(owner[ln])
            else:
                stray.append(ln)  # traced line the classifier calls non-executable (classifier-gap diagnostic)
        funcs = []
        for name, s, e in functions(f):
            fex = {x for x in ex if s < x < e}
            fcov = fex & covered
            funcs.append({"name": name, "start": s, "end": e,
                          "executable": len(fex), "covered": len(fcov),
                          "uncovered": len(fex) - len(fcov)})
        result[f] = {"executable": len(ex), "covered": len(covered),
                     "uncovered_lines": sorted(ex - covered), "functions": funcs,
                     "stray_hits": sorted(stray), "raw_hit_lines": len(raw_hits), "warnings": warn, "had_any_hit": bool(raw_hits)}
    with open(args.out, "w") as fh:
        json.dump(result, fh, indent=1)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("executable")
    p.add_argument("files", nargs="+")
    p.add_argument("--lines", action="store_true")
    p.set_defaults(fn=cmd_executable)
    p = sub.add_parser("collect")
    p.add_argument("--fifo", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--root", required=True)
    p.add_argument("--target", action="append")
    p.set_defaults(fn=cmd_collect)
    p = sub.add_parser("report")
    p.add_argument("--hits", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("files", nargs="+")
    p.set_defaults(fn=cmd_report)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
