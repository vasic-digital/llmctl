#!/usr/bin/env python3
"""Contract assertions for lib/onnx_server.py, driven by tests/test_onnx_runtime.sh.

argv[1] = JSON file {"ports": {name: port}, "key": str, "rec": {name: path}}.
Prints "  ok: msg" / "  FAIL: msg" lines (helpers.sh format) and exits 1 on any FAIL.
Talks to REAL servers over REAL sockets; only the onnxruntime/sentencepiece/
tokenizers backends are stubs (tests/fixtures/onnx_stubs).
"""
import http.client
import json
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor

CFG = json.load(open(sys.argv[1]))
PORTS, KEY, REC = CFG["ports"], CFG["key"], CFG["rec"]
FAILS = 0


def check(cond, msg):
    global FAILS
    if cond:
        print("  ok: %s" % msg)
    else:
        FAILS += 1
        print("  FAIL: %s" % msg, file=sys.stderr)


def req(name, method, path, body=None, auth=KEY, raw=None, headers=None, conn=None):
    c = conn or http.client.HTTPConnection("127.0.0.1", PORTS[name], timeout=15)
    h = dict(headers or {})
    if auth is not None:
        h["Authorization"] = "Bearer " + auth
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if data is not None:
        h.setdefault("Content-Type", "application/json")
    c.request(method, path, body=data, headers=h)
    r = c.getresponse()
    txt = r.read()
    try:
        js = json.loads(txt)
    except ValueError:
        js = None
    if conn is None:
        c.close()
    return r.status, js, txt, r


def pair(p, h):
    return {"pairs": [{"premise": p, "hypothesis": h}]}


def rows(path):
    return [json.loads(l) for l in open(path) if l.strip()]


# ---- health / readiness ---------------------------------------------------------
s, js, txt, _ = req("A", "GET", "/healthz", auth=None)
check(s == 200 and js == {"status": "ok"}, "/healthz: unauthenticated, body is exactly {\"status\":\"ok\"} (no profile name)")
s, js, txt, _ = req("A", "GET", "/readyz", auth=None)
check(s == 200 and js == {"status": "ready"}, "/readyz: ready after the load-time smoke ran a real stub inference")
s, js, txt, _ = req("A", "GET", "/health", auth=None)
check(s == 404, "legacy /health (profile-leaking, backend-less) no longer exists -> 404")
for n in ("I", "J"):
    s, js, txt, _ = req(n, "GET", "/readyz", auth=None)
    check(s == 503 and js == {"status": "not_ready"}, "/readyz: %s -> 503 not_ready when the load-time smoke inference fails" % n)
    s, js, _t, _ = req(n, "POST", "/v1/score", pair("a b", "c"))
    check(s == 503 and js["error"] == "not_ready", "/v1/score on a not-ready runtime -> 503 JSON, not a dropped connection")
    s, js, _t, _ = req(n, "GET", "/healthz", auth=None)
    check(s == 200, "/healthz stays 200 (liveness) while not_ready")

# ---- auth -----------------------------------------------------------------------
body = pair("The invoice was paid.", "The invoice was paid.")
s, js, _t, r = req("A", "POST", "/v1/score", body, auth=None)
check(s == 401 and js["error"] == "unauthorized", "auth: no Bearer -> 401 JSON")
check(r.getheader("Connection") == "close", "auth: 401 on an unread body closes the connection (no mis-parsed leftover, N-12)")
s, js, _t, _ = req("A", "POST", "/v1/score", body, auth="wrong")
check(s == 401, "auth: wrong Bearer -> 401")
s, js, _t, _ = req("A", "POST", "/v1/score", body, auth="envkey-from-environment")
check(s == 401, "auth: LLMCTL_DECIDE_API_KEY in the environment is NOT accepted as the key")
s, js, _t, _ = req("A", "POST", "/v1/score", body, headers={"Authorization": "Basic abc"}, auth=None)
check(s == 401, "auth: non-Bearer scheme -> 401")
s, js, _t, _ = req("A", "POST", "/v1/score", body)
check(s == 200, "auth: correct Bearer -> 200")

# ---- score semantics + label order ------------------------------------------------
two = {"pairs": [{"premise": "The invoice was paid on Monday.", "hypothesis": "The invoice was paid"},
                 {"premise": "The invoice was paid on Monday.", "hypothesis": "The invoice was not paid"}]}
for name, order in (("A", ["entailment", "neutral", "contradiction"]),
                    ("B", ["contradiction", "neutral", "entailment"])):
    s, js, _t, _ = req(name, "POST", "/v1/score", two)
    ok = s == 200 and js["labels"] == order
    check(ok, "%s: labels follow the pinned config.json id2label order %s" % (name, order))
    if ok:
        e, c = order.index("entailment"), order.index("contradiction")
        check(js["scores"][0][e] > 0.8 and js["scores"][1][c] > 0.9,
              "%s: scores columns line up with labels (pair0 entails, pair1 contradicts)" % name)
        check(all(abs(sum(row) - 1.0) < 1e-12 for row in js["scores"]), "%s: each score row is a float64 softmax summing to 1" % name)
        check(js["truncated"] == [False, False], "%s: truncated flags present and false for short pairs" % name)
        check(js["model"] == "llmctl-toy-onnx" and js["max_tokens"] == 512, "%s: model name + default max_tokens=512" % name)
        check(js["label_source"].startswith("config:"), "%s: label_source says the order came from config.json (%s)" % (name, js["label_source"]))
s, js, _t, _ = req("C", "POST", "/v1/score", two)
check(s == 200 and js["labels"] == ["entailment", "neutral", "contradiction"] and js["label_source"] == "config:onnx/config.json",
      "C: onnx/config.json BESIDE onnx/model.onnx beats the root config.json (N-21 precedence): %s" % (js and js.get("label_source")))
s, js, _t, _ = req("D", "POST", "/v1/score", two)
check(s == 200 and js["labels"] == ["LABEL_0", "LABEL_1", "LABEL_2"] and js["label_source"].startswith("generic-config"),
      "D: LABEL_n id2label is served but FLAGGED in label_source: %s" % (js and js.get("label_source")))
s, js, _t, _ = req("E", "POST", "/v1/score", two)
check(s == 200 and js["labels"] == ["LABEL_0", "LABEL_1", "LABEL_2"] and js["label_source"].startswith("none"),
      "E: no config.json -> explicit LABEL_n fallback flagged 'none': %s" % (js and js.get("label_source")))

# ---- inputs fed to the graph --------------------------------------------------------
req("A", "POST", "/v1/score", body)
r_a = rows(REC["A"])
check(all(set(r) == {"input_ids", "attention_mask"} for r in r_a),
      "A: graph declaring 2 inputs is fed exactly input_ids+attention_mask (token_type_ids not forced, D-17b)")
req("F", "POST", "/v1/score", body)
r_f = rows(REC["F"])
check(all(set(r) == {"input_ids", "attention_mask", "token_type_ids"} for r in r_f),
      "F: graph declaring token_type_ids is fed it too (BYO export served, D-17b)")

# ---- premise-only truncation ----------------------------------------------------------
long_p = " ".join("w%d" % i for i in range(60))
before = len(rows(REC["F"]))
s, js, _t, _ = req("F", "POST", "/v1/score", pair(long_p, "the claim is not true"))
check(s == 200 and js["truncated"] == [True] and js["max_tokens"] == 16, "F: long premise -> truncated=[true], max_tokens=16")
last = rows(REC["F"])[before:][-1]
ids = last["input_ids"][0]
check(len(ids) <= 16, "F: sequence fed to the model is capped at max_tokens (%d <= 16)" % len(ids))
check(ids[0] == 1 and ids[-1] == 2 and ids.count(2) == 2, "F: [CLS] ... [SEP] hyp [SEP] special tokens survive truncation")
check(7 in ids[ids.index(2) + 1:] and len(ids) - ids.index(2) - 2 == 5,
      "F: all 5 HYPOTHESIS tokens (incl. its 'not' token) survive intact after the premise was cut")
check(js["scores"][0][2] > 0.9, "F: the model saw the surviving hypothesis -> contradiction wins (hypothesis never truncated, D-01)")
s, js, _t, _ = req("F", "POST", "/v1/score", {"pairs": [
    {"premise": "short premise", "hypothesis": "ok"},
    {"premise": long_p, "hypothesis": "ok"}]})
check(s == 200 and js["truncated"] == [False, True], "F: truncated is reported PER PAIR")
s, js, _t, _ = req("F", "POST", "/v1/score", pair("p", " ".join("h%d" % i for i in range(30))))
check(s == 422 and js["error"] == "hypothesis_too_long", "F: hypothesis alone over max_tokens -> 422 JSON (hypothesis is never shortened)")
s, js, _t, _ = req("G", "POST", "/v1/score", pair(long_p, "the claim is not true"))
check(s == 200 and js["truncated"] == [True] and js["scores"][0][2] > 0.9,
      "G: tokenizer.json path truncates ONLY the premise (only_first) and reports it")
s, js, _t, _ = req("G", "POST", "/v1/score", pair("p", " ".join("h%d" % i for i in range(30))))
check(s == 422, "G: tokenizer.json path: hypothesis too long -> 422")

# ---- ctx / max_tokens -----------------------------------------------------------------
s, js, _t, _ = req("L", "POST", "/v1/score", body)
check(s == 200 and js["max_tokens"] == 24, "L: LLMCTL_CTX_<PROFILE>=24 honoured as max_tokens (N-20)")

# ---- runtime failures are HTTP errors, never dropped connections --------------------
s, js, txt, _ = req("H", "GET", "/readyz", auth=None)
check(s == 200, "H: model healthy at load (smoke passed) before it starts failing")
s, js, txt, _ = req("H", "POST", "/v1/score", body)
check(s == 500 and js["error"] == "non_finite_logits" and b"NaN" not in txt, "H: NaN logits -> 500 JSON error, NaN never serialised (N-24)")
s, js, txt, _ = req("K2", "POST", "/v1/score", body)
check(s == 500 and js["error"] == "label_count_mismatch", "K2: logits count != id2label count -> 500 JSON (D-07, no SystemExit)")
s, js, txt, _ = req("R", "POST", "/v1/score", body)
check(s == 500 and js["error"] == "inference_failed", "R: backend exception -> 500 JSON (N-24)")
s, js, txt, _ = req("R", "POST", "/v1/score", body)
check(s == 500, "R: the server survives and answers the next request too")

# ---- request validation ---------------------------------------------------------------
for label, raw in (("JSON array", b"[1,2,3]"), ("JSON string", b'"just a string"'), ("not JSON", b"{oops"),
                   ("null", b"null"), ("number", b"7")):
    s, js, _t, _ = req("A", "POST", "/v1/score", raw=raw)
    check(s == 400 and js["error"] == "bad_request", "400: body is %s (D-08)" % label)
for label, b in (("pairs missing", {}), ("pairs empty", {"pairs": []}), ("pairs not a list", {"pairs": "x"}),
                 ("pair not an object", {"pairs": ["x"]}),
                 ("premise missing", {"pairs": [{"hypothesis": "h"}]}),
                 ("hypothesis empty", {"pairs": [{"premise": "p", "hypothesis": ""}]}),
                 ("premise not a string", {"pairs": [{"premise": 5, "hypothesis": "h"}]})):
    s, js, _t, _ = req("A", "POST", "/v1/score", b)
    check(s == 400 and js["error"] == "bad_request", "400: %s" % label)
s, js, _t, _ = req("A", "POST", "/v1/nope", {"pairs": []})
check(s == 404, "unknown POST path -> 404 JSON")
s, js, _t, _ = req("A", "PUT", "/v1/score", body)
check(s == 405 and js is not None, "unsupported method -> 405 JSON (not an HTML page)")

# ---- limits (env-configured: MAX_PAIRS=3, MAX_BODY=2048) --------------------------------
s, js, _t, _ = req("K", "POST", "/v1/score", {"pairs": [{"premise": "p", "hypothesis": "h"}] * 4})
check(s == 413 and js["error"] == "too_many_pairs", "K: more pairs than LLMCTL_ONNX_MAX_PAIRS -> 413")
s, js, _t, _ = req("K", "POST", "/v1/score", {"pairs": [{"premise": "p", "hypothesis": "h"}] * 3})
check(s == 200 and len(js["scores"]) == 3, "K: exactly MAX_PAIRS pairs -> 200 (boundary)")
big = json.dumps(pair("x " * 4000, "h")).encode()
s, js, _t, r = req("K", "POST", "/v1/score", raw=big)
check(s == 413 and js["error"] == "body_too_large", "K: body over the cap -> 413 BEFORE the body is read")
check(r.getheader("Connection") == "close", "K: oversized-body rejection closes the connection")
c = http.client.HTTPConnection("127.0.0.1", PORTS["K"], timeout=10)
c.putrequest("POST", "/v1/score")
c.putheader("Authorization", "Bearer " + KEY)
c.putheader("Transfer-Encoding", "chunked")
c.endheaders()
r = c.getresponse()
check(r.status == 411, "K: chunked / no Content-Length -> 411 JSON")
c.close()

# ---- HTTP/1.1 keep-alive stays correct after an error ------------------------------------
c = http.client.HTTPConnection("127.0.0.1", PORTS["A"], timeout=10)
s1, js1, _t, r1 = req("A", "POST", "/v1/score", raw=b"{oops", conn=c)
sock1 = c.sock
s2, js2, _t, r2 = req("A", "POST", "/v1/score", body, conn=c)
check(s1 == 400 and s2 == 200 and c.sock is sock1 and r1.getheader("Connection") != "close",
      "keep-alive: a 400 on a fully-read body keeps the connection and the next request parses cleanly (N-12)")
c.close()

# ---- slow / half-sent client is cut off by the socket timeout ------------------------------
t0 = time.time()
sk = socket.create_connection(("127.0.0.1", PORTS["K"]), 5)
sk.sendall(b"POST /v1/score HTTP/1.1\r\nHost: x\r\nContent-Length: 200\r\n")
sk.settimeout(6)
try:
    data = sk.recv(10)
    closed = data == b"" or data.startswith(b"HTTP/")
except socket.timeout:
    closed = False
except OSError:
    closed = True
sk.close()
check(closed and time.time() - t0 < 6, "half-sent headers: connection is closed by the socket timeout (%.1fs, D-09)" % (time.time() - t0))

# ---- threaded: concurrent requests all succeed ----------------------------------------------
with ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda _i: req("A", "POST", "/v1/score", two)[0], range(16)))
check(res == [200] * 16, "16 concurrent requests over 8 threads -> all 200")

sys.exit(1 if FAILS else 0)
