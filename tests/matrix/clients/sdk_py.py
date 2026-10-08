#!/usr/bin/env python3
"""typesafe-sdk (PyPI) matrix adapter. Run with the private venv's interpreter (the runner
installs the SDK into a temp venv). Applicable only to the SDK's own surface:
POST /v1/systemone and GET /v1/models. See README.md.

CA-trust mechanisms tried in order, each reported on a TRUST line:
  1. env-SSL_CERT_FILE      SSL_CERT_FILE=<ca> with the SDK's default HTTP client
  2. http_client-ssl-context  the documented hook: http_client=httpx2.Client(verify=<ssl context>)
"""
import base64
import json
import os
import ssl
import sys


def parse(argv):
    method, url, cacert, tmo, bodyf, hdrf = argv[1:7]
    headers = {}
    if hdrf != "-":
        for line in open(hdrf, encoding="utf-8"):
            line = line.rstrip("\n")
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
    body = None if bodyf == "-" else json.loads(open(bodyf, "rb").read() or b"null")
    return method, url, cacert, float(tmo), body, headers


def emit(status, hdrs, payload):
    print("STATUS %d" % status)
    for k, v in (hdrs or {}).items():
        print("HEADER %s: %s" % (k.lower(), v))
    print("BODY_B64 " + base64.b64encode(payload if isinstance(payload, bytes) else json.dumps(payload).encode()).decode())


def build_questions(sdk, raw):
    out = {}
    for name, q in raw.items():
        q = dict(q)
        t = q.pop("type")
        out[name] = {"noul": sdk.Noul, "choice": sdk.Choice, "score": sdk.Score}[t](**q)
    return out


def call(sdk, client, method, path, body, extra=None):
    if method == "POST" and path == "/v1/systemone":
        r = client.system_one(body["state"], build_questions(sdk, body["questions"]), model=body.get("model"),
                              extra_headers=extra or None)
        return 200, {}, json.loads(r.model_dump_json(by_alias=True)) if hasattr(r, "model_dump_json") else r
    if method == "GET" and path == "/v1/models":
        r = client.models.list(extra_headers=extra or None)
        return 200, {}, json.loads(r.model_dump_json(by_alias=True))
    raise LookupError("outside the SDK surface")


def main(argv):
    method, url, cacert, tmo, body, headers = parse(argv)
    try:
        import typesafe_sdk as sdk
        import httpx2
    except ImportError as e:
        print("ERROR client not installed: %s" % e)
        return 2
    from urllib.parse import urlsplit
    u = urlsplit(url)
    base = "%s://%s" % (u.scheme, u.netloc)
    key = headers.get("authorization", "")
    key = key[7:] if key.lower().startswith("bearer ") else headers.get("x-api-key", "")
    retry = sdk.RetryPolicy(max_retries=0)
    # headers other than credentials/body framing (e.g. the reference server's scenario header) go through extra_headers
    extra = {k: v for k, v in headers.items() if k not in ("authorization", "x-api-key", "content-type", "content-length")}
    mechs = []
    if u.scheme == "https":
        def env_client():
            os.environ["SSL_CERT_FILE"] = cacert
            return sdk.TypeSafeClient(api_key=key, base_url=base, retry=retry, timeout=tmo)

        def hook_client():
            os.environ.pop("SSL_CERT_FILE", None)
            hc = httpx2.Client(verify=ssl.create_default_context(cafile=cacert), timeout=tmo)
            return sdk.TypeSafeClient(api_key=key, base_url=base, retry=retry, http_client=hc)
        mechs = [("env-SSL_CERT_FILE", env_client), ("http_client-ssl-context", hook_client)]
    else:
        mechs = [("plain-http", lambda: sdk.TypeSafeClient(api_key=key, base_url=base, retry=retry, timeout=tmo))]
    last = ""
    if u.scheme == "https":
        # CONTROL: with no CA configured the SDK must REFUSE the private certificate; otherwise a later
        # "trust ok" would not prove verification is on.
        os.environ.pop("SSL_CERT_FILE", None)
        try:
            call(sdk, sdk.TypeSafeClient(api_key=key, base_url=base, retry=retry, timeout=tmo), "GET", "/v1/models", None)
            print("TRUST control-no-ca UNEXPECTED-OK: certificate verification may be disabled")
        except Exception as e:  # noqa: BLE001
            full = ("%s %r %r" % (e, e.__cause__, e.__context__)).replace("\n", " ")
            if "CERTIFICATE_VERIFY_FAILED" in full or "certificate verify" in full.lower():
                print("TRUST control-no-ca refused-as-expected")
            else:
                print("TRUST control-no-ca UNEXPECTED-OK: failed for another reason: %s" % full[:160])
    for name, mk in mechs:
        try:
            client = mk()
            status, hdrs, payload = call(sdk, client, method, u.path, body, extra)
            print("TRUST %s ok" % name)
            emit(status, hdrs, payload)
            return 0
        except LookupError as e:
            print("ERROR %s" % e)
            return 0
        except sdk.TypeSafeAPIResponseValidationError as e:
            # the server answered, but with a body the SDK's response model rejects: not a success
            print("TRUST %s ok" % name)
            print("ERROR sdk response validation failed at %s: %s" % (getattr(e, "field_path", "?"), str(e).replace("\n", " ")[:200]))
            return 0
        except sdk.TypeSafeAPIError as e:
            print("TRUST %s ok" % name)
            hd = {k: v for k, v in dict(e.headers).items()}
            emit(e.status, hd, e.body if isinstance(e.body, (dict, list)) else (e.body or "").encode() if isinstance(e.body, str) else {})
            return 0
        except Exception as e:
            msg = ("%s: %s" % (type(e).__name__, e)).replace("\n", " ")
            cause = repr(getattr(e, "__cause__", None)) + repr(getattr(e, "__context__", None))
            full = (msg + " " + cause).replace("\n", " ")
            last = full[:300]
            if "CERTIFICATE_VERIFY_FAILED" in full or "certificate verify" in full.lower() or "SSL" in full:
                print("TRUST %s fail: %s" % (name, last))
                continue
            print("TRUST %s ok" % name)
            print("ERROR %s" % full[:400])
            return 0
    print("TRUST none fail: %s" % last)
    print("ERROR trust-configuration failure: no CA-trust mechanism worked")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
