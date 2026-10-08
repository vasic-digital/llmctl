#!/usr/bin/env python3
"""python-urllib matrix adapter (stdlib urllib + ssl only). See README.md."""
import base64
import ssl
import sys
import urllib.error
import urllib.request


def main(argv):
    method, url, cacert, tmo, bodyf, hdrf = argv[1:7]
    ctx = ssl.create_default_context(cafile=None if cacert == "-" else cacert)
    data = None if bodyf == "-" else open(bodyf, "rb").read()
    headers = {}
    if hdrf != "-":
        for line in open(hdrf, encoding="utf-8"):
            line = line.rstrip("\n")
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip()] = v.strip()
    req = urllib.request.Request(url, data=data, method=method, headers=headers)

    def emit(status, hdrs, body):
        print("STATUS %d" % status)
        for k, v in hdrs.items():
            print("HEADER %s: %s" % (k.lower(), v))
        print("BODY_B64 " + base64.b64encode(body).decode())

    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                         urllib.request.HTTPHandler())
    try:
        with opener.open(req, timeout=float(tmo)) as r:
            emit(r.status, dict(r.headers.items()), r.read())
    except urllib.error.HTTPError as e:
        emit(e.code, dict(e.headers.items()), e.read())
    except Exception as e:  # transport failure: no HTTP answer
        print("ERROR %s: %s" % (type(e).__name__, str(e).replace("\n", " ")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
