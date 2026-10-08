#!/usr/bin/env python3
"""router.py - a consumer-side decision router for the llmctl gateway (FR-086, idea 3-I03).

A tested, corrected replacement for the two router snippets in the Jev.md source material
(research/jev-md-coverage-3.md J3-038 / J3-058). Defects of those snippets that this version does not have:

  * `ROUTES[route_name]` raised KeyError for a name that was only a prefix of real routes (and for every
    fallback that was not a route key)  ->  every lookup is checked; an unknown route is an ESCALATE result.
  * recursion on `fallback` without a cycle guard  ->  a visited set and a depth limit.
  * no HTTP status check, broad `except Exception` that returned a half-built result  ->  only a 200 with a
    well-formed answer for EVERY question counts; anything else is a failure that follows the fallback chain.
  * `max_labels` / `min_agreement` / `cost_budget` read nowhere  ->  `max_labels` is enforced; the other two
    are not implemented and are rejected at load time instead of being silently ignored.
  * the scaled confidence compared with a differently-scaled `min_probability`  ->  one unit only:
    `min_confidence`, the lowest confidence over all questions (noul: abs(p-0.5)*2; choice/score: the answer's
    own confidence).
  * `result["questions"][qid]` assumed the backend echoed every id (and used the wrong key: the gateway's
    field is "answers")  ->  a missing answer is a failure.
  * plain HTTP, no key  ->  HTTPS only, certificate verification always on, the key from the environment or a
    key file (never a literal in code), no proxy, no redirect following.

The router NEVER returns an allow on a failure. Its terminal outcomes are a served model id (success), or
the reserved words "escalate" (hand to a human / a stronger system) and "deny" (fail closed).

Routes file (JSON):  {"routes": {"<name>": {"model": "...", "min_confidence": 0.7, "max_labels": 50,
                                             "fallback": "<route>|escalate|deny"},
                                "<selector>": {"switch": {"label_count_over": 50, "to": "<route>"}, "to": "<route>"}}}
"""
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

MAX_RESPONSE = 16 << 20
RESERVED = ("escalate", "deny")
RETRYABLE = (429, 503, 529)


class Secret:
    """Holds the access key; its repr/str never show it."""

    def __init__(self, value):
        self._v = value

    def reveal(self):
        return self._v

    def __repr__(self):
        return "Secret(***)"

    __str__ = __repr__


class ConfigError(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None  # a redirect is an error: never forward the key elsewhere


def load_key(env=os.environ):
    """LLMCTL_API_KEY, else the value of LLMCTL_API_KEY in the file named by LLMCTL_API_KEY_FILE
    (a bare key or a KEY=VALUE .env file)."""
    v = env.get("LLMCTL_API_KEY", "").strip()
    if v:
        return Secret(v)
    path = env.get("LLMCTL_API_KEY_FILE", "")
    if path:
        try:
            text = open(path, encoding="utf-8").read()
        except OSError as e:
            raise ConfigError("cannot read LLMCTL_API_KEY_FILE (%s)" % e.__class__.__name__)
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("LLMCTL_API_KEY="):
                return Secret(line.split("=", 1)[1].strip().strip("'\""))
        if text.strip() and "=" not in text:
            return Secret(text.strip())
    raise ConfigError("no access key: set LLMCTL_API_KEY or LLMCTL_API_KEY_FILE")


def _validate_routes(routes):
    if not isinstance(routes, dict) or not routes:
        raise ConfigError("routes must be a non-empty object")
    for name, r in routes.items():
        if name in RESERVED:
            raise ConfigError("route name %r is reserved" % name)
        if not isinstance(r, dict):
            raise ConfigError("route %r must be an object" % name)
        for bad in ("min_agreement", "cost_budget", "min_probability"):
            if bad in r:
                raise ConfigError("route %r: %r is not supported (see the module docstring)" % (name, bad))
    return routes


class Router:
    def __init__(self, routes, endpoint, cafile=None, key=None, timeout=30.0, max_depth=6):
        self.routes = _validate_routes(routes)
        if not endpoint.startswith("https://"):
            raise ConfigError("the endpoint must be an https:// URL")
        self.endpoint = endpoint.rstrip("/")
        self.key = key
        self.timeout = timeout
        self.max_depth = max_depth
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.check_hostname = True
        ctx.verify_mode = ssl.CERT_REQUIRED
        if cafile:
            try:
                ctx.load_verify_locations(cafile=cafile)
            except (OSError, ssl.SSLError) as e:
                raise ConfigError("cannot load the CA certificate %r (%s)" % (cafile, e.__class__.__name__))
        else:
            ctx.load_default_certs()
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx), _NoRedirect())

    @classmethod
    def from_env(cls, routes_path, env=os.environ, **kw):
        try:
            routes = json.load(open(routes_path, encoding="utf-8"))["routes"]
        except (OSError, ValueError, KeyError, TypeError) as e:
            raise ConfigError("cannot read routes from %r (%s)" % (routes_path, e.__class__.__name__))
        port = env.get("LLMCTL_DECIDE_PORT", "8095")
        endpoint = env.get("LLMCTL_ENDPOINT") or "https://127.0.0.1:%s" % port
        cafile = env.get("LLMCTL_CACERT") or os.path.join(env.get("LLMCTL_HOME") or os.path.join(os.path.expanduser("~"), "llmctl"), "cert", "ca", "ca.crt")
        return cls(routes, endpoint, cafile=cafile, key=load_key(env), **kw)

    # ------------------------------------------------------------------ one gateway call
    def _post(self, model, state, questions):
        body = {"state": state, "questions": questions}
        if model:
            body["model"] = model
        req = urllib.request.Request(self.endpoint + "/v1/systemone", data=json.dumps(body).encode("utf-8"), method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", "Bearer " + self.key.reveal())
        try:
            with self._opener.open(req, timeout=self.timeout) as resp:
                status = resp.status
                raw = resp.read(MAX_RESPONSE + 1)
        except urllib.error.HTTPError as e:
            raise _Fail("gateway answered HTTP %d%s" % (e.code, " (retryable)" if e.code in RETRYABLE else ""))
        except (urllib.error.URLError, OSError, ssl.SSLError) as e:
            raise _Fail("gateway unreachable or TLS failure (%s)" % e.__class__.__name__)
        if status != 200 or len(raw) > MAX_RESPONSE:
            raise _Fail("unexpected gateway response (status %d)" % status)
        try:
            return json.loads(raw)
        except ValueError:
            raise _Fail("the gateway answer is not JSON")

    @staticmethod
    def min_confidence(result, questions):
        """The lowest confidence over all questions; a missing or malformed answer is a failure."""
        answers = result.get("answers") if isinstance(result, dict) else None
        if not isinstance(answers, dict):
            raise _Fail("the gateway answer has no 'answers' object")
        confs = []
        for qid, q in questions.items():
            a = answers.get(qid)
            if not isinstance(a, dict):
                raise _Fail("no answer for question %r" % qid)
            if q.get("type") == "noul":
                p = a.get("noul")
                if isinstance(p, bool) or not isinstance(p, (int, float)) or not 0 <= p <= 1:
                    raise _Fail("malformed noul answer for %r" % qid)
                confs.append(abs(p - 0.5) * 2)
            else:
                c = a.get("confidence")
                if isinstance(c, bool) or not isinstance(c, (int, float)) or not 0 <= c <= 1:
                    raise _Fail("answer for %r carries no confidence" % qid)
                confs.append(float(c))
        if not confs:
            raise _Fail("no questions")
        return min(confs)

    # ------------------------------------------------------------------ routing
    def decide(self, route_name, state, questions, label_count=0):
        trail = []
        name = route_name
        visited = set()
        last = "no route tried"
        while True:
            if name in RESERVED:
                return {"ok": False, "source": name, "reason": last, "trail": trail}
            if name in visited or len(trail) >= self.max_depth:
                return {"ok": False, "source": "escalate", "reason": "route cycle or depth limit at %r" % name, "trail": trail}
            visited.add(name)
            route = self.routes.get(name)
            if route is None:
                return {"ok": False, "source": "escalate", "reason": "unknown route %r" % name, "trail": trail}
            if "switch" in route or ("to" in route and "model" not in route):
                sw = route.get("switch") or {}
                target = route.get("to")
                over = sw.get("label_count_over")
                if isinstance(over, (int, float)) and label_count > over and sw.get("to"):
                    target = sw["to"]
                if not isinstance(target, str):
                    return {"ok": False, "source": "escalate", "reason": "selector %r has no target" % name, "trail": trail}
                trail.append("%s->%s" % (name, target))
                name = target
                continue
            model, minc = route.get("model"), route.get("min_confidence")
            fallback = route.get("fallback", "escalate")
            if not isinstance(model, str) or isinstance(minc, bool) or not isinstance(minc, (int, float)):
                return {"ok": False, "source": "escalate", "reason": "route %r needs a model and a min_confidence" % name, "trail": trail}
            maxl = route.get("max_labels")
            if isinstance(maxl, (int, float)) and label_count > maxl:
                last = "route %r supports at most %s labels" % (name, maxl)
                trail.append("%s:max_labels" % name)
                name = fallback
                continue
            try:
                result = self._post(model, state, questions)
                conf = self.min_confidence(result, questions)
            except _Fail as e:
                last = "route %r failed: %s" % (name, e)
                trail.append("%s:error" % name)
                name = fallback
                continue
            if conf >= minc:
                served = result.get("model") if isinstance(result.get("model"), str) else model
                trail.append("%s:ok" % name)
                return {"ok": True, "source": served, "route": name, "result": result, "confidence": conf, "trail": trail}
            last = "route %r: confidence %.3f is below %.3f" % (name, conf, minc)
            trail.append("%s:low" % name)
            name = fallback


class _Fail(Exception):
    pass


def main(argv):
    """router.py ROUTES.json ROUTE 'STATE' 'QUESTIONS_JSON' [LABEL_COUNT]  -> one JSON line, exit 0 only on success."""
    if len(argv) < 5:
        sys.stderr.write(main.__doc__ + "\n")
        return 2
    try:
        r = Router.from_env(argv[1])
        res = r.decide(argv[2], argv[3], json.loads(argv[4]), int(argv[5]) if len(argv) > 5 else 0)
    except (ConfigError, ValueError) as e:
        print(json.dumps({"ok": False, "source": "escalate", "reason": "configuration: %s" % e}))
        return 1
    print(json.dumps(res))
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
