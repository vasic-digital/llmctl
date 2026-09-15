#!/usr/bin/env python3
"""range_server.py - minimal HTTP/1.1 server that DOES honor Range requests.

Used only by tests/test_download_resume.sh to prove llmctl's download-resume
path performs a genuine partial fetch (Range: bytes=N-) rather than
re-downloading the whole file. Python's stdlib http.server does NOT support
Range requests (verified against Python 3.14 - "Range" is absent from
SimpleHTTPRequestHandler's source), so this fixture exists specifically to
fill that gap for the test.

Usage: range_server.py <port> <file-to-serve> <request-log-path> <url-path>
Serves that one file at the exact <url-path> (e.g. "/toy/repo/resolve/main/
model.bin", matching lib/download.sh's real "<repo>/resolve/<revision>/
<name>" URL shape) on 127.0.0.1:<port>. Every request's Range header (or
"none") is appended to <request-log-path>, one line per request, so the
test can assert exactly which byte range was actually requested.
"""
import http.server
import re
import sys

PORT = int(sys.argv[1])
FILE_PATH = sys.argv[2]
LOG_PATH = sys.argv[3]
URL_PATH = sys.argv[4]


class RangeHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep test output quiet; the request-log file is the evidence

    def do_GET(self):
        if self.path != URL_PATH:
            self.send_error(404)
            return
        with open(FILE_PATH, "rb") as f:
            data = f.read()
        total = len(data)
        range_header = self.headers.get("Range")
        with open(LOG_PATH, "a") as log:
            log.write((range_header or "none") + "\n")

        if range_header:
            m = re.match(r"bytes=(\d+)-(\d*)", range_header)
            if not m:
                self.send_error(416)
                return
            start = int(m.group(1))
            end = int(m.group(2)) if m.group(2) else total - 1
            end = min(end, total - 1)
            chunk = data[start:end + 1]
            self.send_response(206)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
            self.send_header("Content-Length", str(len(chunk)))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            self.wfile.write(chunk)
        else:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(total))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            self.wfile.write(data)


if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), RangeHandler)
    server.serve_forever()
