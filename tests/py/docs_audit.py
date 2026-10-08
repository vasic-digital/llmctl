#!/usr/bin/env python3
"""docs_audit.py - documentation audit (SC-009, T121). Driven by tests/test_docs_audit.sh.

Rules (each reports how many items it EXAMINED, so a zero is never silent):
  links   relative markdown links in README.md and docs/**.md must resolve to a file or directory
  ports   docs/ports.md table == models/catalog.json `ports`; `profile NNNN` mentions elsewhere must match the catalog
  counts  "<N> decide profiles", "<N> profiles", "<N> CLI agents" must equal what the repo actually contains
  code    LLMCTL_* variables named in the docs must exist in the code; `llmctl decide <sub>` must be a real subcommand
  keys    no literal access key (Bearer / --api-key / *API_KEY= / bare 43-char generated-key shape)

Exit: 0 clean, 1 mismatches, 2 BLIND (a rule examined nothing, so its clean result would prove nothing).
Historical logs (CONTINUATION, plan, progress, initial request, research, qa) are dated records, not live claims: skipped.
"""
import json
import os
import re
import sys

HISTORICAL = ("docs/research/", "docs/qa/", "docs/CONTINUATION.md", "docs/llmctl_initial_request.md",
              "docs/llmctl_plan.md", "docs/llmctl_progress_status.md")
WORDNUM = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
           "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
           "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "twenty-two": 22}


def num(tok):
    tok = tok.lower()
    return int(tok) if tok.isdigit() else WORDNUM.get(tok)


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def doc_files(root):
    out = []
    for p in ["README.md"]:
        if os.path.isfile(os.path.join(root, p)):
            out.append(p)
    for d, _, fs in os.walk(os.path.join(root, "docs")):
        for f in fs:
            if f.endswith(".md"):
                out.append(os.path.relpath(os.path.join(d, f), root))
    return sorted(out)


def prose_lines(text):
    """(lineno, line) outside fenced code blocks."""
    fence = False
    for i, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if not fence:
            yield i, line


def live(rel):
    return not any(rel == h or rel.startswith(h) for h in HISTORICAL)


class Audit:
    def __init__(self, root):
        self.root = root
        self.hits = []
        self.examined = {}

    def seen(self, rule, n=1):
        self.examined[rule] = self.examined.get(rule, 0) + n

    def hit(self, rule, rel, line, msg):
        self.hits.append((rule, rel, line, msg))

    # ---------------------------------------------------------------- links
    def links(self, files):
        rx = re.compile(r"\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
        for rel in files:
            base = os.path.dirname(os.path.join(self.root, rel))
            for ln, line in prose_lines(read(os.path.join(self.root, rel))):
                for m in rx.finditer(line):
                    t = m.group(1)
                    if re.match(r"^[a-z][a-z0-9+.-]*:", t, re.I) or t.startswith("#") or "$" in t or "{" in t:
                        continue
                    t = t.split("#", 1)[0].split("?", 1)[0]
                    if not t:
                        continue
                    self.seen("links")
                    tgt = os.path.normpath(os.path.join(self.root, t.lstrip("/")) if t.startswith("/") else os.path.join(base, t))
                    if not os.path.exists(tgt):
                        self.hit("links", rel, ln, "missing link target: %s" % t)

    # ---------------------------------------------------------------- ports
    def ports(self, files, catalog):
        ports = catalog.get("ports", {})
        pdoc = "docs/ports.md"
        if os.path.isfile(os.path.join(self.root, pdoc)):
            rows = {}
            in_table = False
            for ln, line in prose_lines(read(os.path.join(self.root, pdoc))):
                if rows and in_table and not line.startswith("|"):
                    break  # only the first (profile) table is the catalog mirror; later tables list other ports
                if line.startswith("|"):
                    in_table = True
                m = re.match(r"^\|\s*(\d{4,5})\s*\|\s*`([^`]+)`", line)
                if m:
                    self.seen("ports")
                    port, name = int(m.group(1)), m.group(2)
                    rows[name] = port
                    if name not in ports:
                        self.hit("ports", pdoc, ln, "profile %s is not in the catalog" % name)
                    elif ports[name] != port:
                        self.hit("ports", pdoc, ln, "%s documented on %d, catalog says %d" % (name, port, ports[name]))
            for name, port in ports.items():
                if rows and name not in rows:
                    self.hit("ports", pdoc, 0, "catalog profile %s (%d) missing from the table" % (name, port))
        names = sorted(ports, key=len, reverse=True)
        if not names:
            return
        rx = re.compile(r"(?<![\w-])`?(" + "|".join(re.escape(n) for n in names) + r")`?(?![\w-])\)?[ ]*[(:]?[ ]*(\d{4,5})\b")
        for rel in files:
            if rel == pdoc or not live(rel):
                continue
            for ln, line in prose_lines(read(os.path.join(self.root, rel))):
                for m in rx.finditer(line):
                    self.seen("ports")
                    if ports[m.group(1)] != int(m.group(2)):
                        self.hit("ports", rel, ln, "%s documented on %s, catalog says %d" % (m.group(1), m.group(2), ports[m.group(1)]))

    # --------------------------------------------------------------- counts
    def counts(self, files, catalog):
        profiles = catalog.get("profiles", {})
        n_all = len(profiles)
        n_dec = len([p for p in profiles if p.startswith("decide")])
        agents_dir = os.path.join(self.root, "docs", "integrations")
        n_agents = len([f for f in os.listdir(agents_dir) if f.startswith("install_") and f.endswith(".sh")]) if os.path.isdir(agents_dir) else None
        w = r"(\d+|[a-z]+(?:-[a-z]+)?)"
        rules = [
            (re.compile(r"(?<![\w-])" + w + r" (?:decide|decision) profiles", re.I), n_dec, "decide profiles"),
            (re.compile(r"(?:(?:all|every one of the|the)\s+" + w + r"\s+catalog profiles|catalog (?:has|holds|carries|lists|ships)\s+" + w + r"\s+profiles|" + w + r"\s+profiles in the catalog)", re.I), n_all, "catalog profiles"),
            (re.compile(r"(?<!other )(?<![\w-])" + w + r" (?:supported )?CLI agents", re.I), n_agents, "CLI agents"),
        ]
        for rel in files:
            if not live(rel):
                continue
            for ln, line in prose_lines(read(os.path.join(self.root, rel))):
                for i, (rx, want, label) in enumerate(rules):
                    for m in rx.finditer(line):
                        tok = next(g for g in m.groups() if g)
                        n = num(tok)
                        if n is None or want is None:
                            continue
                        self.seen("counts")
                        if n != want:
                            self.hit("counts", rel, ln, "says %s %s, repository has %d" % (tok, label, want))

    # ----------------------------------------------------------------- code
    def code(self, files, catalog_profiles=()):
        corpus = []
        for d in ("lib", "bin", "scripts", "cmd", "internal", "models", "templates", "tests", "docs/integrations"):
            for dp, _, fs in os.walk(os.path.join(self.root, d)):
                for f in fs:
                    if f.endswith((".sh", ".go", ".py", ".json", ".service", ".tmpl", ".env", ".example", "")) or "." not in f:
                        try:
                            corpus.append(read(os.path.join(dp, f)))
                        except OSError:
                            pass
        for f in ("llmctl", "install.sh", "Makefile"):
            if os.path.isfile(os.path.join(self.root, f)):
                corpus.append(read(os.path.join(self.root, f)))
        blob = "\n".join(corpus)
        rx = re.compile(r"\bLLMCTL_[A-Z0-9_]*[A-Z0-9](?![A-Za-z0-9_<*{])")
        subs = set()
        dec = os.path.join(self.root, "lib", "decide.sh")
        if os.path.isfile(dec):
            t = read(dec)
            m = re.search(r"cmd_decide\(\)\s*\{(.*?)\n\}", t, re.S)
            if m:
                subs |= set(re.findall(r"^\s{4}([a-z][a-z0-9|-]*)\)", m.group(1), re.M))
                subs = {s for a in subs for s in a.split("|")}
            m = re.search(r'_DECIDE_FORWARDED="([^"]*)"', t)
            if m:
                subs |= set(m.group(1).split())
        prof_up = {re.sub(r"[-.]", "_", p).upper() for p in catalog_profiles}
        sub_rx = re.compile(r"\bllmctl decide ([a-z][a-z-]*)\b")
        for rel in files:
            if not live(rel):
                continue
            for ln, line in prose_lines(read(os.path.join(self.root, rel))):
                for m in rx.finditer(line):
                    self.seen("code")
                    var = m.group(0)
                    derived = re.match(r"^(LLMCTL_(?:PORT|BIND_HOST))_(.+)$", var)
                    if derived and derived.group(2) in prof_up and derived.group(1) + "_" in blob:
                        continue  # per-profile override built at run time from the profile name
                    if var not in blob:
                        self.hit("code", rel, ln, "%s is documented but no code mentions it" % m.group(0))
                if subs:
                    for m in sub_rx.finditer(line):
                        if m.group(1) in ("the", "is", "a", "and", "or", "to", "with", "for", "in", "on", "as", "can", "does", "will", "has", "uses"):
                            continue
                        self.seen("code")
                        if m.group(1) not in subs:
                            self.hit("code", rel, ln, "`llmctl decide %s` is not a decide subcommand" % m.group(1))

    # ----------------------------------------------------------------- keys
    def keys(self, files):
        ok_start = ("$", "<", "{", "[", "...", "…")
        pats = [("bearer", re.compile(r"Authorization:\s*Bearer\s+([^\s\"'`)\\]+)", re.I)),
                ("cli-key", re.compile(r"(?<![\w-])(?:--(?:openai-|anthropic-)?api-key|--key)(?:\s+|=)([^\s\"'`)\\]+)")),
                ("assign", re.compile(r"\b[A-Z][A-Z0-9_]*API_KEY=(\"[^\"]*\"|'[^']*'|[^\s\"'`)\\]*)"))]
        tok = re.compile(r"(?<![A-Za-z0-9_/.-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_/.-])")

        def fine(v):
            v = v.strip().strip("\"'")
            return v == "" or v.startswith(ok_start) or v.startswith(("\"$", "'$", "\"<", "'<")) or len(v) < 16 or v.lower().startswith(("sk-no-key", "no-key", "not-needed"))
        for rel in files:
            self.seen("keys")
            for ln, line in enumerate(read(os.path.join(self.root, rel)).splitlines(), 1):
                for kind, rx in pats:
                    for m in rx.finditer(line):
                        if not fine(m.group(1)):
                            self.hit("keys", rel, ln, "literal key (%s)" % kind)
                for m in tok.finditer(line):
                    t = m.group(0)
                    if any(c.islower() for c in t) and any(c.isupper() for c in t) and any(c.isdigit() for c in t) and not re.fullmatch(r"[0-9a-f]+", t):
                        self.hit("keys", rel, ln, "literal key (token shape)")

    def run(self):
        files = doc_files(self.root)
        lfiles = [f for f in files if live(f)]
        cpath = os.path.join(self.root, "models", "catalog.json")
        catalog = json.load(open(cpath)) if os.path.isfile(cpath) else {}
        self.links(lfiles)
        self.ports(lfiles, catalog)
        self.counts(lfiles, catalog)
        self.code(lfiles, catalog.get("profiles", {}))
        self.keys(files)


def main(argv):
    root = os.getcwd()
    allow_empty = set()
    i = 0
    while i < len(argv):
        if argv[i] == "--root":
            root = argv[i + 1]
            i += 1
        elif argv[i] == "--allow-empty":
            allow_empty.add(argv[i + 1])
            i += 1
        i += 1
    a = Audit(os.path.abspath(root))
    a.run()
    for rule, rel, ln, msg in a.hits:
        print("MISMATCH %s %s:%s %s" % (rule, rel, ln, msg))
    for rule in ("links", "ports", "counts", "code", "keys"):
        print("examined %s=%d" % (rule, a.examined.get(rule, 0)))
    blind = [r for r in ("links", "ports", "counts", "code", "keys") if a.examined.get(r, 0) == 0 and r not in allow_empty]
    if a.hits:
        print("RESULT: %d mismatches" % len(a.hits))
        return 1
    if blind:
        print("RESULT: BLIND rules (examined nothing): %s" % ",".join(blind))
        return 2
    print("RESULT: 0 mismatches")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
