"""Unit tests for tests/evidence/writer.py (contracts/evidence-schema.md)."""
import hashlib
import json
import os
import shutil
import tempfile
import unittest

from tests.evidence import writer

SECRET = "wR7-writer-secret-literal-9921"


def _rec(w, **kw):
    base = dict(requirement=["FR-066"], command="curl https://127.0.0.1:8095/v1/models",
                cwd="/tmp", env_names=["PATH", "HOME"], exit_code=0,
                stdout=b'{"data":[]}', stderr=b"", duration_ms=41,
                cls="real-component", vantage="host", client="curl", result="pass")
    base.update(kw)
    return w.append(**base)


class WriterTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="evwriter-")
        self.addCleanup(shutil.rmtree, self.d, True)
        self.w = writer.EvidenceWriter(self.d, run_id="r1", secrets=[SECRET])

    def lines(self):
        with open(os.path.join(self.d, "evidence.jsonl")) as f:
            return [json.loads(l) for l in f if l.strip()]

    def test_record_has_all_schema_fields(self):
        _rec(self.w)
        r = self.lines()[0]
        for k in ("id", "ts", "requirement", "command", "cwd", "env_digest", "exit_code",
                  "stdout_sha256", "stderr_sha256", "artifact_paths", "duration_ms", "class",
                  "vantage", "client", "result", "prev_sha256"):
            self.assertIn(k, r)
        self.assertEqual(r["id"], "EV-r1-0001")
        self.assertTrue(r["ts"].endswith("Z"))
        self.assertEqual(r["class"], "real-component")

    def test_sha256_of_output_and_artifact_written(self):
        _rec(self.w, stdout=b"payload")
        r = self.lines()[0]
        self.assertEqual(r["stdout_sha256"], hashlib.sha256(b"payload").hexdigest())
        ap = os.path.join(self.d, r["artifact_paths"][0])
        self.assertEqual(open(ap, "rb").read(), b"payload")

    def test_env_digest_hashes_sorted_names_only(self):
        _rec(self.w, env_names=["B", "A"])
        want = "sha256:" + hashlib.sha256(b"A\nB").hexdigest()
        self.assertEqual(self.lines()[0]["env_digest"], want)

    def test_seq_monotonic_and_survives_reopen(self):
        _rec(self.w)
        _rec(self.w)
        w2 = writer.EvidenceWriter(self.d, run_id="r1", secrets=[SECRET])
        _rec(w2)
        self.assertEqual([r["id"] for r in self.lines()], ["EV-r1-0001", "EV-r1-0002", "EV-r1-0003"])

    def test_hash_chain_links_previous_line(self):
        _rec(self.w)
        _rec(self.w)
        raw = open(os.path.join(self.d, "evidence.jsonl"), "rb").read().split(b"\n")
        recs = self.lines()
        self.assertEqual(recs[1]["prev_sha256"], hashlib.sha256(raw[0]).hexdigest())
        self.assertEqual(recs[0]["prev_sha256"], "0" * 64)

    def test_verify_chain_ok_then_tamper_detected(self):
        _rec(self.w)
        _rec(self.w)
        _rec(self.w)
        self.assertEqual(writer.verify_chain(os.path.join(self.d, "evidence.jsonl")), [])
        p = os.path.join(self.d, "evidence.jsonl")
        s = open(p).read().replace('"exit_code": 0', '"exit_code": 7', 1)
        open(p, "w").write(s)
        self.assertTrue(writer.verify_chain(p))

    def test_verify_chain_detects_deleted_and_reordered(self):
        for _ in range(3):
            _rec(self.w)
        p = os.path.join(self.d, "evidence.jsonl")
        ls = open(p).read().splitlines()
        open(p, "w").write("\n".join([ls[0], ls[2]]) + "\n")
        self.assertTrue(writer.verify_chain(p))
        open(p, "w").write("\n".join([ls[1], ls[0], ls[2]]) + "\n")
        self.assertTrue(writer.verify_chain(p))

    def test_pass_requires_captured_output(self):
        with self.assertRaises(writer.EvidenceError):
            _rec(self.w, stdout=b"", stderr=b"")

    def test_fail_and_not_exercised_require_reason(self):
        for res in ("fail", "not-exercised"):
            with self.assertRaises(writer.EvidenceError):
                _rec(self.w, result=res, stdout=b"", cls="not-exercised" if res != "fail" else "real-component")
        _rec(self.w, result="not-exercised", stdout=b"", reason="no GPU", cls="not-exercised", vantage="none")
        self.assertEqual(self.lines()[0]["reason"], "no GPU")

    def test_enum_validation(self):
        for kw in ({"cls": "mock"}, {"vantage": "moon"}, {"client": "wget"}, {"result": "ok"}):
            with self.assertRaises(writer.EvidenceError):
                _rec(self.w, **kw)

    def test_agent_client_allowed(self):
        _rec(self.w, client="agent:opencode")

    def test_stand_in_cannot_claim_pass_in_real_summary(self):
        _rec(self.w, cls="stand-in")
        _rec(self.w)
        s = writer.summarize(os.path.join(self.d, "evidence.jsonl"))
        self.assertEqual(s["real_pass"], 1)
        self.assertEqual(s["excluded_stand_in"], 1)

    def test_refuses_registered_secret_in_command(self):
        with self.assertRaises(writer.SecretRefused):
            _rec(self.w, command="curl -H 'Authorization: Bearer %s'" % SECRET)
        self.assertFalse(os.path.exists(os.path.join(self.d, "evidence.jsonl")))

    def test_refuses_secret_in_output_without_writing_artifact(self):
        with self.assertRaises(writer.SecretRefused):
            _rec(self.w, stdout=("leak " + SECRET).encode())
        raw = os.path.join(self.d, "raw")
        self.assertFalse(os.path.isdir(raw) and os.listdir(raw))

    def test_refuses_pem_and_key_like_values(self):
        pem = ("-----BEGIN " + "PRIVATE KEY-----").encode()
        with self.assertRaises(writer.SecretRefused):
            _rec(self.w, stderr=pem)
        with self.assertRaises(writer.SecretRefused):
            _rec(self.w, command="x sk-" + "Zz9Yy8Xx7Ww6Vv5Uu4Tt3Ss2")

    def test_error_message_never_contains_secret(self):
        try:
            _rec(self.w, command=SECRET + " go")
        except writer.SecretRefused as e:
            self.assertNotIn(SECRET, str(e))

    def test_refusal_does_not_consume_sequence_number(self):
        with self.assertRaises(writer.SecretRefused):
            _rec(self.w, command=SECRET + "x")
        _rec(self.w)
        self.assertEqual(self.lines()[0]["id"], "EV-r1-0001")


if __name__ == "__main__":
    unittest.main()
