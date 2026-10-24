#!/usr/bin/env python3
"""validate_judge.py - deterministic model validation runner + judge for llmctl (stdlib only).

Sends the known-answer prompts of a validation suite to a model's OpenAI-compatible endpoint
(llama-server) with deterministic sampling (temperature 0, fixed seed, top_k 1, no prompt cache) and
judges every answer DETERMINISTICALLY: normalised substring / ordered-substring / forbidden-substring /
first-number / regex / JSON-subset checks taken from the suite file. There is no LLM-as-judge.

Suite kinds:
  vision     validation/suites/<suite>/expectations.json + PNG fixtures (image + prompt -> answer)
  chat|coder validation/suites/<suite>/suite.json (text prompt -> answer)
  embedding  validation/suites/<suite>/suite.json (anchor/positive/negative cosine ordering)
  decide     validation/suites/<suite>/suite.json (typed choice question -> exact choice, asked through the production
             Go driver: `llmctl-decide smoke --question-file`)

Anti-bluff structure of every run (any one of these failing makes the run non-PASS):
  1. suite integrity: every fixture file's sha256 equals the value recorded in the suite file
  2. judge self-test: canned answers with a known verdict (judge_controls) are judged FIRST; a judge that
     passes a known-wrong answer (or fails a known-right one) is broken -> exit 1 before any request
  3. model identity: GET /v1/models must report the catalog model file (or the run is UNDETERMINED)
  4. every probe needs a REAL, COMPLETE answer from the endpoint; no answer is UNDETERMINED, never PASS. An
     answer cut off by the token budget (finish_reason=length) or empty content with reasoning content is
     UNDETERMINED too (a budget problem, not a wrong answer); a complete wrong or genuinely empty answer FAILs
  5. golden-bad controls (vision): a control image answered with a golden probe's prompt MUST fail that
     golden probe's checks; if it passes, the validator does not discriminate -> exit 1
  6. determinism: every judged probe is asked LLMCTL_VALIDATE_REPEAT times (default 3, Constitution 11.4.50); all answers must be
     byte-identical. 1 is the quick mode (only determinism_repeat, once more): never a decision-bearing run, never recorded
  0. before all of these, the suite schema: an empty / unknown / uncompilable check, or a probe without a canned PASS and a canned
     FAIL judge control, is a SuiteDefect (UNDETERMINED)
  3b. local runs: the model file of the PROCESS that answers (cmdline, /v1/models path, /props) must be the profile's file
Records (`key` / `record` / `check`): the real sha256 of every model file, the catalog pins, the machine id (hashed), the run's evidence
sha256, an HMAC-SHA256 signature - see docs/validation.md "Records".

Exit codes: 0 every check passed; 1 any wrong result (or a broken judge/undiscriminating control);
            2 could not determine (endpoint down, no answer, wrong model served, corrupt suite, ...).
A wrong result outranks could-not-determine (1 beats 2).

Usage:
  validate_judge.py run --suite DIR --endpoint URL [--expect-model NAME] [--expect-model-path PATH] [--json] [--evidence FILE]
  validate_judge.py key|record|check|coverage ...   (validation records; called by lib/validate.sh)
  validate_judge.py selftest --suite DIR
  validate_judge.py hash --suite DIR
"""
import argparse
import base64
import hashlib
import ipaddress
import json
import math
import os
import re
import signal
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

MAX_RESPONSE_BYTES = 8 * 1024 * 1024   # a model reply is a few KB; anything larger is not one
CLOCK_SKEW_SECONDS = 60   # a validation record stamped further ahead than this is rejected

NUMBER_WORDS = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
    "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
    "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
}
TENS_WORDS = {"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90}


# --- normalisation + checks (the deterministic judge) -----------------------------------------------------
class SuiteDefect(ValueError):
    """The suite itself is unusable (an empty / unknown / uncompilable check, a probe without a prompt, a probe without
    canned PASS and FAIL controls ...). Never a verdict on a model: the run is UNDETERMINED (exit 2) before any request."""


def fold(text):
    """Unicode folding BEFORE any case mapping (finding 4 of the 2026-10-15 review: str.upper() turned the dotless 'Parıs'
    and the long-s 'Pariſ' into PARIS). NFKC (fullwidth '３' -> '3'); every Unicode decimal digit -> its ASCII digit
    ('٣' -> '3'); typographic apostrophes -> "'"; every remaining NON-ASCII letter -> a space, so it can never be read as
    an ASCII letter. Other symbols are kept (they are separators for the checks)."""
    out = []
    for ch in "" if text is None else str(text):          # per character: NFKC must not map 'ſ' to 's' first
        if ch.isascii():
            out.append(ch)
        elif unicodedata.category(ch) == "Nd":
            out.append(str(unicodedata.digit(ch)))
        elif ch in "\u2018\u2019\u02bc\u2032":
            out.append("'")
        elif "\uff01" <= ch <= "\uff5e":                    # fullwidth ASCII forms: the same characters, wider
            out.append(unicodedata.normalize("NFKC", ch))
        elif unicodedata.category(ch)[0] in "LM":
            out.append(" ")
        else:
            out.append(unicodedata.normalize("NFKC", ch))
    return "".join(out)


def norm(text):
    """Folded (fold), upper-case, every run of non-alphanumerics -> one space, padded so boundary matching is ' X '."""
    return " " + re.sub(r"[^A-Z0-9]+", " ", fold(text).upper()).strip() + " "


def has_token(answer_norm, needle):
    n = norm(needle)
    return n.strip() != "" and n in answer_norm


# Claims (finding 7 of the 2026-10-14 review): a needle only counts when the answer ASSERTS it. The answer is split into
# word tokens and clause separators (newline ! ? ; : and a '.' that is not a decimal point); a needle occurrence is
# NEGATED when one of the (at most) _NEG_WINDOW words before it, inside the same clause, is a negation word. "There is
# no ORANGE TIGER 42 here" therefore does not claim ORANGE TIGER 42, while "No problem. ORANGE TIGER 42" does.
_NEG_WORDS = {"NO", "NOT", "NONE", "NEVER", "NOR", "WITHOUT", "CANNOT", "NEITHER", "RATHER", "INSTEAD"}
_HEDGE_AFTER_NEG = {"SURE", "CERTAIN"}          # 'Not sure, dark.' - a hedge about the speaker, not a negation of 'dark'
_COPULA = {"IS", "ARE", "WAS", "WERE", "BE", "BEEN"}
_WRONG_WORDS = {"INCORRECT", "WRONG", "FALSE", "MISTAKEN"}
_RETRACT_RE = re.compile(r"\s*(NO|WAIT|ACTUALLY|CORRECTION|SORRY|OOPS|NOPE)\b\s*[,.!:;\-]")
_NT_PREFIX = {"DON", "DOESN", "DIDN", "ISN", "AREN", "WASN", "WEREN", "CAN", "COULDN", "WON", "WOULDN", "SHOULDN",
              "HASN", "HAVEN", "HADN", "AIN", "MUSTN"}
_NEG_WINDOW = 4
_DENIAL_WORDS = {"NO", "NOT"}   # label_set: 'no OK button' denies a label that is not there (never a label itself)
_TOKEN_RE = re.compile(r"[A-Z0-9]+|\n|[!?;:]|(?<!\d)\.|\.(?!\d)")


def _tokens(raw):
    """[(word | None, start, end)] of the folded, upper-cased answer: words, and clause separators (word None)."""
    return [(m.group(0) if m.group(0)[0].isalnum() else None, m.start(), m.end())
            for m in _TOKEN_RE.finditer(fold(raw).upper())]


def _negated(toks, start, marks=frozenset()):
    """True when a negation word precedes position `start` within _NEG_WINDOW words of the same clause ('not sure' /
    'not certain' is a hedge about the speaker, not a negation of what follows). A word in `marks` (the word that opens a
    RETRACTION clause: the 'No' of 'London. No, Paris.') is a clause boundary, not a negation: it withdraws what came
    before it and asserts what follows (finding 5 of the third 2026-10-15 review)."""
    seen, i = 0, start - 1
    while i >= 0 and seen < _NEG_WINDOW:
        w = toks[i][0]
        if w is None:
            return False          # clause boundary: a negation in another clause does not negate this one
        if i in marks:
            return False          # the retraction word opens a clause: what follows it is the corrected claim
        if w in _NEG_WORDS or (w == "T" and i > 0 and toks[i - 1][0] in _NT_PREFIX):
            nxt = toks[i + 1][0] if i + 1 < len(toks) else None
            if not (nxt in _HEDGE_AFTER_NEG and i + 1 != start):
                return True
        seen += 1
        i -= 1
    return False


def _post_negated(toks, end):
    """True when the words right after the occurrence (same clause) deny it: '<X> is not ...', '<X> isn't ...',
    '<X> is incorrect / wrong'. A bare 'not' after it ('Paris, not London') denies the NEXT word, not <X>."""
    w = [t[0] for t in toks[end + 1:end + 4]]
    if not w or w[0] is None:
        return False
    if w[0] in _WRONG_WORDS:
        return True
    if w[0] in _COPULA and len(w) > 1 and w[1] is not None and (w[1] in _NEG_WORDS or w[1] in _WRONG_WORDS):
        return True
    if w[0] in _NT_PREFIX and len(w) > 1 and w[1] == "T":
        return True
    return False


def _retracted_before(raw, toks):
    """Character offset of the first clause that RETRACTS what came before it ('Paris? No, Lyon.', 'Three. Wait - four.',
    'Actually, ...'); None when there is none. An occurrence before that offset is not a claim of the answer."""
    up = fold(raw).upper()
    starts = [0] + [t[2] for t in toks if t[0] is None]
    for st in starts[1:]:
        if _RETRACT_RE.match(up, st):
            return st
    return None


def _retraction_marks(raw, toks):
    """Token indices of the words that OPEN a retraction clause (the clause starts that _retracted_before recognises)."""
    up = fold(raw).upper()
    marks = set()
    for i, t in enumerate(toks):
        if t[0] is None and _RETRACT_RE.match(up, t[2]):
            j = i + 1
            while j < len(toks) and toks[j][0] is None:
                j += 1
            if j < len(toks):
                marks.add(j)
    return marks


def claim_occurrences(raw, needle, offsets=False):
    """[(word_index, negated)] (with offsets=True: [(word_index, negated, char_offset)]) of every occurrence of `needle` (its normalised words, consecutive; separators between
    them are skipped like the normaliser does). word_index counts words only. 'negated' covers a negation before it, a
    denial after it ('X is not ...'), a '-less'/'-free' compound ('login-less'), and a later retraction clause."""
    want = norm(needle).split()
    if not want:
        return []
    toks = _tokens(raw)
    up = fold(raw).upper()
    words = [(i, t[0]) for i, t in enumerate(toks) if t[0] is not None]
    retract = _retracted_before(raw, toks)
    marks = _retraction_marks(raw, toks)
    out = []
    for k in range(len(words) - len(want) + 1):
        if all(words[k + j][1] == want[j] for j in range(len(want))):
            first, last = words[k][0], words[k + len(want) - 1][0]
            neg = _negated(toks, first, marks) or _post_negated(toks, last) \
                or bool(re.match(r"\s*-\s*(LESS|FREE)\b", up[toks[last][2]:])) \
                or (retract is not None and toks[first][1] < retract)
            out.append((k, neg, toks[first][1]) if offsets else (k, neg))
    return out


def asserts(raw, needle):
    """The answer asserts `needle`: at least one occurrence that is not negated."""
    return any(not neg for _, neg in claim_occurrences(raw, needle))


def _aside_depths(up):
    """Per character of `up`: how many ( ) / [ ] asides enclose it (an unbalanced closer never goes below 0)."""
    depth, out = 0, []
    for ch in up:
        if ch in ")]":
            depth = max(0, depth - 1)
        out.append(depth)
        if ch in "([":
            depth += 1
    return out


def asserts_main(raw, needle):
    """The answer asserts `needle` OUTSIDE every parenthetical aside: 'A dashboard (login screen is next).' does not claim
    a login screen - the aside is a remark next to the claim, not the claim (finding 3 of the third 2026-10-15 review).
    An answer that is ONE aside as a whole ('(Dark)') is read without its brackets."""
    t = str(raw).strip()
    m = re.match(r"^[(\[]([^()\[\]]*)[)\]]\.?$", t)
    if m:
        t = m.group(1)
    depth = _aside_depths(fold(t).upper())
    return any(not neg and depth[off] == 0 for _, neg, off in claim_occurrences(t, needle, offsets=True))


def _ordered_ok(raw, items):
    """The sequence of ALL occurrences of the listed items, in answer order, must BE the listed order: an item missing,
    repeated, extra or out of place is not that order ('Red, green, blue, red' is not RED GREEN BLUE); a NEGATED
    occurrence ('Not red, green, blue.') makes the sequence no claim at all (finding 4 of the 2026-10-15 review)."""
    occ, neg = [], False
    for idx, t in enumerate(items):
        for pos, n in claim_occurrences(raw, t):
            occ.append((pos, idx))
            neg = neg or n
    occ.sort()
    seq = [idx for _, idx in occ]
    return (not neg) and seq == list(range(len(items))), seq


def _json_eq(a, b):
    """JSON equality WITHOUT Python's bool/int coercion: true is not 1, false is not 0, "1" is not 1; numbers compare
    by value (1 == 1.0)."""
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_json_eq(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return set(a) == set(b) and all(_json_eq(a[k], b[k]) for k in a)
    return type(a) is type(b) and a == b


_LIST_CHECKS = ("contains_all", "contains_any", "ordered", "forbidden", "regex_all", "regex_none", "number_allow",
                "label_set", "words_allow")
_TOKEN_CHECKS = ("contains_all", "contains_any", "ordered", "forbidden", "label_set", "words_allow")
_KNOWN_CHECKS = set(_LIST_CHECKS) | {"number_equals", "json_subset", "choice_equals", "json_equals", "exact_text",
                                     "exact_words", "max_words", "python_function_sum"}


def validate_checks(checks):
    """Raise SuiteDefect unless `checks` is a non-empty dict of known, non-empty, usable checks (a vacuous check would
    PASS any answer)."""
    if not isinstance(checks, dict) or not checks:
        raise SuiteDefect("empty or non-object checks %r (a probe with no check passes any answer)" % (checks,))
    for key, val in checks.items():
        if key not in _KNOWN_CHECKS:
            raise SuiteDefect("unknown check type %r" % key)
        if key in _LIST_CHECKS:
            if not isinstance(val, list) or not val or not all(isinstance(t, str) and t for t in val):
                raise SuiteDefect("%s must be a non-empty list of non-empty strings, got %r" % (key, val))
            if key in _TOKEN_CHECKS and any(not norm(t).strip() for t in val):
                raise SuiteDefect("%s has an item with no letters or digits: %r" % (key, val))
            if key.startswith("regex"):
                for p in val:
                    try:
                        re.compile(p)
                    except re.error as e:
                        raise SuiteDefect("%s pattern %r does not compile: %s" % (key, p, e))
        elif key == "number_equals":
            if isinstance(val, bool) or not isinstance(val, (int, float)) or not math.isfinite(float(val)):
                raise SuiteDefect("number_equals must be a finite number, got %r" % (val,))
        elif key == "json_subset":
            if not isinstance(val, dict) or not val:
                raise SuiteDefect("json_subset must be a non-empty object, got %r" % (val,))
        elif key == "choice_equals":
            if not isinstance(val, str) or not val:
                raise SuiteDefect("choice_equals must be a non-empty string, got %r" % (val,))
        elif key == "json_equals":
            try:
                json.dumps(val, allow_nan=False)
            except (TypeError, ValueError):
                raise SuiteDefect("json_equals must be a finite JSON value, got %r" % (val,))
        elif key == "exact_text":
            if not isinstance(val, str) or not val.strip():
                raise SuiteDefect("exact_text must be a non-empty string, got %r" % (val,))
        elif key == "exact_words":
            if not isinstance(val, str) or not norm(val).strip():
                raise SuiteDefect("exact_words must be a string with letters or digits, got %r" % (val,))
        elif key == "max_words":
            if isinstance(val, bool) or not isinstance(val, int) or val < 1:
                raise SuiteDefect("max_words must be a positive integer, got %r" % (val,))
        elif key == "python_function_sum":
            if not isinstance(val, str) or not val.isidentifier():
                raise SuiteDefect("python_function_sum must name a Python function, got %r" % (val,))
    if "number_allow" in checks and "number_equals" not in checks:
        raise SuiteDefect("number_allow is only meaningful next to number_equals")
    if "words_allow" in checks:
        if "exact_words" not in checks and "label_set" not in checks:
            raise SuiteDefect("words_allow is only meaningful next to exact_words or label_set")
        allow = {w for item in checks["words_allow"] for w in norm(item).split()}
        expected = set(norm(checks.get("exact_words", "")).split())
        for item in checks.get("label_set", []):
            expected |= set(norm(item).split())
        if allow & (expected | _NEG_WORDS | _DENIAL_WORDS):
            raise SuiteDefect("words_allow may not contain an expected or a negation word: %s"
                              % sorted(allow & (expected | _NEG_WORDS | _DENIAL_WORDS)))
    if "label_set" in checks and len({norm(t) for t in checks["label_set"]}) != len(checks["label_set"]):
        raise SuiteDefect("label_set items must be distinct, got %r" % (checks["label_set"],))


def _strip_python_comments(src):
    """The code with every '#' comment blanked (tokenize; a '#' inside a string literal is not a comment). Text that
    does not tokenize as Python is handled line by line with a small quote-aware scanner."""
    import io
    import tokenize
    lines = src.splitlines(True)
    try:
        cuts = {}
        for tok in tokenize.generate_tokens(io.StringIO(src).readline):
            if tok.type == tokenize.COMMENT:
                cuts[tok.start[0]] = tok.start[1]
        return "".join((l[:cuts[i + 1]] + ("\n" if l.endswith("\n") else "")) if (i + 1) in cuts else l
                       for i, l in enumerate(lines))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        out = []
        for l in lines:
            q, cut = None, None
            for j, ch in enumerate(l):
                if q:
                    if ch == q and (j == 0 or l[j - 1] != "\\"):
                        q = None
                elif ch in "'\"":
                    q = ch
                elif ch == "#":
                    cut = j
                    break
            out.append(l if cut is None else l[:cut] + ("\n" if l.endswith("\n") else ""))
        return "".join(out)


def code_of(answer, language):
    """The code a coding answer contains: the fenced blocks when there are any, else the whole answer; comments of
    `language` removed (comments are not code: 'return a - b  # not: return a + b' is a subtraction)."""
    raw = "" if answer is None else str(answer)
    blocks = re.findall(r"```[^\n`]*\n(.*?)```", raw, re.S)
    src = "\n".join(blocks) if blocks else raw
    if language == "python":
        return _strip_python_comments(src)
    raise SuiteDefect("unsupported code_language %r" % language)


def judge_probe(probe, answer):
    """(passed, reasons) for one probe of a suite: its checks validated (SuiteDefect when unusable), applied to the
    answer - or, for a probe with a code_language, to the code of the answer (fenced blocks, comments removed)."""
    checks = probe.get("checks") if isinstance(probe, dict) else None
    validate_checks(checks)
    lang = probe.get("code_language")
    if lang is not None:
        if answer is None or not str(answer).strip():
            return False, ["empty answer"]
        answer = code_of(answer, lang)
    return judge(checks, answer)


# A number is digits with an optional '.' fraction. A ',' directly followed by a digit (a thousands separator:
# '10,000') or a '.'/',' directly before the digits ('.42') is NOT part of a number, so '10,000' never equals 10.
_NUM_RE = r"(?<![\d.,])-?\d+(?:\.\d+)?(?!\d)(?!,\d)"
_WORD_RE = re.compile(r"(?<![\w-])(" + "|".join(NUMBER_WORDS) + r")(?![\w-])", re.I)   # not inside 'twenty-two'


def _number_at(raw, start):
    """The number that starts at or after `start` (digits or an English number word zero..twenty): (pos, value)."""
    best = None
    m = re.compile(_NUM_RE).search(raw, start)
    if m:
        best = (m.start(), float(m.group(0).replace(",", ".")))
    w = _WORD_RE.search(raw, start)
    if w and (best is None or w.start() < best[0]):
        best = (w.start(), float(NUMBER_WORDS[w.group(1).lower()]))
    return best


def _all_numbers(raw, start=0):
    """[(pos, value)] of every number stated at or after `start` (digits, or a number word zero..twenty)."""
    out, pos = [], start
    while True:
        b = _number_at(raw, pos)
        if b is None:
            return out
        out.append(b)
        m = re.compile(_NUM_RE).match(raw, b[0]) or _WORD_RE.match(raw, b[0])
        pos = b[0] + max(1, len(m.group(0)) if m else 1)


# Numbers (finding 4 of the 2026-10-15 review; finding 1 of the third review of that day): every number_equals prompt asks
# for ONLY the number, so the answer must BE a number - not merely mention one. The answer is split into sentences; EVERY
# sentence must be one of these forms and state the same value (else FAIL):
#   N                         '42', '42.0', '58,40', '$58.40', 'forty-two', 'Three', '**3**', a fenced '3'
#   N (N')                    '3 (three)' - the same value twice
#   <arithmetic> = N          '17 + 25 = 42' (operands and operators only before the '=')
#   <lead-in> N               'The answer is 42', 'There are 3' (a FIXED list of lead-ins, _LEAD_INS)
# and nothing else may stand next to N except the probe's OWN declared words (number_allow, a positive allow-list per
# probe: ['RED CIRCLES', 'CIRCLES'] for a count of red circles, ['NOT FOUND'] for HTTP 404, ['INVOICE NO', ...] for an
# invoice number), removed as whole words at the start or end of a sentence ('There are 3 red circles' -> 'There are 3').
# There is NO open 'N <any 1-4 words>' form any more: '42 thousand', '42 squared', '42 in hex', '3 pairs', '42 I think',
# '3 red circles presumably' name no allowed word and FAIL - a positive allow-list, never a list of blocked words
# (Constitution 11.4.250). A number_allow entry ending in '.' declares an abbreviation ('NO.'): its period is not a
# sentence end ('Invoice No. 7731'), while the period after any other word still is ('3 red circles. 3.').
# N is digits with an optional '.' fraction (three fraction digits are refused as an ambiguous thousands separator:
# '10.000'), a decimal comma with exactly two digits, an optional currency symbol, or an English number word
# (zero..twenty, 'forty-two'). Anything else - 'Not 3', 'At least 3', 'About 3', '3 or more', '3rd', '3%', '3/4',
# '4.2e1', '7,731', 'Three. No wait - four.' - is not a stated number.
_N_DIGITS = re.compile(r"^[$€£]?\s*(\d+(?:\.\d{1,2}|\.\d{4,})?|\d+,\d{2})\s*[$€£]?$")
_LEAD_INS = ("THE ANSWER IS", "ANSWER IS", "ANSWER", "IT IS", "IT'S", "THERE ARE", "THERE IS", "I COUNT", "I SEE",
             "THE RESULT IS", "RESULT", "OUTPUT", "TOTAL", "THE TOTAL IS", "THE NUMBER IS", "THE STATUS CODE IS",
             "THE SUM IS")


def _strip_markup(t):
    t = t.strip()
    m = re.match(r"^```[^\n`]*\n(.*?)\n?```$", t, re.S)
    if m:
        t = m.group(1)
    return re.sub(r"[*_`]+", "", t).strip()


def _num_value(tok):
    """The value of ONE number token (see the rules above), else None."""
    t = tok.strip().rstrip(".")
    m = _N_DIGITS.match(t)
    if m:
        return float(m.group(1).replace(",", "."))
    low = t.lower()
    if low in NUMBER_WORDS:
        return float(NUMBER_WORDS[low])
    m = re.match(r"^(" + "|".join(TENS_WORDS) + r")[- ](one|two|three|four|five|six|seven|eight|nine)$", low)
    if m:
        return float(TENS_WORDS[m.group(1)] + NUMBER_WORDS[m.group(2)])
    if low in TENS_WORDS:
        return float(TENS_WORDS[low])
    return None


def _sentence_number(sent, allow):
    """(value, None) when the sentence is one of the allowed number forms, else (None, why)."""
    t = sent.strip().rstrip(".!").strip()
    up = t.upper()
    for a in sorted(allow, key=len, reverse=True):       # declared neighbours of the number: removed as whole words
        A = a.upper()
        if up.startswith(A) and (len(up) == len(A) or not up[len(A)].isalnum() or not A[-1].isalnum()):
            t, up = t[len(A):].strip(" -#:"), up[len(A):].strip(" -#:")
        if up.endswith(A) and (len(up) == len(A) or not up[-len(A) - 1].isalnum()):
            t, up = t[:-len(A)].strip(" -#:,"), up[:-len(A)].strip(" -#:,")
    m = re.match(r"^\(([^()]*)\)$", t)                              # a number written as one aside: '(404)'
    if m:
        t = m.group(1).strip()
    v = _num_value(t)
    if v is not None:
        return v, None
    m = re.match(r"^(.+?)\s*\((.+)\)$", t)                          # N (N')  /  N (<an allowed word>)
    if m:
        a, b = _num_value(m.group(1)), _num_value(m.group(2))
        if a is not None and (a == b or m.group(2).strip().upper() in {x.upper() for x in allow}):
            return a, None
    m = re.match(r"^([0-9\s.+\-*/x×()]+?)\s*=\s*(.+)$", t)        # arithmetic = N
    if m and re.search(r"[+\-*/x×]", m.group(1)):
        v = _num_value(m.group(2))
        if v is not None:
            return v, None
    for lead in _LEAD_INS:                                          # lead-in N (nothing after N)
        if up.startswith(lead) and len(up) > len(lead) and not up[len(lead)].isalnum():
            v = _num_value(t[len(lead):].strip(" :"))
            if v is not None:
                return v, None
            break
    return None, "%r is not just a number (a hedge, comparison, negation, unit, ordinal, alternative or a word the " \
                 "probe does not allow)" % t


def stated_number(raw, allow=()):
    """(value, why): the ONE number the answer states when it states only that (rules above), or (None, reason)."""
    t = _strip_markup(fold(raw))
    if not t:
        return None, "empty answer"
    for a in allow:              # a declared abbreviation ('NO.' -> 'Invoice No. 7731'): its period is no full stop
        if len(a) > 1 and a.endswith(".") and a[-2].isalnum():
            t = re.sub(r"(?i)(?<![A-Za-z0-9])" + re.escape(a), a[:-1] + " ", t)
    sents = [x for x in re.split(r"\.{2,}|\.(?=\s|$)|\n|;|!|\?", t) if x.strip()]
    vals = []
    for sent in sents:
        v, why = _sentence_number(sent, allow)
        if v is None:
            return None, why
        vals.append(v)
    if not vals:
        return None, "no number in the answer"
    if len(set(vals)) > 1:
        return None, "the answer states several different numbers %s" % ", ".join("%g" % v for v in sorted(set(vals)))
    return vals[0], ""


def first_number(raw):
    """Back-compat name: the single stated number (stated_number), None when there is none or several differ."""
    return stated_number(raw)[0]


def first_json_object(raw):
    s = raw.strip()
    s = re.sub(r"^```[a-zA-Z]*\s*", "", s)
    s = re.sub(r"\s*```\s*$", "", s)
    start = s.find("{")
    while start != -1:
        depth = 0
        for i in range(start, len(s)):
            if s[i] == "{":
                depth += 1
            elif s[i] == "}":
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads(s[start:i + 1])
                        if isinstance(obj, dict):
                            return obj
                    except ValueError:
                        break
                    break
        start = s.find("{", start + 1)
    return None


class _DuplicateKey(ValueError):
    """A JSON object of the answer repeats a key."""


def _no_dup_pairs(pairs):
    seen = {}
    for k, v in pairs:
        if k in seen:
            raise _DuplicateKey(k)
        seen[k] = v
    return seen


def _bad_constant(name):
    raise ValueError("non-finite number %s" % name)


def json_document(raw):
    """(value, None) when the WHOLE answer (one optional ```json fence) is exactly one JSON document without duplicate
    keys or NaN/Infinity, else (None, why): '{"a": 1} -- no wait: {...}', duplicate keys and a Python dict are not."""
    t = str(raw).strip()
    m = re.match(r"^```[A-Za-z]*\s*\n?(.*?)\n?```$", t, re.S)
    if m:
        t = m.group(1).strip()
    try:
        return json.loads(t, object_pairs_hook=_no_dup_pairs, parse_constant=_bad_constant), None
    except _DuplicateKey as e:
        return None, "duplicate JSON key %r" % str(e)
    except ValueError as e:
        return None, "the answer is not exactly one JSON document (%s)" % str(e)[:80]


def _exact_text_of(raw):
    t = str(raw).strip()
    m = re.match(r"^```[^\n`]*\n(.*?)\n?```$", t, re.S)
    if m:
        t = m.group(1).strip()
    if len(t) >= 2 and t[0] == t[-1] and t[0] in "`'\"":
        t = t[1:-1].strip()
    if t.endswith(".") and not t.endswith(".."):
        t = t[:-1]
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", t)).strip()


def _sum_of(e, a, b):
    import ast
    return (isinstance(e, ast.BinOp) and isinstance(e.op, ast.Add) and isinstance(e.left, ast.Name)
            and isinstance(e.right, ast.Name) and {e.left.id, e.right.id} == {a, b} and a != b)


def python_function_sum(code, name):
    """None when `code` defines exactly one top-level function `name` of two positional parameters that ends in its ONLY
    return, `return p1 + p2` (or `return t` after `t = p1 + p2`), has no control flow or nested definition, never
    re-binds a parameter, and `name` is bound nowhere else; else why. Judged on the AST: a docstring or string literal
    saying 'return a + b', a dead branch, a sum in another function or a later redefinition do not count (finding 4 of
    the 2026-10-15 review). The code is parsed, never executed."""
    import ast
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError) as e:
        return "the code does not parse as Python (%s)" % str(e)[:60]
    defs = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == name]
    if len(defs) != 1 or not isinstance(defs[0], ast.FunctionDef):
        return "expected exactly one top-level 'def %s', found %d" % (name, len(defs))
    f = defs[0]
    # Finding 4 of the third 2026-10-15 review: 'add.__code__ = ...' and "globals()['add'] = ..." re-bind the function
    # without naming it as a target. The module may hold ONLY the def, imports and a leading docstring; nothing anywhere
    # may call anything (adding two numbers needs no call) or store through an attribute or a subscript.
    for i, st in enumerate(tree.body):
        if st is f or isinstance(st, (ast.Import, ast.ImportFrom)):
            continue
        if i == 0 and isinstance(st, ast.Expr) and isinstance(st.value, ast.Constant) and isinstance(st.value.value, str):
            continue
        return "the module holds a %s next to 'def %s' (only the function, imports and a docstring)" % (
            type(st).__name__, name)
    for n in ast.walk(tree):
        if isinstance(n, ast.Call):
            return "the code calls something (line %d); adding two numbers needs no call" % getattr(n, "lineno", 0)
        if isinstance(n, (ast.Attribute, ast.Subscript)) and isinstance(n.ctx, (ast.Store, ast.Del)):
            return "the code writes through an attribute or a subscript (line %d)" % getattr(n, "lineno", 0)
    for n in ast.walk(tree):
        if n is f:
            continue
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n.name == name:
            return "%r is defined again" % name
        if isinstance(n, ast.Name) and n.id == name and isinstance(n.ctx, (ast.Store, ast.Del)):
            return "%r is re-bound" % name
        if isinstance(n, ast.alias) and (n.asname or n.name) == name:
            return "%r is re-bound by an import" % name
    if f.decorator_list:
        return "%r is decorated" % name
    a = f.args
    params = [x.arg for x in a.posonlyargs + a.args]
    if len(params) != 2 or a.vararg or a.kwarg or a.kwonlyargs:
        return "%r must take exactly two positional parameters" % name
    body = list(f.body)
    if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant) \
            and isinstance(body[0].value.value, str):
        body = body[1:]
    p1, p2 = params
    if not body or not isinstance(body[-1], ast.Return):
        return "%r does not end in a return" % name
    for st in body[:-1]:
        if not isinstance(st, (ast.Assign, ast.AnnAssign, ast.Expr, ast.Pass)):
            return "%r contains %s (only plain statements before its return)" % (name, type(st).__name__)
    for n in ast.walk(f):
        if n is not f and isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)):
            return "%r contains a nested definition" % name
        if isinstance(n, ast.Return) and n is not body[-1]:
            return "%r has more than one return" % name
        if isinstance(n, ast.Name) and n.id in (p1, p2) and isinstance(n.ctx, (ast.Store, ast.Del)):
            return "%r re-binds its parameter %r" % (name, n.id)
        if isinstance(n, (ast.Global, ast.Nonlocal)):
            return "%r declares global/nonlocal names" % name
    ret = body[-1].value
    if _sum_of(ret, p1, p2):
        return None
    if isinstance(ret, ast.Name):
        sums = [st for st in body[:-1] if isinstance(st, ast.Assign) and len(st.targets) == 1
                and isinstance(st.targets[0], ast.Name) and st.targets[0].id == ret.id]
        others = [n for st in body[:-1] for n in ast.walk(st)
                  if isinstance(n, ast.Name) and n.id == ret.id and isinstance(n.ctx, ast.Store)]
        if len(sums) == 1 and len(others) == 1 and _sum_of(sums[0].value, p1, p2):
            return None
    return "%r does not return %s + %s" % (name, p1, p2)


# A clause of a label answer ends at a newline, , ; : . ! ? ( ) [ ] an en/em dash or a free-standing hyphen run.
_LABEL_CLAUSE = re.compile(r"[\n,;:.!?()\[\]\u2013\u2014]|\s-+\s|^-+\s|\s-+$")


def _drop_phrases(words, phrases):
    """`words` with every contiguous occurrence of an allowed phrase (words_allow; longest first) removed. A phrase is
    removed only as a whole: 'FROM LEFT TO RIGHT' is allowed framing, 'from right to left' is not."""
    want = sorted((norm(p).split() for p in phrases), key=len, reverse=True)
    out, i = [], 0
    while i < len(words):
        hit = next((x for x in want if x and words[i:i + len(x)] == x), None)
        if hit is None:
            out.append(words[i])
            i += 1
        else:
            i += len(hit)
    return out


def label_set_why(raw, items, allow=()):
    """None when the answer names EXACTLY the labels of `items` - each once, in any order - and nothing else, else why.
    Only the probe's words_allow may stand next to them ('Cancel and Delete', 'Delete button, Cancel button'); a clause
    that DENIES one other label ('Cancel, Delete - no OK button') is a remark, not a label; any other word ('Cancel,
    Delete, OK', 'Neither Cancel nor Delete') is an extra or a negated claim (finding 3 of the third 2026-10-15 review:
    contains_all accepted a third, hallucinated label)."""
    want = sorted((norm(t).split() for t in items), key=len, reverse=True)
    itemwords = {w for x in want for w in x}
    words = []
    for clause in _LABEL_CLAUSE.split(_strip_markup(fold(raw))):
        ws = norm(clause).split()
        if not ws:
            continue
        rest = _drop_phrases(ws[1:], allow)
        if ws[0] in _DENIAL_WORDS and len(rest) <= 1 and not set(ws) & itemwords:
            continue
        words.extend(_drop_phrases(ws, allow))
    seen, extra, i = [], [], 0
    while i < len(words):
        hit = next((x for x in want if words[i:i + len(x)] == x), None)
        if hit is None:
            extra.append(words[i])
            i += 1
        else:
            seen.append(" ".join(hit))
            i += len(hit)
    if extra:
        return "words other than the labels: %s" % extra[:8]
    if sorted(seen) != sorted(" ".join(x) for x in want):
        return "the labels named are %s, not each of %s exactly once" % (seen, [" ".join(x) for x in want])
    return None


def judge(checks, answer):
    """Return (passed: bool, reasons: [str]). Pure function of (checks, answer). Unusable checks raise SuiteDefect."""
    validate_checks(checks)
    raw = "" if answer is None else str(answer)
    reasons = []
    if not raw.strip():
        return False, ["empty answer"]
    for key, val in checks.items():
        if key == "contains_all":
            miss = [t for t in val if not asserts(raw, t)]
            if miss:
                reasons.append("contains_all: missing (or only negated) %s" % miss)
        elif key == "contains_any":
            if not any(asserts_main(raw, t) for t in val):
                reasons.append("contains_any: none of %s asserted outside a parenthetical aside" % val)
        elif key == "ordered":
            ok, seq = _ordered_ok(raw, val)
            if not ok:
                reasons.append("ordered: the items occur as %s, not exactly once each in the order %s" % (
                    [val[i] for i in seq], val))
        elif key == "forbidden":
            hit = [t for t in val if asserts(raw, t)]
            if hit:
                reasons.append("forbidden: answer claims %s" % hit)
        elif key == "number_equals":
            got, why = stated_number(raw, checks.get("number_allow") or ())
            if got is None or not math.isclose(got, float(val), rel_tol=0, abs_tol=1e-9):
                reasons.append("number_equals: expected %s, %s" % (val, why or "the answer states %g" % got))
        elif key == "number_allow":
            pass    # a modifier of number_equals
        elif key == "json_equals":
            doc, why = json_document(raw)
            if why is not None:
                reasons.append("json_equals: %s" % why)
            elif not _json_eq(doc, val):
                reasons.append("json_equals: expected %s, got %s" % (json.dumps(val), json.dumps(doc)[:200]))
        elif key == "exact_text":
            got = _exact_text_of(raw)
            if got != val:
                reasons.append("exact_text: expected exactly %r, got %r" % (val, got[:200]))
        elif key == "exact_words":
            got = " ".join(_drop_phrases(norm(_strip_markup(raw)).split(), checks.get("words_allow") or ()))
            if got != norm(val).strip():
                reasons.append("exact_words: expected the words %r, got %r" % (norm(val).strip(), got[:200]))
        elif key == "label_set":
            why = label_set_why(raw, val, checks.get("words_allow") or ())
            if why:
                reasons.append("label_set: %s" % why)
        elif key == "words_allow":
            pass    # a modifier of exact_words / label_set
        elif key == "max_words":
            ws = norm(raw).split()
            if len(ws) > val:
                reasons.append("max_words: %d words, at most %d asked" % (len(ws), val))
            elif "OR" in ws:
                reasons.append("max_words: a short answer naming alternatives ('or') states no single answer")
        elif key == "python_function_sum":
            why = python_function_sum(raw, val)
            if why:
                reasons.append("python_function_sum: %s" % why)
        elif key == "choice_equals":
            if raw.strip() != val:
                reasons.append("choice_equals: expected choice %r, got %r" % (val, raw.strip()))
        elif key == "regex_all":
            miss = [p for p in val if not re.search(p, raw, re.I | re.S)]
            if miss:
                reasons.append("regex_all: no match for %s" % miss)
        elif key == "regex_none":
            hit = [p for p in val if re.search(p, raw, re.I | re.S)]
            if hit:
                reasons.append("regex_none: matched %s" % hit)
        elif key == "json_subset":
            obj = first_json_object(raw)
            if obj is None:
                reasons.append("json_subset: no JSON object in answer")
            else:
                diff = {k: obj.get(k) for k, v in val.items() if k not in obj or not _json_eq(obj[k], v)}
                if diff:
                    reasons.append("json_subset: expected %s, got %s" % (val, diff))
        else:   # unreachable: validate_checks refused it
            raise SuiteDefect("unknown check type %r (suite/judge mismatch)" % key)
    return (not reasons), reasons


# --- suite loading + integrity ----------------------------------------------------------------------------
def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def suite_hash(suite_dir):
    """sha256 over (relative path, file sha256) of every file in the suite directory, sorted."""
    h = hashlib.sha256()
    for root, _, files in os.walk(suite_dir):
        for f in sorted(files):
            p = os.path.join(root, f)
            rel = os.path.relpath(p, suite_dir)
            h.update(rel.encode() + b"\0" + sha256_file(p).encode() + b"\n")
    return h.hexdigest()


def load_suite(suite_dir):
    for name in ("expectations.json", "suite.json"):
        p = os.path.join(suite_dir, name)
        if os.path.isfile(p):
            with open(p) as fh:
                return json.load(fh)
    raise FileNotFoundError("no expectations.json / suite.json in %s" % suite_dir)


def probes_of(suite):
    """Flatten to [(key, fixture_or_None, probe)] for vision/chat/coder suites."""
    out = []
    if suite["kind"] == "vision":
        for fx in suite["fixtures"]:
            for pr in fx["probes"]:
                out.append(("%s/%s" % (fx["id"], pr["id"]), fx, pr))
    else:
        for case in suite.get("cases", []):
            out.append((case["id"], None, case))
    return out


def integrity_errors(suite, suite_dir):
    errs = []
    if suite.get("kind") == "vision":
        for fx in suite["fixtures"]:
            p = os.path.join(suite_dir, fx["image"])
            if not os.path.isfile(p):
                errs.append("missing fixture %s" % fx["image"])
            elif sha256_file(p) != fx["sha256"]:
                errs.append("fixture %s sha256 %s != recorded %s" % (fx["image"], sha256_file(p), fx["sha256"]))
    return errs


def validate_suite(suite):
    """Raise SuiteDefect unless the suite is usable: a known kind; probes with an id, a non-empty prompt and valid,
    non-empty checks; and - for every judged kind - at least one canned PASS and one canned FAIL judge control per
    probe, so the self-test that runs before any request proves the judge on every probe it will judge."""
    if not isinstance(suite, dict):
        raise SuiteDefect("suite file is not a JSON object")
    kind = suite.get("kind")
    if kind not in ("vision", "chat", "coder", "embedding", "decide"):
        raise SuiteDefect("unknown suite kind %r" % kind)
    if kind == "embedding":
        cases = suite.get("cases")
        if not isinstance(cases, list) or not cases:
            raise SuiteDefect("embedding suite has no cases")
        for c in cases:
            if not all(isinstance(c.get(k), str) and c.get(k) for k in ("id", "anchor", "positive", "negative")):
                raise SuiteDefect("embedding case %r needs non-empty id/anchor/positive/negative" % c.get("id"))
        return
    try:
        probes = probes_of(suite)
    except (KeyError, TypeError) as e:
        raise SuiteDefect("malformed suite structure: %s" % e)
    if not probes:
        raise SuiteDefect("suite has no probes")
    seen = set()
    for key, _, pr in probes:
        if key in seen:
            raise SuiteDefect("duplicate probe id %r" % key)
        seen.add(key)
        if kind == "decide":
            q = pr.get("question")
            if not isinstance(q, dict) or q.get("type") != "choice" or not isinstance(q.get("state"), str) \
                    or not q.get("state") or not isinstance(q.get("instructions"), str) or not q.get("instructions") \
                    or not isinstance(q.get("criteria"), dict) or len(q["criteria"]) < 2:
                raise SuiteDefect("decide case %r needs a question {type: choice, state, instructions, criteria (>= 2)}"
                                  % key)
            if set(pr.get("checks") or {}) != {"choice_equals"} or pr["checks"]["choice_equals"] not in q["criteria"]:
                raise SuiteDefect("decide case %r must check choice_equals with one of its criteria keys" % key)
        elif not isinstance(pr.get("prompt"), str) or not pr["prompt"].strip():
            raise SuiteDefect("probe %r has no prompt" % key)
        validate_checks(pr.get("checks"))
        if pr.get("code_language") not in (None, "python"):
            raise SuiteDefect("probe %r: unsupported code_language %r" % (key, pr.get("code_language")))
    ctls = suite.get("judge_controls", [])
    if not isinstance(ctls, list):
        raise SuiteDefect("judge_controls must be a list")
    for c in ctls:
        if not isinstance(c, dict) or c.get("probe") not in seen or c.get("expect") not in ("pass", "fail") \
                or not isinstance(c.get("answer"), str):
            raise SuiteDefect("malformed judge control %r" % (c,))
    for key in seen:
        have = {c["expect"] for c in ctls if c["probe"] == key}
        if have != {"pass", "fail"}:
            raise SuiteDefect("probe %r lacks a canned %s judge control (every probe needs at least one PASS and "
                              "one FAIL control)" % (key, " and ".join(sorted({"pass", "fail"} - have))))


def judge_selftest(suite):
    """Judge the canned judge_controls. Returns list of (control, ok, detail)."""
    index = {k: pr for k, _, pr in probes_of(suite)}
    res = []
    for ctl in suite.get("judge_controls", []):
        pr = index.get(ctl["probe"])
        if pr is None:
            res.append((ctl, False, "judge control names unknown probe %r" % ctl["probe"]))
            continue
        passed, reasons = judge_probe(pr, ctl["answer"])
        want = ctl["expect"] == "pass"
        res.append((ctl, passed == want, "judged %s (want %s) %s" % (
            "PASS" if passed else "FAIL", ctl["expect"].upper(), "; ".join(reasons))))
    return res


# --- HTTP -------------------------------------------------------------------------------------------------
class NoAnswer(Exception):
    """Could not obtain an answer (connection, timeout, 5xx): UNDETERMINED."""


class Rejected(Exception):
    """The endpoint refused the request SHAPE (HTTP 400/422 only): a real FAIL of the served model."""


def redact_url(url):
    """scheme://host[:port]/path - userinfo, query string and fragment (where tokens live) are dropped. For every
    place a URL is printed, logged or recorded."""
    try:
        sp = urllib.parse.urlsplit(url)
        host = sp.hostname or ""
        if ":" in host:
            host = "[" + host + "]"
        port = sp.port
        return "%s://%s%s%s" % (sp.scheme, host, (":%d" % port) if port else "", sp.path)
    except ValueError:
        return "<unparseable url>"


def open_private(path, mode="a"):
    """Open for writing with the file forced to 0600 (evidence and state may describe a protected endpoint)."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | (os.O_APPEND if mode == "a" else os.O_TRUNC), 0o600)
    os.chmod(path, 0o600)
    return os.fdopen(fd, mode)


def api_key_for(url):
    """The bearer token (LLMCTL_VALIDATE_API_KEY) may be sent ONLY to a loopback host - 127.0.0.0/8, ::1,
    localhost - which is where every locally started profile listens, or to a host named EXACTLY in the
    comma-separated allowlist LLMCTL_VALIDATE_API_KEY_HOSTS. Any other endpoint (a --host URL pointing
    elsewhere) never receives it. No DNS lookup: a hostname is loopback only if it IS 'localhost'."""
    key = os.environ.get("LLMCTL_VALIDATE_API_KEY")
    if not key:
        return None
    # Parser-differential guard: refuse any URL a different parser could read differently (backslash, whitespace,
    # control characters), and require urlsplit and urllib's own Request (what actually connects) to agree on the host.
    if "\\" in url or any(c.isspace() or ord(c) < 0x20 or ord(c) == 0x7f for c in url):
        return None
    try:
        host = (urllib.parse.urlsplit(url).hostname or "").lower()
        conn = urllib.request.Request(url).host or ""
        conn_host = (urllib.parse.urlsplit("//" + conn.rpartition("@")[2]).hostname or "").lower()
    except ValueError:
        return None
    if not host or host != conn_host:
        return None
    allowed = {h.strip().lower() for h in os.environ.get("LLMCTL_VALIDATE_API_KEY_HOSTS", "").split(",") if h.strip()}
    if host == "localhost" or host in allowed:
        return key
    try:
        if ipaddress.ip_address(host).is_loopback:
            return key
    except ValueError:
        pass
    return None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: urllib would replay the request headers (Authorization) to the new host."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _build_opener():
    """An opener from an EXPLICIT handler list: http/https only. build_opener() would add file:, ftp: and data:
    handlers (a `--host file:///path#` would then read a local file as a model reply); no env proxies either."""
    op = urllib.request.OpenerDirector()
    for h in (urllib.request.ProxyHandler({}), urllib.request.HTTPHandler(), urllib.request.HTTPSHandler(),
              urllib.request.HTTPDefaultErrorHandler(), urllib.request.HTTPErrorProcessor(), _NoRedirect()):
        op.add_handler(h)
    return op


_OPENER = _build_opener()
_warned_hosts = set()


class _Deadline(BaseException):
    """Raised by the SIGALRM handler when a request exceeds its overall deadline (BaseException: no library
    `except Exception` / `except OSError` can swallow it)."""


class _deadline:
    """Wall-clock deadline via setitimer/SIGALRM (main thread, POSIX). Elsewhere it degrades to per-socket timeouts."""
    def __init__(self, seconds):
        self.seconds = seconds
        self.ok = hasattr(signal, "setitimer") and threading.current_thread() is threading.main_thread()

    def __enter__(self):
        if self.ok:
            def handler(signum, frame):
                raise _Deadline()
            self.old = signal.signal(signal.SIGALRM, handler)
            signal.setitimer(signal.ITIMER_REAL, float(self.seconds))
        return self

    def __exit__(self, *exc):
        if self.ok:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, self.old)
        return False


def http_json(url, body=None, timeout=60):
    """One JSON request. `timeout` is BOTH the per-socket timeout and an overall wall-clock deadline for the whole
    request (connect, headers, body): a server that trickles bytes can no longer stall validation."""
    scheme = urllib.parse.urlsplit(url).scheme.lower()
    if scheme not in ("http", "https"):
        raise NoAnswer("refusing endpoint with scheme %r (only http and https): %.80s" % (scheme, redact_url(url)))
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"},
                                 method="GET" if body is None else "POST")
    key = api_key_for(url)
    if key:
        req.add_header("Authorization", "Bearer " + key)
    elif os.environ.get("LLMCTL_VALIDATE_API_KEY"):
        h = urllib.parse.urlsplit(url).hostname
        if h not in _warned_hosts:
            _warned_hosts.add(h)
            print("note: LLMCTL_VALIDATE_API_KEY NOT sent to %r (not loopback; list it in "
                  "LLMCTL_VALIDATE_API_KEY_HOSTS to allow)" % h, file=sys.stderr)
    with _deadline(timeout):
        try:
            with _OPENER.open(req, timeout=timeout) as resp:
                raw = resp.read(MAX_RESPONSE_BYTES + 1)
                if len(raw) > MAX_RESPONSE_BYTES:
                    raise NoAnswer("response too large (> %d bytes)" % MAX_RESPONSE_BYTES)
                parsed = json.loads(raw.decode("utf-8", "replace"))
                if not isinstance(parsed, dict):
                    raise NoAnswer("response is not a JSON object: %.200s" % json.dumps(parsed))
                return parsed
        except urllib.error.HTTPError as e:
            detail = e.read(401).decode("utf-8", "replace")[:400]
            if e.code in (400, 422):   # only an answer-SHAPE refusal is a verdict on the model; 401/403/404/408/413/429 are operational
                raise Rejected("HTTP %d: %s" % (e.code, detail))
            raise NoAnswer("HTTP %d: %s" % (e.code, detail))
        except _Deadline:
            raise NoAnswer("overall deadline of %ss exceeded (server too slow or trickling bytes)" % timeout)
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise NoAnswer("%s: %s" % (type(e).__name__, e))


def served_model_ids(endpoint, timeout):
    d = http_json(endpoint.rstrip("/") + "/v1/models", timeout=timeout)
    try:
        return [m.get("id", "") for m in d.get("data", [])] + [m.get("name", "") for m in d.get("models", [])]
    except (AttributeError, TypeError):
        raise NoAnswer("malformed /v1/models response: %.200s" % json.dumps(d))


# --- the PROCESS that answers (finding 6 of the 2026-10-14 review) --------------------------------------------------
_LOOPBACK = ("127.0.0.1", "localhost", "::1")


def _listening_pids(port):
    """pids of THIS user's processes holding a LISTEN socket on TCP `port` (any address), from /proc/net/tcp{,6} and a
    /proc/<pid>/fd scan. Processes of other users are never inspected (Constitution 11.4.174). Linux only; [] elsewhere."""
    inodes = set()
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(f) as fh:
                rows = fh.read().splitlines()[1:]
        except OSError:
            continue
        for row in rows:
            parts = row.split()
            if len(parts) < 10 or parts[3] != "0A":       # 0A = TCP_LISTEN
                continue
            try:
                if int(parts[1].rsplit(":", 1)[1], 16) == port and parts[9] != "0":
                    inodes.add("socket:[%s]" % parts[9])
            except (ValueError, IndexError):
                continue
    if not inodes:
        return []
    uid, pids = os.getuid(), []
    try:
        entries = os.listdir("/proc")
    except OSError:
        return []
    for d in entries:
        if not d.isdigit():
            continue
        try:
            if os.stat("/proc/" + d).st_uid != uid:
                continue
            for fd in os.listdir("/proc/%s/fd" % d):
                try:
                    if os.readlink("/proc/%s/fd/%s" % (d, fd)) in inodes:
                        pids.append(int(d))
                        break
                except OSError:
                    continue
        except OSError:
            continue
    return pids


def _cmdline_model(pid):
    """The model path on a server's command line (--model/-m/--model-dir VALUE or --model=VALUE; a relative path is
    resolved against the process's cwd), None when it names none."""
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            argv = [x.decode("utf-8", "replace") for x in fh.read().split(b"\0") if x]
        cwd = os.readlink("/proc/%d/cwd" % pid)
    except OSError:
        return None
    for i, t in enumerate(argv):
        for flag in ("--model", "-m", "--model-dir"):
            if t == flag and i + 1 < len(argv) and argv[i + 1]:
                return os.path.join(cwd, argv[i + 1])
            if t.startswith(flag + "=") and len(t) > len(flag) + 1:
                return os.path.join(cwd, t[len(flag) + 1:])
    return None


def _cmdline_argv(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            return [x.decode("utf-8", "replace") for x in fh.read().split(b"\0") if x]
    except OSError:
        return None


def _cmdline_value(argv, flag):
    for i, t in enumerate(argv):
        if t == flag and i + 1 < len(argv):
            return argv[i + 1]
        if t.startswith(flag + "="):
            return t[len(flag) + 1:]
    return None


def _argv_fingerprint(argv):
    """launch_fingerprint() of a RUNNING process: its argv (exec + arguments) without --host/--port."""
    kept, skip = [], False
    for t in argv[1:]:
        if skip:
            skip = False
            continue
        if t in ("--host", "--port"):
            skip = True
            continue
        kept.append(t)
    return hashlib.sha256(("\0".join([argv[0]] + kept)).encode()).hexdigest()


def _env_launch(env_file):
    """[exec] + args of an env record, shell-unquoted (as the unit's ExecStart runs them)."""
    import shlex
    exe, args = "", []
    with open(env_file) as fh:
        for line in fh:
            if line.startswith("LLMCTL_EXEC="):
                v = shlex.split(line.split("=", 1)[1])
                exe = v[0] if v else ""
            elif line.startswith("LLMCTL_ARGS="):
                args = shlex.split(line.split("=", 1)[1])
    return [exe] + args


def _mapped_mismatch(pid, expected):
    """A message when process `pid` maps a file at the expected path that is NOT the file on disk now (a replaced or
    deleted file: the served bytes are not the validated ones), else None. A process that does not map it (no mmap) says
    nothing either way."""
    try:
        st = os.stat(expected)
        with open("/proc/%d/maps" % pid) as fh:
            for line in fh:
                parts = line.split(None, 5)
                if len(parts) < 6:
                    continue
                path = parts[5].rstrip("\n")
                if path == expected + " (deleted)":
                    return "the process maps a DELETED file at %s (the model was replaced after it was loaded)" % expected
                if path == expected and int(parts[4]) != st.st_ino:
                    return "the process maps another inode at %s (the model was replaced after it was loaded)" % expected
    except (OSError, ValueError):
        return None
    return None


def served_model_info(endpoint, expected, ids, timeout, launch_env=None):
    """What the probed server really loads, from every source that can say it: the cmdline of the process listening on
    the endpoint's loopback port, absolute-path ids of /v1/models, and /props model_path. Returns a dict with
    confirmed (bool), sources, path/size/mtime_ns when confirmed, and `mismatch` (a message) when ANY source names a file
    that is not `expected` (compared by realpath). For a listening process that names a model on its command line
    (finding 11 of the 2026-10-15 review) also: its --mmproj must lie next to the model file, the model file it MAPS must
    be the file on disk now (inode; a replaced file is a mismatch), and - with `launch_env` - its command line must be
    the launch of that env record (the record binds that launch: --host/--port excluded)."""
    sp = urllib.parse.urlsplit(endpoint)
    found = []
    extra = []
    try:
        port = sp.port
    except ValueError:
        port = None
    exp_real = os.path.realpath(expected)
    if (sp.hostname or "").lower() in _LOOPBACK and port:
        for pid in _listening_pids(port):
            m = _cmdline_model(pid)
            if m:
                found.append(("cmdline", m, pid))
                argv = _cmdline_argv(pid) or []
                mm = _cmdline_value(argv, "--mmproj")
                if mm:
                    try:
                        mm_real = os.path.realpath(os.path.join(os.readlink("/proc/%d/cwd" % pid), mm))
                    except OSError:
                        mm_real = os.path.realpath(mm)
                    if os.path.dirname(mm_real) != os.path.dirname(exp_real):
                        extra.append("its --mmproj %s is not the profile's projector (not next to %s)" % (mm, expected))
                why = _mapped_mismatch(pid, exp_real)
                if why:
                    extra.append(why)
                if launch_env and os.path.isfile(launch_env) and argv:
                    # compared when the listening process IS the env record's engine binary (a fixture or another program
                    # on the port is judged by the model-file sources above)
                    try:
                        env_argv = _env_launch(launch_env)
                        if env_argv[0] and os.path.realpath(argv[0]) == os.path.realpath(env_argv[0]) \
                                and _argv_fingerprint(argv) != _argv_fingerprint(env_argv):
                            extra.append("its command line is not the launch of %s (the record would vouch for another "
                                         "launch)" % launch_env)
                    except (OSError, ValueError):
                        extra.append("its launch could not be compared with %s" % launch_env)
    for i in ids:
        if isinstance(i, str) and os.path.isabs(i):
            found.append(("v1/models", i, None))
    try:
        props = http_json(endpoint.rstrip("/") + "/props", timeout=min(timeout, 10))
        mp = props.get("model_path")
        if isinstance(mp, str) and os.path.isabs(mp):
            found.append(("props", mp, None))
    except (NoAnswer, Rejected):
        pass
    exp = exp_real
    info = {"expected": expected, "confirmed": False, "sources": [], "path": None}
    bad = [(src, path) for src, path, _ in found if os.path.realpath(path) != exp]
    if bad:
        info["mismatch"] = "the probed server loads %s, not the profile's model file %s" % (
            "; ".join("%s (%s)" % (p, s) for s, p in bad), expected)
        info["served"] = [{"source": s, "path": p} for s, p in bad]
        return info
    if extra:
        info["mismatch"] = "the probed server: " + "; ".join(extra)
        return info
    if found:
        try:
            st = os.stat(exp)
            info.update({"size": st.st_size, "mtime_ns": st.st_mtime_ns})
        except OSError:
            pass
        info.update({"confirmed": True, "path": expected, "sources": sorted({s for s, _, _ in found}),
                     "pids": sorted({p for _, _, p in found if p})})
    else:
        info["note"] = ("the probed process's model file could not be established (no listening process of this user "
                        "with a --model argument, no path in /v1/models or /props)")
    return info


def ask(endpoint, suite, prompt, image_path=None, timeout=180):
    req = dict(suite.get("request", {}))
    if image_path:
        with open(image_path, "rb") as fh:
            b64 = base64.b64encode(fh.read()).decode()
        content = [{"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
                   {"type": "text", "text": prompt}]
    else:
        content = prompt
    req["messages"] = [{"role": "user", "content": content}]
    t0 = time.monotonic()
    d = http_json(endpoint.rstrip("/") + "/v1/chat/completions", req, timeout=timeout)
    dt = time.monotonic() - t0
    try:
        ch = d["choices"][0]
        msg = ch["message"]
        reasoning = msg.get("reasoning_content") or msg.get("reasoning") or ""
        return {"content": msg.get("content") or "", "finish_reason": ch.get("finish_reason"),
                "reasoning_chars": len(reasoning) if isinstance(reasoning, str) else 0,
                "max_tokens": req.get("max_tokens"), "seconds": round(dt, 3), "usage": d.get("usage", {})}
    except (KeyError, IndexError, TypeError, AttributeError):
        raise NoAnswer("malformed completion response: %s" % json.dumps(d)[:300])


def undetermined_reason(a, probe=None):
    """None when the completion may be judged as it stands. Otherwise the reason it cannot be judged (UNDETERMINED,
    exit 2 - never PASS, never FAIL):
      * finish_reason=length WITH reasoning content: the budget went into the reasoning channel, the final answer
        never came;
      * finish_reason=length, no reasoning content, and the (truncated) content PASSES the probe (or no probe is
        given): the pass cannot be trusted to be a complete answer;
      * empty content with reasoning content (finish_reason=stop).
    A truncated answer that is WRONG is a FAIL (judged normally), as is an empty answer with no reasoning content."""
    rc = a.get("reasoning_chars", 0)
    if a.get("finish_reason") == "length":
        hint = ("answer truncated (finish_reason=length, max_tokens=%s, reasoning_chars=%s): the model did not "
                "finish within the request budget - raise request.max_tokens in the suite; this is not a verdict "
                "on the answer" % (a.get("max_tokens"), rc))
        if rc > 0 or probe is None:
            return hint
        if judge_probe(probe, a.get("content", ""))[0]:
            return hint + " (the truncated content would pass, but a cut-off pass is not trusted)"
        return None
    if not str(a.get("content", "")).strip() and rc > 0:
        return ("no final answer: message.content is empty but the reasoning channel has %d chars "
                "(a reasoning model that spent its output in reasoning) - not a verdict on the answer" % rc)
    return None


def embed(endpoint, text, timeout):
    d = http_json(endpoint.rstrip("/") + "/v1/embeddings", {"input": text}, timeout=timeout)
    try:
        return [float(x) for x in d["data"][0]["embedding"]]
    except (KeyError, IndexError, TypeError, ValueError, AttributeError):
        raise NoAnswer("malformed embeddings response: %s" % json.dumps(d)[:300])


def cosine(a, b):
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    if na == 0 or nb == 0:
        return 0.0
    return sum(x * y for x, y in zip(a, b)) / (na * nb)


# --- decide suites: known-answer typed decisions through the production Go driver ---------------------------------
DECIDE_PROTOCOLS = ("letter-logit", "nli-onnx", "systemone-native")


def decide_ask(args, case, timeout):
    """Ask ONE decide case through `llmctl-decide smoke --question-file` (the production driver of the protocol) and
    return {content: choice, raw: canonical answer for the determinism check, ...}. Driver exit 6 / 2 / other -> NoAnswer
    (UNDETERMINED); a flagged readout (the model does not answer in this protocol) -> Rejected (FAIL)."""
    import subprocess
    import tempfile
    q = case["question"]
    body = {"model": "smoke", "state": q["state"],
            "questions": {"q": {"type": q["type"], "instructions": q["instructions"], "criteria": q["criteria"]}}}
    fd, path = tempfile.mkstemp(prefix="llmctl-validate-q.", suffix=".json")
    t0 = time.monotonic()
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(body, fh)
        cmd = [args.decide_bin, "smoke", "--url", args.endpoint.rstrip("/"), "--protocol", args.decide_protocol,
               "--question-file", path, "--json", "--timeout", "%ds" % max(1, int(timeout))]
        if args.decide_key_file:
            cmd += ["--key-file", args.decide_key_file]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 15)
        except subprocess.TimeoutExpired:
            raise NoAnswer("the decide driver did not finish within %ss" % timeout)
        except OSError as e:
            raise NoAnswer("cannot run the decide driver: %s" % e)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    err = (p.stderr or "").strip()[-400:]
    if p.returncode == 6:
        raise NoAnswer("engine unreachable: %s" % err)
    if p.returncode == 2:
        raise NoAnswer("the decide driver refused the question (exit 2; an llmctl-decide without --question-file? "
                       "rebuild with: llmctl build decide): %s" % err)
    if p.returncode != 0:
        if "readout is flagged" in err:
            raise Rejected(err)
        raise NoAnswer("decide driver exit %d: %s" % (p.returncode, err))
    try:
        d = json.loads(p.stdout)
    except ValueError:
        raise NoAnswer("the decide driver printed no JSON answer")
    choice = d.get("choice") if isinstance(d, dict) else None
    if not isinstance(choice, str) or not choice:
        raise NoAnswer("the decide driver returned no typed choice")
    raw = json.dumps({"choice": choice, "confidence": d.get("confidence"), "probabilities": d.get("probabilities")},
                     sort_keys=True)
    return {"content": choice, "raw": raw, "finish_reason": "stop", "seconds": round(time.monotonic() - t0, 3)}


def run_decide(args, suite, report, counts, out, finish, timeout, repeat):
    proto = args.decide_protocol or ""
    if proto not in DECIDE_PROTOCOLS:
        out("[UNDETERMINED] decision protocol %r is implemented by no decide driver (%s) - this profile cannot be "
            "validated" % (proto or "none", ", ".join(DECIDE_PROTOCOLS)))
        counts["undetermined"] += 1
        return finish()
    if not args.decide_bin or not (os.path.isfile(args.decide_bin) and os.access(args.decide_bin, os.X_OK)):
        out("[UNDETERMINED] the decide driver binary %r is missing (build it: llmctl build decide)" % args.decide_bin)
        counts["undetermined"] += 1
        return finish()
    if args.expect_model_path:
        # a decide engine has no unauthenticated /v1/models: the model file of the probed process IS the identity check
        sm = served_model_info(args.endpoint, args.expect_model_path, [], timeout, args.expect_launch_env or None)
        report["served_model"] = sm
        if sm.get("mismatch") or not sm["confirmed"]:
            out("[UNDETERMINED] served model file: %s" % (sm.get("mismatch") or sm.get("note")))
            counts["undetermined"] += 1
            return finish()
        out("served model file: %s (confirmed by %s)" % (sm["path"], ", ".join(sm["sources"])))
    else:
        out("model identity: NOT checked (--host: a decide engine has no unauthenticated /v1/models; evidence only)")
    asks = repeat if repeat >= 2 else 2 if repeat == 1 else 1
    if repeat == 1:
        out("quick mode (LLMCTL_VALIDATE_REPEAT=1): every decision asked twice - NOT a decision-bearing run, never recorded")
    for key, _, case in probes_of(suite):
        got, why_und, rej = [], None, None
        for _ in range(asks):
            try:
                got.append(decide_ask(args, case, timeout))
            except Rejected as e:
                rej = str(e)
                break
            except NoAnswer as e:
                why_und = str(e)
                break
        rec = {"key": key, "role": "golden", "question": case["question"]}
        if rej:
            counts["fail"] += 1
            rec.update(verdict="FAIL", reasons=["the engine readout is flagged: " + rej])
            out("[FAIL] %s: %s" % (key, rej))
            report["results"].append(rec)
            continue
        if not got:
            counts["undetermined"] += 1
            rec.update(verdict="UNDETERMINED", reasons=["no answer: %s" % why_und])
            out("[UNDETERMINED] %s: no answer: %s" % (key, why_und))
            report["results"].append(rec)
            continue
        ok, reasons = judge_probe(case, got[0]["content"])
        counts["pass" if ok else "fail"] += 1
        rec.update(verdict="PASS" if ok else "FAIL", answer=got[0]["content"], reasons=reasons)
        report["results"].append(rec)
        out("[%s] %s (%.2fs) choice=%s" % ("PASS" if ok else "FAIL", key, got[0]["seconds"], got[0]["content"]))
        if reasons:
            out("       wrong:  %s" % "; ".join(reasons))
        if why_und:
            counts["undetermined"] += 1
            out("[UNDETERMINED] determinism %s: %s" % (key, why_und))
            continue
        if len(got) > 1:
            same = all(g["raw"] == got[0]["raw"] for g in got)
            counts["pass" if same else "fail"] += 1
            out("[%s] determinism %s: repeat=%d %s" % ("PASS" if same else "FAIL", key, len(got),
                                                       "byte-identical" if same else "the choice/probabilities DIFFER"))
            if not same:
                for i, g in enumerate(got):
                    out("       #%d: %s" % (i + 1, g["raw"]))
            report["determinism"].append({"key": key, "identical": same, "repeat": len(got)})
    return finish()


# --- run --------------------------------------------------------------------------------------------------
DEFAULT_REPEAT = 3   # Constitution 11.4.50: a decision-bearing run asks every probe 3 times; all answers must be identical


def repeat_count():
    """How many times every probe is asked (LLMCTL_VALIDATE_REPEAT, default 3). 1 is the documented QUICK mode: only
    the suite's determinism_repeat probes are asked once more, and the run is never recorded (not decision-bearing)."""
    raw = os.environ.get("LLMCTL_VALIDATE_REPEAT", str(DEFAULT_REPEAT)).strip()
    if not re.fullmatch(r"[1-9][0-9]?", raw):
        raise ValueError("LLMCTL_VALIDATE_REPEAT must be an integer 1..99, got %r" % raw)
    return int(raw)


def request_timeout():
    """LLMCTL_VALIDATE_TIMEOUT seconds (default 180); nan / inf / <= 0 are refused (ValueError)."""
    raw = os.environ.get("LLMCTL_VALIDATE_TIMEOUT", "180")
    t = float(raw)
    if not math.isfinite(t) or t <= 0:
        raise ValueError("LLMCTL_VALIDATE_TIMEOUT must be a finite number > 0, got %r" % raw)
    return t


def run(args):
    suite_dir = os.path.abspath(args.suite)
    suite = load_suite(suite_dir)
    report = {"suite": suite.get("suite"), "kind": suite.get("kind"), "suite_hash": suite_hash(suite_dir),
              "endpoint": redact_url(args.endpoint), "expect_model": args.expect_model, "results": [],
              "controls": [], "determinism": [], "judge_selftest": [], "notes": []}
    counts = {"pass": 0, "fail": 0, "undetermined": 0}
    lines = []

    def out(s=""):
        lines.append(s)
        if not args.json:
            print(s, flush=True)

    out("suite %s (%s) hash %s" % (suite.get("suite"), suite.get("kind"), report["suite_hash"]))
    out("endpoint %s" % redact_url(args.endpoint))
    try:
        timeout = request_timeout()
        repeat = repeat_count()
    except ValueError as e:
        out("[UNDETERMINED] %s" % e)
        counts["undetermined"] += 1
        timeout, repeat = 0, 0
    report.update({"repeat": repeat, "quick": repeat == 1})

    def finish():
        if counts["fail"]:
            verdict, rc = "FAIL", 1
        elif counts["undetermined"] or counts["pass"] == 0:
            verdict, rc = "UNDETERMINED", 2
        else:
            verdict, rc = "PASS", 0
        report.update({"verdict": verdict, "exit_code": rc, "counts": counts})
        if args.report_file:
            with open_private(args.report_file, "w") as fh:
                json.dump({k: report.get(k) for k in ("verdict", "exit_code", "counts", "repeat", "quick", "suite",
                                                       "suite_hash", "served_model", "served_models")}, fh)
        out("VERDICT: %s pass=%d fail=%d undetermined=%d" % (verdict, counts["pass"], counts["fail"],
                                                              counts["undetermined"]))
        if args.json:
            print(json.dumps(report, indent=1))
        if args.verdict_file:
            # the explicit verdict for the caller: a bare exit code 1 is NOT trusted as a FAIL (a crash also exits 1)
            with open_private(args.verdict_file, "w") as fh:
                fh.write(verdict + "\n")
        if args.evidence:
            with open_private(args.evidence, "a") as fh:
                fh.write("\n".join(lines) + "\n")
                fh.write("JSON " + json.dumps(report) + "\n")
        return rc

    if counts["undetermined"]:
        return finish()

    # 0. suite schema: a vacuous / unusable suite is a defect of the suite, never a verdict on the model
    try:
        validate_suite(suite)
    except SuiteDefect as e:
        out("[UNDETERMINED] suite defect: %s" % e)
        report["notes"].append("suite defect: %s" % e)
        counts["undetermined"] += 1
        return finish()

    # 1. integrity
    errs = integrity_errors(suite, suite_dir)
    if errs:
        for e in errs:
            out("[UNDETERMINED] suite integrity: %s" % e)
        report["notes"] += errs
        counts["undetermined"] += 1
        return finish()

    # 2. judge self-test (before any request)
    st = judge_selftest(suite) if suite["kind"] != "embedding" else []
    for ctl, ok, detail in st:
        report["judge_selftest"].append({"probe": ctl["probe"], "answer": ctl["answer"], "ok": ok, "detail": detail})
        if not ok:
            out("[FAIL] judge self-test %s answer=%r: %s" % (ctl["probe"], ctl["answer"], detail))
            counts["fail"] += 1
    if st and all(ok for _, ok, _ in st):
        out("judge self-test: %d/%d canned controls judged as required" % (len(st), len(st)))
    if counts["fail"]:
        out("the judge itself is broken - refusing to judge a model with it")
        return finish()

    if suite["kind"] == "decide":
        return run_decide(args, suite, report, counts, out, finish, timeout, repeat)

    # 3. model identity
    try:
        ids = served_model_ids(args.endpoint, min(timeout, 30))
    except (NoAnswer, Rejected) as e:
        out("[UNDETERMINED] endpoint unreachable: %s" % e)
        counts["undetermined"] += 1
        return finish()
    report["served_models"] = ids
    if args.expect_model:
        # exact identity: the served id IS the expected name, or is a path whose basename is (llama-server serves the path)
        if not any(i == args.expect_model or os.path.basename(i) == args.expect_model for i in ids):
            out("[UNDETERMINED] endpoint serves %s, not the expected model %s" % (ids, args.expect_model))
            counts["undetermined"] += 1
            return finish()
        out("model identity: endpoint serves %s" % ids)

    # 3b. the model FILE of the probed process (local runs: --expect-model-path)
    if args.expect_model_path:
        sm = served_model_info(args.endpoint, args.expect_model_path, ids, timeout, args.expect_launch_env or None)
        report["served_model"] = sm
        if sm.get("mismatch"):
            out("[UNDETERMINED] served model file: %s" % sm["mismatch"])
            counts["undetermined"] += 1
            return finish()
        if sm["confirmed"]:
            out("served model file: %s (confirmed by %s)" % (sm["path"], ", ".join(sm["sources"])))
        else:
            out("[NOTE] served model file UNCONFIRMED: %s" % sm["note"])

    # 4. probes
    if suite["kind"] == "embedding":
        for case in suite.get("cases", []):
            try:
                a, p, n = (embed(args.endpoint, case[k], timeout) for k in ("anchor", "positive", "negative"))
                again = [embed(args.endpoint, case["anchor"], timeout) for _ in range(max(1, repeat - 1))]
            except Rejected as e:
                counts["fail"] += 1
                out("[FAIL] %s: endpoint rejected the request: %s" % (case["id"], e))
                continue
            except NoAnswer as e:
                counts["undetermined"] += 1
                out("[UNDETERMINED] %s: no answer: %s" % (case["id"], e))
                continue
            sp, sn = cosine(a, p), cosine(a, n)
            margin = float(case.get("margin", 0.0))
            same = max((max(abs(x - y) for x, y in zip(a, a2)) if len(a) == len(a2) and a else float("inf"))
                       for a2 in again)
            reasons = []
            if not sp > sn + margin:
                reasons.append("cos(anchor,positive)=%.4f not > cos(anchor,negative)=%.4f + %.4f" % (sp, sn, margin))
            if same > 1e-5:
                reasons.append("non-deterministic embedding: max |delta| %.3g between two identical requests" % same)
            ok = not reasons
            counts["pass" if ok else "fail"] += 1
            out("[%s] %s cos+=%.4f cos-=%.4f dim=%d %s" % ("PASS" if ok else "FAIL", case["id"], sp, sn, len(a),
                                                       "; ".join(reasons)))
            report["results"].append({"key": case["id"], "verdict": "PASS" if ok else "FAIL", "cos_pos": sp,
                                      "cos_neg": sn, "dim": len(a), "reasons": reasons})
        return finish()

    answers = {}

    def do_probe(key, fx, pr, image=None):
        img = os.path.join(suite_dir, image or fx["image"]) if fx else None
        try:
            a = ask(args.endpoint, suite, pr["prompt"], img, timeout)
            return a, None
        except Rejected as e:
            return None, ("rejected", str(e))
        except NoAnswer as e:
            return None, ("noanswer", str(e))

    for key, fx, pr in probes_of(suite):
        if fx is not None and fx.get("role") == "control-bad":
            role = "control-self"
        else:
            role = "golden"
        a, err = do_probe(key, fx, pr)
        rec = {"key": key, "role": role, "prompt": pr["prompt"]}
        if err:
            kind, msg = err
            if kind == "rejected":
                counts["fail"] += 1
                rec.update(verdict="FAIL", reasons=["endpoint rejected the request: " + msg])
                out("[FAIL] %s: endpoint rejected the request: %s" % (key, msg))
            else:
                counts["undetermined"] += 1
                rec.update(verdict="UNDETERMINED", reasons=["no answer: " + msg])
                out("[UNDETERMINED] %s: no answer: %s" % (key, msg))
            report["results"].append(rec)
            continue
        why = undetermined_reason(a, pr)
        if why:
            counts["undetermined"] += 1
            rec.update(verdict="UNDETERMINED", reasons=[why], answer=a["content"], finish_reason=a["finish_reason"])
            report["results"].append(rec)
            out("[UNDETERMINED] %s (%.2fs, finish=%s): %s" % (key, a["seconds"], a["finish_reason"], why))
            continue
        answers[key] = a
        ok, reasons = judge_probe(pr, a["content"])
        counts["pass" if ok else "fail"] += 1
        rec.update(verdict="PASS" if ok else "FAIL", answer=a["content"], finish_reason=a["finish_reason"],
                   seconds=a["seconds"], reasons=reasons)
        report["results"].append(rec)
        out("[%s] %s (%.2fs, finish=%s)" % ("PASS" if ok else "FAIL", key, a["seconds"], a["finish_reason"]))
        out("       answer: %s" % json.dumps(a["content"]))
        if reasons:
            out("       wrong:  %s" % "; ".join(reasons))

    # 5. golden-bad controls must FAIL the golden probe they discriminate against
    if suite["kind"] == "vision":
        index = {k: (fx, pr) for k, fx, pr in probes_of(suite)}
        for fx in suite["fixtures"]:
            for target in fx.get("discriminates", []):
                gfx, gpr = index[target]
                a, err = do_probe(target, gfx, gpr, image=fx["image"])
                key = "%s vs %s" % (fx["id"], target)
                if err:
                    counts["undetermined"] += 1
                    out("[UNDETERMINED] control %s: no answer: %s" % (key, err[1]))
                    report["controls"].append({"key": key, "verdict": "UNDETERMINED", "reasons": [err[1]]})
                    continue
                why = undetermined_reason(a, gpr)
                if why:
                    counts["undetermined"] += 1
                    out("[UNDETERMINED] control %s: %s" % (key, why))
                    report["controls"].append({"key": key, "verdict": "UNDETERMINED", "reasons": [why]})
                    continue
                golden_ok, golden_reasons = judge_probe(gpr, a["content"])
                if golden_ok:
                    counts["fail"] += 1
                    out("[FAIL] control %s: the golden checks PASSED on a golden-bad image - the validator "
                        "does not discriminate (or the model claims content that is not there)" % key)
                    verdict = "FAIL"
                else:
                    counts["pass"] += 1
                    out("[PASS] control %s: golden checks correctly FAIL on the control image (%s)" % (
                        key, "; ".join(golden_reasons)))
                    verdict = "PASS"
                out("       answer: %s" % json.dumps(a["content"]))
                report["controls"].append({"key": key, "verdict": verdict, "answer": a["content"],
                                           "golden_reasons": golden_reasons})

    # 6. determinism (Constitution 11.4.50): every judged probe is asked `repeat` times in total and every answer must be
    # byte-identical. repeat=1 is the QUICK mode: only the suite's determinism_repeat probes are asked once more.
    index = {k: (fx, pr) for k, fx, pr in probes_of(suite)}
    if repeat == 1:
        plan = [(k, 1) for k in suite.get("determinism_repeat", []) if k in answers]
        out("quick mode (LLMCTL_VALIDATE_REPEAT=1): only %s asked once more - NOT a decision-bearing run, never "
            "recorded" % ([k for k, _ in plan] or "no probe"))
    else:
        plan = [(k, repeat - 1) for k, _, _ in probes_of(suite) if k in answers]
    for key, extra in plan:
        fx, pr = index[key]
        diff, und = None, None
        for i in range(extra):
            a, err = do_probe(key, fx, pr)
            if err:
                und = "no answer: %s" % err[1]
                break
            why = undetermined_reason(a)
            if why:
                und = why
                break
            if a["content"] != answers[key]["content"]:
                diff = (i + 2, a["content"])
                break
        if und:
            counts["undetermined"] += 1
            out("[UNDETERMINED] determinism %s: %s" % (key, und))
            report["determinism"].append({"key": key, "identical": None, "repeat": extra + 1})
            continue
        same = diff is None
        counts["pass" if same else "fail"] += 1
        out("[%s] determinism %s: repeat=%d %s" % ("PASS" if same else "FAIL", key, extra + 1,
                                                   "byte-identical" if same else "answer #%d DIFFERS" % diff[0]))
        if not same:
            out("       first:  %s" % json.dumps(answers[key]["content"]))
            out("       #%d:     %s" % (diff[0], json.dumps(diff[1])))
        report["determinism"].append({"key": key, "identical": same, "repeat": extra + 1})
    return finish()


# --- validation state (what `llmctl require-validated` checks) --------------------------------------------
def profile_suites(catalog, profile):
    """(suites, reason): suites listed in the catalog profile's `validation` object."""
    p = catalog["profiles"][profile]
    v = p.get("validation")
    if not isinstance(v, dict):
        return [], "catalog profile %s has no 'validation' entry" % profile
    suites = v.get("suites") or []
    if not suites:
        return [], v.get("reason") or "catalog profile %s lists no validation suite" % profile
    return list(suites), ""


def launch_fingerprint(env_file):
    """sha256 of the service's exec + arguments, ignoring --host/--port (placement, not behaviour)."""
    import shlex
    if not env_file or not os.path.isfile(env_file):
        return "none"
    exe, args = "", []
    with open(env_file) as fh:
        for line in fh:
            if line.startswith("LLMCTL_EXEC="):
                exe = line.split("=", 1)[1].strip()
            elif line.startswith("LLMCTL_ARGS="):
                args = shlex.split(line.split("=", 1)[1])
    kept, skip = [], False
    for t in args:
        if skip:
            skip = False
            continue
        if t in ("--host", "--port"):
            skip = True
            continue
        kept.append(t)
    return hashlib.sha256(("\0".join([exe] + kept)).encode()).hexdigest()


# --- model bytes, host identity, record signing -------------------------------------------------------------
# Finding 3 of the 2026-10-14 review: the record used to bind the catalog's "name:sha" STRINGS and the files' size+mtime,
# so different bytes with a restored size+mtime still validated, and a hand-written JSON file was a "record". Now:
#   * every model file is hashed for real (streaming sha256). The hash is cached in a 0600 file keyed by
#     (size, mtime_ns, ctime_ns, inode, device) - ctime cannot be set back by a user, so ANY write re-hashes - and each
#     cache entry carries an HMAC so an edited cache entry is ignored;
#   * a PASS record is written only when every pinned file equals its catalog sha256, and the record step re-hashes
#     every file whose hash came from the cache (the documented fast path verifies the pin once per record creation);
#   * the record is signed with HMAC-SHA256 under a key kept 0600 in the state directory (created on first use) and
#     binds the sha256 of its own evidence file. LIMIT (documented): this stops accidental and hand-made edits; a
#     malicious process running as the SAME user can read the key and forge a record - it is not a defence against that.
HASH_BLOCK = 1 << 20


def stat_tuple(st):
    return [st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, st.st_dev]


class InsecureKey(Exception):
    """The signing key file is not ours or is readable by group/other."""


def load_hmac_key(path, create=True):
    """The record-signing key (32 random bytes, hex) at `path`; created 0600 (directory 0700) on first use when
    `create`. Raises FileNotFoundError (absent, not created) or InsecureKey."""
    try:
        st = os.stat(path)
    except FileNotFoundError:
        if not create:
            raise
        import secrets
        d = os.path.dirname(path) or "."
        os.makedirs(d, mode=0o700, exist_ok=True)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as fh:
                fh.write(secrets.token_hex(32) + "\n")
        except FileExistsError:
            pass    # another validator created it first: use theirs
        st = os.stat(path)
    if st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise InsecureKey("signing key %s must be owned by uid %d and mode 0600 (is uid %d, mode %o)" % (
            path, os.getuid(), st.st_uid, st.st_mode & 0o777))
    raw = open(path).read().strip()
    if not re.fullmatch(r"[0-9a-f]{64}", raw):
        raise InsecureKey("signing key %s is malformed" % path)
    return bytes.fromhex(raw)


def _canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def sign_record(record, key):
    import hmac
    return hmac.new(key, _canonical({k: v for k, v in record.items() if k != "signature"}), hashlib.sha256).hexdigest()


def signature_ok(record, key):
    import hmac
    sig = record.get("signature")
    return isinstance(sig, str) and hmac.compare_digest(sig, sign_record(record, key))


class HashCache:
    """sha256 of model files, cached by (size, mtime_ns, ctime_ns, inode, device) in a 0600 JSON file. An entry whose HMAC
    does not verify (edited by hand) is ignored and the file is re-hashed."""

    def __init__(self, path, key):
        self.path, self.key, self.data, self.dirty = path, key, {}, False
        if path and os.path.isfile(path):
            try:
                with open(path) as fh:
                    d = json.load(fh)
                self.data = d if isinstance(d, dict) else {}
            except (OSError, ValueError):
                self.data = {}

    def _mac(self, path, st, sha):
        import hmac
        return hmac.new(self.key, _canonical([path, st, sha]), hashlib.sha256).hexdigest()

    def sha256(self, path):
        """(sha256, 'cache'|'hashed', stat list)."""
        st = stat_tuple(os.stat(path))
        e = self.data.get(path)
        import hmac
        if isinstance(e, dict) and e.get("stat") == st and isinstance(e.get("sha256"), str) \
                and hmac.compare_digest(str(e.get("mac", "")), self._mac(path, st, e["sha256"])):
            return e["sha256"], "cache", st
        sha = sha256_file(path)
        st2 = stat_tuple(os.stat(path))
        if st2 == st:   # unchanged while hashing: cacheable
            self.data[path] = {"stat": st, "sha256": sha, "mac": self._mac(path, st, sha)}
            self.dirty = True
        return sha, "hashed", st2

    def save(self):
        if self.dirty and self.path:
            tmp = self.path + ".tmp.%d" % os.getpid()
            with open_private(tmp, "w") as fh:
                json.dump(self.data, fh)
            os.replace(tmp, self.path)


def host_identity():
    """(host_id, source, hostname). host_id = sha256 of a fixed prefix and the machine id (/etc/machine-id, else
    /var/lib/dbus/machine-id); the raw machine id is never written anywhere. Documented fallback when neither is readable:
    the hostname (source 'hostname' - weaker: a hostname can be set to anything). Hermetic tests may point
    LLMCTL_MACHINE_ID_FILE / LLMCTL_TEST_HOSTNAME elsewhere ONLY with LLMCTL_VALIDATE_HERMETIC=1."""
    import socket
    hermetic = os.environ.get("LLMCTL_VALIDATE_HERMETIC") == "1"
    hostname = (os.environ.get("LLMCTL_TEST_HOSTNAME") if hermetic else None) or socket.gethostname()
    files = ["/etc/machine-id", "/var/lib/dbus/machine-id"]
    if hermetic and os.environ.get("LLMCTL_MACHINE_ID_FILE"):
        files = [os.environ["LLMCTL_MACHINE_ID_FILE"]]
    for f in files:
        try:
            mid = open(f).read().strip().lower()
        except OSError:
            continue
        if re.fullmatch(r"[0-9a-f]{32}", mid):
            return hashlib.sha256(b"llmctl-validation-host:" + mid.encode()).hexdigest(), "machine-id", hostname
    return hashlib.sha256(b"llmctl-validation-host:hostname:" + hostname.encode()).hexdigest(), "hostname", hostname


def compute_key(a):
    with open(a.catalog) as fh:
        catalog = json.load(fh)
    if a.profile not in catalog["profiles"]:
        raise KeyError("unknown profile %s" % a.profile)
    p = catalog["profiles"][a.profile]
    hkey = load_hmac_key(a.hmac_key, create=True) if a.hmac_key else None
    cache = HashCache(a.hash_cache, hkey) if (a.hash_cache and hkey) else HashCache("", b"\0" * 32)
    lines, files, mismatch, unpinned = [], [], [], []
    for f in p.get("files", []):
        path = os.path.abspath(os.path.join(a.models_dir, a.profile, f["name"]))
        pin = f.get("sha256") or None
        if os.path.isfile(path):
            sha, src, st = cache.sha256(path)
            size = st[0]
        else:
            sha, src, st, size = None, "missing", None, None
        if pin is None:
            unpinned.append(f["name"])
        elif sha != pin:
            mismatch.append(f["name"])
        lines.append("%s:%s" % (f["name"], sha or "missing"))
        files.append({"name": f["name"], "path": path, "size": size, "sha256": sha, "catalog_sha256": pin,
                      "role": f.get("role") or "model", "stat": st, "hash_source": src})
    cache.save()
    suites, reason = profile_suites(catalog, a.profile)
    if a.only_kind:
        suites = [s for s in suites if load_suite(os.path.join(a.suites_dir, s)).get("kind") == a.only_kind]
    host_id, host_src, hostname = host_identity()
    return {"profile": a.profile, "host": hostname, "host_id": host_id, "host_id_source": host_src,
            "model_sha256": hashlib.sha256("\n".join(lines).encode()).hexdigest(),
            "model_files": files, "pin_mismatch": mismatch, "unpinned_files": unpinned,
            "engine": p.get("engine"), "engine_tag": a.engine_tag,
            "launch_fingerprint": launch_fingerprint(a.env_file),
            "suites": {s: suite_hash(os.path.join(a.suites_dir, s)) for s in suites},
            "no_suite_reason": reason}


def _files_identity(files):
    return [{"name": f.get("name"), "size": f.get("size"), "sha256": f.get("sha256")} for f in (files or [])]


MIN_DECISION_REPEAT = 3


def check_state(state, key, max_age):
    """Return list of reasons the record does not cover the current key (empty = fresh pass). The SIGNATURE is verified
    by the caller (main 'check') before this runs."""
    why = []
    if state.get("status") != "pass":
        why.append("status=%s" % state.get("status"))
    # host: a record produced on another machine (copied state dir, shared home) never validates this one
    for field in ("host_id", "model_sha256", "engine_tag", "launch_fingerprint"):
        if state.get(field) != key.get(field):
            why.append("%s changed (validated %s, now %s)" % (field, json.dumps(state.get(field)),
                                                               json.dumps(key.get(field))))
    if _files_identity(state.get("model_files")) != _files_identity(key.get("model_files")):
        why.append("model files changed on disk (validated %s, now %s)" % (
            json.dumps(_files_identity(state.get("model_files"))), json.dumps(_files_identity(key.get("model_files")))))
    if key.get("pin_mismatch"):
        why.append("model file(s) %s do not match their catalog-pinned sha256 (not the model the catalog names)" %
                   ", ".join(key["pin_mismatch"]))
    if not key.get("suites"):
        why.append("profile has no validation suite: %s" % key.get("no_suite_reason"))
    for s, h in key.get("suites", {}).items():
        if state.get("suites", {}).get(s) != h:
            why.append("suite %s not validated with its current content (hash %s)" % (s, h[:12]))
    rep = state.get("repeat")
    if not isinstance(rep, int) or isinstance(rep, bool) or rep < MIN_DECISION_REPEAT:
        why.append("record is not from a decision-bearing run (repeat=%s, needs >= %d)" % (rep, MIN_DECISION_REPEAT))
    ev, evsha = state.get("evidence_file"), state.get("evidence_sha256")
    try:
        cur = sha256_file(ev) if isinstance(ev, str) and ev else None
    except OSError:
        cur = None
    if not cur or cur != evsha:
        why.append("evidence file of the record is missing or changed (%s)" % (ev or "none"))
    now = time.time()
    try:
        epoch = float(state.get("epoch"))
    except (TypeError, ValueError):
        epoch = None
    if epoch is None or isinstance(state.get("epoch"), bool) or not math.isfinite(epoch):
        why.append("record has no usable epoch (%s)" % json.dumps(state.get("epoch")))
    elif epoch > now + CLOCK_SKEW_SECONDS:
        # a record stamped in the future would stay "fresh" for max_age beyond its real age; never trust it
        why.append("record epoch %d is in the future (now %d): clock skew or a forged record" % (epoch, now))
    else:
        age = now - epoch
        if age > max_age:
            why.append("record is %ds old (max %ds, LLMCTL_VALIDATION_MAX_AGE)" % (age, max_age))
    return why


def parse_max_age(raw):
    """LLMCTL_VALIDATION_MAX_AGE: a finite number of seconds >= 0; nan / inf / negative / garbage -> ValueError."""
    v = float(raw)
    if not math.isfinite(v) or v < 0:
        raise ValueError("max age must be a finite number of seconds >= 0, got %r" % raw)
    return v


def do_record(a):
    """The `record` subcommand. Exit 0 written (or a prior PASS/FAIL kept); 4 not recorded: quick-mode run; 5 refused:
    the model is not the pinned / validated bytes; 2 cannot record (key / IO)."""
    with open(a.key) as fh:
        key = json.load(fh)
    reports = []
    for rf in a.report or []:
        try:
            with open(rf) as fh:
                reports.append(json.load(fh))
        except (OSError, ValueError):
            reports.append({})
    prior = {}
    if os.path.isfile(a.out):
        try:
            with open(a.out) as fh:
                prior = json.load(fh)
        except (OSError, ValueError):
            prior = {}
    if a.status == "undetermined" and prior.get("status") in ("pass", "fail"):
        # could-not-determine is not evidence against an earlier verdict (endpoint blip, OOM on start): a PASS or a FAIL
        # record is kept. require-validated still compares the record to the CURRENT key, so a stale pass is refused.
        print("kept prior %s record %s (this run was UNDETERMINED)" % (prior["status"], a.out))
        return 0
    repeat = min([r.get("repeat") or 0 for r in reports] or [0])
    if a.status == "pass":
        if repeat < MIN_DECISION_REPEAT:
            print("quick mode run (repeat=%s): NOT recorded - only a run that asks every probe >= %d times "
                  "(LLMCTL_VALIDATE_REPEAT) can validate a profile" % (repeat, MIN_DECISION_REPEAT))
            return 4
        if key.get("pin_mismatch"):
            print("NOT recorded: model file(s) %s do not match their catalog-pinned sha256" % ", ".join(key["pin_mismatch"]))
            return 5
        for f in key.get("model_files", []):
            path = f.get("path")
            try:
                st = stat_tuple(os.stat(path))
            except (OSError, TypeError):
                print("NOT recorded: model file %s disappeared during validation" % f.get("name"))
                return 5
            if st != f.get("stat"):
                print("NOT recorded: model file %s changed during validation" % f.get("name"))
                return 5
            if f.get("hash_source") != "hashed":
                # the fast path (hash cache) is verified once per record creation: the bytes are hashed now
                if sha256_file(path) != f.get("sha256"):
                    print("NOT recorded: model file %s does not hash to its cached sha256" % f.get("name"))
                    return 5
        for r in reports:
            sm = r.get("served_model") or {}
            if sm.get("mismatch"):
                print("NOT recorded: %s" % sm["mismatch"])
                return 5
    try:
        hkey = load_hmac_key(a.hmac_key, create=True)
    except (OSError, InsecureKey) as e:
        print("NOT recorded: %s" % e)
        return 2
    rec = {k: v for k, v in key.items() if k not in ("pin_mismatch",)}
    rec["model_files"] = [{k: v for k, v in f.items() if k not in ("stat", "hash_source")} for f in key.get("model_files", [])]
    served = [r.get("served_model") for r in reports if r.get("served_model")]
    rec.update({"status": a.status, "epoch": int(time.time()),
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "repeat": repeat,
                "served_model": served[0] if served else None})
    if a.evidence and os.path.isfile(a.evidence):
        rec["evidence_file"] = os.path.abspath(a.evidence)
        rec["evidence_sha256"] = sha256_file(a.evidence)
    else:
        rec["evidence_file"], rec["evidence_sha256"] = None, None
    rec["signature"] = sign_record(rec, hkey)
    tmp = a.out + ".tmp.%d" % os.getpid()
    with open_private(tmp, "w") as fh:
        json.dump(rec, fh, indent=1, sort_keys=True)
    os.replace(tmp, a.out)
    old_ev = prior.get("evidence_file")
    if isinstance(old_ev, str) and old_ev != rec.get("evidence_file") and \
            os.path.dirname(os.path.abspath(old_ev)) == os.path.dirname(os.path.abspath(a.out)) and \
            os.path.basename(old_ev).startswith(os.path.basename(a.out)[:-len(".json")] + ".evidence."):
        try:
            os.remove(old_ev)   # the replaced record's evidence snapshot (only ours, only in the state dir)
        except OSError:
            pass
    return 0


def do_check(a):
    """The `check` subcommand: 0 fresh, signed passing record; 1 not validated (reasons on stdout); 2 cannot determine
    (bad --max-age, insecure key)."""
    try:
        max_age = parse_max_age(a.max_age)
    except ValueError as e:
        print("LLMCTL_VALIDATION_MAX_AGE refused: %s" % e)
        return 2
    if not os.path.isfile(a.state):
        print("no validation record (%s)" % a.state)
        return 1
    try:
        with open(a.state) as fh:
            state = json.load(fh)
        with open(a.key) as fh:
            key = json.load(fh)
    except (OSError, ValueError) as e:
        print("unreadable validation record or key: %s" % e)
        return 1
    if not isinstance(state, dict):
        print("validation record is not a JSON object")
        return 1
    try:
        hkey = load_hmac_key(a.hmac_key, create=False) if a.hmac_key else None
    except FileNotFoundError:
        hkey = None
    except InsecureKey as e:
        print("cannot verify the record: %s" % e)
        return 2
    why = []
    if hkey is None:
        why.append("record signature cannot be verified: no signing key (%s)" % (a.hmac_key or "none given"))
    elif not signature_ok(state, hkey):
        why.append("record signature invalid: the record was written or edited by something other than llmctl validate")
    why += check_state(state, key, max_age)
    if why:
        for w in why:
            print(w)
        return 1
    print("fresh passing validation from %s (suites: %s)" % (state.get("timestamp"), ", ".join(sorted(state.get("suites", {})))))
    return 0


def do_coverage(a):
    """`coverage`: one line per catalog profile - a signed, unexpired PASS record, or NOT VALIDATED with the reason;
    profiles/suites never executed against their real model say so."""
    with open(a.catalog) as fh:
        cat = json.load(fh)["profiles"]
    try:
        hkey = load_hmac_key(a.hmac_key, create=False)
    except (FileNotFoundError, InsecureKey):
        hkey = None
    try:
        max_age = parse_max_age(a.max_age)
    except ValueError:
        max_age = 0
    bad = 0
    items = [(a.profile, cat[a.profile])] if a.profile else list(cat.items())
    for name, prof in items:
        v = prof.get("validation") if isinstance(prof.get("validation"), dict) else {}
        suites = v.get("suites") or []
        unexec = []
        if v.get("executed") is False:
            unexec.append(v.get("unexecuted_reason") or "catalog marks this profile's validation as never executed")
        for sname in suites:
            try:
                if load_suite(os.path.join(a.suites_dir, sname)).get("execution_status") == "unexecuted":
                    unexec.append("suite %s was never executed against a real model" % sname)
            except (OSError, ValueError):
                unexec.append("suite %s is missing" % sname)
        note = ("; never executed against its real model: " + " | ".join(unexec)) if unexec else ""
        rec_path = os.path.join(a.state_dir, name + ".json")
        why = None
        if not suites:
            why = "no validation suite"
        elif not os.path.isfile(rec_path):
            why = "no validation record"
        else:
            try:
                with open(rec_path) as fh:
                    rec = json.load(fh)
            except (OSError, ValueError):
                rec = {}
            if hkey is None or not signature_ok(rec, hkey):
                why = "record signature invalid or unverifiable"
            elif rec.get("status") != "pass":
                why = "last recorded verdict: %s" % rec.get("status")
            else:
                try:
                    age = time.time() - float(rec.get("epoch"))
                except (TypeError, ValueError):
                    age = float("inf")
                if not math.isfinite(age) or age > max_age or age < -CLOCK_SKEW_SECONDS:
                    why = "PASS record expired or undated"
        if why:
            bad += 1
            print("  %s: NOT VALIDATED - %s%s" % (name, why, note))
        else:
            print("  %s: validated (signed PASS record %s; model bytes re-checked by require-validated)%s" % (
                name, rec.get("timestamp"), note))
    if not a.profile:
        print("NOT VALIDATED: %d of %d catalog profiles" % (bad, len(cat)))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="deterministic llmctl model validation")
    sub = ap.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("key")
    for opt in ("--catalog", "--profile", "--models-dir", "--suites-dir"):
        k.add_argument(opt, required=True)
    k.add_argument("--engine-tag", default="unknown")
    k.add_argument("--env-file", default="")
    k.add_argument("--only-kind", default="")
    k.add_argument("--hash-cache", default="", help="0600 sha256 cache of model files (state dir)")
    k.add_argument("--hmac-key", default="", help="0600 signing key (state dir); created on first use")
    rec = sub.add_parser("record")
    rec.add_argument("--key", required=True)
    rec.add_argument("--status", required=True, choices=["pass", "fail", "undetermined"])
    rec.add_argument("--evidence", default="")
    rec.add_argument("--out", required=True)
    rec.add_argument("--hmac-key", required=True)
    rec.add_argument("--report", action="append", default=[], help="a run's --report-file (repeatable)")
    chk = sub.add_parser("check")
    chk.add_argument("--state", required=True)
    chk.add_argument("--key", required=True)
    chk.add_argument("--max-age", default="604800")
    chk.add_argument("--hmac-key", default="")
    cv = sub.add_parser("coverage")
    cv.add_argument("--catalog", required=True)
    cv.add_argument("--state-dir", required=True)
    cv.add_argument("--suites-dir", required=True)
    cv.add_argument("--hmac-key", default="")
    cv.add_argument("--max-age", default="604800")
    cv.add_argument("--profile", default="", help="one catalog profile only (llmctl status)")
    r = sub.add_parser("run")
    r.add_argument("--suite", required=True)
    r.add_argument("--endpoint", required=True)
    r.add_argument("--expect-model", default="")
    r.add_argument("--expect-model-path", default="", help="the file/dir the probed process must load (local runs)")
    r.add_argument("--expect-launch-env", default="", help="the env record whose launch the probed process must run (local runs)")
    r.add_argument("--decide-bin", default="", help="llmctl-decide binary (decide suites)")
    r.add_argument("--decide-protocol", default="", help="the profile's decision protocol (decide suites)")
    r.add_argument("--decide-key-file", default="", help="0600 engine key file passed to the driver (never read here)")
    r.add_argument("--json", action="store_true")
    r.add_argument("--evidence", default="")
    r.add_argument("--verdict-file", default="", help="write the final verdict word (PASS/FAIL/UNDETERMINED) here")
    r.add_argument("--report-file", default="", help="write a small JSON summary (verdict, repeat, served model) here")
    s = sub.add_parser("selftest")
    s.add_argument("--suite", required=True)
    rd = sub.add_parser("redact")
    rd.add_argument("url")
    h = sub.add_parser("hash")
    h.add_argument("--suite", required=True)
    a = ap.parse_args(argv)
    if a.cmd == "key":
        try:
            print(json.dumps(compute_key(a), sort_keys=True))
        except (KeyError, OSError, ValueError, InsecureKey) as e:
            # an unknown profile key (e.g. a scaled instance "decide.2") is "cannot determine", never a traceback
            print("[UNDETERMINED] cannot compute a validation key for %r: %s" % (a.profile, e), file=sys.stderr)
            return 2
        return 0
    if a.cmd == "record":
        return do_record(a)
    if a.cmd == "check":
        return do_check(a)
    if a.cmd == "coverage":
        return do_coverage(a)
    if a.cmd == "redact":
        print(redact_url(a.url))
        return 0
    if a.cmd == "hash":
        print(suite_hash(os.path.abspath(a.suite)))
        return 0
    if a.cmd == "selftest":
        suite = load_suite(a.suite)
        try:
            validate_suite(suite)
        except SuiteDefect as e:
            print("BROKEN suite defect: %s" % e)
            print("judge self-test: refused (the suite itself is unusable)")
            return 1
        res = judge_selftest(suite)
        bad = [r for r in res if not r[1]]
        for ctl, ok, detail in res:
            print("%s %s answer=%r %s" % ("ok" if ok else "BROKEN", ctl["probe"], ctl["answer"], detail))
        print("judge self-test: %d/%d as required" % (len(res) - len(bad), len(res)))
        return 1 if bad or not res else 0
    try:
        return run(a)
    except Exception as e:     # noqa: BLE001 - exit 1 is reserved for an explicit "VERDICT: FAIL"; anything else is UNDETERMINED
        print("[UNDETERMINED] validation could not complete: %s: %s" % (type(e).__name__, e))
        print("VERDICT: UNDETERMINED pass=0 fail=0 undetermined=1")
        return 2


if __name__ == "__main__":
    sys.exit(main())
