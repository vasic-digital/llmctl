#!/usr/bin/env python3
"""fake_letter_engine.py - a stand-in for a llama-server serving a letter-logit decision model.

Answers POST /v1/chat/completions the way llama-server does for the production letter-logit driver (one token with
first-token top_logprobs, internal/gateway/letter.go): it reads the rendered decision prompt (contract.RenderPrompt:
"Question: <instructions>" then one "<LETTER>) <key> - <description>" line per option), looks the question's
instructions up in a known-answer table (decide-v1: instructions -> expected choice key), and puts the option letter of
the expected key at the top of the logprobs (all other option letters present, much lower). Deterministic: the same
prompt always yields byte-identical answers. GET /health and /v1/models answer 200. Nothing else is served.

  fake_letter_engine.py --table <instructions->key.json> --port-file <file> [--wrong]
    --wrong  answer the SECOND listed option instead (a deliberately wrong model: the judge must FAIL it)

The chosen port is written to --port-file once the socket listens. The process never prints a request body.
"""
import argparse
import http.server
import json
import re
import sys

OPT = re.compile(r"^([A-Z])\) (.*)$")


class H(http.server.BaseHTTPRequestHandler):
    table = {}
    wrong = False

    def _send(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path in ("/health", "/v1/models", "/props"):
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
            prompt = req["messages"][0]["content"]
        except (ValueError, KeyError, IndexError, TypeError):
            self._send(400, {"error": "bad request"})
            return
        if self.path != "/v1/chat/completions":
            self._send(404, {"error": "not found"})
            return
        lines = prompt.split("\n")
        instr = next((l[len("Question: "):] for l in lines if l.startswith("Question: ")), "")
        opts = [m.groups() for m in (OPT.match(l) for l in lines) if m]
        want = self.table.get(instr)
        pick = None
        for i, (letter, label) in enumerate(opts):
            key = label.split(" - ", 1)[0]
            if self.wrong:
                if i == 1:
                    pick = letter
            elif key == want:
                pick = letter
        if pick is None:
            self._send(422, {"error": "fake engine: no known answer for question %r" % instr})
            return
        top = []
        for letter, _ in opts:
            top.append({"token": letter, "logprob": -0.05 if letter == pick else -6.0})
        self._send(200, {"choices": [{"message": {"content": pick}, "logprobs": {"top_logprobs": [top]}}]})

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--table", required=True)
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--wrong", action="store_true")
    a = ap.parse_args()
    H.table = json.load(open(a.table))
    H.wrong = a.wrong
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    with open(a.port_file, "w") as fh:
        fh.write(str(srv.server_address[1]))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
