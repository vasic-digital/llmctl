"""Unit tests for scripts/golden/run_golden.py against an in-process HTTPS stand-in.

The stand-in is a stdlib ThreadingHTTPServer wrapped in TLS with a throw-away certificate
made by the openssl CLI in a temp dir. It is a stand-in (evidence class stand-in) and proves
the runner's request building and result handling only - never model behaviour.
"""
import contextlib
import io
import json
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from scripts.golden import run_golden, stats
from tests.evidence import manifest, writer

KEY = "gk-test-key-7731-not-a-real-secret"


def make_cert(d):
    crt, key = os.path.join(d, "ca.pem"), os.path.join(d, "key.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt,
                    "-days", "2", "-subj", "/CN=localhost",
                    "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return crt, key


class StandIn:
    """Positional stand-in: noul true iff the state mentions 'rm -rf'; choice = FIRST listed option
    (so permuting the options flips it); score = level 1. Behaviour switches for fault tests."""

    def __init__(self, crt, key):
        self.seen = []            # (path, auth header, body dict)
        self.fail_first = 0       # answer 503 this many times before behaving
        self.always_status = None
        self.always_body = {"error": "x"}   # JSON body of the always_status answer (dict, or raw bytes)
        self.always_headers = {}  # extra headers of the always_status answer
        self.bad_shape = False
        self.refuse_over = None   # choice items with more options than this get the gateway's 422 validation_failed
        self.calibrated = False   # answer like a gateway applying a calibration profile (FR-080)
        self.lock = threading.Lock()
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                n = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(n) or b"{}")
                with outer.lock:
                    outer.seen.append((self.path, self.headers.get("Authorization"), body))
                    count = len(outer.seen)
                if self.headers.get("Authorization") != "Bearer " + KEY:
                    return self._send(401, {"error": "unauthorized"})
                if outer.always_status:
                    return self._send(outer.always_status, outer.always_body,
                                      dict({"Retry-After": "0"}, **outer.always_headers))
                if count <= outer.fail_first:
                    return self._send(503, {"error": "not ready"}, {"Retry-After": "0"})
                q = body["questions"]["q"]
                t = q["type"]
                if outer.refuse_over and t == "choice" and len(q["criteria"]) > outer.refuse_over:
                    return self._send(422, {"message": "Request failed validation.", "error_type": "validation_failed"})
                if outer.bad_shape:
                    ans = {"type": t}
                elif t == "noul":
                    p = 0.97 if "rm -rf" in body["state"] else 0.03
                    ans = {"type": "noul", "noul": p}
                elif t == "choice":
                    ks = list(q["criteria"].keys())
                    probs = {k: 0.1 / max(1, len(ks) - 1) for k in ks}
                    probs[ks[0]] = 0.9
                    ans = {"type": "choice", "choice": ks[0], "probabilities": probs, "confidence": 0.8}
                    if outer.calibrated:   # calibrated confidence is flattering; the raw readout is untouched
                        ans.update(confidence=0.95, confidence_raw=0.8,
                                   calibration={"method": "temperature", "n": 240, "profile_id": "stand-in"})
                else:
                    n_lv = len(q["criteria"])
                    lvl = min(1, n_lv - 1)
                    probs = {str(i): 0.0 for i in range(n_lv)}
                    probs[str(lvl)] = 1.0
                    ans = {"type": "score", "score": float(lvl), "legend": {str(i): None for i in range(n_lv)},
                           "probabilities": probs, "confidence": 1.0}
                self._send(200, {"model": "stand-in", "answers": {"q": ans}, "usage": {"input_tokens": 1, "output_tokens": 1}},
                           {"x-llmctl-request-id": "req-%04d" % count})

            def _send(self, code, obj, hdrs=None):
                raw = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                for k, v in (hdrs or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(raw)

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        self.srv.socket = ctx.wrap_socket(self.srv.socket, server_side=True)
        self.url = "https://127.0.0.1:%d" % self.srv.server_address[1]
        self.t = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.t.start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


def _jload(path):
    with open(path) as f:
        return json.load(f)


def _jlines(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def have_openssl():
    return shutil.which("openssl") is not None


@unittest.skipUnless(have_openssl(), "openssl CLI not available")
class RunnerE2ETests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="golden-runner-")
        cls.crt, cls.key = make_cert(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.srv = StandIn(self.crt, self.key)
        self.out = tempfile.mkdtemp(prefix="golden-out-", dir=self.tmp)
        self.addCleanup(self.srv.close)

    def run_main(self, extra, key=KEY):
        env = dict(os.environ)
        env["GOLDEN_TEST_KEY"] = key
        argv = ["--base-url", self.srv.url, "--cacert", self.crt, "--key-env", "GOLDEN_TEST_KEY",
                "--profile", "stand-in", "--out-dir", self.out, "--run-id", "t1", "--evidence-class", "stand-in",
                "--retry-sleep", "0"] + extra
        out, err = io.StringIO(), io.StringIO()
        old = os.environ.get("GOLDEN_TEST_KEY")
        os.environ["GOLDEN_TEST_KEY"] = key
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = run_golden.main(argv)
        finally:
            if old is None:
                os.environ.pop("GOLDEN_TEST_KEY", None)
            else:
                os.environ["GOLDEN_TEST_KEY"] = old
        return rc, out.getvalue(), err.getvalue()

    def all_output_bytes(self):
        blobs = []
        for root, _, files in os.walk(self.out):
            for f in files:
                with open(os.path.join(root, f), "rb") as fh:
                    blobs.append(fh.read())
        return b"\n".join(blobs)

    # oracle: CHARACTERIZATION (pins the runner's request shape and counts against the in-file stand-in; 132 and 0.85 are hand-counted from the fixture questions; proves runner plumbing, not model behaviour)
    def test_end_to_end_all_types(self):
        rc, out, err = self.run_main(["--limit", "200", "--types", "noul,choice,score", "--set", "questions"])
        self.assertEqual(rc, 0, err)
        self.assertEqual(len(self.srv.seen), 132)
        # request shape: one question named q, bearer auth, model passed through
        path, auth, body = self.srv.seen[0]
        self.assertEqual(path, "/v1/systemone")
        self.assertEqual(auth, "Bearer " + KEY)
        self.assertEqual(sorted(body), ["model", "questions", "state"])
        self.assertEqual(list(body["questions"]), ["q"])
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertEqual(res["report"]["well_formed"]["ok"], 132)
        # stand-in says true only for 'rm -rf' states: dangerous_command true items with rm -rf
        by_id = {r["id"]: r for r in res["records"]}
        self.assertTrue(by_id["N-001"]["predicted"])     # rm -rf / --no-preserve-root
        self.assertFalse(by_id["N-008"]["predicted"])    # ls -la
        self.assertEqual(by_id["N-001"]["request_id"].startswith("req-"), True)
        # the stand-in always says false for noul except rm -rf: majority baseline for is_urgent is 0.85, accuracy 0.85
        fam = res["report"]["per_family"]["is_urgent"]
        self.assertAlmostEqual(fam["accuracy"], 0.85)
        self.assertFalse(fam["lower_bound_exceeds_majority"])

    # oracle: CHARACTERIZATION (pins the runner's own record design (p_pred stays the raw winner probability); pins the runner's own design against the in-file stand-in gateway, whose behaviour is defined in this test file (class stand-in); no external spec states this)
    def test_records_keep_raw_and_served_confidence_and_p_pred_stays_raw(self):
        rc, _, err = self.run_main(["--limit", "200", "--types", "choice", "--set", "questions"])
        self.assertEqual(rc, 0, err)
        r = _jload(os.path.join(self.out, "results.json"))["records"][0]
        self.assertEqual((r["confidence"], r["confidence_raw"], r["calibration"]), (0.8, None, None))
        self.srv.calibrated = True
        self.out = tempfile.mkdtemp(prefix="golden-out-", dir=self.tmp)
        rc, _, err = self.run_main(["--limit", "200", "--types", "choice", "--set", "questions"])
        self.assertEqual(rc, 0, err)
        r = _jload(os.path.join(self.out, "results.json"))["records"][0]
        self.assertEqual(r["confidence"], 0.95)
        self.assertEqual(r["confidence_raw"], 0.8)
        self.assertEqual(r["calibration"], {"method": "temperature", "n": 240, "profile_id": "stand-in"})
        # p_pred is the winner's own (raw) probability: a calibrated gateway cannot move it
        self.assertAlmostEqual(r["p_pred"], 0.9)

    # oracle: CHARACTERIZATION (pins answer_confidence() tolerance of hostile shapes as the runner designs it; no spec text)
    def test_answer_confidence_is_defensive(self):
        f = run_golden.answer_confidence
        cal = {"method": "platt", "n": 300, "profile_id": "p"}
        good = {"answers": {"q": {"confidence": 0.9, "confidence_raw": 0.4, "calibration": cal}}}
        self.assertEqual(f(good), (0.9, 0.4, cal))
        self.assertEqual(f({"answers": {"q": {"confidence": 0.9, "calibration": "mixed"}}}), (0.9, None, "mixed"))
        self.assertEqual(f({"answers": {"q": {"confidence": 0.9}}}), (0.9, None, None))
        for bad in ({}, {"answers": {}}, {"answers": {"q": 3}},
                    {"answers": {"q": {"confidence": True, "confidence_raw": 7, "calibration": 5}}},
                    {"answers": {"q": {"confidence": float("nan"), "confidence_raw": "x", "calibration": []}}}):
            self.assertEqual(f(bad), (None, None, None))

    # oracle: INVARIANT (the access key and state text never appear in any output file or log; chain and manifest verifiers are sibling code in tests/evidence, not an independent implementation)
    def test_evidence_chain_manifest_and_no_leaks(self):
        rc, out, err = self.run_main(["--limit", "10"])
        self.assertEqual(rc, 0, err)
        self.assertEqual(writer.verify_chain(os.path.join(self.out, "evidence.jsonl")), [])
        self.assertTrue(manifest.verify(self.out)["ok"])
        blob = self.all_output_bytes()
        self.assertNotIn(KEY.encode(), blob)
        # logs carry ids only, never state text
        self.assertNotIn("rm -rf", out + err)
        self.assertNotIn("git status", out + err)
        recs = _jlines(os.path.join(self.out, "evidence.jsonl"))
        self.assertTrue(all(r["class"] in ("stand-in", "not-exercised") for r in recs))
        # stand-in evidence is excluded from real-behaviour summaries
        self.assertEqual(writer.summarize(os.path.join(self.out, "evidence.jsonl"))["real_pass"], 0)

    # oracle: CHARACTERIZATION (flip count is computed with run_golden.permuted_keys, the code under test's own helper, so only the 41-group count and wire order are independent; FR-080 flip probe (specs/009-jev-decision-models/spec.md:305))
    def test_permute_groups_detects_position_bias(self):
        rc, out, err = self.run_main(["--types", "choice", "--permute-groups"])
        self.assertEqual(rc, 0, err)
        res = _jload(os.path.join(self.out, "results.json"))
        fl = res["report"]["flip"]
        self.assertEqual(fl["groups"], 41)
        # a stand-in that always picks the first LISTED option flips exactly when the first listed
        # option differs between the original and the permuted order (computed independently here)
        choices = [i for i in run_golden.load_items(["questions"]) if i["type"] == "choice"]
        expect = sum(1 for c in choices
                     if run_golden.permuted_keys(c, "20261007")[0] != list(c["criteria"])[0])
        self.assertGreater(expect, 0)
        self.assertEqual(fl["flipped"], expect)
        self.assertAlmostEqual(fl["flip_rate"], expect / 41.0)
        orig = [r for r in res["records"] if r["variant"] == "orig"]
        perm = [r for r in res["records"] if r["variant"] == "perm"]
        self.assertEqual((len(orig), len(perm)), (41, 41))
        # the permuted requests really carry the permuted order on the wire
        wire = [b["questions"]["q"]["criteria"] for _, _, b in self.srv.seen]
        want = [{k: c["criteria"][k] for k in run_golden.permuted_keys(c, "20261007")} for c in choices]
        for w in want:
            self.assertIn(list(w), [list(x) for x in wire])

    # oracle: CHARACTERIZATION (pins the runner's bounded retry design (attempt counts) against the stand-in; pins the runner's own design against the in-file stand-in gateway, whose behaviour is defined in this test file (class stand-in); no external spec states this)
    def test_retry_is_bounded_and_recovers(self):
        self.srv.fail_first = 1
        rc, out, err = self.run_main(["--limit", "1", "--types", "noul", "--retries", "2"])
        self.assertEqual(rc, 0, err)
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertEqual(res["records"][0]["attempts"], 2)
        self.assertTrue(res["records"][0]["well_formed"])

    # oracle: CHARACTERIZATION (pins 1 attempt + N retries and the fail record as the runner designs them; pins the runner's own design against the in-file stand-in gateway, whose behaviour is defined in this test file (class stand-in); no external spec states this)
    def test_retry_gives_up_after_bound(self):
        self.srv.always_status = 503
        rc, out, err = self.run_main(["--limit", "1", "--types", "noul", "--retries", "2"])
        self.assertEqual(rc, 1)       # malformed result -> non-zero
        self.assertEqual(len(self.srv.seen), 3)   # 1 attempt + 2 retries, no more
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertFalse(res["records"][0]["well_formed"])
        recs = _jlines(os.path.join(self.out, "evidence.jsonl"))
        self.assertEqual(recs[0]["result"], "fail")
        self.assertIn("0 of 1", recs[0]["reason"])

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:28 (502 deadline_exceeded signalled by x-llmctl-decide-reason; internal/server/handlers.go:284-286 says a client must not retry it))
    def test_gateway_deadline_502_is_not_retried(self):
        # a 502 the gateway marks deadline_exceeded means a slow-but-alive engine: a retry would cancel
        # the engine task and redo the whole prefill (guaranteed waste), so it is recorded, not retried
        self.srv.always_status = 502
        self.srv.always_headers = {"x-llmctl-decide-reason": "deadline_exceeded", "x-llmctl-decide-deadline-ms": "8000"}
        rc, out, err = self.run_main(["--limit", "1", "--types", "noul", "--retries", "2"])
        self.assertEqual(rc, 1)
        self.assertEqual(len(self.srv.seen), 1)
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertEqual(res["records"][0]["attempts"], 1)
        self.assertEqual(res["records"][0]["status"], 502)

    # oracle: SPECIFIED (RFC 9110 section 5.1: HTTP field names are case-insensitive; header name per specs/009-jev-decision-models/contracts/openapi.yaml:28)
    def test_gateway_deadline_502_header_name_is_case_insensitive(self):
        # HTTP header names are case-insensitive: a canonical-case or mixed-case name must be recognised
        for name in ("X-Llmctl-Decide-Reason", "X-LLMCTL-decide-REASON"):
            with self.subTest(header=name):
                self.srv.seen.clear()
                self.srv.always_status = 502
                self.srv.always_headers = {name: "deadline_exceeded"}
                rc, out, err = self.run_main(["--limit", "1", "--types", "noul", "--retries", "2"])
                self.assertEqual(rc, 1)
                self.assertEqual(len(self.srv.seen), 1, "deadline_exceeded must not be retried (header %s)" % name)
                res = _jload(os.path.join(self.out, "results.json"))
                self.assertEqual(res["records"][0]["attempts"], 1)
                self.assertEqual(res["records"][0]["reason"], "deadline_exceeded")

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:28 (502 retryable; gateway-internal 502 paths set no reason header))
    def test_gateway_502_without_reason_header_is_still_retried(self):
        self.srv.always_status = 502
        self.srv.always_headers = {}
        rc, out, err = self.run_main(["--limit", "1", "--types", "noul", "--retries", "2"])
        self.assertEqual(rc, 1)
        self.assertEqual(len(self.srv.seen), 3)
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertEqual(res["records"][0]["attempts"], 3)
        self.assertIsNone(res["records"][0]["reason"])

    # oracle: CHARACTERIZATION (record fields status/reason are the runner's own schema; header name and value per specs/009-jev-decision-models/contracts/openapi.yaml:28 only)
    def test_gateway_reason_is_persisted_in_record_and_raw_log(self):
        self.srv.always_status = 502
        self.srv.always_headers = {"x-llmctl-decide-reason": "engine_error"}
        rc, out, err = self.run_main(["--limit", "1", "--types", "noul", "--retries", "0"])
        self.assertEqual(rc, 1)
        res = _jload(os.path.join(self.out, "results.json"))
        rec = res["records"][0]
        self.assertEqual((rec["status"], rec["reason"]), (502, "engine_error"))
        self.assertIn("error", rec)  # existing consumers keep their field
        # a 200 carries no reason
        self.srv.always_status = None
        rc, out, err = self.run_main(["--limit", "1", "--types", "noul"])
        self.assertEqual(rc, 0, err)
        self.assertIsNone(_jload(os.path.join(self.out, "results.json"))["records"][0]["reason"])

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:28 (502 retryable; any other backend 502 carries engine_error))
    def test_gateway_engine_error_502_is_still_retried(self):
        self.srv.always_status = 502
        self.srv.always_headers = {"x-llmctl-decide-reason": "engine_error"}
        rc, out, err = self.run_main(["--limit", "1", "--types", "noul", "--retries", "2"])
        self.assertEqual(rc, 1)
        self.assertEqual(len(self.srv.seen), 3)

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:21 (401 not retryable); key-not-in-output is the runner's secret-handling design)
    def test_wrong_key_is_recorded_not_leaked(self):
        rc, out, err = self.run_main(["--limit", "2", "--types", "noul"], key="gk-wrong-key-0000-not-real-2")
        self.assertEqual(rc, 1)
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertEqual(res["records"][0]["status"], 401)
        self.assertEqual(len(self.srv.seen), 2)   # 401 is not retried
        self.assertNotIn(b"gk-wrong-key-0000-not-real-2", self.all_output_bytes())

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:286-340 (answer schemas: a typed answer lacking its value is malformed))
    def test_malformed_answer_shape_fails_not_passes(self):
        self.srv.bad_shape = True
        rc, out, err = self.run_main(["--limit", "3", "--types", "noul,choice,score"])
        self.assertEqual(rc, 1)
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertEqual(res["report"]["well_formed"]["ok"], 0)

    # oracle: CHARACTERIZATION (pins the runner's CLI key-source behaviour and exit code 2 as designed; no spec text)
    def test_key_file_and_missing_key(self):
        kf = os.path.join(self.tmp, "key.txt")
        with open(kf, "w") as f:
            f.write(KEY + "\n")
        os.chmod(kf, 0o600)
        argv = ["--base-url", self.srv.url, "--cacert", self.crt, "--key-file", kf, "--profile", "p",
                "--out-dir", self.out, "--run-id", "t2", "--evidence-class", "stand-in", "--limit", "1", "--types", "noul"]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(run_golden.main(argv), 0)
        os.environ.pop("GOLDEN_NO_SUCH_KEY", None)
        errs = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(errs):
            rc = run_golden.main(["--base-url", self.srv.url, "--profile", "p", "--key-env", "GOLDEN_NO_SUCH_KEY",
                                  "--out-dir", self.out])
        self.assertEqual(rc, 2)
        self.assertIn("no access key", errs.getvalue())

    # oracle: CHARACTERIZATION (23 probes and 3 pairs are hand-counted from the probes fixture; pins the runner's report shape)
    def test_probes_set_runs_and_pairs_are_reported(self):
        rc, out, err = self.run_main(["--set", "probes"])
        self.assertEqual(rc, 0, err)
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertEqual(res["report"]["well_formed"]["n"], 23)
        self.assertEqual(res["report"]["pair_consistency"]["pairs"], 3)


    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:25 (422 validation_failed for a limit violation) plus internal/contract/request.go:110 (options above MaxOptions rejected); the refused record shape is the runner's design)
    def test_refusal_recorded_when_over_profile_limit(self):
        """G-160: 422 validation_failed on a choice item with more options than --max-options."""
        self.srv.always_status = 422
        self.srv.always_body = (b'{"message":"Request failed validation.","error_type":"validation_failed"}')
        rc, out, _ = self.run_main(["--types", "choice", "--limit", "3", "--max-options", "1"])
        res = _jload(os.path.join(self.out, "results.json"))
        for r in res["records"]:
            self.assertTrue(r["refused"])
            self.assertEqual(r["refusal_reason"], "max_options")
            self.assertFalse(r["well_formed"])
        self.assertEqual(res["report"]["refused"]["n"], 3)
        self.assertEqual(res["report"]["well_formed"]["n"], 0)
        self.assertIn("REFUSED(max_options)", out)

    # oracle: CHARACTERIZATION (pins that a 422 is not called a refusal unless --max-options is given (the runner's G-160 design))
    def test_422_without_max_options_flag_stays_malformed(self):
        self.srv.always_status = 422
        self.srv.always_body = (b'{"message":"Request failed validation.","error_type":"validation_failed"}')
        self.run_main(["--types", "choice", "--limit", "2"])
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertFalse(any(r.get("refused") for r in res["records"]))
        self.assertEqual(res["report"]["well_formed"]["n"], 2)

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:25 (422 also covers deterministic readout_failure, which is not a limit refusal))
    def test_readout_failed_422_stays_malformed_e2e(self):
        self.srv.always_status = 422
        self.srv.always_body = RefusalClassifyTests.RF
        self.run_main(["--types", "choice", "--limit", "2", "--max-options", "1"])
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertFalse(any(r.get("refused") for r in res["records"]))


    # oracle: DERIVED (hand-worked: 5 items with 12 options and 4 with 20 give 9 items over 8; specs/009-jev-decision-models/spec.md:384 (SC-003) denominators)
    def test_refused_items_do_not_fail_the_run_and_sc003_pass_row_explains(self):
        """IMPORTANT-1: refused items shrink the denominator; run exits 0, SC-003 passes WITH a reason."""
        self.srv.refuse_over = 8
        rc, out, err = self.run_main(["--types", "choice", "--limit", "100", "--max-options", "8"])
        self.assertEqual(rc, 0, err)
        res = _jload(os.path.join(self.out, "results.json"))
        nref = res["report"]["refused"]["n"]
        self.assertEqual(nref, 9)           # 5 x 12 + 4 x 20 options -> 9 items over 8
        self.assertEqual(res["report"]["well_formed"]["ok"], res["report"]["well_formed"]["n"])
        rows = _jlines(os.path.join(self.out, "evidence.jsonl")) if os.path.exists(os.path.join(self.out, "evidence.jsonl")) else None
        if rows is None:
            rows = [json.loads(l) for root, _, fs in os.walk(self.out) for f in fs if f.endswith(".jsonl")
                    and "responses" not in f for l in open(os.path.join(root, f)) if l.strip()]
        sc3 = [r for r in rows if r.get("requirement") == ["SC-003"] and r.get("result") == "pass"][0]
        self.assertIn("9 items refused by max_options=8", sc3["reason"])

    # oracle: CHARACTERIZATION (pins that the runner records the flag in meta and argv; no spec text)
    def test_max_options_recorded_in_meta_and_argv(self):
        self.run_main(["--types", "noul", "--limit", "1", "--max-options", "7"])
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertEqual(res["meta"]["max_options"], 7)
        self.assertIn("--max-options 7", b"\n".join(
            open(os.path.join(r, f), "rb").read() for r, _, fs in os.walk(self.out) for f in fs
            if f.endswith(".jsonl")).decode())

    # oracle: CHARACTERIZATION (expected 16 is the decide-2b value read from models/catalog.json by the same test author; the warning is the runner's design)
    def test_catalog_mismatch_warns_on_stderr_and_meta(self):
        # real profile name from models/catalog.json (decide-2b has max_options 16)
        argv = ["--base-url", self.srv.url, "--cacert", self.crt, "--key-env", "GOLDEN_TEST_KEY",
                "--profile", "decide-2b", "--out-dir", self.out, "--run-id", "t1", "--evidence-class", "stand-in",
                "--retry-sleep", "0", "--types", "noul", "--limit", "1", "--max-options", "20"]
        os.environ["GOLDEN_TEST_KEY"] = KEY
        errs = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(errs):
            run_golden.main(argv)
        self.assertIn("differs from catalog", errs.getvalue())
        res = _jload(os.path.join(self.out, "results.json"))
        self.assertEqual(res["meta"]["max_options_catalog"], 16)
        self.assertTrue(res["meta"]["max_options_mismatch"])


class PureUnitTests(unittest.TestCase):
    def item(self, typ):
        return next(i for i in run_golden.load_items(["questions"]) if i["type"] == typ)

    # oracle: CHARACTERIZATION (thresholds 50/40/30 are the golden-set size chosen in this repo; specs/009-jev-decision-models/spec.md:384 (SC-003) only requires 30 questions in total)
    def test_fixture_loads_with_required_counts(self):
        items = run_golden.load_items(["questions"])
        c = {t: sum(1 for i in items if i["type"] == t) for t in ("noul", "choice", "score")}
        self.assertGreaterEqual(c["noul"], 50)
        self.assertGreaterEqual(c["choice"], 40)
        self.assertGreaterEqual(c["score"], 30)

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:186-202 (SystemOneRequest: model plus a questions map; noul criteria true/false, choice criteria object, score criteria list))
    def test_build_request_shapes(self):
        n = run_golden.build_request(self.item("noul"), "m")
        self.assertEqual(n["questions"]["q"]["type"], "noul")
        self.assertEqual(sorted(n["questions"]["q"]["criteria"]), ["false", "true"])
        c = self.item("choice")
        req = run_golden.build_request(c, "m")
        self.assertEqual(list(req["questions"]["q"]["criteria"]), list(c["criteria"]))
        s = run_golden.build_request(self.item("score"), "m")
        self.assertIsInstance(s["questions"]["q"]["criteria"], list)
        self.assertEqual(s["model"], "m")

    # oracle: INVARIANT (same seed gives the same order, the result is a permutation of the keys, and it differs from the original order)
    def test_permutation_deterministic_and_different(self):
        for c in [i for i in run_golden.load_items(["questions"]) if i["type"] == "choice"]:
            a = run_golden.permuted_keys(c, "7")
            self.assertEqual(a, run_golden.permuted_keys(c, "7"))
            self.assertEqual(sorted(a), sorted(c["criteria"]))
            self.assertNotEqual(a, list(c["criteria"]))
        c = next(i for i in run_golden.load_items(["questions"]) if i.get("option_count") == 20)
        self.assertNotEqual(run_golden.permuted_keys(c, "1"), run_golden.permuted_keys(c, "2"))

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:286-295 (NoulAnswer: noul is a number in [0,1]; type must match the question))
    def test_parse_answer_noul(self):
        it = self.item("noul")
        ok = {"answers": {"q": {"type": "noul", "noul": 0.2}}}
        wf, pred, p, _ = run_golden.parse_answer(it, ok)
        self.assertEqual((wf, pred), (True, False))
        self.assertAlmostEqual(p, 0.8)
        for bad in ({"answers": {"q": {"type": "noul", "noul": 1.5}}}, {"answers": {"q": {"type": "choice"}}},
                    {"answers": {}}, {}, {"answers": {"q": {"type": "noul", "noul": True}}}):
            self.assertFalse(run_golden.parse_answer(it, bad)[0])

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:296-316 (ChoiceAnswer: choice is a listed option, probabilities sum to 1 within 1e-6))
    def test_parse_answer_choice_rejects_unknown_option_and_bad_sum(self):
        it = self.item("choice")
        ks = list(it["criteria"])
        good = {"answers": {"q": {"type": "choice", "choice": ks[1], "confidence": 0.5,
                                  "probabilities": {ks[0]: 0.25, ks[1]: 0.75}}}}
        self.assertEqual(run_golden.parse_answer(it, good)[:2], (True, ks[1]))
        for mut in (lambda a: a.update(choice="zzz"),
                    lambda a: a["probabilities"].update({ks[0]: 0.5}),        # sum 1.25
                    lambda a: a.pop("confidence"),
                    lambda a: a["probabilities"].pop(ks[0])):
            body = json.loads(json.dumps(good))
            mut(body["answers"]["q"])
            self.assertFalse(run_golden.parse_answer(it, body)[0])

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:317-340 (ScoreAnswer: level index within the scale); rounding 2.6 to 3 is the runner's design)
    def test_parse_answer_score_rounding_and_range(self):
        it = next(i for i in run_golden.load_items(["questions"]) if i["type"] == "score" and i["scale"] == 5)
        probs = {str(i): 0.0 for i in range(5)}
        probs["3"] = 1.0
        body = {"answers": {"q": {"type": "score", "score": 2.6, "legend": {}, "confidence": 0.9, "probabilities": probs}}}
        self.assertEqual(run_golden.parse_answer(it, body)[:2], (True, 3))          # 2.6 rounds to level 3
        body["answers"]["q"]["score"] = 5.0                                         # outside 0..4
        self.assertFalse(run_golden.parse_answer(it, body)[0])

    # oracle: INVARIANT (--dry-run never prints state text)
    def test_dry_run_prints_no_state_text(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = run_golden.main(["--base-url", "https://x", "--profile", "p", "--dry-run", "--limit", "5"])
        self.assertEqual(rc, 0)
        self.assertNotIn("rm -rf", out.getvalue())

    # oracle: CHARACTERIZATION (pins exit code 2 for unknown --types and --set values as the runner designs it)
    def test_bad_arguments(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(run_golden.main(["--base-url", "u", "--profile", "p", "--types", "bogus", "--dry-run"]), 2)
            self.assertEqual(run_golden.main(["--base-url", "u", "--profile", "p", "--set", "bogus", "--dry-run"]), 2)


class RefusalClassifyTests(unittest.TestCase):
    """G-160: the precise predicate. The gateway's over-limit refusal is HTTP 422 with error_type
    validation_failed (internal/contract/request.go: len(options) > lim.MaxOptions -> errInvalid)."""
    VF = b'{"message":"Request failed validation.","error_type":"validation_failed"}'
    RF = b'{"message":"The model produced no usable answer for this question.","error_type":"readout_failed"}'

    def choice(self, n):
        return {"id": "C", "type": "choice", "criteria": {"k%d" % i: "d" for i in range(n)}}

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:25 and internal/contract/request.go:110 (options above MaxOptions give 422 validation_failed))
    def test_a_over_limit_422_is_refused(self):
        self.assertEqual(run_golden.classify_refusal(422, self.VF, self.choice(20), 16), "max_options")

    # oracle: SPECIFIED (specs/009-jev-decision-models/contracts/openapi.yaml:25 (readout_failed is a deterministic model fault, not a limit refusal))
    def test_b_readout_failed_is_still_malformed(self):
        self.assertIsNone(run_golden.classify_refusal(422, self.RF, self.choice(20), 16))

    # oracle: CHARACTERIZATION (pins that a 200 is never classified as a refusal; runner design)
    def test_c_200_unchanged(self):
        self.assertIsNone(run_golden.classify_refusal(200, b"{}", self.choice(20), 16))

    # oracle: CHARACTERIZATION (pins the runner's precise predicate: only an option count above the limit is a refusal (G-160); request.go:110)
    def test_within_limit_validation_failure_is_not_a_refusal(self):
        self.assertIsNone(run_golden.classify_refusal(422, self.VF, self.choice(16), 16))

    # oracle: CHARACTERIZATION (pins that an unknown limit never classifies a refusal; runner design)
    def test_unknown_limit_never_refuses(self):
        self.assertIsNone(run_golden.classify_refusal(422, self.VF, self.choice(20), None))

    # oracle: CHARACTERIZATION (pins the classifier's defensive handling of non-choice items and hostile bodies; runner design)
    def test_non_choice_and_hostile_body(self):
        self.assertIsNone(run_golden.classify_refusal(422, self.VF, {"type": "noul", "criteria": {"a": 1, "b": 2}}, 1))
        self.assertIsNone(run_golden.classify_refusal(422, b"\xff not json", self.choice(20), 16))
        self.assertIsNone(run_golden.classify_refusal(None, b"", self.choice(20), 16))

    # oracle: CHARACTERIZATION (pins that only a 422 can be a limit refusal (specs/009-jev-decision-models/contracts/openapi.yaml:25 names 422 for it))
    def test_other_statuses_with_validation_failed_body_are_not_refused(self):
        for st in (400, 502, 500, 429):
            self.assertIsNone(run_golden.classify_refusal(st, self.VF, self.choice(20), 16), st)


class CatalogCheckTests(unittest.TestCase):
    # oracle: CHARACTERIZATION (16 and 255 are copied from models/catalog.json by the test author; reads the same file as the code under test, so this is a pinned snapshot)
    def test_known_profile_returns_catalog_value(self):
        self.assertEqual(run_golden.catalog_max_options("decide-2b"), 16)
        self.assertEqual(run_golden.catalog_max_options("decide-julia"), 255)

    # oracle: CHARACTERIZATION (pins the runner's None-on-unknown behaviour; no spec text)
    def test_unknown_profile_or_missing_catalog_is_none(self):
        self.assertIsNone(run_golden.catalog_max_options("no-such-profile"))
        self.assertIsNone(run_golden.catalog_max_options("decide-2b", "/nonexistent/catalog.json"))



if __name__ == "__main__":
    unittest.main()
