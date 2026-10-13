#!/usr/bin/env python3
"""Static lint: a generated PATH shim must not invoke, by bare name, a command that is also a shim name in the same directory.

Incident 2026-10-13: a shim `tr` whose body ran `tr ...` re-executed itself (PATH resolves the bare name to the shim) and
forked ~6,000 processes.  This scans shell files for shims written by here-document (`cat >DIR/NAME <<TAG`) or `printf '...' >DIR/NAME`
(a `# SHIM-LINT-OK: <reason>` comment on or above the writing line exempts a deliberate fixture)
and reports every line of a shim body that runs NAME, or a sibling shim written to the same DIR text, at command position
without an absolute path.  Usage: lint_shim_self_recursion.py FILE...   exit 1 if any finding.
"""
import re
import sys

HEREDOC = re.compile(r'''cat\s*>>?\s*(?P<tgt>"[^"]+"|'[^']+'|\S+)\s*<<-?\s*(?P<q>['"]?)(?P<tag>\w+)(?P=q)''')
PRINTF = re.compile(r'''printf\s+(?P<fmt>'(?:[^']|\\')*'|"(?:[^"\\]|\\.)*")(?P<rest>.*?)>>?\s*(?P<tgt>"[^"]+"|'[^']+'|[^\s;&|]+)''')


def split_target(tgt):
    tgt = tgt.strip('"\'')
    if '/' not in tgt:
        return None, tgt
    d, n = tgt.rsplit('/', 1)
    return d, n


def exempt(lines, i):
    """a deliberate fixture: `# SHIM-LINT-OK: <reason>` on the writing line or the line above"""
    return 'SHIM-LINT-OK:' in lines[i] or (i > 0 and 'SHIM-LINT-OK:' in lines[i - 1])


def shims_in(text):
    """yield (dir, name, body, first_lineno)"""
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = HEREDOC.search(ln)
        if m:
            d, n = split_target(m.group('tgt'))
            tag, body, j = m.group('tag'), [], i + 1
            while j < len(lines) and lines[j].strip() != tag:
                body.append(lines[j]); j += 1
            if d is not None and not exempt(lines, i) and re.fullmatch(r'[A-Za-z0-9_.+-]+', n) and body and body[0].startswith('#!'):
                yield d, n, body, i + 2
            i = j + 1
            continue
        m = PRINTF.search(ln)
        if m:
            d, n = split_target(m.group('tgt'))
            fmt = m.group('fmt')[1:-1].replace('\\n', '\n').replace('\\t', '\t')
            if d is not None and not exempt(lines, i) and re.fullmatch(r'[A-Za-z0-9_.+-]+', n) and fmt.startswith('#!'):
                yield d, n, fmt.split('\n'), i + 1
        i += 1


def strip_comment(line):
    return re.sub(r'(^|\s)#.*$', '', line) if not line.startswith('#!') else ''


def bare_calls(body_line, names):
    """names invoked at command position without a path (line start, after ; & | ( ` $( && ||, or after then/do/else/!)"""
    hits = []
    for nm in names:
        pat = r'(?:^|[;&|(`]|\$\(|\b(?:then|do|else|elif|if|while|until)\b|!)\s*' + re.escape(nm) + r'(?=\s|$|;|\)|`|&|\|)(?!\s*\))'
        if re.search(pat, body_line):
            hits.append(nm)
    return hits


def main(paths):
    findings = 0
    for path in paths:
        try:
            text = open(path, encoding='utf-8', errors='replace').read()
        except OSError as e:
            print(f'{path}: unreadable: {e}', file=sys.stderr); findings += 1; continue
        shims = list(shims_in(text))
        by_dir = {}
        for d, n, body, ln in shims:
            by_dir.setdefault(d, set()).add(n)
        for d, n, body, ln in shims:
            siblings = by_dir[d]
            for k, bl in enumerate(body):
                code = strip_comment(bl)
                if not code.strip():
                    continue
                for nm in bare_calls(code, siblings):
                    kind = 'itself' if nm == n else f'sibling shim `{nm}`'
                    print(f'{path}:{ln + k}: shim `{n}` ({d}) calls {kind} by bare name -> PATH resolves to the shim: {bl.strip()}')
                    findings += 1
    print(f'shim-lint: files={len(paths)} findings={findings}')
    return 1 if findings else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
