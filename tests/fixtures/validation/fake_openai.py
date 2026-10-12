#!/usr/bin/env python3
"""fake_openai.py - deterministic OpenAI-compatible fixture server for the validation tests.

NOT a model. It answers from a fixed answer table so the validator's judge, controls and exit codes can be
tested hermetically (tests/test_vision_validate.sh). It never stands in for a live run: the live evidence
of `llmctl vision validate` comes from a real llama-server (docs/qa/vision-validate-live-*.md).

Answer resolution for POST /v1/chat/completions: the image (data URI) is identified by the sha256 of its
decoded bytes -> fixture id via the suite's expectations.json; the prompt text selects the probe (the
image's own probe with that prompt first, else any probe with that prompt). The answer table is keyed
"<image fixture id>/<probe id>" (vision) or "<case id>" (chat/coder). Unknown key -> HTTP 500.

Usage: fake_openai.py --suite DIR [--suite DIR2 ...] --answers FILE --port-file FILE [--model-id ID]
                      [--mode normal|reject-images|error500|nondeterministic|truncate|reasoning-budget|reasoning-empty-stop]
"""
import argparse
import base64
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", action="append", default=[])
    ap.add_argument("--answers", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--model-id", default="/models/vision/gemma-3-4b-it-Q4_K_M.gguf")
    ap.add_argument("--mode", default="normal")
    a = ap.parse_args()
    answers = json.load(open(a.answers))
    by_sha, prompts = {}, []          # image sha -> fixture id ; [(fixture_id or None, probe_id, prompt)]
    for sd in a.suite:
        for name in ("expectations.json", "suite.json"):
            p = os.path.join(sd, name)
            if os.path.isfile(p):
                s = json.load(open(p))
        if s["kind"] == "vision":
            for fx in s["fixtures"]:
                by_sha[hashlib.sha256(open(os.path.join(sd, fx["image"]), "rb").read()).hexdigest()] = fx["id"]
                for pr in fx["probes"]:
                    prompts.append((fx["id"], pr["id"], pr["prompt"]))
        else:
            for c in s.get("cases", []):
                prompts.append((None, c["id"], c.get("prompt", "")))
    calls = {}

    class H(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/v1/models":
                return self.send(200, {"object": "list", "data": [{"id": a.model_id}]})
            if self.path == "/health":
                return self.send(200, {"status": "ok"})
            self.send(404, {"error": "not found"})

        def do_POST(self):
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            if a.mode == "error500":
                return self.send(500, {"error": "fixture: internal error"})
            if self.path == "/v1/embeddings":
                text = req.get("input", "")
                vec = answers.get("embeddings", {}).get(text)
                if vec is None:
                    return self.send(500, {"error": "fixture: no embedding for %r" % text})
                return self.send(200, {"data": [{"embedding": vec}]})
            if self.path != "/v1/chat/completions":
                return self.send(404, {"error": "not found"})
            content = req["messages"][-1]["content"]
            image_id, prompt = None, content
            if isinstance(content, list):
                prompt = ""
                for part in content:
                    if part.get("type") == "image_url":
                        url = part["image_url"]["url"]
                        raw = base64.b64decode(url.split(",", 1)[1])
                        image_id = by_sha.get(hashlib.sha256(raw).hexdigest(), "unknown-image")
                    elif part.get("type") == "text":
                        prompt = part["text"]
                if image_id and a.mode == "reject-images":
                    return self.send(400, {"error": {"message": "image input is not supported - hint: if this is unexpected, you may need to provide the mmproj"}})
            cands = [(f, p) for f, p, t in prompts if t == prompt]
            own = [(f, p) for f, p in cands if f == image_id]
            pick = (own or cands or [(None, None)])[0]
            if image_id:
                key = "%s/%s" % (image_id, pick[1])
            else:
                key = pick[1]
            if key not in answers:
                return self.send(500, {"error": "fixture: no answer for %s" % key})
            ans = answers[key]
            calls[key] = calls.get(key, 0) + 1
            if a.mode == "nondeterministic" and calls[key] > 1:
                ans = ans + " (second call differs)"
            finish = "length" if a.mode == "truncate" else "stop"
            msg = {"role": "assistant", "content": ans}
            if a.mode == "reasoning-budget":
                # a reasoning model that spent the whole max_tokens budget in the reasoning channel
                msg, finish = {"role": "assistant", "content": "", "reasoning_content": "Let me think step by step ..."}, "length"
            elif a.mode == "reasoning-empty-stop":
                msg = {"role": "assistant", "content": "", "reasoning_content": "thought about it, then said nothing"}
            self.send(200, {"choices": [{"message": msg, "finish_reason": finish}],
                            "usage": {"prompt_tokens": 1, "completion_tokens": 1}})

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    with open(a.port_file + ".tmp", "w") as fh:
        fh.write(str(srv.server_address[1]))
    os.replace(a.port_file + ".tmp", a.port_file)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
