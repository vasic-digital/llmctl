#!/usr/bin/env python3
"""Append-only JSONL evidence writer implementing contracts/evidence-schema.md.

One record per check -> <run_dir>/evidence.jsonl, raw captures -> <run_dir>/raw/.
Records carry sha256 of stdout/stderr, a monotonic seq (in the id) and a
prev_sha256 hash chain (rule 8). Values that look like secrets (registered
literals, PEM private keys, key-like tokens) are REFUSED - nothing is written.
"""
import hashlib
import json
import os
import re
import sys
import time

from tests.evidence import leak_scan

CLASSES = ("real-model", "real-component", "stand-in", "not-exercised")
VANTAGES = ("host", "podman-bridge", "slirp4netns", "second-machine", "none")
CLIENTS = ("curl", "python-urllib", "python-requests", "node-fetch", "go-nethttp", "chromium",
           "llmctl-cli", "typesafe-sdk-py", "typesafe-sdk-js",
           # transport-level tools used by the FR-070 negative TLS script (tests/matrix/negative_tls.py)
           "python-ssl", "openssl-s_client", "go-crypto-tls")
RESULTS = ("pass", "fail", "not-exercised")
ZERO = "0" * 64
FILE = "evidence.jsonl"


class EvidenceError(ValueError):
    pass


class SecretRefused(EvidenceError):
    """Raised (message carries only the field + kind, never the value)."""


def _client_ok(c):
    return c in CLIENTS or bool(re.fullmatch(r"agent:[A-Za-z0-9._-]+", c or ""))


class EvidenceWriter:
    def __init__(self, run_dir, run_id, secrets=None):
        self.dir = run_dir
        self.run_id = run_id
        self._secrets = [s for s in (secrets or []) if s]
        os.makedirs(os.path.join(run_dir, "raw"), exist_ok=True)
        self.path = os.path.join(run_dir, FILE)

    def _state(self):
        """(count, hash of last raw line) from the file on disk (resume-safe)."""
        if not os.path.isfile(self.path):
            return 0, ZERO
        with open(self.path, "rb") as f:
            lines = [l for l in f.read().split(b"\n") if l.strip()]
        if not lines:
            return 0, ZERO
        return len(lines), hashlib.sha256(lines[-1]).hexdigest()

    def _check_secret(self, field, value):
        data = value if isinstance(value, bytes) else str(value).encode()
        hits = leak_scan.find_in_bytes(data, self._secrets)
        if hits:
            raise SecretRefused("refused: field %r contains secret-looking value (%s)" % (field, hits[0][0]))

    def append(self, requirement, command, cwd, env_names, exit_code, stdout, stderr,
               duration_ms, cls, vantage, client, result, reason=None):
        if cls not in CLASSES:
            raise EvidenceError("bad class %r" % (cls,))
        if vantage not in VANTAGES:
            raise EvidenceError("bad vantage %r" % (vantage,))
        if not _client_ok(client):
            raise EvidenceError("bad client %r" % (client,))
        if result not in RESULTS:
            raise EvidenceError("bad result %r" % (result,))
        if (result == "not-exercised") != (cls == "not-exercised"):
            raise EvidenceError("class not-exercised <=> result not-exercised")
        if result in ("fail", "not-exercised") and not reason:
            raise EvidenceError("reason required when result=%s" % result)
        stdout = stdout or b""
        stderr = stderr or b""
        if result == "pass" and not (stdout or stderr):
            raise EvidenceError("result=pass requires captured output")
        reqs = [requirement] if isinstance(requirement, str) else list(requirement)
        for field, val in (("command", command), ("cwd", cwd), ("reason", reason or ""),
                           ("requirement", " ".join(reqs)), ("stdout", stdout), ("stderr", stderr)):
            self._check_secret(field, val)

        count, prev = self._state()
        eid = "EV-%s-%04d" % (self.run_id, count + 1)
        artifacts = []
        for name, blob in (("stdout", stdout), ("stderr", stderr)):
            if blob:
                rel = "raw/%s-%s.txt" % (eid, name)
                with open(os.path.join(self.dir, rel), "wb") as f:
                    f.write(blob)
                artifacts.append(rel)
        rec = {
            "id": eid,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "requirement": reqs,
            "command": command,
            "cwd": cwd,
            "env_digest": "sha256:" + hashlib.sha256("\n".join(sorted(env_names or [])).encode()).hexdigest(),
            "exit_code": exit_code,
            "stdout_sha256": hashlib.sha256(stdout).hexdigest(),
            "stderr_sha256": hashlib.sha256(stderr).hexdigest(),
            "artifact_paths": artifacts,
            "duration_ms": duration_ms,
            "class": cls,
            "vantage": vantage,
            "client": client,
            "result": result,
            "prev_sha256": prev,
        }
        if reason:
            rec["reason"] = reason
        with open(self.path, "ab") as f:
            f.write(json.dumps(rec).encode() + b"\n")
            f.flush()
            os.fsync(f.fileno())
        return rec


def verify_chain(path):
    """Return a list of problems ([] = chain intact). Tail truncation needs SHA256SUMS."""
    problems = []
    with open(path, "rb") as f:
        lines = [l for l in f.read().split(b"\n") if l.strip()]
    prev = ZERO
    for i, raw in enumerate(lines, 1):
        try:
            rec = json.loads(raw)
        except ValueError:
            problems.append("line %d: not JSON" % i)
            prev = hashlib.sha256(raw).hexdigest()
            continue
        if rec.get("prev_sha256") != prev:
            problems.append("line %d: chain break (tamper, deletion or reorder)" % i)
        prev = hashlib.sha256(raw).hexdigest()
    return problems


def summarize(path):
    """Counts generated from JSONL; stand-ins never count as real behaviour."""
    s = {"total": 0, "real_pass": 0, "fail": 0, "not_exercised": 0, "excluded_stand_in": 0}
    with open(path) as f:
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            s["total"] += 1
            if r["class"] == "stand-in":
                s["excluded_stand_in"] += 1
            elif r["result"] == "pass":
                s["real_pass"] += 1
            elif r["result"] == "fail":
                s["fail"] += 1
            else:
                s["not_exercised"] += 1
    return s


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) != 2 or argv[0] not in ("verify-chain", "summarize"):
        print("usage: writer.py verify-chain|summarize evidence.jsonl", file=sys.stderr)
        return 2
    if argv[0] == "summarize":
        print(json.dumps(summarize(argv[1]), indent=2))
        return 0
    p = verify_chain(argv[1])
    for x in p:
        print(x)
    return 1 if p else 0


if __name__ == "__main__":
    sys.exit(main())
