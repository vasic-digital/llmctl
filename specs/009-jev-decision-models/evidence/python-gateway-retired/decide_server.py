#!/usr/bin/env python3
# decide_server.py - deterministic stub of llama-server's OpenAI-compatible
# endpoints for decision-model tests (same fixture class as range_server.py:
# the real curl/python parse path in llmctl executes against a real HTTP
# server; only the model itself is stubbed).
#
#   GET  /health                  -> 200 {"status":"ok"}
#   POST /v1/chat/completions     -> 200 with choices[0].logprobs
#                                    .top_logprobs[0] scripted by prompt text
#
# Prompt-content scripting (deterministic, fixed letter distributions):
#   contains "2+2=4"          -> A heavy (noul yes probe)
#   contains "invoices"       -> A heavy (A = billing in the smoke criteria)
#   contains "Rate the quality" -> top letter of a 3-option set heavy (score)
#   otherwise                 -> fixed default: A heavy over A/B
# Every distribution also carries a non-letter token (" the") so the real
# letter-filtering path in decide_shape_response is exercised.
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def dist_for(prompt):
    """-> list of (token, logprob) for the scripted prompt classes."""
    if "2+2=4" in prompt:
        table = [(" A", -0.03), (" B", -3.5), (" the", -0.5)]
    elif "invoices" in prompt:
        table = [(" A", -0.05), (" B", -3.0), (" the", -0.5)]
    elif "Rate the quality" in prompt:
        table = [(" C", -0.04), (" B", -2.8), (" A", -4.0), (" the", -0.5)]
    else:
        table = [(" A", -0.1), (" B", -2.3), (" the", -0.5)]
    return [{"token": tok, "logprob": lp} for tok, lp in table]


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
        if self.path.split("?")[0] != "/v1/chat/completions":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "bad json"})
            return
        prompt = ""
        for msg in body.get("messages", []):
            if msg.get("role") == "user":
                prompt = msg.get("content") or ""
        top = dist_for(prompt)
        winner = max(top, key=lambda e: e["logprob"])["token"].strip()
        self._send(200, {
            "id": "chatcmpl-decide-fixture",
            "object": "chat.completion",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": winner},
                "finish_reason": "stop",
                "logprobs": {"content": None, "top_logprobs": [top]},
            }],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        })


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18092
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
