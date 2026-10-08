#!/usr/bin/env python3
"""decide_gateway.py - HTTP gateway exposing llmctl decision models over the
Jev/TypeSafe-SDK wire shape (POST /v1/systemone).

stdlib only (python3 is already a hard llmctl dependency; same precedent as
tests/fixtures/range_server.py). Launched by `llmctl decide serve`
(lib/decide.sh), never directly by users.

SINGLE SOURCE OF TRUTH for the decision prompt template: lib/decide.sh's
decide_build_prompt delegates to this file's `--render-prompt` CLI mode, so
the lettered-option template exists exactly once (here). The response-shaping
math (softmax over matched letter logprobs / temperature, confidence
(n*p_max-1)/(n-1) clamped to [0,1]) mirrors decide_shape_response in
lib/decide.sh exactly - keep the two formulas in sync.

Endpoints:
  POST /v1/systemone   {"model": ..., "state": ..., "questions": {name: q}}
                       -> {"model": ..., "answers": {name: answer}, "usage": ...}
                       Question NAMES are never sent to the model (Jev 1P
                       semantics); only instructions/criteria are rendered.
                       With --backend-engine onnx this endpoint is PROXIED
                       (single loopback hop) to the onnx backend's native
                       /v1/systemone instead of being rendered locally.
  GET  /v1/models      {"data": [{"id": "jev-latest"}, ...]} aliases mapping
                       to the active profile.
  GET  /healthz        200 when the backend llama-server /health is up, else 503.

Auth: when --api-key (or LLMCTL_DECIDE_API_KEY) is set, /v1/* requires
"Authorization: Bearer <key>" (401 on mismatch/absence). /healthz stays open
for probes. Bind defaults to 127.0.0.1; --bind-host or an explicitly exported
LLMCTL_BIND_HOST overrides.

usage.input_tokens ESTIMATION (honest method): llama-server is queried with a
raw prompt string and its usage block is not consulted per-question here, so
the gateway estimates input tokens as ceil(len(rendered_prompt_chars) / 4)
summed over all questions (the ~4-chars-per-token rule of thumb for English
text). It is an estimate, NOT a tokenizer-exact count. usage.output_tokens is
exact: one generated token per question (max_tokens=1).
"""
import argparse
import json
import math
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROMPT_HEADER = ("You are a decision engine. Read the state and answer the "
                 "question with exactly one letter.")

# Mirrors lib/decide.sh's option caps: practical cap LLMCTL_DECIDE_MAX_OPTIONS
# (default 20), hard cap 26 letters (A..Z).
MAX_OPTIONS = int(os.environ.get("LLMCTL_DECIDE_MAX_OPTIONS", "20") or "20")


def die(msg, rc=2):
    sys.stderr.write("decide: %s\n" % msg)
    sys.exit(rc)


def derive_options(qtype, criteria):
    """-> (options, legend); options = [{"letter","key","label"}, ...].

    Lettered A..Z in criteria order (JSON object insertion order for choice,
    array order for score). Error messages and exit code 2 match
    decide_options_json in lib/decide.sh exactly.
    """
    options = []
    legend = {}
    raw = (criteria or "").strip()
    if qtype == "noul":
        tdesc = fdesc = ""
        if raw:
            try:
                crit = json.loads(raw)
            except ValueError:
                die("noul --criteria is not valid JSON")
            if not isinstance(crit, dict):
                die('noul --criteria must be a JSON object {"true": ..., "false": ...}')
            tdesc = str(crit.get("true") or "")
            fdesc = str(crit.get("false") or "")
        options.append({"letter": "A", "key": "yes",
                        "label": "yes" + (" - %s" % tdesc if tdesc else "")})
        options.append({"letter": "B", "key": "no",
                        "label": "no" + (" - %s" % fdesc if fdesc else "")})
    elif qtype == "choice":
        if not raw:
            die('choice requires --criteria \'{"option": "description", ...}\'')
        try:
            crit = json.loads(raw)
        except ValueError:
            die("choice --criteria is not valid JSON")
        if not isinstance(crit, dict) or len(crit) < 2:
            die("choice --criteria must be a JSON object with at least 2 options")
        for i, (key, desc) in enumerate(crit.items()):
            options.append({"letter": chr(ord("A") + i), "key": str(key),
                            "label": "%s - %s" % (key, desc)})
    elif qtype == "score":
        if not raw:
            die('score requires --criteria \'["level 0 desc", ...]\' (2-10 levels)')
        try:
            crit = json.loads(raw)
        except ValueError:
            die("score --criteria is not valid JSON")
        if not isinstance(crit, list) or not (2 <= len(crit) <= 10):
            die("score --criteria must be a JSON array of 2-10 ordered level descriptions")
        for i, desc in enumerate(crit):
            options.append({"letter": chr(ord("A") + i), "key": str(i),
                            "label": str(desc)})
            legend[str(i)] = str(desc)
    else:
        die("unknown type: %s (noul|choice|score)" % qtype)
    if len(options) > 26:
        die("%d options exceeds the hard cap of 26 (lettered A..Z)" % len(options))
    if len(options) > MAX_OPTIONS:
        die("%d options exceeds LLMCTL_DECIDE_MAX_OPTIONS=%d" % (len(options), MAX_OPTIONS))
    return options, legend


def render_prompt(qtype, state, instructions, criteria):
    """The ONE prompt template (Pattern A lettered options)."""
    options, _legend = derive_options(qtype, criteria)
    lines = [PROMPT_HEADER, "", "State:", state, "",
             "Question: %s" % instructions]
    for o in options:
        lines.append("%s) %s" % (o["letter"], o["label"]))
    lines += ["", "Answer with a single letter.", "Answer:"]
    return "\n".join(lines)


def shape_answer(qtype, raw, options, legend, temperature):
    """Jev-shaped typed answer from a raw /v1/chat/completions response.

    Identical math to decide_shape_response in lib/decide.sh: letter tokens
    (" A"/"A"/" a"...) normalized strip/upper, absent letters get p=0, softmax
    over matched letter logprobs divided by temperature, confidence
    (n*p_max-1)/(n-1) clamped to [0,1]. Raises ValueError on unusable input.
    """
    try:
        top = raw["choices"][0]["logprobs"]["top_logprobs"][0]
    except (KeyError, IndexError, TypeError):
        raise ValueError("backend response carries no "
                         "choices[0].logprobs.top_logprobs[0] "
                         "(llama-server must be built with OpenAI-compatible "
                         "logprobs support)")
    letter_lp = {}
    for entry in top:
        tok = str(entry.get("token", "")).strip().upper()
        if len(tok) != 1 or not ("A" <= tok <= "Z"):
            continue
        lp = entry.get("logprob")
        if lp is None:
            continue
        if tok not in letter_lp or lp > letter_lp[tok]:
            letter_lp[tok] = float(lp)
    n = len(options)
    matched = [(i, o, letter_lp[o["letter"]])
               for i, o in enumerate(options) if o["letter"] in letter_lp]
    if not matched:
        raise ValueError("no option letters found in backend top_logprobs")
    temp = temperature if temperature > 0 else 1.0
    logps = [lp / temp for _, _, lp in matched]
    m = max(logps)
    exps = [math.exp(x - m) for x in logps]
    denom = sum(exps)
    probs = [0.0] * n
    for (i, _o, _lp), e in zip(matched, exps):
        probs[i] = e / denom
    p_max = max(probs)
    confidence = (n * p_max - 1.0) / (n - 1) if n > 1 else 1.0
    confidence = max(0.0, min(1.0, confidence))
    if qtype == "noul":
        return {"type": "noul", "noul": probs[0]}
    if qtype == "choice":
        return {"type": "choice",
                "choice": options[probs.index(p_max)]["key"],
                "probabilities": {o["key"]: probs[i] for i, o in enumerate(options)},
                "confidence": confidence}
    if qtype == "score":
        return {"type": "score",
                "score": sum(i * probs[i] for i in range(n)),
                "legend": legend,
                "probabilities": {str(i): probs[i] for i in range(n)},
                "confidence": confidence}
    raise ValueError("unknown type: %s (noul|choice|score)" % qtype)


class Gateway:
    """Shared config/state for the request handler."""

    def __init__(self, args):
        self.backend_host = args.backend_host
        self.backend_port = args.backend_port
        # backend_engine: "llama" renders the prompt + shapes logprobs
        # locally against llama-server's /v1/chat/completions; "onnx"
        # proxies /v1/systemone straight through to the onnx server's
        # native same-shaped endpoint (single extra HTTP hop on the
        # loopback path - documented latency cost: one loopback round
        # trip, no prompt rendering or logprob shaping at this layer).
        self.backend_engine = args.backend_engine
        self.profile = args.profile
        self.model_id = args.model_id or ("llmctl-%s" % args.profile)
        self.api_key = args.api_key or os.environ.get("LLMCTL_DECIDE_API_KEY") or ""
        self.max_state_chars = args.max_state_chars
        self.timeout = float(os.environ.get("LLMCTL_DECIDE_TIMEOUT", "30") or "30")
        try:
            self.temperature = float(os.environ.get("LLMCTL_DECIDE_TEMPERATURE", "1.0") or "1.0")
        except ValueError:
            self.temperature = 1.0
        self.seed = os.environ.get("LLMCTL_SEED") or ""

    def backend_url(self, path):
        return "http://%s:%d%s" % (self.backend_host, self.backend_port, path)

    def backend_health(self):
        try:
            with urllib.request.urlopen(self.backend_url("/health"),
                                        timeout=min(self.timeout, 5.0)) as resp:
                return resp.status == 200
        except Exception:
            return False

    def query_logprobs(self, prompt, n_options):
        body = {
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 1,
            "temperature": 0,
            "logprobs": True,
            "top_logprobs": max(n_options, 5),
        }
        if self.seed:
            body["seed"] = int(self.seed)
        req = urllib.request.Request(
            self.backend_url("/v1/chat/completions"),
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def proxy_systemone(self, body):
        """onnx backend mode: forward {model, state, questions} to the onnx
        server's native /v1/systemone (single hop, loopback) and return its
        response verbatim - the onnx server already produces Jev-shaped
        answers and its own usage block."""
        req = urllib.request.Request(
            self.backend_url("/v1/systemone"),
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def truncate_state(self, state):
        """Head+tail truncation to max_state_chars (0 disables)."""
        cap = self.max_state_chars
        if cap <= 0 or len(state) <= cap:
            return state, False
        half = cap // 2
        head = state[:half]
        tail = state[len(state) - (cap - half):]
        return "%s\n...[state truncated to %d chars]...\n%s" % (head, cap, tail), True


def make_handler(gw):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            sys.stderr.write("decide-gateway: %s\n" % (args[0] % args[1:]))

        def _send(self, code, obj, extra_headers=None):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra_headers or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _authorized(self):
            if not gw.api_key:
                return True
            auth = self.headers.get("Authorization") or ""
            return auth == "Bearer %s" % gw.api_key

        def do_GET(self):
            path = self.path.split("?")[0]
            if path == "/healthz":
                if gw.backend_health():
                    self._send(200, {"status": "ok", "profile": gw.profile})
                else:
                    self._send(503, {"status": "backend unavailable"})
                return
            if not self._authorized():
                self._send(401, {"error": "unauthorized"})
                return
            if path == "/v1/models":
                aliases = ["jev-latest", "jev-preview", "llmctl-%s" % gw.profile]
                seen = set()
                data = []
                for a in aliases + [gw.model_id]:
                    if a in seen:
                        continue
                    seen.add(a)
                    data.append({"id": a, "object": "model", "owned_by": "llmctl"})
                self._send(200, {"object": "list", "data": data})
                return
            self._send(404, {"error": "not found"})

        def do_POST(self):
            path = self.path.split("?")[0]
            if path != "/v1/systemone":
                self._send(404, {"error": "not found"})
                return
            if not self._authorized():
                self._send(401, {"error": "unauthorized"})
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            # Bounded request body: state is separately capped at
            # --max-state-chars, so 4 MiB is far beyond any legitimate body.
            if length <= 0 or length > 4 * 1024 * 1024:
                self._send(400, {"error": "missing or oversized request body"})
                return
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                self._send(400, {"error": "request body is not valid JSON"})
                return
            state = body.get("state")
            questions = body.get("questions")
            if not isinstance(state, str) or not state:
                self._send(400, {"error": "body.state (string) is required"})
                return
            if not isinstance(questions, dict) or not questions:
                self._send(400, {"error": "body.questions (object) is required"})
                return
            state, truncated = gw.truncate_state(state)
            if gw.backend_engine == "onnx":
                # Proxy mode (single hop, documented in Gateway.__init__):
                # the onnx backend owns rendering, inference and usage.
                fwd = {"model": body.get("model") or gw.model_id,
                       "state": state, "questions": questions}
                try:
                    upstream = gw.proxy_systemone(fwd)
                except (urllib.error.URLError, ValueError, OSError) as exc:
                    self._send(502, {"error": "onnx backend query failed: %s" % exc})
                    return
                headers = {}
                if truncated:
                    headers["x-llmctl-decide-truncated"] = "true"
                self._send(200, upstream, extra_headers=headers)
                return
            answers = {}
            input_chars = 0
            for name, q in questions.items():
                # NOTE: the question NAME is never rendered into the prompt
                # (Jev 1P semantics); only instructions/criteria reach the model.
                if not isinstance(q, dict):
                    self._send(400, {"error": "question '%s' must be an object" % name})
                    return
                qtype = q.get("type")
                instructions = q.get("instructions")
                criteria = q.get("criteria")
                if qtype not in ("noul", "choice", "score"):
                    self._send(400, {"error": "question '%s': type must be noul|choice|score" % name})
                    return
                if not instructions:
                    self._send(400, {"error": "question '%s': instructions is required" % name})
                    return
                criteria_raw = json.dumps(criteria) if criteria is not None else ""
                try:
                    options, legend = derive_options(qtype, criteria_raw)
                except SystemExit:
                    self._send(400, {"error": "question '%s': invalid criteria for type %s" % (name, qtype)})
                    return
                prompt = render_prompt(qtype, state, instructions, criteria_raw)
                input_chars += len(prompt)
                try:
                    raw = gw.query_logprobs(prompt, len(options))
                except (urllib.error.URLError, ValueError, OSError) as exc:
                    self._send(502, {"error": "backend query failed: %s" % exc})
                    return
                try:
                    answers[name] = shape_answer(qtype, raw, options, legend,
                                                 gw.temperature)
                except ValueError as exc:
                    self._send(502, {"error": str(exc)})
                    return
            # input_tokens: honest estimate, ~4 chars/token over the rendered
            # prompts (see module docstring); NOT a tokenizer-exact count.
            est_input = max(1, math.ceil(input_chars / 4))
            usage = {"input_tokens": est_input,
                     "output_tokens": len(questions),
                     "total_tokens": est_input + len(questions)}
            model = body.get("model") or gw.model_id
            headers = {}
            if truncated:
                headers["x-llmctl-decide-truncated"] = "true"
            self._send(200, {"model": model, "answers": answers, "usage": usage},
                       extra_headers=headers)

    return Handler


def main(argv=None):
    ap = argparse.ArgumentParser(prog="decide_gateway.py")
    ap.add_argument("--render-prompt", action="store_true",
                    help="CLI mode: render one decision prompt on stdout and exit "
                         "(single source of truth for the prompt template; used by "
                         "decide_build_prompt in lib/decide.sh)")
    ap.add_argument("--type", default="")
    ap.add_argument("--state", default="")
    ap.add_argument("--instructions", default="")
    ap.add_argument("--criteria", default="")
    ap.add_argument("--port", type=int, default=int(os.environ.get("LLMCTL_DECIDE_PORT", "8095")))
    ap.add_argument("--bind-host", default=os.environ.get("LLMCTL_BIND_HOST") or "127.0.0.1")
    ap.add_argument("--backend-host", default=os.environ.get("LLMCTL_DECIDE_BACKEND_HOST", "127.0.0.1"))
    ap.add_argument("--backend-port", type=int,
                    default=int(os.environ.get("LLMCTL_DECIDE_BACKEND_PORT", "0") or "0"))
    ap.add_argument("--profile", default="")
    ap.add_argument("--backend-engine", choices=("llama", "onnx"), default="llama",
                    help="llama: render prompts + shape logprobs against the "
                         "backend's /v1/chat/completions; onnx: proxy "
                         "/v1/systemone to the onnx backend's native "
                         "same-shaped endpoint (single loopback hop)")
    ap.add_argument("--model-id", default="")
    ap.add_argument("--api-key", default="")
    ap.add_argument("--max-state-chars", type=int,
                    default=int(os.environ.get("LLMCTL_DECIDE_MAX_STATE_CHARS", "8192") or "8192"))
    args = ap.parse_args(argv)

    if args.render_prompt:
        # Same interface as lib/decide.sh's decide_build_prompt.
        if not args.instructions:
            die("--instructions is required with --render-prompt")
        print(render_prompt(args.type, args.state, args.instructions, args.criteria))
        return 0

    if not args.profile:
        die("--profile is required")
    if not args.backend_port:
        die("--backend-port is required (or LLMCTL_DECIDE_BACKEND_PORT)")
    gw = Gateway(args)
    server = ThreadingHTTPServer((args.bind_host, args.port), make_handler(gw))
    sys.stderr.write("decide-gateway: listening on %s:%d (profile %s, backend %s:%d)\n"
                     % (args.bind_host, args.port, args.profile,
                        args.backend_host, args.backend_port))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
