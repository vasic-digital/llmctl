"""n_tests.py - failing-first (RED) tests for file-review defects N-01..N-29
(specs/009-jev-decision-models/research/jev-llmctl-new-files.md section 6).

Run via tests/red/test_candidate_files_n01_n29.sh (stdlib unittest). Each test
asserts the CORRECT behaviour; a violated assertion is recorded as RED, an
honest non-reproduction as NOT-REPRODUCED, a defect-class that cannot be
exercised here as SKIP (with reason) and a robustness gap with no
user-visible failure as HARDENING. Nothing is forced RED.
"""
import contextlib
import glob
import io
import json
import math
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from n_common import (ROOT, LIB, FIX, SCRATCH, Red, Skip, NotReproduced,  # noqa: E402
                      Hardening, defect, free_port, clean_env, run, llmctl,
                      spawn, kill_all, http, load_module, start_llama_stub,
                      start_onnx_fake, start_gateway, SYSTEMONE_CHOICE, clip)
from n_backend import Backend  # noqa: E402

GW = load_module("decide_gateway_under_test", os.path.join(LIB, "decide_gateway.py"))
ONX = load_module("onnx_server_under_test", os.path.join(LIB, "onnx_server.py"))

PRE = ("source %(l)s/common.sh; source %(l)s/os_detect.sh; source %(l)s/hardware.sh; "
       "source %(l)s/catalog.sh; source %(l)s/decide.sh; source %(l)s/scheduler.sh; " % {"l": LIB})

OPTS_AB = json.dumps([{"letter": "A", "key": "billing", "label": "billing - x"},
                      {"letter": "B", "key": "legal", "label": "legal - y"}])
NOUL_BODY = {"state": "s", "questions": {"q": {"type": "noul", "instructions": "i?"}}}

_RUNS = {}
_RUNS_SKIP = {}


def sh(script, *args, env=None, stdin=None, timeout=60):
    return run(["bash", "-c", PRE + script, "_"] + list(args),
               env=env or clean_env(), stdin=stdin, timeout=timeout)


def run_suite(name, timeout=240):
    """Run an existing tests/test_<name>.sh once; cache (rc, ok_count)."""
    if name not in _RUNS:
        rc, out, err = run(["bash", os.path.join(ROOT, "tests", "test_%s.sh" % name)],
                           env=clean_env(), timeout=timeout)
        _RUNS[name] = (rc, len(re.findall(r"^  ok:", out, re.M)), (out + err)[-200:])
        _RUNS_SKIP[name] = bool(re.search(r"^\s+SKIP:", out + err, re.M))
    return _RUNS[name]


def raw_resp(sock):
    buf = b""
    try:
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                return None
            buf += chunk
        head, rest = buf.split(b"\r\n\r\n", 1)
        status = int(head.split()[1])
        m = re.search(rb"(?i)content-length:\s*(\d+)", head)
        need = int(m.group(1)) if m else 0
        while len(rest) < need:
            chunk = sock.recv(4096)
            if not chunk:
                break
            rest += chunk
        return status
    except (socket.timeout, OSError, ValueError, IndexError):
        return None


def keepalive_probe(port, key, first_valid):
    """two requests on ONE HTTP/1.1 connection -> (status1, status2)."""
    body = json.dumps(NOUL_BODY).encode()
    s = socket.create_connection(("127.0.0.1", port), timeout=3)
    try:
        auth = ("Authorization: Bearer %s\r\n" % key) if first_valid else ""
        s.sendall(("POST /v1/systemone HTTP/1.1\r\nHost: x\r\n" + auth +
                   "Content-Type: application/json\r\nContent-Length: %d\r\n\r\n" % len(body)
                   ).encode() + body)
        s1 = raw_resp(s)
        s.sendall(("GET /v1/models HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer %s\r\n\r\n"
                   % key).encode())
        s2 = raw_resp(s)
        return s1, s2
    finally:
        s.close()


def tearDownModule():
    kill_all()


class CliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stub = start_llama_stub()

    def ask_env(self, port=None, **extra):
        e = clean_env({"LLMCTL_DECIDE_BACKEND_PORT": str(port or self.stub)})
        e.update(extra)
        return e

    ASK = ["decide", "ask", "--profile", "decide-tiny", "--type", "noul",
           "--instructions", "Is 2+2=4?", "--json"]

    @defect("N-01")
    def test_n01_large_state_argv(self):
        d = tempfile.mkdtemp(dir=SCRATCH)
        small, big = os.path.join(d, "small.txt"), os.path.join(d, "big.txt")
        open(small, "w").write("Arithmetic facts.")
        open(big, "w").write("x" * 200000)
        cmd = "llmctl decide ask --state-file <200000-char file> --type noul --json"
        rc0, out0, err0 = llmctl(self.ASK + ["--state-file", small], env=self.ask_env())
        if rc0 != 0 or '"noul"' not in out0:   # control needle: instrument must work
            raise RuntimeError("control (small state) failed rc=%s %s" % (rc0, err0[-150:]))
        rc, out, err = llmctl(self.ASK + ["--state-file", big], env=self.ask_env())
        if rc != 0:
            raise Red(cmd, rc, "control small-state rc=0 OK; 200000-char state-file -> rc=%s: %s"
                      % (rc, (err.strip().splitlines() or [""])[-1]))
        return NotReproduced(cmd, rc, "200000-char state accepted")

    @defect("N-02")
    def test_n02_cli_no_state_length_handling(self):
        be = Backend(reject_over_chars=30000)
        try:
            d = tempfile.mkdtemp(dir=SCRATCH)
            f = os.path.join(d, "mid.txt")
            open(f, "w").write("y" * 40000)
            cmd = "llmctl decide ask --state-file <40000-char file> (backend ctx limit 30000 chars)"
            small = os.path.join(d, "s.txt")
            open(small, "w").write("short")
            rc0, o0, _ = llmctl(self.ASK + ["--state-file", small], env=self.ask_env(be.port))
            if rc0 != 0 or not be.requests:
                raise RuntimeError("control failed rc=%s" % rc0)
            n_before = len(be.requests)
            rc, out, err = llmctl(self.ASK + ["--state-file", f], env=self.ask_env(be.port))
            sent = be.requests[n_before][1] if len(be.requests) > n_before else None
            hint = re.search(r"(?i)truncat|context|too long|max-state", err + out)
            if rc != 0 and not hint:
                raise Red(cmd, rc, "CLI forwarded full state (backend saw %s chars, no truncation) and "
                          "the failure is opaque: %s" % (sent, err.strip()[-160:]))
            return NotReproduced(cmd, rc, "state truncated or failure explained: %s" % clip(err, 120))
        finally:
            be.stop()

    @defect("N-03")
    def test_n03_lowercase_letter_collision(self):
        raw = {"choices": [{"logprobs": {"top_logprobs": [[
            {"token": " a", "logprob": -0.1}, {"token": " B", "logprob": -1.0},
            {"token": " the", "logprob": -0.5}]]}}]}
        ctrl = {"choices": [{"logprobs": {"top_logprobs": [[
            {"token": " A", "logprob": -0.1}, {"token": " B", "logprob": -1.0}]]}}]}
        opts = json.loads(OPTS_AB)
        c = GW.shape_answer("choice", ctrl, opts, {}, 1.0)
        if c["choice"] != "billing":
            raise RuntimeError("control failed")
        g = GW.shape_answer("choice", raw, opts, {}, 1.0)
        rc, out, err = sh('decide_shape_response choice "$1" "$2" ""', json.dumps(raw), OPTS_AB)
        sh_choice = json.loads(out)["choice"] if rc == 0 and out.strip() else "ERR:" + err[-80:]
        cmd = "shape_answer / decide_shape_response with top_logprobs [' a'(-0.1),' B'(-1.0)]"
        if g["choice"] != "legal" or sh_choice != "legal":
            raise Red(cmd, rc, "lower-case article ' a' counted as option A: gateway choice=%s shell choice=%s "
                      "(expected legal)" % (g["choice"], sh_choice))
        return NotReproduced(cmd, rc, "' a' not treated as option A")

    @defect("N-04")
    def test_n04_missing_letter_and_nan(self):
        opts = json.loads(OPTS_AB)
        no_a = {"choices": [{"logprobs": {"top_logprobs": [[
            {"token": " B", "logprob": -0.1}, {"token": " the", "logprob": -0.5}]]}}]}
        ninf = {"choices": [{"logprobs": {"top_logprobs": [[
            {"token": " A", "logprob": float("-inf")}, {"token": " B", "logprob": float("-inf")}]]}}]}
        ctrl = {"choices": [{"logprobs": {"top_logprobs": [[
            {"token": " A", "logprob": -0.1}, {"token": " B", "logprob": -2.0}]]}}]}
        c = GW.shape_answer("noul", ctrl, opts, {}, 1.0)
        if not (0.8 < c["noul"] < 1.0):
            raise RuntimeError("control failed %r" % c)
        problems = []
        try:
            r = GW.shape_answer("noul", no_a, opts, {}, 1.0)
            problems.append("noul with letter A absent -> %r (no error)" % r.get("noul"))
        except ValueError:
            pass
        try:
            r = GW.shape_answer("choice", ninf, opts, {}, 1.0)
            try:
                json.dumps(r, allow_nan=False)
            except ValueError:
                problems.append("all -inf logprobs -> NaN in answer (invalid JSON)")
        except ValueError:
            pass
        raw_inf = ('{"choices":[{"logprobs":{"top_logprobs":[[{"token":" A","logprob":-Infinity},'
                   '{"token":" B","logprob":-Infinity}]]}}]}')
        rc, out, err = sh('decide_shape_response choice "$1" "$2" ""', raw_inf, OPTS_AB)
        if rc == 0 and "NaN" in out:
            problems.append("shell prints NaN: %s" % out.strip()[:80])
        rc2, out2, _ = sh('decide_shape_response noul "$1" "$2" ""', json.dumps(no_a), OPTS_AB)
        if rc2 == 0:
            problems.append("shell noul w/o A -> %s rc=0" % out2.strip()[:60])
        cmd = "shape_answer/decide_shape_response noul(A absent) and all -inf"
        if problems:
            raise Red(cmd, rc2, "; ".join(problems))
        return NotReproduced(cmd, rc2, "errors raised explicitly")

    @defect("N-05")
    def test_n05_bad_seed(self):
        cmd = "LLMCTL_SEED=abc llmctl decide ask ... ; gateway with LLMCTL_SEED=abc"
        rc0, o0, _ = llmctl(self.ASK + ["--state", "s"], env=self.ask_env())
        if rc0 != 0:
            raise RuntimeError("control (valid seed unset) failed")
        rc, out, err = llmctl(self.ASK + ["--state", "s"], env=self.ask_env(LLMCTL_SEED="abc"))
        gp = start_gateway(self.stub, env_extra={"LLMCTL_SEED": "abc"})
        st, _, body = http("POST", gp, "/v1/systemone", NOUL_BODY)
        tb = "Traceback" in err
        if tb or (st == 502 and "invalid literal" in body):
            raise Red(cmd, rc, "CLI rc=%s traceback=%s; gateway accepted bad seed at start and answered %s %s"
                      % (rc, tb, st, clip(body, 110)))
        return NotReproduced(cmd, rc, "clean validation: %s" % clip(err, 120))

    @defect("N-06")
    def test_n06_wizard_eof(self):
        cmd = "llmctl decide interactive --interactive --profile decide-tiny </dev/null"
        ctrl_in = "noul\ns\n.\nq?\n\n\nn\n"
        rc0, o0, e0 = llmctl(["decide", "interactive", "--interactive", "--profile", "decide-tiny"],
                             env=clean_env(), stdin=ctrl_in)
        if rc0 != 0 or "aborted" not in e0:
            raise RuntimeError("control (scripted answers) failed rc=%s %s" % (rc0, e0[-120:]))
        rc, out, err = llmctl(["decide", "interactive", "--interactive", "--profile", "decide-tiny"],
                              env=clean_env())
        src_rc, src_out, _ = sh('decide_interactive --interactive --profile decide-tiny </dev/null; '
                                'echo "AFTER-WIZARD rc=$?"')
        msg = re.search(r"(?i)eof|end of input|no input|aborted|stdin", err)
        killed_shell = "AFTER-WIZARD" not in src_out
        if rc != 2 or not msg or killed_shell:
            raise Red(cmd, rc, "EOF at a prompt: rc=%s (want 2), message=%s, sourcing shell killed silently=%s; stderr=%r"
                      % (rc, bool(msg), killed_shell, clip(err, 90)))
        return NotReproduced(cmd, rc, "clean rc 2 with message")

    @defect("N-07")
    def test_n07_strict_args(self):
        cmd = "llmctl decide status --jsno ; llmctl decide capacity --jsno"
        rc0, o0, _ = llmctl(["decide", "status", "--json"], env=clean_env())
        json.loads(o0)  # control: valid JSON for the valid flag (ValueError -> ERROR)
        env = clean_env({"LLMCTL_FAKE_HW": os.path.join(FIX, "hw-baseline.json")})
        rc1, o1, e1 = llmctl(["decide", "status", "--jsno"], env=env)
        rc2, o2, e2 = llmctl(["decide", "capacity", "--jsno"], env=env)
        if rc1 == 0 or rc2 == 0:
            raise Red(cmd, rc1, "misspelled flag silently accepted: status rc=%s, capacity rc=%s (want 2)" % (rc1, rc2))
        return NotReproduced(cmd, rc1, "unknown arg rejected")

    @defect("N-08")
    def test_n08_doc_function_name(self):
        doc = open(os.path.join(ROOT, "docs/scripts/decide.md"), encoding="utf-8").read()
        code = open(os.path.join(LIB, "decide.sh"), encoding="utf-8").read()
        named = sorted(set(re.findall(r"`(decide_[a-z_]+)`", doc)))
        missing = [n for n in named if not re.search(r"^%s\(\)" % re.escape(n), code, re.M)]
        ctrl = "decide_ask" in named and "decide_ask" not in missing
        if not ctrl:
            raise RuntimeError("control: decide_ask not found/defined")
        cmd = "grep function names in docs/scripts/decide.md vs lib/decide.sh"
        if missing:
            raise Red(cmd, 1, "doc names undefined function(s): %s" % ", ".join(missing))
        return NotReproduced(cmd, 0, "all documented functions exist")

    @defect("N-09")
    def test_n09_prompts_on_piped_stdin(self):
        cmd = "printf 'q?\\n\\n\\nn\\n' | llmctl decide interactive --interactive --profile decide-tiny --type noul --state s"
        rc, out, err = llmctl(["decide", "interactive", "--interactive", "--profile", "decide-tiny",
                               "--type", "noul", "--state", "s"], env=clean_env(), stdin="q?\n\n\nn\n")
        if "aborted" not in err:
            raise RuntimeError("control: wizard did not reach confirmation: %s" % err[-150:])
        if "Instructions (the question" not in err:
            raise Red(cmd, rc, "docs claim prompts go to stderr, but with piped stdin no prompt text is emitted "
                      "(bash read -p only prints on a TTY); stderr=%r" % clip(err, 120))
        return NotReproduced(cmd, rc, "prompts visible on stderr")

    @defect("N-10")
    def test_n10_first_token_assumption(self):
        raise Skip("n/a", None, "needs a real model per profile (first generated token may be a thinking/format "
                   "token); no model installed and a stand-in cannot measure model behaviour (INFERRED/UNCONFIRMED)")

    @defect("N-11")
    def test_n11_byte_identical_repeats(self):
        raise Skip("n/a", None, "SC-001 byte-identical logprobs across llama.cpp slot/batch compositions can only be "
                   "measured on the real engine; stand-in is deterministic by construction (INFERRED)")


class GatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stub = start_llama_stub()

    @defect("N-12")
    def test_n12_keepalive_desync(self):
        gp = start_gateway(self.stub, extra_args=["--api-key", "k-fake"])
        op = start_onnx_fake(extra_args=["--api-key", "k-fake"])
        res = {}
        for name, port in (("gateway", gp), ("onnx", op)):
            c1, c2 = keepalive_probe(port, "k-fake", True)
            if (c1, c2) != (200, 200):          # control: keep-alive works on the happy path
                raise RuntimeError("control keep-alive on %s: %s" % (name, (c1, c2)))
            res[name] = keepalive_probe(port, "k-fake", False)   # first request 401 with unread body
        cmd = "2 requests on one HTTP/1.1 connection; 1st = POST w/o key (401) with body"
        bad = {k: v for k, v in res.items() if v != (401, 200)}
        if bad:
            raise Red(cmd, None, "after an error response the next request on the same connection is "
                      "mis-parsed (leftover body): %s (want 401,200)" % bad)
        return NotReproduced(cmd, None, "no desync")

    @defect("N-13")
    def test_n13_upstream_auth_collapsed(self):
        op = start_onnx_fake(extra_args=["--api-key", "k1"])
        gp = start_gateway(op, engine="onnx")
        op2 = start_onnx_fake()
        gp2 = start_gateway(op2, engine="onnx")
        cs, _, _ = http("POST", gp2, "/v1/systemone", NOUL_BODY)
        if cs != 200:
            raise RuntimeError("control: proxy to key-less onnx runtime returned %s" % cs)
        st, _, body = http("POST", gp, "/v1/systemone", NOUL_BODY)
        cmd = "gateway(onnx proxy, no upstream key) -> onnx runtime with --api-key"
        if st == 502 and re.search(r"HTTP Error 401|Errno|urlopen", body):
            raise Red(cmd, None, "upstream 401 collapsed into %s with raw exception text: %s" % (st, clip(body, 140)))
        return NotReproduced(cmd, None, "status=%s body=%s" % (st, clip(body, 100)))

    @defect("N-14")
    def test_n14_proxy_drops_truncation_header(self):
        op = start_onnx_fake(extra_args=["--max-state-chars", "50"])
        gp = start_gateway(op, engine="onnx", extra_args=["--max-state-chars", "0"])
        body = {"state": "y" * 200, "questions": {"q": {"type": "noul", "instructions": "i?"}}}
        ds, dh, _ = http("POST", op, "/v1/systemone", body)
        if ds != 200 or dh.get("x-llmctl-decide-truncated") != "true":
            raise RuntimeError("control: runtime direct did not signal truncation %s %s" % (ds, dh))
        gs, gh, _ = http("POST", gp, "/v1/systemone", body)
        cmd = "gateway(--max-state-chars 0) -> onnx runtime(--max-state-chars 50), 200-char state"
        if gs == 200 and gh.get("x-llmctl-decide-truncated") != "true":
            raise Red(cmd, None, "runtime truncated (direct header=true) but gateway response omits "
                      "x-llmctl-decide-truncated (status %s)" % gs)
        return NotReproduced(cmd, None, "header forwarded: %s" % gh.get("x-llmctl-decide-truncated"))

    @defect("N-15")
    def test_n15_non_string_state(self):
        gp = start_gateway(self.stub)
        op = start_onnx_fake()
        cs, _, _ = http("POST", gp, "/v1/systemone", NOUL_BODY)
        if cs != 200:
            raise RuntimeError("control failed %s" % cs)
        obj = {"state": {"ticket": "T-1", "text": "hello"}, "questions": NOUL_BODY["questions"]}
        arr = {"state": ["a", "b"], "questions": NOUL_BODY["questions"]}
        res = {"gateway": (http("POST", gp, "/v1/systemone", obj)[0], http("POST", gp, "/v1/systemone", arr)[0]),
               "onnx": (http("POST", op, "/v1/systemone", obj)[0], http("POST", op, "/v1/systemone", arr)[0])}
        cmd = "POST /v1/systemone with state as JSON object / array (FR-075: MUST accept text, object or array)"
        if any(s != 200 for v in res.values() for s in v):
            raise Red(cmd, None, "state object/array rejected (object,array statuses): %s" % res)
        return NotReproduced(cmd, None, "accepted: %s" % res)

    @defect("N-16")
    def test_n16_bad_numeric_env(self):
        base = [sys.executable, "-I", os.path.join(LIB, "decide_gateway.py")]
        e_ok = clean_env()
        rc0, o0, _ = run(base + ["--render-prompt", "--type", "noul", "--state", "s", "--instructions", "i"], env=e_ok)
        if rc0 != 0 or "A) yes" not in o0:
            raise RuntimeError("control failed")
        e1 = clean_env({"LLMCTL_DECIDE_MAX_OPTIONS": "abc"})
        rc1, _, err1 = run(base + ["--render-prompt", "--type", "noul", "--state", "s", "--instructions", "i"], env=e1)
        e2 = clean_env({"LLMCTL_DECIDE_PORT": "abc"})
        rc2, _, err2 = run(base + ["--profile", "x", "--backend-port", "1"], env=e2)
        stub = start_llama_stub()
        e3 = clean_env({"LLMCTL_DECIDE_MAX_OPTIONS": "abc", "LLMCTL_DECIDE_BACKEND_PORT": str(stub)})
        rc3, _, err3 = llmctl(["decide", "ask", "--profile", "decide-tiny", "--type", "noul", "--state", "s",
                               "--instructions", "i?", "--json"], env=e3)
        bad = []
        if "Traceback" in err1:
            bad.append("MAX_OPTIONS=abc --render-prompt: traceback rc=%s" % rc1)
        if "Traceback" in err2:
            bad.append("DECIDE_PORT=abc: traceback rc=%s" % rc2)
        if "Traceback" in err3 or "unbound variable" in err3:
            bad.append("decide ask MAX_OPTIONS=abc: rc=%s %s" % (rc3, clip(err3.strip().splitlines()[-1] if err3.strip() else "", 80)))
        cmd = "LLMCTL_DECIDE_MAX_OPTIONS=abc / LLMCTL_DECIDE_PORT=abc"
        if bad:
            raise Red(cmd, rc1, "; ".join(bad))
        return NotReproduced(cmd, rc1, "clean messages")

    @defect("N-17")
    def test_n17_model_echo(self):
        gp = start_gateway(self.stub)
        op = start_onnx_fake()
        res = {}
        for name, port in (("gateway", gp), ("onnx", op)):
            ctrl = http("POST", port, "/v1/systemone", dict(NOUL_BODY, model="jev-latest"))
            if ctrl[0] != 200:
                raise RuntimeError("control: known alias rejected by %s: %s" % (name, ctrl[0]))
            st, _, txt = http("POST", port, "/v1/systemone", dict(NOUL_BODY, model="no-such-model-xyz"))
            st2, _, txt2 = http("POST", port, "/v1/systemone", dict(NOUL_BODY, model={"x": 1}))
            res[name] = (st, "no-such-model-xyz" in txt, st2, '"x"' in txt2)
        cmd = "POST /v1/systemone with unknown model name / non-string model"
        bad = {k: v for k, v in res.items() if v[0] == 200 or v[2] == 200}
        if bad:
            raise Red(cmd, None, "unknown/non-string model accepted and echoed (status,echo,status2,echo2): %s" % bad)
        return NotReproduced(cmd, None, "rejected: %s" % res)

    @defect("N-18")
    def test_n18_unbounded_questions(self):
        be = Backend()
        try:
            gp = start_gateway(be.port)
            two = {"state": "s", "questions": {"q%d" % i: {"type": "noul", "instructions": "i"} for i in range(2)}}
            http("POST", gp, "/v1/systemone", two)
            if len([r for r in be.requests if r[0] == "/v1/chat/completions"]) != 2:
                raise RuntimeError("control: backend counter did not see 2 requests")
            before = len(be.requests)
            many = {"state": "s", "questions": {"q%d" % i: {"type": "noul", "instructions": "i"} for i in range(500)}}
            st, _, txt = http("POST", gp, "/v1/systemone", many, timeout=120)
            passes = len(be.requests) - before
            cmd = "POST /v1/systemone with 500 questions"
            if st == 200 or passes >= 500:
                raise Red(cmd, None, "status=%s; gateway performed %d full model passes for one request (no questions cap)"
                          % (st, passes))
            return NotReproduced(cmd, None, "rejected status=%s passes=%d" % (st, passes))
        finally:
            be.stop()

    @defect("N-19")
    def test_n19_healthz_amplification_and_leak(self):
        be = Backend()
        try:
            http("GET", be.port, "/health")
            if be.health_hits != 1:
                raise RuntimeError("control: backend /health counter broken")
            be.health_hits = 0
            gp = start_gateway(be.port, extra_args=["--api-key", "k-fake"])
            bodies = [http("GET", gp, "/healthz") for _ in range(5)]
            cmd = "5x unauthenticated GET /healthz (gateway has --api-key set)"
            leak = "toy" in bodies[0][2]
            if be.health_hits >= 5 or leak:
                raise Red(cmd, None, "each unauth hit probes backend (backend /health hits=%d) and body leaks profile: %s"
                          % (be.health_hits, clip(bodies[0][2], 70)))
            return NotReproduced(cmd, None, "hits=%d" % be.health_hits)
        finally:
            be.stop()


class OnnxTests(unittest.TestCase):
    @staticmethod
    def serve(infer, api_key=""):
        args = SimpleNamespace(profile="p", api_key=api_key, max_state_chars=8192)
        srv = ONX.Server(args, infer)
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), ONX.make_handler(srv))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        return httpd

    @defect("N-20")
    def test_n20_ctx_ignored(self):
        class Tok:
            def EncodeAsIds(self, t):
                return list(range(10, 1010))

            def bos_id(self):
                return 1

            def eos_id(self):
                return 2

        class NP:
            int64 = int

            @staticmethod
            def array(x, dtype=None):
                return x
        m = ONX.OnnxModel.__new__(ONX.OnnxModel)
        m.np, m.tokenizer = NP(), ("spm", Tok())
        os.environ["LLMCTL_CTX_DECIDE_NLI"] = "128"
        try:
            ids, _ = m.encode_pair("premise", "hypothesis")
        finally:
            del os.environ["LLMCTL_CTX_DECIDE_NLI"]
        n = len(ids[0])
        sched = open(os.path.join(LIB, "scheduler.sh"), encoding="utf-8").read()
        arm = sched[sched.index("onnx_server.py"):][:900]
        passes_ctx = bool(re.search(r"--(max-len|ctx)", arm))
        cmd = "OnnxModel.encode_pair with 1000+ token input and LLMCTL_CTX_DECIDE_NLI=128"
        if n > 128 and not passes_ctx:
            raise Red(cmd, None, "sequence length %d; ctx 128 ignored (MAX_LEN literal 512) and the scheduler onnx arm passes no ctx arg" % n)
        return NotReproduced(cmd, None, "len=%d" % n)

    @defect("N-21")
    def test_n21_label_order_detection(self):
        problems = []
        d = tempfile.mkdtemp(dir=SCRATCH)
        os.makedirs(d + "/onnx")
        json.dump({"id2label": {"0": "contradiction", "1": "neutral", "2": "entailment"}}, open(d + "/config.json", "w"))
        json.dump({"id2label": {"0": "entailment", "1": "neutral", "2": "contradiction"}}, open(d + "/onnx/config.json", "w"))
        open(d + "/onnx/model.onnx", "w").write("x")
        ent, neu, con, src = ONX.detect_label_order(d)
        # control needle: single root config is read correctly
        d0 = tempfile.mkdtemp(dir=SCRATCH)
        json.dump({"id2label": {"0": "contradiction", "1": "neutral", "2": "entailment"}}, open(d0 + "/config.json", "w"))
        if ONX.detect_label_order(d0)[0] != 2:
            raise RuntimeError("control: simple root config not parsed")
        if ent == 2:
            problems.append("(a) root config.json preferred over onnx/config.json beside model.onnx (ent idx=%d, source=%s)" % (ent, os.path.relpath(src, d)))
        d2 = tempfile.mkdtemp(dir=SCRATCH)
        json.dump({"id2label": {"0": "LABEL_0", "1": "LABEL_1", "2": "LABEL_2"}}, open(d2 + "/config.json", "w"))
        try:
            r = ONX.detect_label_order(d2)
            problems.append("(b) LABEL_0..2 silently falls back with source %r although config.json exists" % r[3])
        except (SystemExit, ValueError):
            pass
        d3 = tempfile.mkdtemp(dir=SCRATCH)
        json.dump({"id2label": {"a": "entailment", "b": "neutral", "c": "contradiction"}}, open(d3 + "/config.json", "w"))
        try:
            ONX.detect_label_order(d3)
        except ValueError as exc:
            problems.append("(c) non-integer id2label key -> uncaught ValueError(%s)" % exc)
        except SystemExit:
            pass
        cmd = "onnx_server.detect_label_order on crafted model dirs"
        if problems:
            raise Red(cmd, None, " ".join(problems))
        return NotReproduced(cmd, None, "all label-order cases handled")

    @defect("N-22")
    def test_n22_engine_drift(self):
        stub = start_llama_stub()
        env = {"LLMCTL_DECIDE_MAX_OPTIONS": "3"}
        gp = start_gateway(stub, env_extra=env)
        op = start_onnx_fake(env_extra=env)
        ctrl = [http("POST", p, "/v1/systemone", NOUL_BODY)[0] for p in (gp, op)]
        if ctrl != [200, 200]:
            raise RuntimeError("control: valid request not 200 on both: %s" % ctrl)
        cases = {
            "noul criteria='banana'": {"state": "s", "questions": {"q": {"type": "noul", "instructions": "i?", "criteria": "banana"}}},
            "choice 5 options, MAX_OPTIONS=3": {"state": "s", "questions": {"q": {"type": "choice", "instructions": "i?",
                                                "criteria": {k: "d" for k in "abcde"}}}},
        }
        diffs = []
        for name, body in cases.items():
            g, o = http("POST", gp, "/v1/systemone", body)[0], http("POST", op, "/v1/systemone", body)[0]
            if g != o:
                diffs.append("%s: gateway=%s onnx=%s" % (name, g, o))
        cmd = "identical invalid requests to gateway(llama) and onnx runtime"
        if diffs:
            raise Red(cmd, None, "engines disagree on the same request: " + "; ".join(diffs))
        return NotReproduced(cmd, None, "same statuses")

    @defect("N-23")
    def test_n23_health_without_inference(self):
        def broken(prem, hyp, idx):
            raise RuntimeError("model broken")
        good = self.serve(lambda p, h, i: [2.0, 0.0, -2.0])
        st, _, _ = http("POST", good.server_address[1], "/v1/systemone", NOUL_BODY)
        if st != 200:
            raise RuntimeError("control: working server did not answer (%s)" % st)
        bad = self.serve(broken)
        hs, _, hb = http("GET", bad.server_address[1], "/health")
        cmd = "GET /health on a server whose inference function always raises"
        if hs == 200:
            raise Red(cmd, None, "/health=200 %s although every inference fails (health never exercises the model)" % clip(hb, 60))
        return NotReproduced(cmd, None, "health=%s" % hs)

    @defect("N-24")
    def test_n24_non_valueerror_and_nan(self):
        errbuf = io.StringIO()
        problems = []
        with contextlib.redirect_stderr(errbuf):
            good = self.serve(lambda p, h, i: [2.0, 0.0, -2.0])
            if http("POST", good.server_address[1], "/v1/systemone", NOUL_BODY)[0] != 200:
                raise RuntimeError("control failed")
            boom = self.serve(lambda p, h, i: (_ for _ in ()).throw(RuntimeError("boom")))
            st, _, txt = http("POST", boom.server_address[1], "/v1/systemone", NOUL_BODY)
            if st is None:
                problems.append("RuntimeError during inference -> connection dropped (%s)" % txt[:50])
            nan = self.serve(lambda p, h, i: [float("nan"), 0.0, -2.0])
            st2, _, txt2 = http("POST", nan.server_address[1], "/v1/systemone", NOUL_BODY)
            if st2 == 200 and "NaN" in txt2:
                problems.append("NaN logits -> 200 with invalid JSON token NaN")
        cmd = "onnx handler with injected infer raising RuntimeError / returning NaN"
        if problems:
            raise Red(cmd, None, "; ".join(problems))
        return NotReproduced(cmd, None, "typed errors returned")


class RepoHygieneTests(unittest.TestCase):
    @defect("N-25")
    def test_n25_fixed_ports(self):
        static = {}
        for f in ("test_decide_download.sh", "test_onnx_download.sh"):
            m = re.search(r"^PORT=(\d+)\s*$", open(os.path.join(ROOT, "tests", f)).read(), re.M)
            static[f] = int(m.group(1)) if m else None
        cmd = "occupy the fixed port and run tests/test_decide_download.sh"
        rc_c, ok_c, tail_c = run_suite("decide_download")
        if rc_c != 0:
            raise Red(cmd, rc_c, "static: fixed PORT literals %s; control run (port free) failed: %s" % (static, tail_c[-100:]))
        port = static["test_decide_download.sh"]
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        bound = False
        for _ in range(20):          # control run's http.server may still be exiting
            try:
                s.bind(("127.0.0.1", port))
                s.listen(1)
                bound = True
                break
            except OSError:
                time.sleep(0.5)
        if not bound:
            raise Red(cmd, None, "static: fixed PORT literals %s; runtime collision run not possible - port %d stayed held by a foreign process" % (static, port))
        try:
            rc, out, err = run(["bash", os.path.join(ROOT, "tests", "test_decide_download.sh")], env=clean_env(), timeout=45)
        finally:
            s.close()
        if rc != 0:
            raise Red(cmd, rc, "fixed PORT literals %s; control rc=0 with port free, rc=%s when 127.0.0.1:%d is occupied: %s"
                      % (static, rc, port, clip((out + err)[-160:], 140)))
        return NotReproduced(cmd, rc, "test passed despite occupied port")

    @defect("N-26")
    def test_n26_tests_encode_success_while_skipped(self):
        hits = []
        for f in ("test_onnx_download.sh", "test_decide_download.sh"):
            lines = open(os.path.join(ROOT, "tests", f), encoding="utf-8").read().splitlines()
            for i, ln in enumerate(lines):
                if "assert_file_contains" in ln and "SUCCESS" in ln:
                    ctx = "\n".join(lines[max(0, i - 8): i + 2])
                    if re.search(r"(?i)skip", ctx):
                        hits.append("%s:%d" % (f, i + 1))
        ctrl = any("assert_file_contains" in l for l in open(os.path.join(ROOT, "tests", "test_onnx_download.sh")))
        if not ctrl:
            raise RuntimeError("control: scanner saw no assert_file_contains")
        cmd = "scan tests/test_*_download.sh for SUCCESS asserted in/after SKIP branches"
        if hits:
            raise Red(cmd, None, "tests assert 'download <p>: SUCCESS' while smoke is skipped/disabled (D-12 encoded as correct): %s" % ", ".join(hits))
        return NotReproduced(cmd, None, "no such assertion")

    @defect("N-27")
    def test_n27_doc_counts_stale(self):
        pairs = [("test_decide", "decide"), ("test_decide_gateway", "decide_gateway"),
                 ("test_decide_download", "decide_download"), ("test_onnx_download", "onnx_download"),
                 ("test_onnx_server", "onnx_server")]
        mism, env_dep = [], []
        for doc, suite in pairs:
            txt = open(os.path.join(ROOT, "docs/scripts/%s.md" % doc), encoding="utf-8").read()
            m = re.search(r"\*\*(\d+)\s+passing", txt.replace("\n", " "))
            rc, ok, tail = run_suite(suite)
            if rc != 0 or m is None:
                raise RuntimeError("control: suite %s rc=%s claim=%s" % (suite, rc, bool(m)))
            if int(m.group(1)) != ok:
                (env_dep if _RUNS_SKIP.get(suite) else mism).append("%s doc=%s actual=%d" % (doc, m.group(1), ok))
        cmd = "compare '<N> passing assertions' in docs/scripts/test_*.md with 'ok:' lines of a real run"
        if mism:
            raise Red(cmd, 0, "stale documented counts: " + "; ".join(mism) +
                      ("  (host-dependent, not counted: %s)" % "; ".join(env_dep) if env_dep else ""))
        return NotReproduced(cmd, 0, "counts match")

    @defect("N-28")
    def test_n28_mirror_only_confirmed(self):
        res = []
        for f in ("encoder-model-hashes.md", "decision-model-hashes.md"):
            t = open(os.path.join(ROOT, "docs/research", f), encoding="utf-8").read()
            res.append((f, t.count("CONFIRMED"), "hf-mirror.com" in t, "huggingface.co" in t))
        ctrl = [r for r in res if r[2]]
        if not ctrl:
            raise RuntimeError("control: no doc names its mirror source")
        cmd = "scan docs/research/*hashes.md for CONFIRMED claims vs sources"
        bad = [r for r in res if r[1] and r[2] and not r[3]]
        if bad:
            raise Red(cmd, None, "CONFIRMED claims with only hf-mirror.com as source and no independent huggingface.co reference: %s"
                      % ", ".join("%s(%d)" % (r[0], r[1]) for r in bad))
        return NotReproduced(cmd, None, str(res))

    @defect("N-29")
    def test_n29_test_file_count_claims(self):
        out = subprocess.run(["git", "ls-files", "tests/test_*.sh"], cwd=ROOT, capture_output=True, text=True).stdout
        head = len([l for l in out.splitlines() if re.match(r"tests/test_[^/]+\.sh$", l)])
        wt = len(glob.glob(os.path.join(ROOT, "tests", "test_*.sh")))
        if head < 30:
            raise RuntimeError("control: git count implausible %d" % head)
        allowed = {head, wt}
        bad = []
        pat = re.compile(r"\b(\d+)\s+(?:`?tests/)?`?test_\*\.sh`?\s+files|\b(\d+)\s+test files")
        names = ("spec.md", "plan.md", "tasks.md", "research.md", "traceability.md", "quickstart.md", "data-model.md")
        for nm in names:
            f = os.path.join(ROOT, "specs/009-jev-decision-models", nm)
            if not os.path.isfile(f):
                continue
            t = open(f, encoding="utf-8").read()
            for m in pat.finditer(t):
                n = int(m.group(1) or m.group(2))
                if n >= 30 and n not in allowed:      # suite-size claims only
                    bad.append("%s:%d" % (nm, n))
        cmd = "git ls-files tests/test_*.sh vs 'N test files' claims in specs/009 and docs"
        if bad:
            raise Red(cmd, 0, "tracked=%d worktree=%d; mismatching claims: %s" % (head, wt, bad[:6]))
        return NotReproduced(cmd, 0, "tracked at HEAD=%d, worktree=%d; no suite-size claim other than HEAD/worktree counts in the normative specs/009 files (plan.md uses 38 at HEAD; 41 is a PASS count)" % (head, wt))


if __name__ == "__main__":
    unittest.main(verbosity=1)
