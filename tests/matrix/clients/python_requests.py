#!/usr/bin/env python3
"""python-requests matrix adapter. Exit 2 when `requests` is not importable. See README.md."""
import base64
import sys

try:
    import requests
except ImportError:
    print("ERROR client not installed: python module 'requests'")
    sys.exit(2)


def main(argv):
    method, url, cacert, tmo, bodyf, hdrf = argv[1:7]
    data = None if bodyf == "-" else open(bodyf, "rb").read()
    headers = {}
    if hdrf != "-":
        for line in open(hdrf, encoding="utf-8"):
            line = line.rstrip("\n")
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip()] = v.strip()
    try:
        r = requests.request(method, url, data=data, headers=headers, timeout=float(tmo),
                             verify=True if cacert == "-" else cacert, allow_redirects=False)
    except Exception as e:
        print("ERROR %s: %s" % (type(e).__name__, str(e).replace("\n", " ")))
        return 0
    print("STATUS %d" % r.status_code)
    for k, v in r.headers.items():
        print("HEADER %s: %s" % (k.lower(), v))
    print("BODY_B64 " + base64.b64encode(r.content).decode())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
