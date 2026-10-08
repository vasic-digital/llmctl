"""RED (failing-first) tests for defects D-01..D-15 of
specs/009-jev-decision-models/source-findings.md.

Convention: every test asserts the CORRECT behaviour.  A failed assertion
= the defect is REPRODUCED (status RED); a test that passes = NOT-REPRODUCED;
an unexpected exception = ERROR (harness problem, not a verdict);
SkipTest = SKIP.  Real entry points only: real sockets to real
lib/onnx_server.py / lib/decide_gateway.py subprocesses, real bash function
sourcing.  Stand-ins exist only for the model backend (onnxruntime /
sentencepiece stubs, tests/fixtures servers, a recording listener).
"""
import errno
import hashlib
import json
import os
import shutil
import signal
import socket
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import redlib as R  # noqa: E402

CHOICE_Q = {"type": "choice", "instructions": "Which team handles invoices?",
            "criteria": {"billing": "handles invoices", "legal": "contracts"}}
BODY = {"state": "Routing request about an unpaid invoice.",
        "questions": {"q": CHOICE_Q}}


def _model_dir(tmp, name="m"):
    d = os.path.join(tmp, name)
    os.makedirs(d, exist_ok=True)
    return d


class RedBase(unittest.TestCase):
    EVID = {}

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="red-d01-")

    def tearDown(self):
        R.reap_all()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def evidence(self, command, excerpt, exit_code=None):
        RedBase.EVID[self.id().split(".")[-1]] = {
            "command": R.redact(command), "exit_code": exit_code,
            "key_output_excerpt": R.redact(excerpt)}

    def check(self, problems, command, ok_note, exit_code=None):
        """problems: list of strings describing observed defect behaviour."""
        if problems:
            ex = " | ".join(problems)
            self.evidence(command, ex, exit_code)
            self.fail(ex)
        self.evidence(command, ok_note, exit_code)


class T(RedBase):
    # ---- D-01 ----------------------------------------------------------
    def test_d01(self):
        have_tok = R_find_tokenizer()
        cmd = "locate DeBERTa spm.model + sentencepiece for lib/onnx_server.py encode_pair"
        if not have_tok:
            self.evidence(cmd, "tokenizer files not present (no DeBERTa spm.model "
                          "under ~/.local/share/llmctl or HF cache; sentencepiece "
                          "not installed; no pinned tokenizer URL in source-findings.md)", 0)
            raise unittest.SkipTest("tokenizer files not present")
        self.skipTest("tokenizer present but real-tokenizer path unimplemented")

    # ---- D-02 ----------------------------------------------------------
    def test_d02(self):
        problems = []
        K = R.SENTINEL
        onnx_port, gw_port = R.free_port(), R.free_port()
        R.start_onnx(onnx_port, _model_dir(self.tmp), ["--api-key", K])
        R.start_gateway(gw_port, onnx_port,
                        ["--backend-engine", "onnx", "--api-key", K])
        st, _h, body = R.http(gw_port, "POST", "/v1/systemone", BODY,
                              {"Authorization": "Bearer " + K})
        if st != 200:
            problems.append("gateway(onnx proxy, same key as runtime) answered %d: %s"
                            % (st, body[:90]))
        env = R.bash_env(self.tmp, {"LLMCTL_DECIDE_API_KEY": K,
                                    "LLMCTL_DECIDE_TIMEOUT": "10"})
        rc, out = R.bash(R.source_libs() + "; decide_query_onnx 127.0.0.1 %d choice "
                         "'state' 'Which team handles invoices?' "
                         "'{\"billing\":\"x\",\"legal\":\"y\"}'" % onnx_port, env)
        if rc != 0:
            problems.append("CLI decide_query_onnx with LLMCTL_DECIDE_API_KEY set "
                            "against keyed runtime exit=%d: %s" % (rc, out.strip()[-90:]))
        self.check(problems, "gateway --backend-engine onnx --api-key K ; POST /v1/systemone "
                   "Bearer K ; decide_query_onnx -> keyed onnx_server", "key honoured end to end")

    # ---- D-03 ----------------------------------------------------------
    def test_d03(self):
        problems = []
        K = R.SENTINEL
        port = R.free_port()
        p = R.start_onnx(port, _model_dir(self.tmp), ["--api-key", K])
        argv = open("/proc/%d/cmdline" % p.pid, "rb").read().decode()
        if K in argv:
            problems.append("key present in /proc/<pid>/cmdline of onnx_server")
        gw = R.start_gateway(R.free_port(), port, ["--api-key", K])
        if K in open("/proc/%d/cmdline" % gw.pid, "rb").read().decode():
            problems.append("key present in /proc/<pid>/cmdline of decide_gateway")
        env = R.bash_env(self.tmp)
        script = ("umask 022; " + R.source_libs() +
                  "; svc_write_env decide-nli onnx /usr/bin/python3 --port 1 --api-key %s; "
                  "stat -c '%%a' \"$LLMCTL_SERVICES_DIR\"/*.env" % K)
        rc, out = R.bash(script, env)
        mode = out.strip().splitlines()[-1] if out.strip() else "?"
        if rc != 0 or int(mode, 8) & 0o077:
            problems.append("service env file holding the key has mode %s (rc=%d), not owner-only"
                            % (mode, rc))
        self.check(problems, "start onnx_server/decide_gateway --api-key K; read /proc/pid/cmdline; "
                   "svc_write_env ... --api-key K; stat env file", "key not exposed; env file 0600", rc)

    # ---- D-04 ----------------------------------------------------------
    def test_d04(self):
        problems = []
        env = R.bash_env(self.tmp, {"LLMCTL_DRY_RUN": "1"})
        rc, out = R.bash(R.source_libs() + "; sched_build_launch decide-nli cpu 8096 512 0 1 auto f16; "
                         "printf 'ARG=%s\\n' \"${SCHED_ARGS[@]}\"", env)
        args = [l[4:] for l in out.splitlines() if l.startswith("ARG=")]
        host = args[args.index("--host") + 1] if "--host" in args else "?"
        if host != "127.0.0.1":
            problems.append("scheduler launches encoder runtime with --host %s by default (rc=%d)"
                            % (host, rc))
        port = R.free_port()
        R.start_onnx(port, _model_dir(self.tmp), ["--api-key", R.SENTINEL])
        st, _h, body = R.http(port, "GET", "/health")
        if "profile" in body:
            problems.append("unauthenticated onnx /health leaks profile name: %s" % body)
        gwp = R.free_port()
        R.start_gateway(gwp, port, ["--backend-engine", "onnx", "--api-key", R.SENTINEL])
        st, _h, body = R.http(gwp, "GET", "/healthz")
        if "profile" in body:
            problems.append("unauthenticated gateway /healthz leaks profile name: %s" % body)
        self.check(problems, "sched_build_launch decide-nli (default env); GET /health, /healthz "
                   "without credentials", "loopback default and no leak", rc)

    # ---- D-05 ----------------------------------------------------------
    def test_d05(self):
        victim = R.spawn(["sleep", "300"])
        env = R.bash_env(self.tmp)
        os.makedirs(env["LLMCTL_RUNTIME_DIR"], exist_ok=True)
        with open(os.path.join(env["LLMCTL_RUNTIME_DIR"], "decide-gateway.pid"), "w") as f:
            f.write("%d\n" % victim.pid)
        rc, out = R.bash(R.source_libs() + "; decide_serve --stop", env)
        time.sleep(0.3)
        alive = victim.poll() is None
        problems = [] if alive else [
            "decide serve --stop (rc=%d) TERM/KILLed unrelated process (a 'sleep 300' we "
            "started) because its PID was in the gateway pidfile" % rc]
        self.check(problems, "pidfile -> unrelated 'sleep 300' pid; decide_serve --stop",
                   "unrelated process left alone", rc)

    # ---- D-06 ----------------------------------------------------------
    def test_d06(self):
        self.evidence("python3 -c 'import onnxruntime, sentencepiece'",
                      "OPEN item addressed by US3: no real-model inference can run offline on "
                      "this host (onnxruntime/sentencepiece absent, no multi-GB models allowed)", 0)
        raise unittest.SkipTest("real-model evidence not obtainable offline")

    # ---- D-07 ----------------------------------------------------------
    def test_d07(self):
        d = _model_dir(self.tmp)
        open(os.path.join(d, "model.onnx"), "wb").write(b"stub")
        open(os.path.join(d, "spm.model"), "wb").write(b"stub")
        port = R.free_port()
        R.start_onnx(port, d, stubs=True)   # real OnnxModel; stubbed ORT/spm backends
        try:
            st, _h, body = R.http(port, "POST", "/v1/systemone", BODY)
            problems = [] if st >= 400 else ["unexpected %d" % st]
        except Exception as exc:  # RemoteDisconnected etc.
            problems = ["model returned 2 logits (not 3) -> SystemExit in request thread -> "
                        "no HTTP response, connection dropped (%s)" % type(exc).__name__]
        self.check(problems, "onnx_server (real OnnxModel, stub onnxruntime returning 2 logits); "
                   "POST /v1/systemone", "HTTP error response received")

    # ---- D-08 ----------------------------------------------------------
    def test_d08(self):
        problems = []
        onnx_port, gw_port = R.free_port(), R.free_port()
        R.start_onnx(onnx_port, _model_dir(self.tmp))
        R.start_gateway(gw_port, onnx_port)
        for label, port in (("onnx_server", onnx_port), ("decide_gateway", gw_port)):
            for raw in (b"[1,2,3]", b'"just a string"'):
                try:
                    st, _h, _b = R.http(port, "POST", "/v1/systemone", raw=raw)
                    if st != 400:
                        problems.append("%s non-object body %r -> %d (want 400)" % (label, raw, st))
                except Exception as exc:
                    problems.append("%s non-object JSON %r -> connection dropped (%s)"
                                    % (label, raw, type(exc).__name__))
        self.check(problems, "POST /v1/systemone with body [1,2,3] and \"str\" to onnx_server and "
                   "decide_gateway", "400 returned")

    # ---- D-09 ----------------------------------------------------------
    def test_d09(self):
        problems = []
        onnx_port, gw_port, dead = R.free_port(), R.free_port(), R.free_port()
        R.start_onnx(onnx_port, _model_dir(self.tmp))
        R.start_gateway(gw_port, dead)          # backend port: nothing listens
        socks = []
        for label, port in (("onnx_server", onnx_port), ("decide_gateway", gw_port)):
            s = socket.create_connection(("127.0.0.1", port), 3)
            s.sendall(b"POST /v1/systemone HTTP/1.1\r\nHost: x\r\nContent-Length: 200\r\n")
            socks.append((label, s))
        st, _h, body = R.http(gw_port, "POST", "/v1/systemone", BODY)
        if st == 502 and ("Errno" in body or "urlopen" in body or str(dead) in body):
            problems.append("502 body echoes backend exception text: %s" % body[:110])
        time.sleep(6)
        for label, s in socks:
            s.settimeout(0.5)
            try:
                data = s.recv(10)
                closed = data == b""
            except socket.timeout:
                closed = False
            except OSError:
                closed = True
            s.close()
            if not closed:
                problems.append("%s keeps a half-sent request open >6s (no socket timeout)" % label)
        self.check(problems, "half-sent headers held 6s on both servers; gateway with dead backend "
                   "port -> 502 body", "slow client closed, error text generic")

    # ---- D-10 ----------------------------------------------------------
    def test_d10(self):
        port = R.free_port()
        R.start_onnx(port, _model_dir(self.tmp), extra_env={"LLMCTL_DECIDE_MAX_OPTIONS": "3"})
        crit = {"o%d" % i: "option %d" % i for i in range(8)}
        st, _h, body = R.http(port, "POST", "/v1/systemone",
                              {"state": "s", "questions": {"q": {
                                  "type": "choice", "instructions": "pick", "criteria": crit}}})
        problems = [] if st == 400 else [
            "LLMCTL_DECIDE_MAX_OPTIONS=3 ignored by encoder runtime: 8-option request -> %d "
            "(8 encoder passes executed)" % st]
        self.check(problems, "LLMCTL_DECIDE_MAX_OPTIONS=3 onnx_server; POST 8-option choice",
                   "request rejected with 400")

    # ---- D-11 ----------------------------------------------------------
    def test_d11(self):
        problems = []
        got = []

        class H(BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                got.append(self.rfile.read(n))
                self.send_response(500)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *a):
                pass
        port = R.free_port()
        try:
            srv = HTTPServer(("127.0.0.2", port), H)
        except OSError as exc:
            self.evidence("bind 127.0.0.2", str(exc))
            raise unittest.SkipTest("cannot bind 127.0.0.2: %s" % exc)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        env = R.bash_env(self.tmp, {"LLMCTL_DECIDE_BACKEND_HOST": "127.0.0.2",
                                    "LLMCTL_DECIDE_BACKEND_PORT": str(port),
                                    "LLMCTL_DECIDE_TIMEOUT": "5"})
        rc, out = R.bash(R.source_libs() + "; decide_ask --profile decide-tiny --type noul "
                         "--state USERSTATE-MARKER --instructions 'is it ok?'", env)
        srv.shutdown()
        if any(b"USERSTATE-MARKER" in g for g in got):
            problems.append("env override LLMCTL_DECIDE_BACKEND_HOST redirected user state to a "
                            "non-profile host (127.0.0.2) in the production path")
        # fake-model seam: garbage "model" accepted as verified
        rc2, out2, fixture_note = _download_toy(self, fake=True)
        if rc2 == 0 and "downloaded and verified" in out2:
            problems.append("LLMCTL_ONNX_FAKE=1 lets download_profile report 'downloaded and "
                            "verified' for a non-ONNX payload (model never opened)")
        elif rc2 == -999:
            problems.append("ERRORHARNESS " + out2)
        self.check(problems, "decide_ask with LLMCTL_DECIDE_BACKEND_HOST=127.0.0.2; "
                   "LLMCTL_ONNX_FAKE=1 download_profile toy-onnx", "seams not honoured in production",
                   rc)

    # ---- D-12 ----------------------------------------------------------
    def test_d12(self):
        if _have_ort():
            raise unittest.SkipTest("onnxruntime+sentencepiece installed: skip branch not reachable")
        rc, out, _ = _download_toy(self, fake=False)
        problems = []
        if rc == 0 and "downloaded and verified" in out:
            problems.append("download_profile exit 0 and prints 'downloaded and verified' although "
                            "the onnx smoke test was SKIPPED (missing deps)")
        self.check(problems, "download_profile toy-onnx (no fake seam, onnxruntime absent)",
                   "no verified claim after skipped smoke", rc)

    # ---- D-13 ----------------------------------------------------------
    def test_d13(self):
        env = R.bash_env(self.tmp)
        rc, out = R.bash(R.source_libs() + "; catalog_files decide-nli", env)
        nosha = [l.split("|")[0] for l in out.splitlines()
                 if l.count("|") == 3 and l.split("|")[2] == ""]
        problems = []
        if nosha:
            problems.append("decide-nli catalog files without pinned sha256 (trust-on-first-use "
                            "via HF API): %s" % ", ".join(nosha))
        self.check(problems, "catalog_files decide-nli", "all files hash-pinned", rc)

    # ---- D-14 ----------------------------------------------------------
    def test_d14(self):
        d = _model_dir(self.tmp, "mod")
        port = R.free_port()
        shim = os.path.join(self.tmp, "bin")
        os.makedirs(shim)
        real = shutil.which("curl")
        with open(os.path.join(shim, "curl"), "w") as f:   # slows POST probes only (timing harness)
            f.write('#!/bin/bash\ncase " $* " in *" -X "*) sleep 8;; esac\nexec %s "$@"\n' % real)
        os.chmod(os.path.join(shim, "curl"), 0o755)
        env = R.bash_env(self.tmp, {"LLMCTL_ONNX_FAKE": "1", "LLMCTL_SMOKE": "1",
                                    "LLMCTL_SMOKE_PORT": str(port), "LLMCTL_SMOKE_TIMEOUT": "20",
                                    "PATH": shim + ":" + os.environ["PATH"]})
        script = (R.source_libs() + "; ensure_state_dirs; _DL_EVIDENCE=\"$LLMCTL_VERIFY_DIR/x.log\"; "
                  ": > \"$_DL_EVIDENCE\"; _dl_smoke_test_onnx toy %s" % d)
        bp = R.spawn(["bash", "-c", script], env=env)
        server_pid = None
        end = time.time() + 20
        while time.time() < end and server_pid is None:
            for pid in os.listdir("/proc"):
                if not pid.isdigit():
                    continue
                try:
                    stat = open("/proc/%s/stat" % pid).read()
                    ppid = int(stat.rsplit(")", 1)[1].split()[1])
                    cmd = open("/proc/%s/cmdline" % pid, "rb").read().decode(errors="replace")
                except OSError:
                    continue
                if ppid == bp.pid and "onnx_server.py" in cmd and str(port) in cmd:
                    server_pid = int(pid)
            time.sleep(0.2)
        if server_pid is None:
            self.evidence("_dl_smoke_test_onnx", "smoke server pid not found")
            self.fail("ERRORHARNESS smoke server never started")
        time.sleep(1.5)                          # inside the (slowed) first probe
        os.kill(bp.pid, signal.SIGTERM)
        bp.wait(timeout=10)
        time.sleep(1.0)
        try:
            os.kill(server_pid, 0)
            orphan = True
        except ProcessLookupError:
            orphan = False
        if orphan:
            R.kill_pid(server_pid)
        problems = ["after SIGTERM to the smoke-test shell the onnx_server child (pid %d) is "
                    "still running as an orphan" % server_pid] if orphan else []
        self.check(problems, "_dl_smoke_test_onnx (LLMCTL_ONNX_FAKE=1, probes slowed); SIGTERM "
                   "the shell mid-probe; check child", "child cleaned up on interrupt")

    # ---- D-15 ----------------------------------------------------------
    def test_d15(self):
        env = R.bash_env(self.tmp, {"LLMCTL_DRY_RUN": "1", "LLMCTL_FAKE_HW": os.path.join(
            R.FIX, "hw-baseline.json")})
        rc, out = R.bash(R.source_libs() + "; svc_install; grep -E '^Memory(High|Max)=' "
                         "\"$LLMCTL_UNIT_DIR/llmctl-onnx@.service\"; "
                         "grep -c '2026-09-15' lib/service_linux.sh", env)
        # Register re-assessment (plan review): follows recorded policy, not a defect (OD-14).
        # Characterisation: unit carries MemoryHigh==MemoryMax and the policy note exists.
        lines = [l for l in out.splitlines() if l.startswith("Memory")]
        ok = len(lines) == 2 and len({l.split("=")[1] for l in lines}) == 1 \
            and int(out.strip().splitlines()[-1]) >= 1
        self.evidence("svc_install; grep Memory* llmctl-onnx@.service",
                      "re-assessed as recorded operator policy (2026-09-15), not a defect; "
                      "unit lines: " + ",".join(lines), rc)
        self.assertTrue(ok, "characterisation of recorded policy failed: " + out[-150:])


# ---- helpers ------------------------------------------------------------
def R_find_tokenizer():
    for root in (os.path.expanduser("~/.local/share/llmctl/models/decide-nli"),
                 os.path.expanduser("~/.cache/huggingface")):
        for dp, _dn, fn in os.walk(root) if os.path.isdir(root) else []:
            if "spm.model" in fn:
                try:
                    import sentencepiece  # noqa: F401
                    return True
                except ImportError:
                    return False
    return False


def _have_ort():
    import subprocess
    r = subprocess.run([sys.executable, "-c", "import onnxruntime, sentencepiece"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


def _download_toy(test, fake):
    """Real download_profile against a local HTTP fixture and a toy (non-ONNX)
    payload.  -> (rc, output, note)."""
    www = os.path.join(test.tmp, "www" + ("f" if fake else "n"))
    rev = "0123456789abcdef0123456789abcdef01234567"
    base = os.path.join(www, "toy", "onnx", "resolve", rev, "onnx")
    os.makedirs(base)
    files = {"model.onnx": b"llmctl red-test payload - NOT a real ONNX protobuf\n",
             "spm.model": b"llmctl red-test payload - NOT a real spm\n"}
    ents = []
    for n, data in files.items():
        open(os.path.join(base, n), "wb").write(data)
        ents.append({"name": "onnx/" + n, "size": len(data),
                     "sha256": hashlib.sha256(data).hexdigest(),
                     "role": "model" if n.endswith("onnx") else "tokenizer"})
    port = R.free_port()
    cat = os.path.join(test.tmp, "cat%s.json" % fake)
    json.dump({"version": 1, "notes": "red", "ports": {"toy-onnx": 9996}, "profiles": {"toy-onnx": {
        "engine": "onnx", "capability": ["decide"], "min_tier": "below-minimum", "port": 9996,
        "hf_repo": "toy/onnx", "hf_revision": rev, "desc": "red toy",
        "defaults": {"ctx": 512, "ngl": 0, "parallel": 1, "flash_attn": "off"},
        "files": ents}}}, open(cat, "w"))
    http_p = R.spawn([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1",
                      "--directory", www])
    if not R.wait_port(port, http_p):
        return -999, "fixture http server failed", ""
    sp = R.free_port()
    env = R.bash_env(test.tmp + ("/fk" if fake else "/nf"), {
        "LLMCTL_HF_BASE": "http://127.0.0.1:%d" % port, "LLMCTL_CATALOG": cat,
        "LLMCTL_SMOKE": "1", "LLMCTL_SMOKE_PORT": str(sp), "LLMCTL_SMOKE_TIMEOUT": "20",
        **({"LLMCTL_ONNX_FAKE": "1"} if fake else {})})
    rc, out = R.bash(R.source_libs() + "; download_profile toy-onnx", env, timeout=90)
    return rc, out, ""


# ---- runner -------------------------------------------------------------
class Result(unittest.TextTestResult):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        self.status = {}

    def _key(self, t):
        return t.id().split(".")[-1]

    def addSuccess(self, t):
        super().addSuccess(t); self.status[self._key(t)] = ("NOT-REPRODUCED", "")

    def addFailure(self, t, err):
        super().addFailure(t, err)
        msg = str(err[1])
        st = "ERROR" if msg.startswith("ERRORHARNESS") else "RED"
        self.status[self._key(t)] = (st, msg)

    def addError(self, t, err):
        super().addError(t, err); self.status[self._key(t)] = ("ERROR", repr(err[1]))

    def addSkip(self, t, reason):
        super().addSkip(t, reason); self.status[self._key(t)] = ("SKIP", reason)


def main(out_path, only=None):
    suite = unittest.TestSuite()
    names = sorted(n for n in dir(T) if n.startswith("test_d"))
    for n in names:
        if not only or n[5:] in only:
            suite.addTest(T(n))
    res = unittest.TextTestRunner(stream=sys.stderr, verbosity=2, resultclass=Result).run(suite)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    cmd_default = {"test_d01": "n/a"}
    with open(out_path, "w") as fh:
        for n in names:
            if n not in res.status:
                continue
            st, msg = res.status[n]
            ev = RedBase.EVID.get(n, {})
            excerpt = ev.get("key_output_excerpt") or R.redact(msg)
            rec = {"id": "D-%s" % n[6:], "status": st,
                   "command": ev.get("command") or "python3 tests/red/py/test_defects_d01_d15.py %s" % n,
                   "exit_code": ev.get("exit_code"),
                   "key_output_excerpt": excerpt[:300]}
            if st == "ERROR":
                rec["key_output_excerpt"] = R.redact(msg)[:300]
            fh.write(json.dumps(rec) + "\n")
    return res.status


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(R.ROOT, "tests", "red", "results",
                                                             "d01_d15.jsonl")
    only = sys.argv[2:] or None
    status = main(out, only)
    codes = {s for s, _ in status.values()}
    sys.exit(2 if "ERROR" in codes else (1 if "RED" in codes else 0))
