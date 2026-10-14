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
  6. determinism: the probes listed in determinism_repeat are asked twice; answers must be identical

Exit codes: 0 every check passed; 1 any wrong result (or a broken judge/undiscriminating control);
            2 could not determine (endpoint down, no answer, wrong model served, corrupt suite, ...).
A wrong result outranks could-not-determine (1 beats 2).

Usage:
  validate_judge.py run --suite DIR --endpoint URL [--expect-model NAME] [--json] [--evidence FILE]
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


# --- normalisation + checks (the deterministic judge) -----------------------------------------------------
def norm(text):
    """Upper-case, every run of non-alphanumerics -> one space, padded so boundary matching is ' X '."""
    return " " + re.sub(r"[^A-Z0-9]+", " ", str(text).upper()).strip() + " "


def has_token(answer_norm, needle):
    n = norm(needle)
    return n.strip() != "" and n in answer_norm


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


def first_number(raw):
    """The number an answer states, None if absent. Rule (documented in docs/validation.md):
    when the answer restates an equation ("17 + 25 = 42") it is the number right after the LAST '=';
    otherwise it is the FIRST number in the answer (digits, or an English number word zero..twenty that is
    not part of a hyphenated compound such as 'twenty-two')."""
    eq = [m.end() for m in re.finditer(r"=\s*", raw)]
    for end in reversed(eq):
        m = re.match(_NUM_RE, raw[end:])
        if m:
            return float(m.group(0).replace(",", "."))
        w = _WORD_RE.match(raw, end)
        if w:
            return float(NUMBER_WORDS[w.group(1).lower()])
    b = _number_at(raw, 0)
    return None if b is None else b[1]


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


def judge(checks, answer):
    """Return (passed: bool, reasons: [str]). Pure function of (checks, answer)."""
    raw = "" if answer is None else str(answer)
    reasons = []
    if not raw.strip():
        return False, ["empty answer"]
    an = norm(raw)
    for key, val in checks.items():
        if key == "contains_all":
            miss = [t for t in val if not has_token(an, t)]
            if miss:
                reasons.append("contains_all: missing %s" % miss)
        elif key == "contains_any":
            if not any(has_token(an, t) for t in val):
                reasons.append("contains_any: none of %s present" % val)
        elif key == "ordered":
            pos, bad = 0, None
            for t in val:
                k = an.find(norm(t), pos)
                if k < 0:
                    bad = t
                    break
                pos = k + len(norm(t)) - 1
            if bad is not None:
                reasons.append("ordered: %r not found after the previous item (expected order %s)" % (bad, val))
        elif key == "forbidden":
            hit = [t for t in val if has_token(an, t)]
            if hit:
                reasons.append("forbidden: answer claims %s" % hit)
        elif key == "number_equals":
            got = first_number(raw)
            if got is None or not math.isclose(got, float(val), rel_tol=0, abs_tol=1e-9):
                reasons.append("number_equals: expected %s, first number in answer is %s" % (val, got))
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
                diff = {k: obj.get(k) for k, v in val.items() if obj.get(k) != v}
                if diff:
                    reasons.append("json_subset: expected %s, got %s" % (val, diff))
        else:
            reasons.append("unknown check type %r (suite/judge mismatch)" % key)
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


def judge_selftest(suite):
    """Judge the canned judge_controls. Returns list of (control, ok, detail)."""
    index = {k: pr for k, _, pr in probes_of(suite)}
    res = []
    for ctl in suite.get("judge_controls", []):
        pr = index.get(ctl["probe"])
        if pr is None:
            res.append((ctl, False, "judge control names unknown probe %r" % ctl["probe"]))
            continue
        passed, reasons = judge(pr["checks"], ctl["answer"])
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


def undetermined_reason(a, checks=None):
    """None when the completion may be judged as it stands. Otherwise the reason it cannot be judged (UNDETERMINED,
    exit 2 - never PASS, never FAIL):
      * finish_reason=length WITH reasoning content: the budget went into the reasoning channel, the final answer
        never came;
      * finish_reason=length, no reasoning content, and the (truncated) content PASSES `checks` (or no checks are
        given): the pass cannot be trusted to be a complete answer;
      * empty content with reasoning content (finish_reason=stop).
    A truncated answer that is WRONG is a FAIL (judged normally), as is an empty answer with no reasoning content."""
    rc = a.get("reasoning_chars", 0)
    if a.get("finish_reason") == "length":
        hint = ("answer truncated (finish_reason=length, max_tokens=%s, reasoning_chars=%s): the model did not "
                "finish within the request budget - raise request.max_tokens in the suite; this is not a verdict "
                "on the answer" % (a.get("max_tokens"), rc))
        if rc > 0 or checks is None:
            return hint
        if judge(checks, a.get("content", ""))[0]:
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


# --- run --------------------------------------------------------------------------------------------------
def run(args):
    suite_dir = os.path.abspath(args.suite)
    suite = load_suite(suite_dir)
    timeout = float(os.environ.get("LLMCTL_VALIDATE_TIMEOUT", "180"))
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

    def finish():
        if counts["fail"]:
            verdict, rc = "FAIL", 1
        elif counts["undetermined"] or counts["pass"] == 0:
            verdict, rc = "UNDETERMINED", 2
        else:
            verdict, rc = "PASS", 0
        report.update({"verdict": verdict, "exit_code": rc, "counts": counts})
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

    # 4. probes
    if suite["kind"] == "embedding":
        for case in suite.get("cases", []):
            try:
                a, p, n = (embed(args.endpoint, case[k], timeout) for k in ("anchor", "positive", "negative"))
                a2 = embed(args.endpoint, case["anchor"], timeout)
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
            same = max(abs(x - y) for x, y in zip(a, a2)) if len(a) == len(a2) else float("inf")
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
        why = undetermined_reason(a, pr["checks"])
        if why:
            counts["undetermined"] += 1
            rec.update(verdict="UNDETERMINED", reasons=[why], answer=a["content"], finish_reason=a["finish_reason"])
            report["results"].append(rec)
            out("[UNDETERMINED] %s (%.2fs, finish=%s): %s" % (key, a["seconds"], a["finish_reason"], why))
            continue
        answers[key] = a
        ok, reasons = judge(pr["checks"], a["content"])
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
                why = undetermined_reason(a, gpr["checks"])
                if why:
                    counts["undetermined"] += 1
                    out("[UNDETERMINED] control %s: %s" % (key, why))
                    report["controls"].append({"key": key, "verdict": "UNDETERMINED", "reasons": [why]})
                    continue
                golden_ok, golden_reasons = judge(gpr["checks"], a["content"])
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

    # 6. determinism
    index = {k: (fx, pr) for k, fx, pr in probes_of(suite)}
    for key in suite.get("determinism_repeat", []):
        if key not in answers:
            continue
        fx, pr = index[key]
        a, err = do_probe(key, fx, pr)
        if err:
            counts["undetermined"] += 1
            out("[UNDETERMINED] determinism %s: no answer: %s" % (key, err[1]))
            continue
        why = undetermined_reason(a)
        if why:
            counts["undetermined"] += 1
            out("[UNDETERMINED] determinism %s: %s" % (key, why))
            continue
        same = a["content"] == answers[key]["content"]
        counts["pass" if same else "fail"] += 1
        out("[%s] determinism %s: repeated request %s" % ("PASS" if same else "FAIL", key,
                                                         "byte-identical" if same else "DIFFERS"))
        if not same:
            out("       first:  %s" % json.dumps(answers[key]["content"]))
            out("       second: %s" % json.dumps(a["content"]))
        report["determinism"].append({"key": key, "identical": same})
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


def compute_key(a):
    with open(a.catalog) as fh:
        catalog = json.load(fh)
    if a.profile not in catalog["profiles"]:
        raise KeyError("unknown profile %s" % a.profile)
    p = catalog["profiles"][a.profile]
    lines, files = [], []
    for f in p.get("files", []):
        lines.append("%s:%s" % (f["name"], f.get("sha256") or "none"))
        path = os.path.join(a.models_dir, a.profile, f["name"])
        st = os.stat(path) if os.path.isfile(path) else None
        files.append({"name": f["name"], "size": st.st_size if st else None,
                      "mtime": int(st.st_mtime) if st else None})
    suites, reason = profile_suites(catalog, a.profile)
    if a.only_kind:
        suites = [s for s in suites if load_suite(os.path.join(a.suites_dir, s)).get("kind") == a.only_kind]
    import socket
    return {"profile": a.profile, "host": socket.gethostname(),
            "model_sha256": hashlib.sha256("\n".join(lines).encode()).hexdigest(),
            "model_files": files, "engine_tag": a.engine_tag,
            "launch_fingerprint": launch_fingerprint(a.env_file),
            "suites": {s: suite_hash(os.path.join(a.suites_dir, s)) for s in suites},
            "no_suite_reason": reason}


def check_state(state, key, max_age):
    """Return list of reasons the record does not cover the current key (empty = fresh pass)."""
    why = []
    if state.get("status") != "pass":
        why.append("status=%s" % state.get("status"))
    # host: a record produced on another machine (copied state dir, shared home) never validates this one
    for field in ("host", "model_sha256", "model_files", "engine_tag", "launch_fingerprint"):
        if state.get(field) != key.get(field):
            why.append("%s changed (validated %s, now %s)" % (field, json.dumps(state.get(field)),
                                                               json.dumps(key.get(field))))
    if not key.get("suites"):
        why.append("profile has no validation suite: %s" % key.get("no_suite_reason"))
    for s, h in key.get("suites", {}).items():
        if state.get("suites", {}).get(s) != h:
            why.append("suite %s not validated with its current content (hash %s)" % (s, h[:12]))
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


def main(argv=None):
    ap = argparse.ArgumentParser(description="deterministic llmctl model validation")
    sub = ap.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("key")
    for opt in ("--catalog", "--profile", "--models-dir", "--suites-dir"):
        k.add_argument(opt, required=True)
    k.add_argument("--engine-tag", default="unknown")
    k.add_argument("--env-file", default="")
    k.add_argument("--only-kind", default="")
    rec = sub.add_parser("record")
    rec.add_argument("--key", required=True)
    rec.add_argument("--status", required=True, choices=["pass", "fail", "undetermined"])
    rec.add_argument("--evidence", default="")
    rec.add_argument("--out", required=True)
    chk = sub.add_parser("check")
    chk.add_argument("--state", required=True)
    chk.add_argument("--key", required=True)
    chk.add_argument("--max-age", type=float, default=604800)
    r = sub.add_parser("run")
    r.add_argument("--suite", required=True)
    r.add_argument("--endpoint", required=True)
    r.add_argument("--expect-model", default="")
    r.add_argument("--json", action="store_true")
    r.add_argument("--evidence", default="")
    r.add_argument("--verdict-file", default="", help="write the final verdict word (PASS/FAIL/UNDETERMINED) here")
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
        except (KeyError, OSError, ValueError) as e:
            # an unknown profile key (e.g. a scaled instance "decide.2") is "cannot determine", never a traceback
            print("[UNDETERMINED] cannot compute a validation key for %r: %s" % (a.profile, e), file=sys.stderr)
            return 2
        return 0
    if a.cmd == "record":
        with open(a.key) as fh:
            key = json.load(fh)
        if a.status == "undetermined" and os.path.isfile(a.out):
            # could-not-determine is not evidence against an earlier PASS (endpoint blip, OOM on start):
            # keep it. require-validated still compares the record to the CURRENT key, so a stale pass
            # for a changed model/engine/suite is refused regardless.
            try:
                with open(a.out) as fh:
                    prior = json.load(fh)
            except (OSError, ValueError):
                prior = {}
            if prior.get("status") == "pass":
                print("kept prior pass record %s (this run was UNDETERMINED)" % a.out)
                return 0
        key.update({"status": a.status, "epoch": int(time.time()),
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "evidence": a.evidence})
        tmp = a.out + ".tmp"
        with open_private(tmp, "w") as fh:
            json.dump(key, fh, indent=1, sort_keys=True)
        os.replace(tmp, a.out)
        return 0
    if a.cmd == "check":
        if not os.path.isfile(a.state):
            print("no validation record (%s)" % a.state)
            return 1
        with open(a.state) as fh:
            state = json.load(fh)
        with open(a.key) as fh:
            key = json.load(fh)
        why = check_state(state, key, a.max_age)
        if why:
            for w in why:
                print(w)
            return 1
        print("fresh passing validation from %s (suites: %s)" % (state.get("timestamp"),
                                                                 ", ".join(sorted(state.get("suites", {})))))
        return 0
    if a.cmd == "redact":
        print(redact_url(a.url))
        return 0
    if a.cmd == "hash":
        print(suite_hash(os.path.abspath(a.suite)))
        return 0
    if a.cmd == "selftest":
        suite = load_suite(a.suite)
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
