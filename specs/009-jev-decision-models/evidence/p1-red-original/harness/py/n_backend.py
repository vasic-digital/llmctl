"""n_backend.py - tiny RECORDING llama-server stand-in (in-process thread).

STAND-IN / unit-level only: it models only the model backend of the llama
engine (GET /health, POST /v1/chat/completions). It records what the code
under test sent so the tests can observe request counts and prompt sizes.
Never counts as real-model proof.
"""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Backend:
    def __init__(self, reject_over_chars=None, top=None):
        self.requests = []          # (path, prompt_chars)
        self.health_hits = 0
        self.reject_over_chars = reject_over_chars
        self.top = top or [{"token": " A", "logprob": -0.1},
                           {"token": " B", "logprob": -2.3},
                           {"token": " the", "logprob": -0.5}]
        self.lock = threading.Lock()
        outer = self

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def _send(self, code, obj):
                b = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def do_GET(self):
                if self.path.split("?")[0] == "/health":
                    with outer.lock:
                        outer.health_hits += 1
                    self._send(200, {"status": "ok"})
                else:
                    self._send(404, {"error": "nf"})

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                prompt = body["messages"][0]["content"]
                with outer.lock:
                    outer.requests.append((self.path, len(prompt), body))
                if outer.reject_over_chars and len(prompt) > outer.reject_over_chars:
                    self._send(400, {"error": {"code": 400, "type": "exceed_context_size_error",
                                               "message": "the request exceeds the available context size"}})
                    return
                self._send(200, {"choices": [{"message": {"content": "A"},
                                              "logprobs": {"top_logprobs": [outer.top]}}]})

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
