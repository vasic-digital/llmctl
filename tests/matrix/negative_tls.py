#!/usr/bin/env python3
"""Negative transport tests (FR-070; SC-013): host name not covered, expired certificate, untrusted
authority, altered certificate, plain HTTP to the TLS port, outdated protocol versions, weak ciphers.

Each negative result is only accepted together with a POSITIVE CONTROL through the same tool and path
(good certificate, correct name -> connects); otherwise the instrument is blind and the case fails.
Tools: curl, python ssl, openssl s_client, and the Go crypto/tls probe built from refserver/main.go.
A case needs >= 1 tool that genuinely reached the server and saw the refusal; a tool that cannot even
offer the tested protocol records `not-exercised` with that reason (never a pass).

Targets: refserver variants started here (class stand-in), or a gateway started with bad certificates
by the operator through --variant-hook CMD (called `CMD start VARIANT` -> prints host:port, `CMD stop VARIANT`).

    python3 -B tests/matrix/negative_tls.py --run-dir RUNDIR [--cacert CA --variant-hook CMD]
"""
import argparse
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, ROOT)

from tests.evidence import leak_scan, manifest, writer  # noqa: E402
from tests.matrix import transport as T  # noqa: E402

VARIANTS = ("good", "wronghost", "expired", "untrusted", "altered")
# Wordings differ by TLS backend: OpenSSL-curl / python-ssl / openssl s_client ("unable to get local issuer",
# "has expired", ...) versus GnuTLS-curl, which prints libcurl's own `cause` strings ("certificate signer not
# trusted", "certificate has expired", the default "certificate error, no details available") inside
# "server verification failed: <cause>. (CAfile: ...)" (curl exit 60), and "certificate subject name 'x' does
# not match target hostname 'y'" (curl exit 60) for a name outside the SANs.  tests/fixtures/curl_gnutls/ holds
# recorded GnuTLS-curl lines that tests/test_matrix_harness.sh checks against these regexes.
WRONG_NAME_RX = r"no alternative certificate subject name|does not match|not valid for|Hostname mismatch|hostname mismatch|subject alternative|verify error:num=62"
NEG = {
    # case -> (variant, host name asked, error regex expected in the tool output)
    "hostname-not-covered": ("wronghost", "localhost", WRONG_NAME_RX),
    "expired-certificate": ("expired", "localhost", r"expired|verify error:num=10|not activated"),
    "untrusted-authority": ("untrusted", "localhost", r"unable to get local issuer|unable to verify|self.signed|issuer|verify error:num=(20|19|18|21)|unknown ca|signer not trusted|signer not found|signer not a CA|issuer is unknown|not trusted"),
    "altered-certificate": ("altered", "localhost", r"signature|unable to verify|decrypt|invalid|bad certificate|verify error:num=7|certificate verify failed|certificate error, no details available|server verification failed"),
}


class Srv:
    def __init__(self, work, binp, certs, variant, key):
        self.variant = variant
        pf = os.path.join(work, "port-" + variant)
        log = open(os.path.join(work, "log-" + variant), "wb")
        self.proc = subprocess.Popen(
            [binp, "serve", "--cert", os.path.join(certs, variant, "cert.pem"), "--key", os.path.join(certs, variant, "key.pem"),
             "--port-file", pf], env=dict(os.environ, REFSERVER_KEY=key), stdout=log, stderr=log, start_new_session=True)
        for _ in range(100):
            if os.path.exists(pf) and open(pf).read().strip():
                break
            if self.proc.poll() is not None:
                raise SystemExit("refserver %s exited early" % variant)
            time.sleep(0.1)
        self.port = int(open(pf).read().strip())

    def stop(self):
        pid = self.proc.pid
        if self.proc.poll() is None and pid > 1:
            try:
                os.killpg(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(pid, signal.SIGKILL)


def sh(argv, inp=None, timeout=20):
    t0 = time.time()
    try:
        p = subprocess.run(argv, input=inp, capture_output=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace"), int((time.time() - t0) * 1000)
    except subprocess.TimeoutExpired:
        return 124, "timeout", int((time.time() - t0) * 1000)


# ---- tools: each returns (connected: bool, output: str, ms: int, offered: bool)

def tool_curl(port, name, cacert, scheme="https", path="/healthz"):
    rc, out, ms = sh(["curl", "-sS", "--max-time", "10", "--cacert", cacert, "--resolve", "%s:%d:127.0.0.1" % (name, port),
                      "%s://%s:%d%s" % (scheme, name, port, path)])
    return rc == 0 and '"status"' in out, "curl rc=%d %s" % (rc, out.strip()[:300]), ms, True


def tool_python(port, name, cacert, **_):
    import socket
    import ssl
    t0 = time.time()
    try:
        raw = socket.create_connection(("127.0.0.1", port), timeout=8)
        with ssl.create_default_context(cafile=cacert).wrap_socket(raw, server_hostname=name) as s:
            s.sendall(("GET /healthz HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" % name).encode())
            data = b""
            while True:
                c = s.recv(4096)
                if not c:
                    break
                data += c
        ok = b'"status"' in data
        return ok, "python-ssl connected", int((time.time() - t0) * 1000), True
    except Exception as e:  # noqa: BLE001
        return False, "python-ssl %s: %s" % (type(e).__name__, str(e).replace("\n", " ")[:300]), int((time.time() - t0) * 1000), True


def tool_openssl(port, name, cacert, extra=()):
    rc, out, ms = sh(["openssl", "s_client", "-connect", "127.0.0.1:%d" % port, "-servername", name, "-CAfile", cacert,
                      "-verify_hostname", name, "-verify_return_error", "-brief"] + list(extra), inp=b"")
    offered = not re.search(r"no protocols available|unsupported protocol|invalid command|Cipher is \(NONE\)|no ciphers available", out) or \
        "alert" in out or "handshake failure" in out
    ok = "Verification: OK" in out or ("Verification" in out and "error" not in out.lower() and rc == 0)
    ok = ok and rc == 0 and "verify error" not in out
    return ok, "openssl rc=%d %s" % (rc, re.sub(r"\s+", " ", out).strip()[:300]), ms, offered


TOOLS = (("curl", "curl", tool_curl), ("python-ssl", "python-ssl", tool_python), ("openssl-s_client", "openssl-s_client", tool_openssl))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--run-id")
    ap.add_argument("--cacert", help="gateway mode: CA that signed the good certificate")
    ap.add_argument("--variant-hook")
    a = ap.parse_args(argv)
    work = tempfile.mkdtemp(prefix="llmctl-negtls-")
    servers = {}
    key = "mk-" + secrets.token_hex(16)
    cls = "stand-in"
    rc = 1
    try:
        if a.variant_hook:
            cls = "real-component"
            cacert = a.cacert
            for v in VARIANTS:
                out = subprocess.run([a.variant_hook, "start", v], capture_output=True, text=True, check=True).stdout.strip()
                s = type("S", (), {})()
                s.port = int(out.rsplit(":", 1)[1])
                s.stop = (lambda v=v: subprocess.run([a.variant_hook, "stop", v], capture_output=True))
                servers[v] = s
            probe = None
        else:
            go = shutil.which("go")
            if not go:
                raise SystemExit("go toolchain required to build the reference server")
            binp = os.path.join(work, "refserver")
            r = subprocess.run([go, "build", "-o", binp, os.path.join(HERE, "refserver", "main.go")], capture_output=True, text=True,
                               cwd=HERE, env=dict(os.environ, GOFLAGS="", GOWORK="off"))
            if r.returncode:
                raise SystemExit("refserver build failed: " + r.stderr[-300:])
            certs = os.path.join(work, "certs")
            subprocess.run([binp, "gencerts", certs], check=True)
            cacert = os.path.join(certs, "ca.pem")
            for v in VARIANTS:
                servers[v] = Srv(work, binp, certs, v, key)
            probe = binp
        run_id = a.run_id or time.strftime("negtls-%Y%m%dT%H%M%SZ", time.gmtime())
        os.makedirs(a.run_dir, exist_ok=True)
        w = writer.EvidenceWriter(a.run_dir, run_id, secrets=[key])
        results = []  # (case, tool, result, reason)

        def rec(case, client, command, out, ms, result, reason=None):
            c = "not-exercised" if result == "not-exercised" else cls
            w.append(requirement=["FR-070", "SC-013"], command="[NEG %s] %s" % (case, command), cwd=ROOT, env_names=["PATH"],
                     exit_code=0 if result == "pass" else 1, stdout=(out or "not executed").encode(), stderr=b"", duration_ms=ms,
                     cls=c, vantage="host", client=client, result=result, reason=reason)
            results.append({"case": case, "tool": client, "result": result, "reason": reason})

        # positive controls (one per tool), reused as the blind-instrument guard of every negative case
        good = servers["good"].port
        controls = {}
        for label, client, fn in TOOLS:
            ok, out, ms, _ = fn(good, "localhost", cacert)
            controls[label] = ok
            rec("control", client, "%s -> good certificate, name localhost" % label, out, ms, "pass" if ok else "fail",
                None if ok else "positive control failed: the tool cannot even succeed against the good server")

        for case, (variant, name, rx) in NEG.items():
            for label, client, fn in TOOLS:
                if not controls[label]:
                    rec(case, client, "%s" % label, "control failed", 0, "fail", "blind: positive control failed for this tool")
                    continue
                ok, out, ms, offered = fn(servers[variant].port, name, cacert)
                good_refusal = (not ok) and re.search(rx, out, re.I) is not None
                if ok:
                    rec(case, client, "%s -> %s certificate" % (label, variant), out, ms, "fail", "connection SUCCEEDED but must be refused")
                elif good_refusal:
                    rec(case, client, "%s -> %s certificate" % (label, variant), out, ms, "pass")
                else:
                    rec(case, client, "%s -> %s certificate" % (label, variant), out, ms, "fail",
                        "refused, but not for the expected reason (regex %r)" % rx)

        # plain HTTP to the TLS port
        for label, client, fn in (("curl", "curl", None), ("python-ssl", "python-ssl", None)):
            if label == "curl":
                rc_, out, ms = sh(["curl", "-sS", "--max-time", "8", "http://127.0.0.1:%d/healthz" % good])
                ok = rc_ != 0 and not out.startswith("HTTP/") and '"status"' not in out
                rec("plain-http-to-tls-port", client, "curl http://127.0.0.1:PORT/healthz", "curl rc=%d %s" % (rc_, out.strip()[:200]), ms,
                    "pass" if ok else "fail", None if ok else "plain HTTP was answered")
            else:
                ok, det = T.plain_http_to_tls("127.0.0.1", good)
                rec("plain-http-to-tls-port", client, "raw socket GET to the TLS port", json.dumps(det), 0, "pass" if ok else "fail",
                    None if ok else "plain HTTP was answered")

        # outdated protocol versions / weak ciphers
        if probe:
            def go_probe(*args):
                return sh([probe, "probe", "--addr", "127.0.0.1:%d" % good, "--cacert", cacert] + list(args))
            r0, o0, ms0 = go_probe()
            r1, o1, ms1 = go_probe("--maxver", "1.2")
            ctrl_ok = "RESULT connected" in o0 and "RESULT connected" in o1
            rec("minimum-protocol", "go-crypto-tls", "go probe default / maxver 1.2 (controls)", o0.strip() + " | " + o1.strip(), ms0 + ms1,
                "pass" if ctrl_ok else "fail", None if ctrl_ok else "controls did not connect: TLS1.2/1.3 must be accepted")
            for case, args in (("tls1.0-only-client", ("--maxver", "1.0")), ("tls1.1-only-client", ("--maxver", "1.1")),
                               ("weak-cipher-only-client", ("--ciphers", "cbc"))):
                _, o, ms = go_probe(*args)
                if "RESULT connected" in o:
                    rec(case, "go-crypto-tls", "go probe %s" % " ".join(args), o.strip(), ms, "fail", "server accepted an outdated/weak offer")
                elif "RESULT refused" in o and re.search(r"protocol version|handshake failure|no cipher|insufficient security|alert", o):
                    rec(case, "go-crypto-tls", "go probe %s" % " ".join(args), o.strip(), ms, "pass" if ctrl_ok else "fail",
                        None if ctrl_ok else "no positive control")
                else:
                    rec(case, "go-crypto-tls", "go probe %s" % " ".join(args), o.strip(), ms, "not-exercised",
                        "client could not offer this configuration: " + o.strip()[:120])
            for case, extra in (("tls1.1-only-client", ["-tls1_1", "-cipher", "DEFAULT:@SECLEVEL=0"]),
                                ("tls1.0-only-client", ["-tls1", "-cipher", "DEFAULT:@SECLEVEL=0"]),
                                ("weak-cipher-only-client", ["-tls1_2", "-cipher", "ECDHE-ECDSA-AES128-SHA"])):
                ok, out, ms, offered = tool_openssl(good, "localhost", cacert, extra)
                if ok:
                    rec(case, "openssl-s_client", "openssl s_client %s" % " ".join(extra), out, ms, "fail", "server accepted an outdated/weak offer")
                elif offered and re.search(r"alert|handshake failure|protocol version|wrong version|sslv3|tlsv1", out, re.I) and controls["openssl-s_client"]:
                    rec(case, "openssl-s_client", "openssl s_client %s" % " ".join(extra), out, ms, "pass")
                else:
                    rec(case, "openssl-s_client", "openssl s_client %s" % " ".join(extra), out, ms, "not-exercised",
                        "openssl could not offer this configuration (client-side refusal): " + out[:120])
        # verdict: every case needs >= 1 pass and no fail
        cases = sorted({r["case"] for r in results})
        summary, bad = {}, []
        for c in cases:
            rs = [r for r in results if r["case"] == c]
            summary[c] = {"pass": sum(r["result"] == "pass" for r in rs), "fail": sum(r["result"] == "fail" for r in rs),
                          "not_exercised": sum(r["result"] == "not-exercised" for r in rs)}
            if summary[c]["fail"] or not summary[c]["pass"]:
                bad.append(c)
        expected = set(NEG) | {"control", "plain-http-to-tls-port", "minimum-protocol", "tls1.0-only-client", "tls1.1-only-client",
                               "weak-cipher-only-client"}
        if not a.variant_hook:
            missing = sorted(expected - set(cases))
        else:
            missing = sorted((set(NEG) | {"control", "plain-http-to-tls-port"}) - set(cases))
        bad += ["missing:" + m for m in missing]
        verdict = "PASS" if not bad else "FAIL"
        nj = {"run_id": run_id, "evidence_class": cls, "minimum_protocol": "TLS 1.2 (refserver; the gateway documents its own)",
              "cases": summary, "problems": bad, "verdict": verdict}
        with open(os.path.join(a.run_dir, "negative_tls.json"), "w") as f:
            json.dump(nj, f, indent=1, sort_keys=True)
            f.write("\n")
        lrc, lrep = leak_scan.run([a.run_dir], [key])
        if lrc != 0:
            nj["verdict"] = verdict = "FAIL"
            print("LEAK SCAN: %s" % lrep["status"], file=sys.stderr)
        manifest.build(a.run_dir)
        print(json.dumps({"verdict": verdict, "cases": summary, "problems": bad}, indent=1))
        rc = 0 if verdict == "PASS" else 1
    finally:
        for s in servers.values():
            s.stop()
        shutil.rmtree(work, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
