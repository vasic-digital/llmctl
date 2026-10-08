#!/usr/bin/env python3
"""TLS stub gateway that answers every request with one fixed HTTP status (used for the 529 case).
usage: status_stub.py <chain.pem> <leaf.key> <status>   prints "READY https://127.0.0.1:<port>"; serves until stdin closes."""
import http.server, ssl, sys, threading, json

chain, key, status = sys.argv[1], sys.argv[2], int(sys.argv[3])

class H(http.server.BaseHTTPRequestHandler):
    def _reply(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        body = json.dumps({"error": {"type": "overloaded", "message": "stub"}}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Retry-After", "0")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST = _reply
    def log_message(self, *a):
        pass

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(chain, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
print("READY https://127.0.0.1:%d" % srv.server_address[1], flush=True)
threading.Thread(target=srv.serve_forever, daemon=True).start()
sys.stdin.read()
srv.shutdown()
