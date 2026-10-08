#!/usr/bin/env python3
"""Fixture Hugging Face API server for tests/test_admit.sh.

Serves <root>/api/models/<owner>/<repo> as JSON (the same path layout as
the real API; the query string is ignored). A file '<repo>.401' makes the
path answer 401 (how huggingface.co answers private-or-missing repos);
anything else missing answers 404. Records the Authorization header of
every request to <root>/../auth.log when AUTH_LOG is set, so a test can
prove HF_TOKEN is honoured and is never persisted anywhere else.
Binds 127.0.0.1 on an ephemeral port and writes the port to argv[2].
"""
import http.server, os, sys

ROOT = os.path.abspath(sys.argv[1])
PORTFILE = sys.argv[2]
AUTH_LOG = os.environ.get("AUTH_LOG")


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if AUTH_LOG:
            with open(AUTH_LOG, "a") as f:
                f.write((self.headers.get("Authorization") or "-") + "\n")
        path = self.path.split("?", 1)[0]
        full = os.path.normpath(os.path.join(ROOT, path.lstrip("/")))
        if not full.startswith(ROOT + os.sep):
            self.send_error(400)
            return
        if os.path.exists(full + ".401"):
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"error":"Invalid username or password."}')
            return
        if not os.path.isfile(full):
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'{"error":"Repository not found"}')
            return
        data = open(full, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
