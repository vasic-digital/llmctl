"""Shared helpers for the RED defect tests (stdlib only)."""
import atexit
import http.client as _hc
import json
import os
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
LIB = os.path.join(ROOT, "lib")
FIX = os.path.join(ROOT, "tests", "fixtures")
STUBS = os.path.join(HERE, "stubs_d01_d15")
SENTINEL = "red-test-sentinel-not-a-real-key"
FORBIDDEN_PORTS = {8080, 8082, 8087, 8099}

_procs = []


def free_port():
    while True:
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        p = s.getsockname()[1]
        s.close()
        if p not in FORBIDDEN_PORTS:
            return p


def redact(text):
    return str(text).replace(SENTINEL, "<KEY>")


def clean_env(extra=None):
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("LLMCTL_") or k.startswith("LLMCTX_"):
            del env[k]
    env["NO_COLOR"] = "1"
    env.update(extra or {})
    return env


def spawn(argv, env=None, **kw):
    p = subprocess.Popen(argv, env=env or clean_env(), stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, **kw)
    _procs.append(p)
    return p


def kill_pid(pid):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            return
        for _ in range(20):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)


def reap_all():
    for p in _procs:
        if p.poll() is None:
            kill_pid(p.pid)
        try:
            p.wait(timeout=3)
        except Exception:
            pass
    del _procs[:]


atexit.register(reap_all)


def wait_port(port, proc=None, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        if proc is not None and proc.poll() is not None:
            return False
        try:
            socket.create_connection(("127.0.0.1", port), 0.3).close()
            return True
        except OSError:
            time.sleep(0.1)
    return False


def start_onnx(port, model_dir, extra_args=(), extra_env=None, stubs=False):
    env = clean_env({"LLMCTL_ONNX_FAKE": "1"} if not stubs else {})
    if stubs:
        env["PYTHONPATH"] = STUBS
    env.update(extra_env or {})
    p = spawn([sys.executable, os.path.join(LIB, "onnx_server.py"),
               "--model-dir", model_dir, "--port", str(port),
               "--profile", "red-onnx", "--host", "127.0.0.1"] + list(extra_args),
              env=env)
    if not wait_port(port, p):
        raise RuntimeError("onnx_server did not start: %s" % redact(_drain(p)))
    return p


def start_gateway(port, backend_port, extra_args=(), extra_env=None):
    env = clean_env(extra_env)
    p = spawn([sys.executable, os.path.join(LIB, "decide_gateway.py"),
               "--port", str(port), "--bind-host", "127.0.0.1",
               "--backend-port", str(backend_port), "--profile", "red-gw"]
              + list(extra_args), env=env)
    if not wait_port(port, p):
        raise RuntimeError("gateway did not start: %s" % redact(_drain(p)))
    return p


def _drain(p):
    try:
        p.kill()
        return p.communicate(timeout=3)[0].decode("utf-8", "replace")[-300:]
    except Exception:
        return ""


def http(port, method, path, body=None, headers=None, raw=None, timeout=10):
    """-> (status, headers, body_text). Raises on connection drop."""
    c = _hc.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        data = raw if raw is not None else (
            json.dumps(body).encode() if body is not None else None)
        hdrs = {"Content-Type": "application/json"}
        hdrs.update(headers or {})
        c.request(method, path, body=data, headers=hdrs)
        r = c.getresponse()
        return r.status, dict(r.getheaders()), r.read().decode("utf-8", "replace")
    finally:
        c.close()


def bash(script, env=None, timeout=60):
    """Run a bash snippet from the repo root. -> (rc, combined output)."""
    r = subprocess.run(["bash", "-c", script], cwd=ROOT, env=env or clean_env(),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=timeout)
    return r.returncode, r.stdout.decode("utf-8", "replace")


LIBS = ("common os_detect hardware catalog decide scheduler "
        "service_linux download")


def bash_env(tmp, extra=None):
    e = clean_env({
        "LLMCTL_ROOT": ROOT,
        "LLMCTL_STATE_DIR": tmp + "/state",
        "LLMCTL_RUNTIME_DIR": tmp + "/state/run",
        "LLMCTL_CONFIG_DIR": tmp + "/config",
        "LLMCTL_DATA_DIR": tmp + "/data",
        "LLMCTL_MODELS_DIR": tmp + "/models",
        "LLMCTL_LOG_DIR": tmp + "/state/logs",
        "LLMCTL_VERIFY_DIR": tmp + "/state/verify",
        "LLMCTL_SERVICES_DIR": tmp + "/state/services",
        "LLMCTL_UNIT_DIR": tmp + "/systemd-user",
        "LLMCTL_PLIST_DIR": tmp + "/LaunchAgents",
        "LLMCTL_READY_TIMEOUT": "0",
    })
    os.makedirs(tmp + "/state/run", exist_ok=True)
    e.update(extra or {})
    return e


def source_libs(names=LIBS):
    return "set -euo pipefail; cd '%s'; %s" % (
        ROOT, "; ".join("source lib/%s.sh" % n for n in names.split()))
