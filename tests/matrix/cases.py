"""Case table of the client-by-call matrix (specs/009-jev-decision-models/contracts/endpoint-inventory.tsv).

Every inventory row needs exactly one handler here and vice versa; run.py fails the run
when either side has a case the other lacks (this is what detects a row removed from an
inventory copy). A handler turns a case into concrete HTTP steps plus the expectation each
step is checked against. Pure data + small validators, stdlib only.
"""
import json
import re

# ------------------------------------------------------------------ parameters


class Params:
    """Knobs that differ between the reference server and the real gateway."""

    def __init__(self, body_cap=65536, budget_chars=4000, profile_max_options=20,
                 conn_cap=8, slow_client_max_s=15.0, burst_max=80):
        self.body_cap = body_cap
        self.budget_chars = budget_chars
        self.profile_max_options = profile_max_options
        self.conn_cap = conn_cap
        self.slow_client_max_s = slow_client_max_s
        self.burst_max = burst_max


# --------------------------------------------------------------------- builders

def _q_noul():
    return {"type": "noul", "instructions": "Is the sky blue?"}


def _q_choice(n=2):
    return {"type": "choice", "instructions": "Pick one.",
            "criteria": {"opt%02d" % i: "option %d" % i for i in range(n)}}


def _q_score(n=5):
    return {"type": "score", "instructions": "Rate it.", "criteria": ["level %d" % i for i in range(n)]}


def req(state="MATRIXSTATE the quick brown fox", questions=None, model=None, **extra):
    d = {"state": state, "questions": questions if questions is not None else {"q": _q_noul()}}
    if model is not None:
        d["model"] = model
    d.update(extra)
    return d


def step(method, path, auth="key", body=None, ctype="application/json", scenario=None,
         status=200, error_type=None, kind=None, headers=None, raw=None, check=None):
    """One HTTP exchange. `body` is a JSON-serialisable value, `raw` raw bytes."""
    data = raw
    if data is None and body is not None:
        data = json.dumps(body).encode()
    return {"method": method, "path": path, "auth": auth, "data": data, "ctype": ctype,
            "scenario": scenario, "status": status, "error_type": error_type, "kind": kind,
            "headers": headers or {}, "request": body if isinstance(body, dict) else None,
            "check": check or []}


# check tokens understood by run.check_step:
#   www-authenticate, allow, retry-after, request-id, truncated, no-cors, error-body, json-ct

def ok_systemone(body, scenario=None, extra_check=None):
    return step("POST", "/v1/systemone", body=body, scenario=scenario, status=200, kind="systemone",
                check=["request-id", "no-cors", "json-ct"] + (extra_check or []))


def err(status, error_type, method="POST", path="/v1/systemone", auth="key", body=None, ctype="application/json",
        scenario=None, raw=None, check=None):
    return step(method, path, auth=auth, body=body, ctype=ctype, scenario=scenario, status=status,
                error_type=error_type, kind="error", raw=raw,
                check=["error-body", "no-cors"] + (check or []))


def cases(p):
    """case_id -> dict(steps=[...], scenario_setup=bool, get_only=bool, sdk=bool, special=None)."""
    big_state = "S" * (p.budget_chars + 500)
    half = "S" * (p.budget_chars - 200)
    long_q = {"type": "noul", "instructions": "Q" * 400}
    choice_cap = _q_choice(p.profile_max_options)
    C = {}

    def add(cid, steps=None, sdk=False, special=None, scenario=False, get_only=None, note=""):
        if get_only is None:
            get_only = bool(steps) and all(s["method"] == "GET" for s in steps)
        C[cid] = {"steps": steps or [], "sdk": sdk, "special": special, "needs_scenario": scenario,
                  "get_only": get_only, "note": note}

    add("EP-001", [ok_systemone(req(questions={"q": _q_noul()}))], sdk=True)
    add("EP-002", [ok_systemone(req(questions={"q": _q_choice(2)}))], sdk=True)
    add("EP-003", [ok_systemone(req(questions={"q": choice_cap}))], sdk=True)
    add("EP-004", [ok_systemone(req(questions={"lo": _q_score(2), "hi": _q_score(10)}))], sdk=True)
    add("EP-005", [ok_systemone(req(questions={"a": _q_noul(), "b": _q_choice(3), "c": _q_score(4)}))], sdk=True)
    add("EP-006", [ok_systemone(req(state={"k": "v", "n": [1, 2]})),
                   ok_systemone(req(state=["a", "b", {"c": 1}])),
                   ok_systemone(req(state="plain MATRIXSTATE text"))], sdk=True)
    add("EP-007", [ok_systemone(req(model="jev-latest"))], sdk=True)
    add("EP-008", [err(422, "validation_failed", body=req(state=big_state))],
        note="DEFAULT behaviour (no shortening); needs --budget-chars to match the served profile")
    add("EP-008b", [ok_systemone(req(state=big_state, questions={"q": _q_noul()}), scenario="truncate_on",
                                 extra_check=["truncated"])], scenario=True,
        note="needs the opt-in shortening setting; scenario truncate_on")
    add("EP-009", [err(401, "unauthorized", auth="none", body=req(), check=["www-authenticate"])])
    add("EP-010", [err(401, "unauthorized", auth="wrong", body=req(), check=["www-authenticate"])])
    add("EP-011", [err(400, "invalid_request", raw=b"this is {not json")])
    add("EP-012", [err(400, "invalid_request", raw=b'["a","list"]'),
                   err(400, "invalid_request", raw=b'"just a string"'),
                   err(400, "invalid_request", raw=b"42")])
    add("EP-013", [err(400, "invalid_request", body=req(), ctype="text/plain")])
    add("EP-014", [err(413, "payload_too_large", raw=b'{"state":"' + b"B" * (p.body_cap + 4096) + b'","questions":{}}')])
    add("EP-015", [err(422, "validation_failed", body=req(questions={"q": _q_choice(1)})),
                   err(422, "validation_failed", body=req(questions={"q": _q_choice(p.profile_max_options + 1)})),
                   err(422, "validation_failed", body=req(questions={"q": _q_score(1)})),
                   err(422, "validation_failed", body=req(questions={"q": _q_score(11)}))])
    add("EP-015b", [err(400, "invalid_request", body=req(questions={"q": _q_choice(256)}))])
    add("EP-016", [err(422, "unknown_model", body=req(model="no-such-model-xyz"))], sdk=True)
    add("EP-016b", [err(503, "not_ready", body=req(), scenario="no_ready_instance", check=["retry-after"])], scenario=True)
    add("EP-017", [err(422, "validation_failed", body=req(state=half, questions={"q": {"type": "noul", "instructions": "Q" * 600}}))],
        note="state alone fits; state + longest question does not")
    add("EP-018", [err(422, "validation_failed", body=req(bogus_field=1)),
                   err(422, "validation_failed", body=req(questions={"q": {"type": "noul", "bogus": 1}}))])
    add("EP-019", special="burst")
    add("EP-020", [err(529, "overloaded", body=req(), scenario="overloaded", check=["retry-after"])], sdk=True, scenario=True)
    add("EP-021", [err(503, "not_ready", body=req(), scenario="draining", check=["retry-after"])], scenario=True)
    add("EP-022", [err(422, "readout_failed", body=req(), scenario="readout_failed")], scenario=True)
    add("EP-023", [err(502, "backend_failed", body=req(), scenario="backend_failed")], scenario=True)
    add("EP-024", special="slow-client")
    add("EP-025", [err(405, "method_not_allowed", method="GET", check=["allow"])])
    add("EP-026", special="conn-cap")
    models_check = ["json-ct", "no-cors"]
    add("EP-030", [step("GET", "/v1/models", status=200, kind="models", check=models_check)], sdk=True)
    add("EP-031", [err(401, "unauthorized", method="GET", path="/v1/models", auth="none", check=["www-authenticate"])])
    add("EP-032", [err(401, "unauthorized", method="GET", path="/v1/models", auth="wrong", check=["www-authenticate"])], sdk=True)
    add("EP-033", [err(405, "method_not_allowed", method="POST", path="/v1/models", body={}, check=["allow"])])
    add("EP-034", [err(503, "not_ready", method="GET", path="/v1/models", scenario="no_ready_instance", check=["retry-after"])], scenario=True)
    add("EP-040", [step("GET", "/healthz", auth="none", status=200, kind="health", check=["json-ct", "no-cors"])])
    add("EP-041", [err(405, "method_not_allowed", method="POST", path="/healthz", auth="none", body={}, check=["allow"])])
    add("EP-045", [step("GET", "/readyz", auth="none", status=200, kind="ready", check=["json-ct", "no-cors"])])
    add("EP-046", [step("GET", "/readyz", auth="none", status=503, kind="notready", scenario="not_ready",
                        check=["retry-after", "json-ct", "no-cors"])], scenario=True)
    add("EP-050", [step("GET", "/metrics", status=200, kind="metrics", check=["no-cors"])])
    add("EP-051", [err(401, "unauthorized", method="GET", path="/metrics", auth="none", check=["www-authenticate"])])
    add("EP-052", [err(405, "method_not_allowed", method="POST", path="/metrics", body={}, check=["allow"])])
    add("EP-060", [err(404, "invalid_request", method="GET", path="/v1/does-not-exist")])
    add("EP-061", [err(401, "unauthorized", method="GET", path="/v1/does-not-exist", auth="none", check=["www-authenticate"])])
    add("EP-070", special="plain-http")
    add("EP-071", special="engine-port")
    return C


# --------------------------------------------------------------------- validators

def _is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


CAL_METHODS = ("temperature", "platt", "isotonic")
_HEX64 = re.compile(r"^[0-9a-f]{64}$")


def _calibration_problems(name, a, base):
    """The additive FR-080 fields of a choice/score answer: confidence_raw and calibration come TOGETHER or not
    at all; calibration is exactly {method, n, profile_id}. Returns problems; the caller has already removed
    nothing - `base` is the answer's required key set."""
    out = []
    extra = set(a) - base
    if not extra:
        return out
    if extra != {"confidence_raw", "calibration"}:
        return ["%s: keys %s" % (name, sorted(a))]
    if not (_is_num(a["confidence_raw"]) and 0 <= a["confidence_raw"] <= 1):
        out.append("%s: bad confidence_raw" % name)
    c = a["calibration"]
    if not (isinstance(c, dict) and set(c) == {"method", "n", "profile_id"} and c["method"] in CAL_METHODS
            and isinstance(c["n"], int) and not isinstance(c["n"], bool) and c["n"] >= 0
            and isinstance(c["profile_id"], str) and c["profile_id"]):
        out.append("%s: bad calibration object" % name)
    return out


def validate_systemone(resp, request):
    """Return a list of problems with a 200 /v1/systemone body (openapi SystemOneResponse)."""
    out = []
    if not isinstance(resp, dict):
        return ["body is not an object"]
    if set(resp) != {"model", "answers", "usage"}:
        out.append("top-level keys %s != model,answers,usage" % sorted(resp))
    if not isinstance(resp.get("model"), str) or not resp.get("model"):
        out.append("model missing")
    u = resp.get("usage")
    if not (isinstance(u, dict) and set(u) == {"input_tokens", "output_tokens"} and
            all(isinstance(v, int) and v >= 0 for v in u.values())):
        out.append("usage malformed")
    ans = resp.get("answers")
    if not isinstance(ans, dict):
        return out + ["answers not an object"]
    qs = (request or {}).get("questions") or {}
    if request is not None and set(ans) != set(qs):
        out.append("answer keys %s != question keys %s" % (sorted(ans), sorted(qs)))
    for name, a in ans.items():
        t = a.get("type") if isinstance(a, dict) else None
        q = qs.get(name) or {}
        if request is not None and q.get("type") != t:
            out.append("%s: answer type %r != question type %r" % (name, t, q.get("type")))
        if t == "noul":
            if set(a) != {"type", "noul"} or not (_is_num(a["noul"]) and 0 <= a["noul"] <= 1):
                out.append("%s: bad noul answer" % name)
        elif t == "choice":
            base = {"type", "choice", "probabilities", "confidence"}
            if not base <= set(a):
                out.append("%s: choice keys %s" % (name, sorted(a)))
                continue
            cp = _calibration_problems(name, a, base)
            if cp:
                out += cp
                continue
            pr = a["probabilities"]
            if a["choice"] not in pr or abs(sum(pr.values()) - 1) > 1e-6 or not all(0 <= v <= 1 for v in pr.values()):
                out.append("%s: bad choice probabilities" % name)
            if request is not None and set(pr) != set((q.get("criteria") or {})):
                out.append("%s: probability keys differ from options" % name)
            if not (_is_num(a["confidence"]) and 0 <= a["confidence"] <= 1):
                out.append("%s: bad confidence" % name)
        elif t == "score":
            base = {"type", "score", "legend", "probabilities", "confidence"}
            if not base <= set(a):
                out.append("%s: score keys %s" % (name, sorted(a)))
                continue
            cp = _calibration_problems(name, a, base)
            if cp:
                out += cp
                continue
            n = len(a["probabilities"])
            if abs(sum(a["probabilities"].values()) - 1) > 1e-6 or not (_is_num(a["score"]) and 0 <= a["score"] <= n - 1):
                out.append("%s: bad score/probabilities" % name)
            if request is not None and n != len(q.get("criteria") or []):
                out.append("%s: level count differs" % name)
            if not (_is_num(a["confidence"]) and 0 <= a["confidence"] <= 1):
                out.append("%s: bad confidence" % name)
        else:
            out.append("%s: unknown answer type %r" % (name, t))
    return out


def _validate_sdk_models(models):
    """The hosted SDK listing: [{name, description, release_date}] (typesafe-sdk py 0.7.2, @typesafe-ai/sdk js 0.6.0)."""
    out = []
    if not (isinstance(models, list) and models):
        return ["sdk model list malformed"]
    for m in models:
        if not (isinstance(m, dict) and set(m) == {"name", "description", "release_date"}):
            out.append("sdk model entry keys %s" % (sorted(m) if isinstance(m, dict) else type(m).__name__))
            continue
        if not (isinstance(m["name"], str) and m["name"] and isinstance(m["description"], str) and m["description"]):
            out.append("sdk model name/description empty")
        if not (isinstance(m["release_date"], str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", m["release_date"])):
            out.append("sdk model release_date %r is not YYYY-MM-DD" % (m["release_date"],))
    return out


def _model_calibration_problems(c):
    """/v1/models calibration: {applied} + (applied: method,n,profile_id) | (not applied: reason)."""
    if not (isinstance(c, dict) and isinstance(c.get("applied"), bool)):
        return ["model calibration lacks a boolean applied"]
    if c["applied"]:
        if set(c) != {"applied", "method", "n", "profile_id"} or c["method"] not in CAL_METHODS or \
                not (isinstance(c["n"], int) and not isinstance(c["n"], bool) and c["n"] >= 0) or \
                not (isinstance(c["profile_id"], str) and c["profile_id"]):
            return ["model calibration (applied) malformed"]
        return []
    reasons = ("mismatch", "unbound", "invalid", "insecure", "model_unresolved")
    if set(c) != {"applied", "reason"} or c["reason"] not in reasons:
        return ["model calibration (not applied) malformed"]
    return []


def validate_models(resp):
    """GET /v1/models. Raw clients see BOTH shapes in one body (G-038); the SDK adapters return only
    their own `models` listing, which is validated against the SDK's required shape."""
    out = []
    if isinstance(resp, dict) and set(resp) == {"models"}:
        return _validate_sdk_models(resp["models"])
    if not (isinstance(resp, dict) and set(resp) == {"object", "data", "models"} and resp["object"] == "list"
            and isinstance(resp["data"], list) and resp["data"]):
        return ["model list envelope malformed"]
    out += _validate_sdk_models(resp["models"])
    for m in resp["data"]:
        need = {"id", "aliases", "protocol", "status", "limits"}
        if not need <= set(m) or set(m) - need - {"notes", "template_hash", "calibration"}:
            out.append("model entry keys %s" % sorted(m))
            continue
        if "template_hash" in m and not (isinstance(m["template_hash"], str) and _HEX64.match(m["template_hash"])):
            out.append("template_hash is not 64 lowercase hex")
        if "calibration" in m:
            out += _model_calibration_problems(m["calibration"])
        if m["protocol"] not in ("letter-logit", "systemone-native", "nli-onnx"):
            out.append("bad protocol")
        if m["status"] not in ("ready", "starting", "degraded", "draining"):
            out.append("bad status")
        lim = m["limits"]
        if not (isinstance(lim, dict) and set(lim) == {"max_options", "score_levels"} and
                isinstance(lim["max_options"], int) and 2 <= lim["max_options"] <= 255 and
                isinstance(lim["score_levels"], list) and len(lim["score_levels"]) == 2):
            out.append("limits malformed")
    return out


ERROR_TYPES = {"invalid_request", "unauthorized", "unknown_model", "validation_failed", "payload_too_large",
               "method_not_allowed", "rate_limited", "overloaded", "not_ready", "readout_failed", "backend_failed"}
