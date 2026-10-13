#!/usr/bin/env python3
"""Static lint: a generated PATH shim must not invoke, by bare name, a command that is also a shim name in the same directory.

Incident 2026-10-13: a shim `tr` whose body ran `tr ...` re-executed itself (PATH resolves the bare name to the shim) and
forked ~6,000 processes.  This scans shell files (and python / Go test files, see below) for shims written by:
  * here-document            cat >DIR/NAME <<TAG ... TAG      and      cat <<TAG | tee DIR/NAME
  * printf / echo literal    printf '#!/bin/sh\\n...' >DIR/NAME     (one line)
  * brace group              { echo '#!/bin/sh'; echo '...'; } >DIR/NAME   (one line or several)
  * loop writers             for t in tr sed; do printf '#!/bin/sh\\n%s "$@"\\n' "$t" >"$B/$t"; done
Shim NAME is the last path segment of the target (a target without '/', e.g. `>"tr"`, is accepted); a target whose name is a
loop variable takes the loop's names; any other dynamic name (`>"${STUB}"`) is UNRESOLVED: the body cannot be checked and the
site is counted as such.  A body line is flagged when it runs NAME or a sibling shim written to the same DIR text (or, for a
loop writer, ANY of the loop's names) at command position without a path, also behind the wrappers exec env command nice
xargs time timeout sudo nohup builtin stdbuf (`command -v X` is a probe, not a call).
A `# SHIM-LINT-OK: <reason>` comment on or above the writing line exempts a deliberate fixture.
Go test files: every `os.WriteFile(..., []byte("#!/..."), ...)` site is counted; its `filepath.Join(dir, "name")` literal name
is taken, and every string literal of the file is checked for a bare call of that name.  Those Go shims are executed by absolute
path (a variable), never via PATH; the lint says so and cannot see a script built from non-literals.
python files: shebang string-literal sites are counted and reported as NOT checked (no safe static form).
Usage: lint_shim_self_recursion.py [-v] FILE...   exit 1 if any finding.  Prints a coverage line with honest counts.
"""
import re
import sys

NAME_RE = re.compile(r'[A-Za-z0-9_.+-]+')
HEREDOC = re.compile(r'''cat\s*>>?\s*(?P<tgt>"[^"]+"|'[^']+'|[^\s<;&|]+)\s*<<-?\s*(?P<q>['"]?)(?P<tag>\w+)(?P=q)''')
HEREDOC_TEE = re.compile(r'''<<-?\s*(?P<q>['"]?)(?P<tag>\w+)(?P=q)\s*\|\s*tee\s+(?:-a\s+)?(?P<tgt>"[^"]+"|'[^']+'|[^\s;&|]+)''')
REDIR = re.compile(r'''(?:(?<![0-9&<>])>>?(?!&)|\|\s*tee\s+(?:-a\s+)?)\s*(?P<tgt>"[^"]+"|'[^']+'|[^\s;&|<>]+)''')
LIT = re.compile(r'''(?:echo|printf)\s+(?:-\w+\s+)*(?P<lit>'(?:[^']|'\\'')*'|"(?:[^"\\]|\\.)*")''')
FOR = re.compile(r'''for\s+(?P<var>\w+)\s+in\s+(?P<vals>[^;]+);\s*do''')
WRAP = r'(?:(?:exec|env|command|nice|xargs|time|timeout|sudo|nohup|builtin|stdbuf)\b(?:\s+-[-\w=.,]*|\s+\d+[smh]?|\s+\w+=\S*)*\s+)*'
SHEBANG_LIT = re.compile(r'''['"`]#!\s*/''')


class Site:
    def __init__(self, kind, lineno, dirkey, names, body):
        self.kind, self.lineno, self.dirkey, self.names, self.body = kind, lineno, dirkey, names, body


def split_target(tgt):
    tgt = tgt.strip('"\'')
    if '/' not in tgt:
        return '', tgt
    d, n = tgt.rsplit('/', 1)
    return d, n


def loop_names(lines, i, seg):
    """names a dynamic basename `$var`/`${var}` takes from an enclosing `for var in ...; do` within 4 lines above (or on) line i"""
    m = re.fullmatch(r'\$\{?(\w+)\}?', seg)
    if not m:
        return None
    for j in range(i, max(-1, i - 5), -1):
        f = FOR.search(lines[j])
        if f and f.group('var') == m.group(1):
            vals = [v.strip('"\'') for v in f.group('vals').split()]
            vals = [v for v in vals if NAME_RE.fullmatch(v)]
            return vals or None
    return None


def resolve(lines, i, tgt):
    d, n = split_target(tgt)
    if NAME_RE.fullmatch(n):
        return d, [n]
    return d, loop_names(lines, i, n)


def unescape(lit):
    s = lit[1:-1]
    return s.replace('\\n', '\n').replace('\\t', '\t')


def exempt(lines, i):
    return 'SHIM-LINT-OK:' in lines[i] or (i > 0 and 'SHIM-LINT-OK:' in lines[i - 1])


def sites_in(text):
    """return (sites, claimed line indexes, lines)"""
    lines = text.split('\n')
    sites, claimed, data = [], set(), set()
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = HEREDOC.search(ln) or HEREDOC_TEE.search(ln)
        if not m:
            m = re.search(r'<<-?\s*(?P<q>[\'"]?)(?P<tag>\w+)(?P=q)', ln)       # any other heredoc: its body is data, not code
            if m and 'tgt' not in m.groupdict():
                tag, j = m.group('tag'), i + 1
                while j < len(lines) and lines[j].strip() != tag:
                    data.add(j); j += 1
                i = j + 1
                continue
            m = None
        if m:
            tag, body, j = m.group('tag'), [], i + 1
            while j < len(lines) and lines[j].strip() != tag:
                body.append(lines[j]); data.add(j); j += 1
            if body and body[0].startswith('#!'):
                claimed.add(i)
                if not exempt(lines, i):
                    d, names = resolve(lines, i, m.group('tgt'))
                    sites.append(Site('heredoc', i + 2, d, names, body))
            i = j + 1
            continue
        i += 1
    # single-line printf/echo/brace-group writers, and multi-line brace groups
    for i, ln in enumerate(lines):
        brace_end = re.match(r'^\s*\}\s*>', ln) is not None
        if i in claimed or i in data or not (SHEBANG_LIT.search(ln) or brace_end):
            continue
        if ln.strip().startswith('#'):
            continue
        start = None
        if brace_end:                                  # multi-line brace group: gather up to 40 lines back to its '{'
            r = REDIR.search(ln)
            for j in range(i - 1, max(-1, i - 40), -1):
                if lines[j].strip() == '{' or lines[j].rstrip().endswith('{') or lines[j].lstrip().startswith('{ '):
                    start = j; break
            seg = '\n'.join(lines[start:i]) if start is not None else ''
            matches = list(LIT.finditer(seg))
        else:
            matches = list(LIT.finditer(ln))
            r = REDIR.search(ln, matches[-1].end()) if matches else None
            seg = ln
        if not r or not matches:
            continue
        lits = [unescape(x.group('lit')) for x in matches]
        if not lits or not lits[0].lstrip().startswith('#!'):
            continue
        claimed.add(i)
        if brace_end and start is not None:
            claimed.update(j for j in range(start, i) if SHEBANG_LIT.search(lines[j]))
        if exempt(lines, i):
            continue
        d, names = resolve(lines, i, r.group('tgt'))
        sites.append(Site('literal', i + 1, d, names, '\n'.join(lits).split('\n')))
    return sites, claimed, data, lines


def strip_comment(line):
    return re.sub(r'(^|\s)#.*$', '', line) if not line.startswith('#!') else ''


def bare_calls(code, names):
    """names invoked at command position without a path (line start, after ; & | ( ` $( && ||, after then/do/else/!), also
    behind wrappers (exec env command nice xargs time timeout sudo nohup ...)"""
    code = re.sub(r'\bcommand\s+-[vV]\b\s*\S*', '', code)
    hits = []
    for nm in names:
        pat = (r'(?:^|[;&|(`]|\$\(|\b(?:then|do|else|elif|if|while|until)\b|!)\s*' + WRAP + re.escape(nm)
               + r'(?=\s|$|;|\)|`|&|\|)(?!\s*\))')
        if re.search(pat, code):
            hits.append(nm)
    return hits


def check_sites(path, sites, out):
    by_dir = {}
    for s in sites:
        by_dir.setdefault(s.dirkey, set()).update(s.names or [])
    findings = checked = unresolved = 0
    for s in sites:
        if not s.names:
            unresolved += 1
            continue
        checked += 1
        union = by_dir[s.dirkey]
        for k, bl in enumerate(s.body):
            code = strip_comment(bl)
            if not code.strip():
                continue
            variants = [code.replace('%s', n) for n in s.names] if '%s' in code else [code]   # loop writer: one body per name
            hit = []
            for v in variants:
                for nm in bare_calls(v, union):
                    if nm not in hit:
                        hit.append(nm)
            for nm in hit:
                if nm in s.names and len(s.names) == 1:
                    kind = 'itself'
                elif nm in s.names:
                    kind = 'a name of its own loop'
                else:
                    kind = 'sibling shim'
                out.append(f'{path}:{s.lineno + k}: shim `{"/".join(s.names)}` (dir `{s.dirkey}`) calls {kind} `{nm}` by bare name '
                           f'-> PATH resolves to the shim: {bl.strip()}')
                findings += 1
    return findings, checked, unresolved


GO_WRITE = re.compile(r'''WriteFile\(.*\[\]byte\(\s*(?:"#!|`#!)''')
GO_JOIN = re.compile(r'''filepath\.Join\([^,\n]+,\s*"(?P<name>[A-Za-z0-9_.+-]+)"\s*\)''')
GO_STR = re.compile(r'''"(?:[^"\\\n]|\\.)*"|`[^`]*`''')


def check_go(path, text, out):
    lines = text.split('\n')
    sites, names = 0, set()
    for i, ln in enumerate(lines):
        if not GO_WRITE.search(ln):
            continue
        sites += 1
        for j in range(i, max(-1, i - 6), -1):      # the Join that named the file, a few lines above
            g = GO_JOIN.search(lines[j])
            if g:
                names.add(g.group('name')); break
    findings = 0
    for nm in sorted(names):
        for m in GO_STR.finditer(text):
            lit = m.group(0)[1:-1].replace('\\n', '\n')
            if lit == nm:
                continue
            for bl in lit.split('\n'):
                if bare_calls(strip_comment(bl), [nm]):
                    out.append(f'{path}: Go shim `{nm}`: a script literal calls it by bare name: {bl.strip()[:100]}')
                    findings += 1
    return sites, findings


def main(argv):
    verbose = '-v' in argv
    paths = [a for a in argv if a != '-v']
    out = []
    tot = dict(files=0, sh_sites=0, recognised=0, checked=0, unresolved=0, go_sites=0, py_sites=0, findings=0)
    missed = []
    for path in paths:
        try:
            text = open(path, encoding='utf-8', errors='replace').read()
        except OSError as e:
            out.append(f'{path}: unreadable: {e}'); tot['findings'] += 1; continue
        tot['files'] += 1
        if path.endswith('.go'):
            n, f = check_go(path, text, out)
            tot['go_sites'] += n; tot['findings'] += f
            continue
        if path.endswith('.py'):
            tot['py_sites'] += sum(1 for l in text.split('\n')[1:] if SHEBANG_LIT.search(l) and not l.strip().startswith('#'))
            continue
        sites, claimed, data, lines = sites_in(text)
        seen = set(claimed)       # every shebang-writing site: a heredoc whose first body line is a shebang, or a quoted '#!/' literal
        for i, l in enumerate(lines):
            if i == 0 or i in data or l.strip().startswith('#'):
                continue
            if SHEBANG_LIT.search(l) and not re.search(r'grep|\[\[|case |assert_|=~|sed -n', l):
                seen.add(i)
        tot['sh_sites'] += len(seen)
        tot['recognised'] += len(seen & claimed)
        for i in sorted(seen - claimed):
            missed.append(f'{path}:{i + 1}: {lines[i].strip()[:110]}')
        f, c, u = check_sites(path, sites, out)
        tot['findings'] += f; tot['checked'] += c; tot['unresolved'] += u
    for o in out:
        print(o)
    if verbose:
        for m in missed:
            print('not-recognised:', m)
    print('shim-lint: files=%(files)d sh-shebang-sites=%(sh_sites)d recognised=%(recognised)d (name-resolved+checked=%(checked)d, '
          'name-unresolved=%(unresolved)d) go-shim-sites=%(go_sites)d (executed by absolute path; literal-name check only) '
          'python-shebang-literals=%(py_sites)d (NOT checked) findings=%(findings)d' % tot)
    return 1 if tot['findings'] else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
