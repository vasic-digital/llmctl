#!/usr/bin/env bash
# test_docs_no_literal_keys.sh - doc-audit rule (idea 1-I09, FR-035): no documentation or template may carry a
# literal access key. Scans docs/ and templates/ for
#   - `Authorization: Bearer <literal>`           (only $VAR / ${VAR} / <placeholder> forms are allowed)
#   - `--api-key <literal>`, `--openai-api-key`, `--key`, `-k`   (same rule)
#   - `...API_KEY=<literal>` assignments           (same rule; an empty value is allowed)
#   - a bare 43-character base64url token that mixes lower/upper/digits (the shape of a generated llmctl key)
# The scanner is itself proven: a control needle of each shape MUST be flagged and a file of allowed forms
# MUST NOT be (a scanner that cannot see a planted key says nothing about the tree).
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }

cat >"${TEST_TMP}/scan.py" <<'PY'
import os, re, sys
TEXT = (".md", ".json", ".sh", ".py", ".js", ".ts", ".txt", ".yaml", ".yml", ".toml", ".env", ".example")
OK_START = ("$", "<", "${", "{", "[", "\"$", "'$", "\"<", "'<", "\"${", "'${", "...", "…")
MIN_LITERAL = 16  # shorter values are placeholders such as K, local, or <key>; a generated key has 43 characters
def ok_value(v):
    v = v.strip().strip("\"'")
    # documented dummy values for local servers that need no key are not secrets
    return v == "" or v.startswith(OK_START) or len(v) < MIN_LITERAL or v.lower().startswith(("sk-no-key", "no-key", "not-needed"))
PATTERNS = [
    ("bearer", re.compile(r"Authorization:\s*Bearer\s+([^\s\"'`)\\]+)", re.I)),
    ("cli-key", re.compile(r"(?<![\w-])(?:--(?:openai-|anthropic-)?api-key|--key|-k)(?:\s+|=)([^\s\"'`)\\]+|\"[^\"]*\"|'[^']*')")),
    ("assign", re.compile(r"\b[A-Z][A-Z0-9_]*API_KEY=(\"[^\"]*\"|'[^']*'|[^\s\"'`)\\]*)")),
]
TOKEN = re.compile(r"(?<![A-Za-z0-9_/.-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_/.-])")
def looks_like_key(t):
    return any(c.islower() for c in t) and any(c.isupper() for c in t) and any(c.isdigit() for c in t) and not re.fullmatch(r"[0-9a-f]+", t)
def scan_text(name, text):
    hits = []
    for i, line in enumerate(text.splitlines(), 1):
        for kind, rx in PATTERNS:
            for m in rx.finditer(line):
                if not ok_value(m.group(1)):
                    hits.append((name, i, kind))
        for m in TOKEN.finditer(line):
            if looks_like_key(m.group(0)):
                hits.append((name, i, "token"))
    return hits
def scan_tree(root):
    hits = []
    for d, _, files in os.walk(root):
        for f in files:
            if f.endswith(TEXT):
                p = os.path.join(d, f)
                try:
                    hits += scan_text(p, open(p, encoding="utf-8", errors="replace").read())
                except OSError:
                    pass
    return hits
if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "needles":
        bad = ['curl -H "Authorization: Bearer abcDEF123456789xyz" https://h', 'aider --openai-api-key sk-abc123def456ghi789 x',
               'cline -k abcDEF123456789xyz -y', 'export OPENAI_API_KEY=abcDEF123456789xyz0', "LLMCTL_API_KEY='abcDEF123456789xyz0'",
               'the key is Zq3vN8mP1xR5tY7uI9oL2kJ4hG6fD0sAaBbCcDdEeFf below']
        good = ['curl -H "Authorization: Bearer $LLMCTL_API_KEY" https://h', 'curl -H "Authorization: Bearer ${LLMCTL_API_KEY}" x',
                'aider --openai-api-key "$LLMCTL_API_KEY"', 'tool --api-key <your key>', 'export LLMCTL_API_KEY=', 'export OPENAI_API_KEY="$X"',
                'sha256 ' + 'ab' * 32, 'https://example.com/' + 'AbC1' * 10 + 'xyz', 'LLMCTL_API_KEY=$(cat file)']
        missed = [b for b in bad if not scan_text("needle", b)]
        flagged = [g for g in good if scan_text("needle", g)]
        print("missed=%d flagged=%d" % (len(missed), len(flagged)))
        for m in missed: print("MISSED:", m)
        for g in flagged: print("FALSE-POSITIVE:", g)
        sys.exit(1 if missed or flagged else 0)
    hits = []
    for root in sys.argv[2:]:
        hits += scan_tree(root)
    for h in hits: print("%s:%d: literal key shape (%s)" % h)
    print("hits=%d" % len(hits))
    sys.exit(1 if hits else 0)
PY
rc=0; out="$(python3 "${TEST_TMP}/scan.py" needles 2>&1)" || rc=$?
assert_eq 0 "${rc}" "control needles: every planted key shape is flagged, no allowed form is"
assert_contains "${out}" "missed=0 flagged=0" "the scanner sees all planted shapes and no allowed form"

mkdir -p "${TEST_TMP}/planted"
printf 'run: curl -H "Authorization: Bearer abcDEF123456789xyz" https://gw\n' >"${TEST_TMP}/planted/x.md"
rc=0; python3 "${TEST_TMP}/scan.py" tree "${TEST_TMP}/planted" >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "a planted key in a scanned tree fails the scan"
# shellcheck disable=SC2016  # the literal $VAR is the point
printf 'run: curl -H "Authorization: Bearer $LLMCTL_API_KEY" https://gw\n' >"${TEST_TMP}/planted/x.md"
rc=0; python3 "${TEST_TMP}/scan.py" tree "${TEST_TMP}/planted" >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "the same line with an environment reference passes"

rc=0; out="$(python3 "${TEST_TMP}/scan.py" tree "${LLMCTL_ROOT}/docs" "${LLMCTL_ROOT}/templates" 2>&1)" || rc=$?
printf '%s\n' "${out}" | tail -n 15 | sed 's/^/    /'
assert_eq 0 "${rc}" "docs/ and templates/ carry no literal key"
for a in opencode pi crush claude-code aider continue cline; do
  assert_file_exists "${LLMCTL_ROOT}/docs/agents/${a}.md" "docs/agents/${a}.md exists (and is inside the scanned tree)"
done
test_finish
