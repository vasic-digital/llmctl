#!/usr/bin/env python3
"""code_server.py PORT MODEL_ID CHAT_CODE [CHAT_CONTENT] - test fixture: /v1/models answers MODEL_ID; every POST answers HTTP
CHAT_CODE (200 -> a chat completion whose content is CHAT_CONTENT). Prints the bound port to stdout. Never a model."""
import http.server, json, sys
port, model, code = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
content = sys.argv[4] if len(sys.argv) > 4 else "no"
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, c, obj):
        b = json.dumps(obj).encode()
        self.send_response(c); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._send(200, {"data": [{"id": model}]})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n: self.rfile.read(n)
        if code == 200:
            self._send(200, {"choices": [{"message": {"content": content}, "finish_reason": "stop"}], "usage": {}})
        else:
            self._send(code, {"error": {"message": "injected %d" % code}})
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", port), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
