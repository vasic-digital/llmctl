#!/usr/bin/env python3
# onnx_decide_server.py - deterministic stub of lib/onnx_server.py's HTTP
# surface for decide-path/gateway tests (same fixture class as
# decide_server.py / range_server.py: the real curl/python parse path in
# llmctl executes against a real HTTP server; only the encoder model is
# stubbed).
#
#   GET  /health           -> 200 {"status":"ok"}
#   POST /v1/systemone     -> 200 {"model", "answers", "usage"} with answers
#                             scripted by question content (deterministic)
#
# Content scripting (mirrors decide_server.py's prompt classes):
#   instructions contains "2+2=4"           -> noul 0.97
#   instructions contains "invoices"        -> choice "billing" 0.97/0.03
#   instructions contains "Rate the quality" -> score probs .05/.25/.70 -> 1.65
#   otherwise                               -> first option heavy (0.9/0.1...)
# Confidence follows the SAME ecosystem formula (n*p_max-1)/(n-1) clamped.
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def confidence(n, p_max):
    c = (n * p_max - 1.0) / (n - 1) if n > 1 else 1.0
    return max(0.0, min(1.0, c))


def answer_for(q):
    """-> scripted typed answer for one question object."""
    qtype = q.get("type")
    instructions = q.get("instructions") or ""
    criteria = q.get("criteria")
    if qtype == "noul":
        p = 0.97 if "2+2=4" in instructions else 0.9
        return {"type": "noul", "noul": p}
    if qtype == "choice":
        keys = list((criteria or {}).keys()) or ["a", "b"]
        if "invoices" in instructions and "billing" in keys:
            probs = {k: 0.03 / (len(keys) - 1) for k in keys}
            probs["billing"] = 0.97
        else:
            probs = {k: 0.1 / (len(keys) - 1) for k in keys}
            probs[keys[0]] = 0.9
        winner = max(probs, key=probs.get)
        return {"type": "choice", "choice": winner, "probabilities": probs,
                "confidence": confidence(len(keys), max(probs.values()))}
    if qtype == "score":
        levels = criteria or ["bad", "good"]
        n = len(levels)
        if "Rate the quality" in instructions and n == 3:
            probs = [0.05, 0.25, 0.70]
        else:
            probs = [0.1 / (n - 1)] * n
            probs[-1] = 0.9
        return {"type": "score",
                "score": sum(i * p for i, p in enumerate(probs)),
                "legend": {str(i): str(l) for i, l in enumerate(levels)},
                "probabilities": {str(i): probs[i] for i in range(n)},
                "confidence": confidence(n, max(probs))}
    return {"error": "unknown type"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep fixture output quiet/deterministic
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?")[0] == "/health":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/v1/systemone":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "bad json"})
            return
        questions = body.get("questions") or {}
        answers = {name: answer_for(q) for name, q in questions.items()}
        self._send(200, {
            "model": body.get("model") or "llmctl-onnx-fixture",
            "answers": answers,
            "usage": {"input_tokens": 42, "output_tokens": len(questions),
                      "total_tokens": 42 + len(questions)},
        })


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18096
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
