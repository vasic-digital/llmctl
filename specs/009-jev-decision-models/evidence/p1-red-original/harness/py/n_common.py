"""n_common.py - shared helpers for the N-01..N-29 failing-first (RED) tests.

stdlib only. Every test method is wrapped by @defect("N-xx"): it returns an
Outcome (NOT-REPRODUCED / HARDENING / SKIP) or raises Red / Skip / Hardening.
Any other exception is recorded as ERROR (never silently as PASS).
Results are appended to the JSONL file named by $RED_RESULTS_FILE.

Stand-ins: ONLY model backends (existing tests/fixtures/decide_server.py,
the tiny recording llama stand-in in n_backend.py, and the LLMCTL_ONNX_FAKE
seam of lib/onnx_server.py). Code under test is always the real code.
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import traceback

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
LIB = os.path.join(ROOT, "lib")
FIX = os.path.join(ROOT, "tests", "fixtures")
RESULTS = os.environ.get("RED_RESULTS_FILE") or os.path.join(
    ROOT, "tests", "red", "results", "n01_n29.jsonl")
SCRATCH = os.environ.get("RED_SCRATCH") or tempfile.mkdtemp(prefix="red-n-")

# PIDs we spawned (killed by PID only - never by name).
_PIDS = []


class Outcome(Exception):
    status = "NOT-REPRODUCED"

    def __init__(self, command="", exit_code=None, excerpt=""):
        Exception.__init__(self, excerpt)
        self.command = command
        self.exit_code = exit_code
        self.excerpt = excerpt


class Red(Outcome):
    status = "RED"


class Skip(Outcome):
    status = "SKIP"


class Hardening(Outcome):
    status = "HARDENING"


class NotReproduced(Outcome):
    status = "NOT-REPRODUCED"


def clip(text, n=300):
    text = re.sub(r"\s+", " ", str(text)).strip()
    return text if len(text) <= n else text[: n - 3] + "..."


def record(id_, status, command, exit_code, excerpt):
    rec = {"id": id_, "status": status, "command": clip(command, 300),
           "exit_code": exit_code, "key_output_excerpt": clip(excerpt, 300)}
    os.makedirs(os.path.dirname(RESULTS), exist_ok=True)
    with open(RESULTS, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec) + "\n")
    return rec


def defect(id_):
    """Decorator: run the test body, record exactly one outcome for id_."""
    def deco(fn):
        def run(self):
            try:
                res = fn(self)
                if isinstance(res, Outcome):
                    raise res
                raise NotReproduced("", None, "test body returned without a verdict")
            except Outcome as o:
                record(id_, o.status, o.command, o.exit_code, o.excerpt)
            except Exception:  # instrument/test bug -> ERROR, never PASS
                record(id_, "ERROR", "", None, traceback.format_exc()[-280:])
        run.__name__ = fn.__name__
        run.__doc__ = fn.__doc__
        return run
    return deco


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def clean_env(extra=None):
    """Hermetic LLMCTL_* env in a fresh temp dir (mirrors tests/helpers.sh)."""
    tmp = tempfile.mkdtemp(prefix="env-", dir=SCRATCH)
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("LLMCTL_"):
            del env[k]
    env.update({
        "LLMCTL_STATE_DIR": tmp + "/state", "LLMCTL_RUNTIME_DIR": tmp + "/state/run",
        "LLMCTL_CONFIG_DIR": tmp + "/config", "LLMCTL_DATA_DIR": tmp + "/data",
        "LLMCTL_MODELS_DIR": tmp + "/models", "LLMCTL_LOG_DIR": tmp + "/state/logs",
        "LLMCTL_VERIFY_DIR": tmp + "/state/verify",
        "LLMCTL_SERVICES_DIR": tmp + "/state/services",
        "LLMCTL_UNIT_DIR": tmp + "/systemd-user", "LLMCTL_PLIST_DIR": tmp + "/LaunchAgents",
        "NO_COLOR": "1", "LLMCTL_READY_TIMEOUT": "0",
        "PYTHONDONTWRITEBYTECODE": "1",
    })
    os.makedirs(env["LLMCTL_RUNTIME_DIR"], exist_ok=True)
    if extra:
        env.update(extra)
    env["_TMP"] = tmp
    return env


def run(cmd, env=None, stdin=None, timeout=60, cwd=None):
    """-> (rc, stdout, stderr). rc=-999 on timeout."""
    e = dict(env or os.environ)
    e.pop("_TMP", None)
    kw = {"input": stdin} if stdin is not None else {"stdin": subprocess.DEVNULL}
    try:
        p = subprocess.run(cmd, env=e, capture_output=True, timeout=timeout,
                           cwd=cwd, text=True, errors="replace", **kw)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -999, "", "TIMEOUT after %ss" % timeout


def llmctl(args, env=None, stdin=None, timeout=60):
    return run([os.path.join(ROOT, "bin", "llmctl")] + list(args),
               env=env, stdin=stdin, timeout=timeout)


def spawn(cmd, env=None, logname="proc"):
    e = dict(env or os.environ)
    e.pop("_TMP", None)
    log = open(os.path.join(SCRATCH, "%s-%d.log" % (logname, len(_PIDS))), "wb")
    p = subprocess.Popen(cmd, env=e, stdout=log, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL)
    _PIDS.append(p)
    return p


def wait_port(port, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def kill_all():
    for p in _PIDS:
        try:
            p.terminate()
            p.wait(timeout=3)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass


def http(method, port, path, body=None, headers=None, timeout=10, raw_body=None):
    """-> (status, headers_dict_lowercase, body_text). status=None + text=exc
    on transport failure (dropped connection etc.)."""
    import http.client
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        h = dict(headers or {})
        data = raw_body
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            h.setdefault("Content-Type", "application/json")
        conn.request(method, path, body=data, headers=h)
        r = conn.getresponse()
        txt = r.read().decode("utf-8", "replace")
        return r.status, {k.lower(): v for k, v in r.getheaders()}, txt
    except Exception as exc:  # RemoteDisconnected, timeout, reset ...
        return None, {}, "%s: %s" % (type(exc).__name__, exc)
    finally:
        conn.close()


def load_module(name, path):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def start_llama_stub():
    """existing fixture tests/fixtures/decide_server.py -> port"""
    port = free_port()
    spawn([sys.executable, "-I", os.path.join(FIX, "decide_server.py"), str(port)],
          logname="llamastub")
    if not wait_port(port):
        raise RuntimeError("decide_server.py stub did not start")
    return port


def start_onnx_fake(extra_args=(), env_extra=None, model_dir=None):
    """real lib/onnx_server.py under the LLMCTL_ONNX_FAKE seam -> port"""
    port = free_port()
    md = model_dir or tempfile.mkdtemp(prefix="onnxmodel-", dir=SCRATCH)
    env = dict(os.environ)
    env["LLMCTL_ONNX_FAKE"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.update(env_extra or {})
    spawn([sys.executable, "-I", os.path.join(LIB, "onnx_server.py"),
           "--model-dir", md, "--port", str(port), "--host", "127.0.0.1",
           "--profile", "toy-onnx"] + list(extra_args), env=env, logname="onnx")
    if not wait_port(port):
        raise RuntimeError("onnx_server.py did not start")
    return port


def start_gateway(backend_port, engine="llama", extra_args=(), env_extra=None):
    """real lib/decide_gateway.py -> port (bound 127.0.0.1)"""
    port = free_port()
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.update(env_extra or {})
    spawn([sys.executable, "-I", os.path.join(LIB, "decide_gateway.py"),
           "--port", str(port), "--bind-host", "127.0.0.1",
           "--backend-host", "127.0.0.1", "--backend-port", str(backend_port),
           "--profile", "toy", "--backend-engine", engine] + list(extra_args),
          env=env, logname="gateway")
    if not wait_port(port):
        raise RuntimeError("decide_gateway.py did not start")
    return port


SYSTEMONE_CHOICE = {"state": "Routing.", "questions": {"q": {
    "type": "choice", "instructions": "Which team handles invoices?",
    "criteria": {"billing": "handles invoices", "legal": "contracts"}}}}
