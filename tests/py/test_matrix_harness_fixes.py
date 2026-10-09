"""Regression tests for the harness defects found by the LAN matrix run
(specs/009-jev-decision-models/evidence/matrix/lan-anton-to-nezha-2026-10-09/README.md):
 (1) node adapter truncated piped stdout at ~8 KiB, (2) no `model` was ever sent, (3) /v1/models + answer
 additive keys (maturity, experimental_types, limits extras) unknown to the validators, (4) the matrix's own
 unauthenticated negatives tripped the failed-auth burst limiter, (5) the resulting truncated base64 was
 reported only as 'body is not JSON'."""
import base64
import http.server
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import types
import unittest

from tests.matrix import cases as C
from tests.matrix import run as M

HERE = os.path.dirname(os.path.abspath(__file__))
NODE_CLIENT = os.environ.get("MATRIX_NODE_CLIENT") or os.path.join(os.path.dirname(HERE), "matrix", "clients", "node_https.mjs")  # override: mutation test


# ------------------------------------------------------------------ (1) node truncation
@unittest.skipUnless(shutil.which("node") and shutil.which("openssl"), "node/openssl not installed")
class NodePipedStdoutTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="mx-node-")
        self.crt, key = os.path.join(self.d, "c.pem"), os.path.join(self.d, "k.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", self.crt,
                        "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                       check=True, capture_output=True)
        self.payload = os.urandom(100 * 1024)
        payload = self.payload

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *a):
                pass

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(self.crt, key)
        self.srv.socket = ctx.wrap_socket(self.srv.socket, server_side=True)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        shutil.rmtree(self.d, ignore_errors=True)

    def test_100kb_body_through_a_pipe_is_complete(self):
        url = "https://localhost:%d/x" % self.srv.server_address[1]
        p = subprocess.run(["node", NODE_CLIENT, "GET", url, self.crt, "20", "-", "-"], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=60)  # stdout is a PIPE, as in run.py
        r = M.parse_lines(p.stdout.decode())
        self.assertIsNone(r.error, r.error)
        self.assertEqual(r.status, 200)
        self.assertEqual(len(r.body), len(self.payload))
        self.assertEqual(r.body, self.payload)
        self.assertEqual(p.returncode, 0)


# ------------------------------------------------------------------ (5) truncated base64
class TruncatedAdapterOutputTests(unittest.TestCase):
    def test_invalid_base64_is_named_not_reported_as_non_json(self):
        full = base64.b64encode(b'{"a": "' + b"x" * 9000 + b'"}').decode()
        r = M.parse_lines("STATUS 200\nHEADER content-type: application/json\nBODY_B64 %s\n" % full[:8190])
        st = C.step("GET", "/v1/models", kind="models", check=["json-ct"])
        problems = M.check_step(st, r)
        self.assertTrue(any("base64" in p for p in problems), problems)


# ------------------------------------------------------------------ (3) additive keys
def _entry(**kw):
    e = {"id": "decide-nli", "aliases": ["decide"], "protocol": "nli-onnx", "status": "ready",
         "limits": {"max_options": 20, "score_levels": [2, 10]}}
    e.update(kw)
    return e


def _models(entry):
    return {"object": "list", "data": [entry],
            "models": [{"name": "decide-nli", "description": "d", "release_date": "2026-10-07"}]}


MAT = {"noul": {"status": "measured", "lower_bound": 0.9, "baseline": 0.5, "n": 300},
       "choice": {"status": "experimental", "lower_bound": 0.4, "baseline": 0.5, "n": 120},
       "score": {"status": "unmeasured", "reason": "not yet measured"}}


class AdditiveKeyTests(unittest.TestCase):
    def test_models_entry_with_maturity_and_experimental_types(self):
        e = _entry(maturity=MAT, experimental_types=["choice", "score"], notes="n")
        self.assertEqual(C.validate_models(_models(e)), [])

    def test_models_entry_with_limit_extras(self):
        e = _entry(limits={"max_options": 20, "score_levels": [2, 10], "max_state_chars": 4000,
                           "max_context_tokens": 2048, "max_pairs": 64})
        self.assertEqual(C.validate_models(_models(e)), [])

    def test_malformed_additive_keys_are_still_rejected(self):
        bad = [_entry(maturity={"noul": {"status": "great"}}),
               _entry(maturity={"bogus": {"status": "measured"}}),
               _entry(maturity="measured"),
               _entry(experimental_types=["noul", 7]),
               _entry(experimental_types=["nonsense"]),
               _entry(limits={"max_options": 20, "score_levels": [2, 10], "max_state_chars": "big"}),
               _entry(surprise=1)]
        for e in bad:
            self.assertTrue(C.validate_models(_models(e)), e)

    def test_answer_maturity_label(self):
        req = {"questions": {"a": {"type": "noul"}}}
        body = {"model": "m", "usage": {"input_tokens": 1, "output_tokens": 2},
                "answers": {"a": {"type": "noul", "noul": 0.5, "maturity": "experimental"}}}
        self.assertEqual(C.validate_systemone(body, req), [])
        body["answers"]["a"]["maturity"] = "shiny"
        self.assertTrue(C.validate_systemone(body, req))
        body["answers"]["a"]["maturity"] = "experimental"
        body["answers"]["a"]["zzz"] = 1
        self.assertTrue(C.validate_systemone(body, req))

    def test_contract_documents_the_additive_keys(self):
        with open(os.path.join(M.ROOT, "specs", "009-jev-decision-models", "contracts", "openapi.yaml")) as f:
            txt = f.read()
        for tok in ("maturity:", "experimental_types:"):
            self.assertIn(tok, txt)


# ------------------------------------------------------------------ (2) model selection
class ModelTests(unittest.TestCase):
    def test_flag_exists_default_none(self):
        a = M.parser().parse_args([])
        self.assertIsNone(a.model)
        self.assertEqual(M.parser().parse_args(["--model", "decide-2b"]).model, "decide-2b")
        self.assertFalse(M.parser().parse_args([]).each_profile)

    def test_apply_model_injects_only_when_missing(self):
        st = C.ok_systemone(C.req())
        M.apply_model(st, "decide")
        self.assertEqual(json.loads(st["data"])["model"], "decide")
        self.assertEqual(st["request"]["model"], "decide")
        st2 = C.ok_systemone(C.req(model="jev-latest"))
        M.apply_model(st2, "decide")
        self.assertEqual(json.loads(st2["data"])["model"], "jev-latest")
        raw = C.err(400, "invalid_request", raw=b"this is {not json")
        M.apply_model(raw, "decide")
        self.assertEqual(raw["data"], b"this is {not json")
        get = C.step("GET", "/v1/models")
        M.apply_model(get, "decide")
        self.assertIsNone(get["data"])
        none = C.ok_systemone(C.req())
        before = none["data"]
        M.apply_model(none, None)
        self.assertEqual(none["data"], before)

    def test_pick_default_model(self):
        body = {"data": [{"id": "decide-nli", "aliases": []}, {"id": "decide-2b", "aliases": ["decide"]}]}
        self.assertEqual(M.pick_default_model(body), "decide")
        body = {"data": [{"id": "decide-nli", "aliases": []}, {"id": "decide-2b", "aliases": []}]}
        self.assertEqual(M.pick_default_model(body), "decide-nli")
        self.assertIsNone(M.pick_default_model({"data": []}))
        self.assertIsNone(M.pick_default_model("junk"))
        self.assertEqual(M.profile_ids({"data": [{"id": "a"}, {"id": "b"}]}), ["a", "b"])

    def test_exec_http_sends_the_model(self):
        env = FakeEnv([resp(200, {}, b"{}")], model="decide-2b")
        case = {"steps": [C.ok_systemone(C.req())]}
        cell = M.Cell()
        M.exec_http(env, "curl", "EP-001", case, cell)
        self.assertEqual(json.loads(env.sent[0][5])["model"], "decide-2b")


class ModelResolutionTests(unittest.TestCase):
    def test_resolve_model_from_the_gateway_listing(self):
        body = json.dumps({"data": [{"id": "decide-2b", "aliases": ["decide"]}]}).encode()
        env = FakeEnv([resp(200, {"content-type": "application/json"}, body)])
        a = M.parser().parse_args(["--base-url", "https://x:1", "--cacert", "c"])
        env.a.timeout = 5
        self.assertEqual(M.resolve_model(env, a), "GET /v1/models")
        self.assertEqual(env.model, "decide")

    def test_resolve_model_flag_wins_and_reference_server_sends_none(self):
        env = FakeEnv([])
        self.assertEqual(M.resolve_model(env, M.parser().parse_args(["--model", "m1"])), "flag")
        self.assertEqual(env.model, "m1")
        env2 = FakeEnv([])
        M.resolve_model(env2, M.parser().parse_args([]))
        self.assertIsNone(env2.model)

    def test_unlistable_gateway_sends_no_model_and_says_so(self):
        env = FakeEnv([resp(503, {}, b"{}")])
        a = M.parser().parse_args(["--base-url", "https://x:1", "--cacert", "c"])
        self.assertIn("no model sent", M.resolve_model(env, a))
        self.assertIsNone(env.model)

    def test_each_profile_runs_once_per_profile_in_its_own_dir(self):
        a = M.parser().parse_args(["--base-url", "https://x:1", "--cacert", "c", "--each-profile", "--run-dir", "/r"])
        seen = []
        rc = M.do_each_profile(a, run=lambda b: (seen.append((b.model, b.run_dir, b.each_profile)) or (1 if b.model == "b" else 0)),
                               fetch=lambda _a: ["a", "b"])
        self.assertEqual(seen, [("a", "/r/a", False), ("b", "/r/b", False)])
        self.assertEqual(rc, 1)

    def test_each_profile_needs_a_gateway(self):
        self.assertEqual(M.main(["--each-profile"]), 2)


# ------------------------------------------------------------------ (4) failed-auth limiter
def resp(status, headers, body):
    r = M.Resp()
    r.status, r.headers, r.body = status, headers, body
    return r


E401 = json.dumps({"message": "Unauthorized.", "error_type": "unauthorized"}).encode()
E429 = json.dumps({"message": "Too many failed authentications.", "error_type": "rate_limited"}).encode()
WWW = {"www-authenticate": 'Bearer realm="llmctl"'}


class FakeEnv:
    def __init__(self, responses, model=None, gap=0.0, max_wait=120.0):
        self.responses = list(responses)
        self.sent = []
        self.slept = []
        self.a = types.SimpleNamespace(timeout=5, scenario_hook=None, model=model, auth_neg_gap=gap,
                                       auth_throttle_max_wait=max_wait)
        self.base = "https://x:1"
        self.scenario_header = True
        self.model = model

    def sleep(self, s):
        self.slept.append(s)

    def invoke(self, client, method, url, auth, headers, data, tmo):
        self.sent.append((client, method, url, auth, headers, data))
        return self.responses.pop(0)


def neg_case():
    return {"steps": [C.err(401, "unauthorized", method="GET", path="/v1/models", auth="none", check=["www-authenticate"])]}


class AuthThrottleTests(unittest.TestCase):
    def run_cell(self, env, case=None):
        cell = M.Cell()
        M.exec_http(env, "curl", "EP-031", case or neg_case(), cell)
        return cell

    def test_429_then_reprobe_after_retry_after_passes_with_documented_class(self):
        env = FakeEnv([resp(429, {"retry-after": "3"}, E429), resp(401, WWW, E401)])
        cell = self.run_cell(env)
        self.assertEqual(cell.result, "pass", cell.reason)
        self.assertEqual(cell.reason_class, "auth_throttled")
        self.assertEqual(len(env.sent), 2)
        self.assertTrue(env.slept and env.slept[0] >= 3, env.slept)

    def test_429_that_persists_after_the_wait_fails(self):
        env = FakeEnv([resp(429, {"retry-after": "1"}, E429), resp(429, {"retry-after": "1"}, E429)])
        cell = self.run_cell(env)
        self.assertEqual(cell.result, "fail")

    def test_reprobe_must_still_be_the_right_answer(self):
        # after the wait the answer is a 200: the assertion stays meaningful (an auth hole is not hidden by the retry)
        env = FakeEnv([resp(429, {"retry-after": "1"}, E429), resp(200, {}, b"{}")])
        cell = self.run_cell(env)
        self.assertEqual(cell.result, "fail")
        self.assertIsNone(cell.reason_class)  # a wrong re-probe is never labelled auth_throttled

    def test_429_with_unusable_retry_after_or_over_the_cap_fails_without_waiting_forever(self):
        for hdr in ({}, {"retry-after": "abc"}, {"retry-after": "9999"}):
            env = FakeEnv([resp(429, hdr, E429)], max_wait=60)
            cell = self.run_cell(env)
            self.assertEqual(cell.result, "fail", hdr)
            self.assertFalse(env.slept and env.slept[0] > 60, env.slept)
            self.assertEqual(len(env.sent), 1)

    def test_authenticated_steps_are_never_retried(self):
        step = C.ok_systemone(C.req())
        env = FakeEnv([resp(429, {"retry-after": "1"}, E429)])
        cell = self.run_cell(env, {"steps": [step]})
        self.assertEqual(cell.result, "fail")
        self.assertEqual(len(env.sent), 1)
        self.assertEqual(env.slept, [])

    def test_no_throttle_no_class_no_sleep(self):
        env = FakeEnv([resp(401, WWW, E401)])
        cell = self.run_cell(env)
        self.assertEqual((cell.result, cell.reason_class, env.slept), ("pass", None, []))

    def test_spacing_between_failed_auth_steps(self):
        env = FakeEnv([resp(401, WWW, E401)], gap=0.25)
        self.run_cell(env)
        self.assertEqual(env.slept, [0.25])

    def test_a_pass_with_class_is_not_a_completeness_problem(self):
        cells = [{"case_id": "EP-001", "client": "curl", "vantage": "host", "result": "pass",
                  "reason_class": "auth_throttled", "reason": "r"}]
        self.assertEqual(M.check_completeness(["EP-001"], ["EP-001"], ["curl"], ["host"], cells, False), [])

    def test_phase_order_puts_failed_auth_negatives_late_and_burst_last(self):
        table = C.cases(C.Params())
        ids = sorted(table)
        phases = M.order_phases(ids, table)
        flat = [c for ph in phases for c in ph]
        self.assertEqual(sorted(flat), ids)
        self.assertEqual(phases[-1], ["EP-019"])
        for neg in ("EP-009", "EP-010", "EP-031", "EP-032", "EP-051", "EP-061"):
            self.assertIn(neg, phases[1], neg)
        for ok in ("EP-001", "EP-030", "EP-040", "EP-050"):
            self.assertIn(ok, phases[0], ok)


if __name__ == "__main__":
    unittest.main()
