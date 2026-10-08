#!/usr/bin/env python3
"""fake_engine.py - a harmless stand-in for llama-server / the encoder runtime.

Used by tests/test_dynamic_ports.sh and tests/test_registry_discovery.sh as
LLMCTL_LLAMA_SERVER. It parses the same flags the scheduler passes (--host,
--port, --api-key-file ...), binds EXACTLY that host:port (exits 1 when the
port is taken, like the real server), answers 200 on /health and /v1/models
and does nothing else. The model file is never read. The internal key file,
when named, is only checked to exist (never printed).
"""
import http.server
import os
import sys
import time


def arg(name, default=None):
    a = sys.argv
    return a[a.index(name) + 1] if name in a and a.index(name) + 1 < len(a) else default


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/health", "/v1/models"):
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *a):
        pass


class S(http.server.HTTPServer):
    allow_reuse_address = True  # like the real engine (SO_REUSEADDR): TIME_WAIT must not block a restart; a LISTENing port still fails


def main():
    host = arg("--host", "127.0.0.1")
    port = int(arg("--port", "0"))
    keyf = arg("--api-key-file")
    if keyf and not os.path.isfile(keyf):
        sys.stderr.write("fake_engine: key file %s missing\n" % keyf)
        return 2
    # FAKE_ENGINE_DELAY: seconds to wait before binding - a loading model that
    # is alive (registrable process) but not yet answering.
    delay = float(os.environ.get("FAKE_ENGINE_DELAY", "0") or 0)
    if delay > 0:
        time.sleep(delay)
    try:
        srv = S((host, port), H)
    except OSError as e:
        sys.stderr.write("couldn't bind HTTP server socket, hostname: %s, port: %d (%s)\n" % (host, port, e))
        return 1
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
