"""Shared helpers for the RED (failing-first) defect tests D-16..D-32.

stdlib only. Never prints credentials. Starts/kills only its own PIDs.
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import http.client as httpclient

sys.dont_write_bytecode = True

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
FORBIDDEN_PORTS = {8080, 8082, 8087, 8099}
DUMMY_KEY = "red-dummy-key-0000"  # not a credential; a throwaway test constant

_procs = []


def free_port():
    while True:
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        p = s.getsockname()[1]
        s.close()
        if p not in FORBIDDEN_PORTS:
            return p


def scrub(text):
    text = re.sub(r"Bearer\s+\S+", "Bearer <redacted>", text or "")
    text = text.replace(DUMMY_KEY, "<dummy-key>")
    return text


def base_env(extra=None):
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["NO_COLOR"] = "1"
    for k in list(env):
        if k.startswith("LLMCTL_") and k not in ("LLMCTL_ROOT",):
            del env[k]
    if extra:
        env.update(extra)
    return env


def tmp_dirs():
    t = tempfile.mkdtemp(prefix="llmctl-red-")
    d = {
        "LLMCTL_STATE_DIR": t + "/state", "LLMCTL_RUNTIME_DIR": t + "/state/run",
        "LLMCTL_CONFIG_DIR": t + "/config", "LLMCTL_DATA_DIR": t + "/data",
        "LLMCTL_MODELS_DIR": t + "/models", "LLMCTL_LOG_DIR": t + "/state/logs",
        "LLMCTL_VERIFY_DIR": t + "/state/verify", "LLMCTL_SERVICES_DIR": t + "/state/services",
        "LLMCTL_UNIT_DIR": t + "/systemd-user", "LLMCTL_PLIST_DIR": t + "/LaunchAgents",
        "LLMCTL_READY_TIMEOUT": "0",
    }
    os.makedirs(d["LLMCTL_RUNTIME_DIR"], exist_ok=True)
    os.makedirs(d["LLMCTL_LOG_DIR"], exist_ok=True)
    d["_tmp"] = t
    return d


LIBS = ("common", "os_detect", "hardware", "catalog", "decide", "scheduler", "engine")


def bash_run(script, extra_env=None, timeout=60):
    """Run `script` in a real bash that has sourced the real lib/*.sh."""
    dirs = tmp_dirs()
    env = base_env({k: v for k, v in dirs.items() if not k.startswith("_")})
    env["LLMCTL_ROOT"] = ROOT
    if extra_env:
        env.update(extra_env)
    pre = "set -uo pipefail\n" + "".join(
        'source "%s/lib/%s.sh"\n' % (ROOT, lib) for lib in LIBS)
    p = subprocess.run(["bash", "-c", pre + script], env=env, cwd=ROOT,
                       capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr, dirs


def start(argv, env=None, cwd=None):
    p = subprocess.Popen(argv, env=env or base_env(), cwd=cwd or ROOT,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _procs.append(p)
    return p


def stop(p):
    if p is None or p.poll() is not None:
        return
    p.terminate()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait(timeout=5)


def cleanup_all():
    for p in _procs:
        stop(p)


def http(method, url, body=None, headers=None, timeout=10):
    """-> (status|None, headers dict, text). Transport errors -> (None,{},msg)."""
    data = None
    h = dict(headers or {})
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        h.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode("utf-8", "replace")
    except (urllib.error.URLError, httpclient.HTTPException, OSError) as e:
        return None, {}, "%s: %s" % (type(e).__name__, e)


def wait_http(url, tries=60):
    for _ in range(tries):
        s, _, _ = http("GET", url, timeout=2)
        if s is not None:
            return True
        time.sleep(0.1)
    return False


def write_model_dir(d, with_spm=True, with_tokjson=False):
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "model.onnx"), "wb").write(b"\0")
    if with_spm:
        open(os.path.join(d, "spm.model"), "wb").write(b"\0")
    if with_tokjson:
        open(os.path.join(d, "tokenizer.json"), "w").write("{}")
    json.dump({"id2label": {"0": "entailment", "1": "neutral", "2": "contradiction"}},
              open(os.path.join(d, "config.json"), "w"))


NOUL_BODY = {"model": "m", "state": "The invoice is overdue.",
             "questions": {"q": {"type": "noul", "instructions": "Is it overdue?"}}}
