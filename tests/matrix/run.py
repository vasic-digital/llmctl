#!/usr/bin/env python3
"""Client-by-call matrix runner (FR-069, SC-013; specs/009-jev-decision-models).

For every case of contracts/endpoint-inventory.tsv x every client x every vantage it executes the
call through an independent client process, compares status / error type / body shape / headers to the
contract, and writes ONE evidence record per cell with tests/evidence/writer.py (result pass | fail |
not-exercised + a reason CLASS). It then emits matrix.json and a completeness check: every inventory
row must appear for every client, and every not-exercised cell must fall in a class fixed in advance.

Target: by default a self-contained reference HTTPS server (tests/matrix/refserver, class `stand-in` -
it validates the HARNESS only). The real gateway is targeted with the same runner:

    LLMCTL_API_KEY=... python3 -B tests/matrix/run.py --base-url https://HOST:PORT --cacert ca.pem \
        --server-cert server-cert.pem --engine-port N --scenario-hook ./hook.sh --run-dir RUNDIR

Verify a finished run independently:  run.py --check RUNDIR
"""
import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, ROOT)

from tests.evidence import leak_scan, manifest, writer  # noqa: E402
from tests.matrix import cases as C  # noqa: E402
from tests.matrix import transport as T  # noqa: E402

DEFAULT_INVENTORY = os.path.join(ROOT, "specs", "009-jev-decision-models", "contracts", "endpoint-inventory.tsv")

PROGRAMMATIC = ["curl", "python-urllib", "python-requests", "node-fetch", "go-nethttp"]
DEFAULT_CLIENTS = PROGRAMMATIC + ["chromium"]
SDK_CLIENTS = ["typesafe-sdk-py", "typesafe-sdk-js"]
PENDING_ADAPTERS = {"llmctl-cli": "llmctl-decide ask adapter is wired later (T-runner follow-up)",
                    "agent:*": "the seven coding-agent adapters are wired later (defined subset: one authenticated "
                               "success call + one unauthenticated call each)"}

# Classes of "not-exercised" fixed in advance. FR-069 names the first three; the rest are proposals that
# need spec sign-off and are counted separately in matrix.json (classes_beyond_fr069).
NE_CLASSES_FR069 = {
    "browser-non-get": "browser client on non-GET cases (FR-069)",
    "agent-outside-subset": "agents outside their defined subset (FR-069)",
    "sdk-no-ca-trust": "hosted SDK where no CA-trust mechanism works (FR-069; recorded as a trust-configuration failure)",
}
NE_CLASSES_PROPOSED = {
    "sdk-outside-subset": "SDK exposes only POST /v1/systemone and GET /v1/models; other cases are outside its surface",
    "transport-not-per-client": "transport-level behaviour (slow client, connection cap, engine port) is client-independent; "
                                "executed once by the stdlib socket helper under python-urllib (and curl for the engine port)",
}
NE_CLASS_ENV = "env-gap"  # client/runtime/network missing on this host: honest, but a FAIL of the strict gate unless allowed
ALL_NE_CLASSES = set(NE_CLASSES_FR069) | set(NE_CLASSES_PROPOSED) | {NE_CLASS_ENV}

TRANSPORT_CLIENT = {"slow-client": ["python-urllib"], "conn-cap": ["python-urllib"],
                    "engine-port": ["curl", "python-urllib"]}


# ----------------------------------------------------------------------- inventory

def load_inventory(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            parts = line.split("\t")
            rows.append(dict(zip(header, parts)))
    return rows


def req_ids(text):
    out = []
    for tok in re.split(r"[,\s]+", text or ""):
        tok = tok.strip()
        if not tok or tok == "-":
            continue
        out.append(tok if tok.startswith(("FR-", "SC-", "D-", "OD-")) else "FR-" + tok)
    return out or ["FR-069"]


# ---------------------------------------------------------------- completeness check

def check_completeness(inv_ids, handler_ids, clients, vantages, cells, allow_env_gaps):
    """Pure function: returns a list of problem strings (empty = complete)."""
    problems = []
    for i in sorted(set(inv_ids) - set(handler_ids)):
        problems.append("inventory row %s has no handler in the case table (untested call)" % i)
    for i in sorted(set(handler_ids) - set(inv_ids)):
        problems.append("case %s exists in the harness but not in the inventory (inventory row removed?)" % i)
    seen = {}
    for c in cells:
        key = (c["case_id"], c["client"], c["vantage"])
        if key in seen:
            problems.append("duplicate cell %s" % (key,))
        seen[key] = c
        if c["case_id"] not in inv_ids or c["client"] not in clients or c["vantage"] not in vantages:
            problems.append("unexpected cell %s" % (key,))
        if c["result"] == "not-exercised":
            cls = c.get("reason_class")
            if cls not in ALL_NE_CLASSES:
                problems.append("cell %s not-exercised with undeclared class %r" % (key, cls))
            elif cls == NE_CLASS_ENV and not allow_env_gaps:
                problems.append("cell %s not-exercised: env-gap (%s)" % (key, c.get("reason", "")))
    for cid in inv_ids:
        for cl in clients:
            for v in vantages:
                if (cid, cl, v) not in seen:
                    problems.append("MISSING cell %s x %s x %s" % (cid, cl, v))
    return problems


# ------------------------------------------------------------------ client plumbing

class Resp:
    def __init__(self):
        self.status = None
        self.headers = {}
        self.body = b""
        self.error = None
        self.trust = []
        self.rc = 0
        self.raw = ""
        self.ms = 0


def parse_lines(text):
    r = Resp()
    r.raw = text
    for line in text.splitlines():
        if line.startswith("STATUS "):
            r.status = int(line[7:].strip())
        elif line.startswith("HEADER "):
            k, _, v = line[7:].partition(":")
            r.headers[k.strip().lower()] = v.strip()
        elif line.startswith("BODY_B64 "):
            try:
                r.body = base64.b64decode(line[9:])
            except ValueError:
                r.error = "adapter produced invalid base64"
        elif line.startswith("ERROR "):
            r.error = line[6:]
        elif line.startswith("TRUST "):
            r.trust.append(line[6:])
    return r


class Env:
    """Everything the runner knows about the target and its clients."""

    def __init__(self, a, work):
        self.a = a
        self.work = work
        self.cmds = {}          # client -> argv prefix
        self.extra_env = {}     # client -> env additions
        self.avail = {}         # client -> (ok, reason)
        self.client_dir = os.environ.get("MATRIX_CLIENT_DIR") or os.path.join(HERE, "clients")
        self.key = None
        self.cacert = a.cacert
        self.base = a.base_url
        self.scenario_header = False
        self.proc = None
        self.engine_port = a.engine_port
        self.cls = "real-component"
        self.spki = None
        self.sleep = time.sleep   # injectable for tests
        self.model = getattr(a, "model", None)

    # ---- clients
    def prepare(self, wanted):
        cd = self.client_dir
        py = sys.executable
        self.cmds["curl"] = ["bash", os.path.join(cd, "curl.sh")]
        self.avail["curl"] = (bool(shutil.which("curl")), "curl not installed")
        self.cmds["python-urllib"] = [py, "-B", os.path.join(cd, "python_urllib.py")]
        self.avail["python-urllib"] = (True, "")
        self.cmds["python-requests"] = [py, "-B", os.path.join(cd, "python_requests.py")]
        r = subprocess.run([py, "-B", "-c", "import requests"], capture_output=True)
        self.avail["python-requests"] = (r.returncode == 0, "python module 'requests' is not installed "
                                                            "(install it: pip install requests)")
        node = shutil.which("node")
        self.cmds["node-fetch"] = [node or "node", os.path.join(cd, "node_https.mjs")]
        self.avail["node-fetch"] = (bool(node), "node not installed")
        if "go-nethttp" in wanted:
            self.avail["go-nethttp"] = self._build_go()
        if "chromium" in wanted:
            binp = os.environ.get("MATRIX_CHROMIUM_BIN") or shutil.which("chromium") or shutil.which("chromium-browser") \
                or shutil.which("google-chrome")
            ok = bool(binp and node)
            self.cmds["chromium"] = [node or "node", os.path.join(cd, "chromium_cdp.mjs")]
            self.extra_env["chromium"] = {"MATRIX_CHROMIUM_BIN": binp or "chromium", "MATRIX_CHROMIUM_SPKI": self.spki or ""}
            self.avail["chromium"] = (ok, "no browser installed (chromium / google-chrome not found)" if not binp else "node missing")
        if "typesafe-sdk-py" in wanted:
            self.avail["typesafe-sdk-py"] = self._sdk_py()
        if "typesafe-sdk-js" in wanted:
            self.avail["typesafe-sdk-js"] = self._sdk_js()

    def _build_go(self):
        if not shutil.which("go"):
            return False, "go toolchain not installed"
        out = os.path.join(self.work, "go_client")
        src = os.path.join(self.client_dir, "go_client", "main.go")
        r = subprocess.run(["go", "build", "-o", out, src], capture_output=True, text=True, cwd=HERE,
                           env=dict(os.environ, GOFLAGS="", GOWORK="off"))
        if r.returncode != 0:
            return False, "go build failed: " + r.stderr.strip()[-300:]
        self.cmds["go-nethttp"] = [out]
        return True, ""

    def _sdk_py(self):
        uv = shutil.which("uv")
        if not uv:
            return False, "uv not installed (cannot create the private venv for typesafe-sdk)"
        v = os.path.join(self.work, "sdkvenv")
        for cmd in ([uv, "venv", "-q", v], [uv, "pip", "install", "-q", "--python", os.path.join(v, "bin", "python"), "typesafe-sdk"]):
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if r.returncode != 0:
                return False, "SDK install failed: " + (r.stderr or r.stdout).strip()[-300:]
        self.cmds["typesafe-sdk-py"] = [os.path.join(v, "bin", "python"), "-B", os.path.join(self.client_dir, "sdk_py.py")]
        return True, ""

    def _sdk_js(self):
        npm, node = shutil.which("npm"), shutil.which("node")
        if not (npm and node):
            return False, "npm/node not installed"
        d = os.path.join(self.work, "sdknpm")
        os.makedirs(d, exist_ok=True)
        r = subprocess.run([npm, "install", "--prefix", d, "--silent", "--no-audit", "--no-fund", "@typesafe-ai/sdk"],
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            return False, "SDK install failed: " + (r.stderr or r.stdout).strip()[-300:]
        self.cmds["typesafe-sdk-js"] = [node, os.path.join(self.client_dir, "sdk_js.mjs")]
        self.extra_env["typesafe-sdk-js"] = {"MATRIX_SDK_JS_DIR": d}
        return True, ""

    # ---- one call
    def invoke(self, client, method, url, auth, headers, data, tmo):
        h = dict(headers)
        if auth == "key":
            h["Authorization"] = "Bearer " + self.key
        elif auth == "wrong":
            h["Authorization"] = "Bearer wrong-" + secrets.token_hex(8)
        d = tempfile.mkdtemp(prefix="mx-", dir=self.work)
        os.chmod(d, 0o700)
        try:
            hf = os.path.join(d, "h")
            with open(hf, "w", encoding="utf-8") as f:
                f.write("".join("%s: %s\n" % kv for kv in h.items()))
            os.chmod(hf, 0o600)
            bf = "-"
            if data is not None:
                bf = os.path.join(d, "b")
                with open(bf, "wb") as f:
                    f.write(data)
            argv = self.cmds[client] + [method, url, self.cacert or "-", str(tmo), bf, hf if h else "-"]
            env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
            env.update(self.extra_env.get(client, {}))
            if client == "typesafe-sdk-js" or client == "typesafe-sdk-py":
                pass
            t0 = time.time()
            try:
                p = subprocess.run(argv, capture_output=True, text=True, timeout=tmo + 60, env=env)
                r = parse_lines(p.stdout)
                r.rc = p.returncode
                if p.returncode not in (0,) and not r.error and r.status is None:
                    r.error = "adapter exit %d: %s" % (p.returncode, (p.stderr or p.stdout).strip()[-200:])
            except subprocess.TimeoutExpired:
                r = Resp()
                r.error = "adapter hung (killed)"
                r.rc = 124
            r.ms = int((time.time() - t0) * 1000)
            return r
        finally:
            shutil.rmtree(d, ignore_errors=True)


# --------------------------------------------------------------------- step checks

def json_body(r):
    try:
        return json.loads(r.body.decode("utf-8")), None
    except (ValueError, UnicodeDecodeError) as e:
        return None, "body is not JSON (%s)" % type(e).__name__


def check_step(st, r, sdk=False):
    """Compare one response to its step's expectation; returns problems."""
    if r.error and r.status is None:
        return ["no HTTP answer: %s" % r.error[:200]]
    pr = []
    if r.status != st["status"]:
        pr.append("status %s != expected %s" % (r.status, st["status"]))
        return pr
    if r.error:
        # an adapter that got a status but could not hand over the body (e.g. truncated/invalid base64): name it
        # instead of letting it surface as an unexplained 'body is not JSON'
        return ["adapter error with status %s: %s" % (r.status, r.error[:200])]
    h = r.headers
    # SDK success paths do not expose response headers to the caller: header checks apply to their error paths only
    for tok in ([] if (sdk and r.status == 200) else st["check"]):
        if tok == "www-authenticate" and h.get("www-authenticate") != 'Bearer realm="llmctl"':
            pr.append("WWW-Authenticate header %r" % h.get("www-authenticate"))
        elif tok == "allow" and not h.get("allow"):
            pr.append("Allow header missing")
        elif tok == "retry-after" and not re.fullmatch(r"\d+", h.get("retry-after", "")):
            pr.append("Retry-After missing/not an integer: %r" % h.get("retry-after"))
        elif tok == "request-id" and not re.fullmatch(r"[0-9a-f]{16}", h.get("x-llmctl-request-id", "")):
            pr.append("x-llmctl-request-id missing/invalid")
        elif tok == "truncated" and h.get("x-llmctl-decide-truncated") != "true":
            pr.append("x-llmctl-decide-truncated: true missing")
        elif tok == "no-cors" and any(k.startswith("access-control-") for k in h):
            pr.append("CORS headers present")
        elif tok == "json-ct" and "application/json" not in h.get("content-type", ""):
            pr.append("Content-Type %r is not JSON" % h.get("content-type"))
    kind = st["kind"]
    if kind == "metrics":
        txt = r.body.decode("utf-8", "replace")
        if "# TYPE" not in txt and "# HELP" not in txt:
            pr.append("metrics body is not text exposition")
        if "MATRIXSTATE" in txt or "Bearer" in txt:
            pr.append("metrics body leaks request content")
        return pr
    body, e = json_body(r)
    if e:
        return pr + [e]
    if kind == "error":
        if not (isinstance(body, dict) and set(body) == {"message", "error_type"}):
            pr.append("error body keys %s" % (sorted(body) if isinstance(body, dict) else type(body).__name__))
        else:
            if body["error_type"] != st["error_type"] or body["error_type"] not in C.ERROR_TYPES:
                pr.append("error_type %r != %r" % (body["error_type"], st["error_type"]))
            if not isinstance(body["message"], str) or re.search(r"Traceback|/home/|\.go:\d+|\.py\b", body["message"]):
                pr.append("error message is not generic")
    elif kind == "systemone":
        pr += C.validate_systemone(body, st["request"])
    elif kind == "models":
        pr += C.validate_models(body)
    elif kind in ("health", "ready", "notready"):
        want = {"health": "ok", "ready": "ready", "notready": "not_ready"}[kind]
        if body != {"status": want}:
            pr.append("probe body %r != {'status': %r}" % (body, want))
    return pr


def summarize(st, r, extra=""):
    keep = {k: v for k, v in r.headers.items() if k in
            ("content-type", "www-authenticate", "allow", "retry-after", "x-llmctl-request-id", "x-llmctl-decide-truncated")}
    return {"request": "%s %s auth=%s" % (st["method"], st["path"], st["auth"]), "status": r.status,
            "headers": keep, "body": r.body.decode("utf-8", "replace")[:1200], "error": r.error,
            "trust": r.trust or None, "note": extra or None}


# ------------------------------------------------------------------------ the cells

class Cell:
    def __init__(self):
        self.result = "pass"
        self.reason = None
        self.reason_class = None
        self.command = ""
        self.stdout = b""
        self.stderr = b""
        self.rc = 0
        self.ms = 0
        self.env_names = []

    def fail(self, reason):
        self.result = "fail"
        self.reason = (self.reason + "; " if self.reason else "") + reason

    def ne(self, cls, reason):
        self.result = "not-exercised"
        self.reason_class = cls
        self.reason = "class:%s: %s" % (cls, reason)


def url_for(env, path, scheme=None):
    b = env.base
    if scheme == "http":
        b = "http://" + b.split("://", 1)[1]
    return b.rstrip("/") + path


def run_scenario_hook(env, action, scenario):
    if env.scenario_header:
        return True, ""
    hook = env.a.scenario_hook
    if not hook:
        return False, "scenario %r needs the operator to arrange it: pass --scenario-hook CMD (called as `CMD setup|teardown %s`)" % (scenario, scenario)
    r = subprocess.run([hook, action, scenario], capture_output=True, text=True, timeout=120)
    return r.returncode == 0, "scenario hook %s %s rc=%d" % (action, scenario, r.returncode)


AUTH_THROTTLED = "auth_throttled"


def apply_model(st, model):
    """Put `model` into a JSON /v1/systemone step that names none (run.py used to send none, so a gateway
    without a default model answered 503/422). Explicit models, raw bodies and non-POST steps are left alone."""
    if not model or st["method"] != "POST" or st["path"] != "/v1/systemone" or not st.get("request"):
        return st
    if "model" in st["request"]:
        return st
    st["request"] = dict(st["request"], model=model)
    st["data"] = json.dumps(st["request"]).encode()
    return st


def profile_ids(models_body):
    """Served profile ids of a GET /v1/models body (the llmctl `data` listing)."""
    if not (isinstance(models_body, dict) and isinstance(models_body.get("data"), list)):
        return []
    return [m["id"] for m in models_body["data"] if isinstance(m, dict) and isinstance(m.get("id"), str)]


def pick_default_model(models_body):
    """The model to send when none is given: the served default `decide` if the listing offers it (id or alias),
    else the first listed profile, else None."""
    ids = profile_ids(models_body)
    if not ids:
        return None
    for m in models_body["data"]:
        if "decide" == m.get("id") or "decide" in (m.get("aliases") or []):
            return "decide"
    return ids[0]


def fails_auth(st):
    """A step that is SUPPOSED to be refused for authentication (counts towards the failed-auth limiter)."""
    return st["auth"] in ("none", "wrong") and st["status"] == 401


def order_phases(inv_ids, table):
    """Three phases: ordinary cells; cells whose steps FAIL authentication on purpose (unauthenticated / wrong key:
    each one counts towards the gateway's failed-auth burst limiter, so they run after everything that needs a
    clean source); the deliberate burst case last."""
    normal, neg, burst = [], [], []
    for c in inv_ids:
        if c not in table:
            continue
        t = table[c]
        if t["special"] == "burst":
            burst.append(c)
        elif any(fails_auth(st) for st in t["steps"]):
            neg.append(c)
        else:
            normal.append(c)
    return [normal, neg, burst]


def _retry_after_s(r):
    v = r.headers.get("retry-after", "")
    return int(v) if re.fullmatch(r"\d+", v) else None


def invoke_step(env, client, st, hdrs, tmo, cell, notes):
    """One step. A step that fails authentication on purpose is spaced (--auth-neg-gap) and, if the failed-auth
    burst limiter (429 rate_limited + Retry-After) answered instead of the expected 401, re-probed ONCE after
    Retry-After. The cell passes only if the re-probe gives the real expected answer; it is then recorded with
    the documented class `auth_throttled`. A 429 that persists, has no usable Retry-After or asks for more than
    --auth-throttle-max-wait is left as the (failing) answer. Authenticated steps are never retried."""
    neg = fails_auth(st)
    gap = getattr(env.a, "auth_neg_gap", 0) or 0
    if neg and gap > 0:
        env.sleep(gap)
    r = env.invoke(client, st["method"], url_for(env, st["path"]), st["auth"], hdrs, st["data"], tmo)
    cell.ms += r.ms
    if neg and r.status == 429 and st["status"] != 429:
        wait = _retry_after_s(r)
        cap = getattr(env.a, "auth_throttle_max_wait", 120)
        if wait is None or wait > cap:
            notes.append("429 rate_limited without a usable Retry-After within %ss (got %r): not re-probed"
                         % (cap, r.headers.get("retry-after")))
            return r
        env.sleep(wait + 1)
        r2 = env.invoke(client, st["method"], url_for(env, st["path"]), st["auth"], hdrs, st["data"], tmo)
        cell.ms += r2.ms
        if not check_step(st, r2):
            cell.reason_class = AUTH_THROTTLED
            cell.reason = "class:%s: 429 rate_limited (Retry-After %ss) from the matrix's own failed-auth volume; " \
                          "the same call re-probed after the wait gave the expected answer" % (AUTH_THROTTLED, wait)
            notes.append("auth_throttled: 429 then, after %ss, the expected answer" % (wait + 1))
        else:
            notes.append("429 rate_limited, and the re-probe after %ss still did not match" % (wait + 1))
        return r2
    return r


def exec_http(env, client, cid, case, cell):
    outs = []
    tmo = env.a.timeout
    model = getattr(env, "model", None)
    for st in case["steps"]:
        st = apply_model(dict(st), model)
        hdrs = dict(st["headers"])
        if st["data"] is not None and st["ctype"]:
            hdrs["Content-Type"] = st["ctype"]
        sc = st["scenario"]
        torn = False
        if sc:
            if env.scenario_header:
                hdrs["x-refserver-scenario"] = sc
            else:
                ok, msg = run_scenario_hook(env, "setup", sc)
                if not ok:
                    cell.fail(msg)
                    return
                torn = True
        notes = []
        try:
            r = invoke_step(env, client, st, hdrs, tmo, cell, notes)
        finally:
            if torn:
                run_scenario_hook(env, "teardown", sc)
        cell.rc = r.rc
        problems = check_step(st, r, sdk=client in SDK_CLIENTS)
        if r.trust and any(t.startswith("none fail") for t in r.trust):
            cell.ne("sdk-no-ca-trust", "trust-configuration failure: " + "; ".join(r.trust)[:300])
            outs.append(summarize(st, r))
            cell.stdout = json.dumps(outs, indent=1).encode()
            return
        if any("control-no-ca UNEXPECTED" in t for t in r.trust):
            cell.fail("CA-trust control failed (verification may be off): " + "; ".join(r.trust)[:200])
        if r.error and r.status is None and (r.rc == 2 or "client not installed" in r.error):
            cell.ne(NE_CLASS_ENV, r.error[:200])
            outs.append(summarize(st, r))
            cell.stdout = json.dumps(outs, indent=1).encode()
            return
        outs.append(summarize(st, r, "; ".join(notes + problems)))
        for p in problems:
            cell.fail("%s %s: %s" % (st["method"], st["path"], p))
    cell.stdout = json.dumps(outs, indent=1).encode()


def exec_plain_http(env, client, cell):
    outs = []
    c = C.step("GET", "/healthz", auth="none", status=200, kind="health")
    r1 = env.invoke(client, "GET", url_for(env, "/healthz"), "none", {}, None, env.a.timeout)
    cell.ms += r1.ms
    outs.append(summarize(c, r1, "control: same client over HTTPS"))
    if r1.error and r1.status is None and (r1.rc == 2 or "client not installed" in r1.error):
        cell.ne(NE_CLASS_ENV, r1.error[:200])
        cell.stdout = json.dumps(outs, indent=1).encode()
        return
    if r1.status != 200:
        cell.fail("control over HTTPS did not answer 200 (%s %s): a refusal of plain HTTP would prove nothing" % (r1.status, r1.error))
    r2 = env.invoke(client, "GET", url_for(env, "/healthz", "http"), "none", {}, None, env.a.timeout)
    cell.ms += r2.ms
    outs.append(summarize(C.step("GET", "/healthz", auth="none"), r2, "plain HTTP to the TLS port"))
    if r2.status is not None:
        cell.fail("plain HTTP to the TLS port got an HTTP answer (status %s); it must be reset, never answered" % r2.status)
    elif not r2.error:
        cell.fail("plain HTTP: neither answer nor error reported")
    cell.stdout = json.dumps(outs, indent=1).encode()


def split_hostport(base):
    hp = base.split("://", 1)[1].split("/", 1)[0]
    h, _, p = hp.rpartition(":")
    return h, int(p)


def exec_special(env, client, cid, kind, cell):
    host, port = split_hostport(env.base)
    p = env.a.params
    if kind == "plain-http":
        return exec_plain_http(env, client, cell)
    if kind == "burst":
        outs, got = [], None
        wrong = C.step("POST", "/v1/systemone", auth="wrong", body=C.req(), status=429, error_type="rate_limited", kind="error",
                       check=["error-body", "retry-after"])
        for i in range(p.burst_max):
            r = env.invoke(client, "POST", url_for(env, "/v1/systemone"), "wrong", {"Content-Type": "application/json"},
                           wrong["data"], env.a.timeout)
            cell.ms += r.ms
            if r.status == 429:
                got = (i + 1, r)
                break
            if r.status not in (401,):
                cell.fail("failed-auth burst request %d got status %s %s" % (i + 1, r.status, r.error))
                break
        if got is None and not cell.reason:
            cell.fail("no 429 after %d failed authentications" % p.burst_max)
        if got:
            probs = check_step(wrong, got[1])
            outs.append(summarize(wrong, got[1], "first 429 after %d wrong-key requests" % got[0]))
            for pr_ in probs:
                cell.fail(pr_)
        ok_step = C.ok_systemone(C.req())
        r = env.invoke(client, "POST", url_for(env, "/v1/systemone"), "key", {"Content-Type": "application/json"},
                       ok_step["data"], env.a.timeout)
        cell.ms += r.ms
        pr2 = check_step(ok_step, r)
        outs.append(summarize(ok_step, r, "valid key from the same source right after the burst"))
        for pr_ in pr2:
            cell.fail("valid key after burst: " + pr_)
        cell.stdout = json.dumps(outs, indent=1).encode()
        return
    if kind in ("slow-client", "conn-cap"):
        t0 = time.time()
        if kind == "slow-client":
            ok, det = T.slow_client(host, port, env.cacert, p.slow_client_max_s)
        else:
            ok, det = T.conn_cap(host, port, env.cacert, p.conn_cap)
        cell.ms = int((time.time() - t0) * 1000)
        cell.stdout = json.dumps(det, indent=1).encode()
        if not ok:
            cell.fail("%s expectation not met: %s" % (kind, json.dumps(det)))
        return
    if kind == "engine-port":
        if env.engine_port is None:
            cell.ne(NE_CLASS_ENV, "engine port unknown: pass --engine-port (the loopback-only port of an engine/runtime behind the gateway)")
            return
        ip = env.a.host_ip or T.nonloopback_ip()
        if not ip:
            cell.ne(NE_CLASS_ENV, "this host has no non-loopback address; the refusal from another address cannot be tested here")
            return
        if client == "python-urllib":
            ok, det = T.engine_refused(ip, env.engine_port)
            cell.stdout = json.dumps(det, indent=1).encode()
            if not ok:
                cell.fail("engine port not refused on %s: %s" % (ip, json.dumps(det)))
            return
        outs = []
        ctrl = env.invoke("curl", "GET", "http://127.0.0.1:%d/" % env.engine_port, "none", {}, None, 5)
        far = env.invoke("curl", "GET", "http://%s:%d/" % (ip, env.engine_port), "none", {}, None, 5)
        cell.ms = ctrl.ms + far.ms
        outs.append({"control_loopback": ctrl.error or ctrl.status, "non_loopback": far.error or far.status})
        cell.stdout = json.dumps(outs, indent=1).encode()
        if ctrl.error and re.search(r"refus|Failed to connect|rc=7", ctrl.error):
            cell.fail("control: loopback engine port itself refused (blind)")
        if far.status is not None or not far.error or not re.search(r"refus|Failed to connect|rc=7", far.error) \
                or re.search(r"timed out|No route|unreachable", far.error):
            cell.fail("non-loopback address did not refuse the connection: %s" % (far.error or far.status))
        return
    cell.fail("unknown special kind %r" % kind)


def applicable(env, client, cid, case):
    """Return None when the cell is executed, else (class, reason)."""
    sp = case["special"]
    if sp in TRANSPORT_CLIENT:
        if client not in TRANSPORT_CLIENT[sp]:
            return "transport-not-per-client", "%s is client-independent transport behaviour, executed by %s" % (sp, "+".join(TRANSPORT_CLIENT[sp]))
        return None
    if client in SDK_CLIENTS:
        if sp or not case["sdk"]:
            return "sdk-outside-subset", "outside the SDK's own surface (POST /v1/systemone, GET /v1/models) or needs a raw/unsupported request"
        return None
    if client == "chromium":
        if sp == "burst":
            return "browser-non-get", "the failed-auth burst is a POST case"
        if sp == "plain-http":
            return None
        if not case["get_only"]:
            return "browser-non-get", "a browser CLI client issues GET navigations only"
    return None


def run_cell(env, client, vantage, cid, case, row):
    cell = Cell()
    cell.command = "[%s] %s %s %s %s" % (cid, client, row["method"], row["path"], row["scenario"][:60])
    na = applicable(env, client, cid, case)
    if na:
        cell.ne(na[0], na[1])
        return cell
    ok, why = env.avail.get(client, (False, "client not prepared"))
    if not ok:
        cell.ne(NE_CLASS_ENV, "client not installed/usable: %s" % why)
        return cell
    t0 = time.time()
    try:
        if case["special"]:
            exec_special(env, client, cid, case["special"], cell)
        else:
            exec_http(env, client, cid, case, cell)
    except Exception as e:  # noqa: BLE001 - an adapter/runner crash is a FAIL with the exception named
        cell.fail("runner exception %s: %s" % (type(e).__name__, e))
    if not cell.ms:
        cell.ms = int((time.time() - t0) * 1000)
    if cell.result == "pass" and not cell.stdout:
        cell.fail("no captured output")
    return cell


# -------------------------------------------------------------- reference server mgmt

def start_refserver(env, work):
    go = shutil.which("go")
    if not go:
        raise SystemExit("go toolchain required to build the reference server (or pass --base-url)")
    binp = os.path.join(work, "refserver")
    r = subprocess.run([go, "build", "-o", binp, os.path.join(HERE, "refserver", "main.go")], capture_output=True, text=True,
                       cwd=HERE, env=dict(os.environ, GOFLAGS="", GOWORK="off"))
    if r.returncode:
        raise SystemExit("refserver build failed: " + r.stderr[-400:])
    certs = os.path.join(work, "certs")
    subprocess.run([binp, "gencerts", certs], check=True)
    env.key = "mk-" + secrets.token_hex(16)
    pf, ef = os.path.join(work, "port"), os.path.join(work, "eport")
    p = env.a.params
    log = open(os.path.join(work, "refserver.log"), "wb")
    env.proc = subprocess.Popen(
        [binp, "serve", "--cert", os.path.join(certs, "good", "cert.pem"), "--key", os.path.join(certs, "good", "key.pem"),
         "--port-file", pf, "--engine-port-file", ef, "--budget-chars", str(p.budget_chars), "--body-cap", str(p.body_cap),
         "--conn-cap-per-source", str(p.conn_cap), "--profile-max-options", str(p.profile_max_options)],
        env=dict(os.environ, REFSERVER_KEY=env.key), stdout=log, stderr=log, start_new_session=True)
    for _ in range(100):
        if os.path.exists(pf) and os.path.exists(ef) and open(pf).read().strip() and open(ef).read().strip():
            break
        if env.proc.poll() is not None:
            raise SystemExit("refserver exited early: " + open(os.path.join(work, "refserver.log")).read()[-300:])
        time.sleep(0.1)
    env.base = "https://127.0.0.1:%s" % open(pf).read().strip()
    env.engine_port = int(open(ef).read().strip())
    env.cacert = os.path.join(certs, "ca.pem")
    env.scenario_header = True
    env.cls = "stand-in"
    env.spki = open(os.path.join(certs, "good", "spki.b64")).read().strip()


def stop_refserver(env):
    if env.proc and env.proc.poll() is None:
        # own child + own session only (never a pgid <= 1)
        pid = env.proc.pid
        if pid > 1:
            try:
                os.killpg(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            env.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(env.proc.pid, signal.SIGKILL)


def spki_from_cert(path):
    try:
        pub = subprocess.run(["openssl", "x509", "-in", path, "-pubkey", "-noout"], capture_output=True, check=True).stdout
        der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "der"], input=pub, capture_output=True, check=True).stdout
        return base64.b64encode(hashlib.sha256(der).digest()).decode()
    except (subprocess.CalledProcessError, OSError):
        return None


# ------------------------------------------------------------------------- main run

def resolve_model(env, a):
    """Decide env.model. --model wins; against a gateway otherwise ask GET /v1/models; the reference server needs none."""
    if a.model:
        env.model = a.model
        return "flag"
    if not a.base_url:
        env.model = None
        return "none (reference server has a default)"
    try:
        r = env.invoke("python-urllib", "GET", url_for(env, "/v1/models"), "key", {}, None, a.timeout)
        body, e = json_body(r)
        m = None if e or r.status != 200 else pick_default_model(body)
    except Exception as ex:  # noqa: BLE001
        m, e = None, type(ex).__name__
    env.model = m
    return "GET /v1/models" if m else "none (could not list /v1/models: no model sent)"


def fetch_profiles(a):
    """Served profile ids of the target gateway (for --each-profile)."""
    work = tempfile.mkdtemp(prefix="llmctl-matrix-list-")
    try:
        env = Env(a, work)
        env.key = os.environ.get(a.key_env)
        if not env.key:
            raise SystemExit("API key not set: export %s" % a.key_env)
        env.cacert, env.base = a.cacert, a.base_url
        env.cmds["python-urllib"] = [sys.executable, "-B", os.path.join(env.client_dir, "python_urllib.py")]
        r = env.invoke("python-urllib", "GET", url_for(env, "/v1/models"), "key", {}, None, a.timeout)
        body, e = json_body(r)
        if e or r.status != 200:
            raise SystemExit("cannot list profiles: status %s %s" % (r.status, e or r.error))
        return profile_ids(body)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def do_each_profile(a, run=None, fetch=None):
    ids = (fetch or fetch_profiles)(a)
    if not ids:
        print("no served profile found", file=sys.stderr)
        return 1
    base_dir = a.run_dir or os.path.join(ROOT, "docs", "qa", "009-jev-decision-models",
                                         a.run_id or time.strftime("matrix-%Y%m%dT%H%M%SZ", time.gmtime()))
    rc = 0
    for pid in ids:
        b = argparse.Namespace(**vars(a))
        b.model, b.each_profile, b.run_dir = pid, False, os.path.join(base_dir, pid)
        b.run_id = (a.run_id + "-" + pid) if a.run_id else None
        rc = max(rc, (run or do_run)(b))
    return rc


def do_run(a):
    inv = load_inventory(a.inventory)
    inv_ids = [r["case_id"] for r in inv]
    rows = {r["case_id"]: r for r in inv}
    table = C.cases(a.params)
    clients = [c for c in a.clients.split(",") if c]
    if a.with_sdk:
        clients += [c for c in SDK_CLIENTS if c not in clients]
    work = tempfile.mkdtemp(prefix="llmctl-matrix-")
    env = Env(a, work)
    rc = 1
    try:
        if not a.base_url:
            start_refserver(env, work)
        else:
            key = os.environ.get(a.key_env)
            if not key:
                raise SystemExit("API key not set: export %s" % a.key_env)
            env.key = key
            env.cacert = a.cacert
            env.base = a.base_url
            env.scenario_header = False
            if a.server_cert:
                env.spki = spki_from_cert(a.server_cert)
        if a.class_override:
            env.cls = a.class_override
        env.prepare(clients)
        model_note = resolve_model(env, a)
        run_id = a.run_id or time.strftime("matrix-%Y%m%dT%H%M%SZ", time.gmtime())
        run_dir = a.run_dir or os.path.join(ROOT, "docs", "qa", "009-jev-decision-models", run_id)
        os.makedirs(run_dir, exist_ok=True)
        w = writer.EvidenceWriter(run_dir, run_id, secrets=[env.key])
        vantages = ["host"]
        plan = {"target": env.base, "class": env.cls, "clients": {c: ("available" if env.avail.get(c, (False,))[0] else
                                                                      "unavailable: " + env.avail.get(c, (0, "n/a"))[1]) for c in clients},
                "pending_adapters": PENDING_ADAPTERS,
                "vantages": {"host": "exercised", "second-machine": "pending-vantage (vantage helper not wired yet)"},
                "cases": len(inv_ids), "model": env.model, "model_source": model_note}
        print(json.dumps({"plan": plan}, indent=1))
        if a.plan:
            return 0

        # The failed-auth burst case leaves the source throttled for a while, so it runs in a final
        # phase after every other case of every client (otherwise later 401 cells would see 429).
        cells = []
        for phase in order_phases(inv_ids, table):
            for client in clients:
                for cid in phase:
                    for v in vantages:
                        cell = run_cell(env, client, v, cid, table[cid], rows[cid])
                        ev_cls = "not-exercised" if cell.result == "not-exercised" else env.cls
                        ev_names = ["PATH"] + (["MATRIX_CHROMIUM_SPKI"] if client == "chromium" else [])
                        rec = w.append(requirement=req_ids(rows[cid].get("requirement", "")) + ["FR-069", "SC-013"],
                                       command=cell.command, cwd=ROOT, env_names=ev_names, exit_code=cell.rc,
                                       stdout=cell.stdout or (b"not executed\n" if cell.result == "not-exercised" else b""),
                                       stderr=cell.stderr, duration_ms=cell.ms, cls=ev_cls, vantage="host", client=client,
                                       result=cell.result, reason=cell.reason)
                        cells.append({"case_id": cid, "client": client, "vantage": v, "result": cell.result,
                                      "reason_class": cell.reason_class, "reason": cell.reason, "evidence_id": rec["id"]})
                        if a.verbose:
                            print("%-8s %-16s %-14s %s" % (cid, client, cell.result, (cell.reason or "")[:100]))

        problems = check_completeness(inv_ids, list(table), clients, vantages, cells, a.allow_env_gaps)
        pend = [v for v in ("second-machine",)]
        if a.require_second:
            problems.append("second network vantage required but pending (vantage helper not wired)")
        fails = [c for c in cells if c["result"] == "fail"]
        by = {}
        for c in cells:
            by[c["result"]] = by.get(c["result"], 0) + 1
        beyond = sum(1 for c in cells if c.get("reason_class") in NE_CLASSES_PROPOSED)
        mj = {"run_id": run_id, "target": env.base, "evidence_class": env.cls, "model": env.model,
              "inventory": {"path": os.path.relpath(a.inventory, ROOT) if a.inventory.startswith(ROOT) else a.inventory,
                            "sha256": hashlib.sha256(open(a.inventory, "rb").read()).hexdigest(), "rows": len(inv_ids), "case_ids": inv_ids},
              "clients": plan["clients"], "pending_adapters": PENDING_ADAPTERS,
              "vantages": plan["vantages"], "pending_vantages": pend,
              "not_exercised_classes": {"fr069": NE_CLASSES_FR069, "proposed_beyond_fr069": NE_CLASSES_PROPOSED, "env": NE_CLASS_ENV},
              "cells": cells,
              "summary": {"cells": len(cells), **by, "classes_beyond_fr069": beyond,
                          "auth_throttled": sum(1 for c in cells if c.get("reason_class") == AUTH_THROTTLED)},
              "completeness": {"problems": problems, "complete": not problems},
              "verdict": "PASS" if not problems and not fails else "FAIL"}
        with open(os.path.join(run_dir, "matrix.json"), "w") as f:
            json.dump(mj, f, indent=1, sort_keys=True)
            f.write("\n")
        lrc, lrep = leak_scan.run([run_dir], [env.key])
        mj["leak_scan"] = {"rc": lrc, "status": lrep["status"], "control_needle_found": lrep["control_needle_found"]}
        with open(os.path.join(run_dir, "matrix.json"), "w") as f:
            json.dump(mj, f, indent=1, sort_keys=True)
            f.write("\n")
        if lrc != 0:
            mj["verdict"] = "FAIL"
            print("LEAK SCAN: %s" % lrep["status"], file=sys.stderr)
        manifest.build(run_dir)
        print(json.dumps({"verdict": mj["verdict"], "summary": mj["summary"], "problems": problems[:20],
                          "first_failures": [(c["case_id"], c["client"], c["reason"][:160]) for c in fails[:10]],
                          "run_dir": run_dir}, indent=1))
        rc = 0 if mj["verdict"] == "PASS" and lrc == 0 else 1
    finally:
        stop_refserver(env)
        shutil.rmtree(work, ignore_errors=True)
    return rc


# --------------------------------------------------------------- independent verify

def do_check(a):
    d = a.check
    probs = []
    ev = os.path.join(d, "evidence.jsonl")
    mj = json.load(open(os.path.join(d, "matrix.json")))
    probs += ["evidence chain: " + x for x in writer.verify_chain(ev)]
    mv = manifest.verify(d)
    if not mv["ok"]:
        probs.append("manifest: tampered=%s missing=%s extra=%s errors=%s" % (mv["tampered"], mv["missing"], mv["extra"], mv["errors"]))
    recs = {}
    for line in open(ev):
        if line.strip():
            r = json.loads(line)
            recs[r["id"]] = r
    inv_ids = [r["case_id"] for r in load_inventory(a.inventory)]
    for c in mj["cells"]:
        r = recs.get(c["evidence_id"])
        m = re.match(r"\[(EP-[0-9a-z]+)\]", r["command"]) if r else None
        if not r or not m or m.group(1) != c["case_id"] or r["client"] != c["client"] or r["result"] != c["result"] \
                or r["vantage"] != c["vantage"]:
            probs.append("cell %s/%s does not match its evidence record %s" % (c["case_id"], c["client"], c["evidence_id"]))
    probs += check_completeness(inv_ids, inv_ids, list(mj["clients"]), ["host"], mj["cells"], a.allow_env_gaps)
    nf = sum(1 for c in mj["cells"] if c["result"] == "fail")
    if nf:
        probs.append("%d failing cells" % nf)
    print(json.dumps({"check": "FAIL" if probs else "OK", "problems": probs[:30]}, indent=1))
    return 1 if probs else 0


def parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", help="target gateway (https://host:port); omit to start the reference server")
    ap.add_argument("--cacert", help="CA bundle (PEM) that signed the gateway certificate")
    ap.add_argument("--server-cert", help="gateway server certificate (PEM), used to compute the browser SPKI pin")
    ap.add_argument("--key-env", default="LLMCTL_API_KEY", help="environment variable holding the access key")
    ap.add_argument("--inventory", default=DEFAULT_INVENTORY)
    ap.add_argument("--run-dir")
    ap.add_argument("--run-id")
    ap.add_argument("--clients", default=",".join(DEFAULT_CLIENTS))
    ap.add_argument("--with-sdk", action="store_true", help="also run the typesafe SDK adapters (installs them into temp dirs; needs network)")
    ap.add_argument("--allow-env-gaps", action="store_true", help="a client missing on this host is reported, not a failure")
    ap.add_argument("--require-second", action="store_true", help="treat the pending second vantage as a failure")
    ap.add_argument("--engine-port", type=int)
    ap.add_argument("--host-ip", help="non-loopback address of the host (auto-detected)")
    ap.add_argument("--scenario-hook", help="executable called as `CMD setup|teardown SCENARIO` (gateway mode)")
    ap.add_argument("--body-cap", type=int, default=65536)
    ap.add_argument("--budget-chars", type=int, default=4000)
    ap.add_argument("--profile-max-options", type=int, default=20)
    ap.add_argument("--conn-cap", type=int, default=8)
    ap.add_argument("--slow-client-max-s", type=float, default=15.0)
    ap.add_argument("--burst-max", type=int, default=80)
    ap.add_argument("--timeout", type=int, default=20)
    ap.add_argument("--model", help="`model` to send in POST /v1/systemone requests that name none (default against a gateway: "
                                    "`decide` if /v1/models offers it, else its first profile; the reference server needs none)")
    ap.add_argument("--each-profile", action="store_true",
                    help="gateway mode: run the whole matrix once per served profile (each in RUNDIR/<profile>)")
    ap.add_argument("--auth-neg-gap", type=float, default=0.0,
                    help="seconds to wait before each deliberately failed-authentication step (spacing against the failed-auth limiter)")
    ap.add_argument("--auth-throttle-max-wait", type=float, default=120.0,
                    help="longest Retry-After (s) honoured when the failed-auth limiter answers 429 to such a step; it is re-probed once")
    ap.add_argument("--class-override", choices=["real-model", "real-component", "stand-in"])
    ap.add_argument("--plan", action="store_true", help="print the plan and exit")
    ap.add_argument("--check", metavar="RUNDIR", help="independently verify a finished run directory")
    ap.add_argument("--verbose", action="store_true")
    return ap


def main(argv=None):
    a = parser().parse_args(argv)
    a.params = C.Params(body_cap=a.body_cap, budget_chars=a.budget_chars, profile_max_options=a.profile_max_options,
                        conn_cap=a.conn_cap, slow_client_max_s=a.slow_client_max_s, burst_max=a.burst_max)
    if a.check:
        return do_check(a)
    if a.base_url and not a.cacert:
        print("--cacert is required with --base-url", file=sys.stderr)
        return 2
    if a.each_profile:
        if not a.base_url:
            print("--each-profile needs --base-url", file=sys.stderr)
            return 2
        return do_each_profile(a)
    return do_run(a)


if __name__ == "__main__":
    sys.exit(main())
