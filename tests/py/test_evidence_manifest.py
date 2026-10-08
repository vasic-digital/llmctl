"""Unit tests for tests/evidence/manifest.py."""
import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest

from tests.evidence import manifest


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="manifest-")
        self.addCleanup(shutil.rmtree, self.d, True)
        self._w("evidence.jsonl", '{"a":1}\n')
        self._w("raw/x.txt", "hello")

    def _w(self, name, data):
        p = os.path.join(self.d, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(data)
        return p

    def test_build_writes_manifest_and_sha256sums(self):
        manifest.build(self.d)
        sums = open(os.path.join(self.d, "SHA256SUMS")).read().splitlines()
        names = [l.split("  ", 1)[1] for l in sums]
        self.assertIn("evidence.jsonl", names)
        self.assertIn("raw/x.txt", names)
        self.assertIn("MANIFEST.json", names)
        self.assertNotIn("SHA256SUMS", names)
        m = json.load(open(os.path.join(self.d, "MANIFEST.json")))
        self.assertEqual(sorted(f["path"] for f in m["files"]), ["evidence.jsonl", "raw/x.txt"])

    def test_sha256sums_format_compatible_with_sha256sum(self):
        manifest.build(self.d)
        import subprocess
        r = subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=self.d, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_verify_clean(self):
        manifest.build(self.d)
        res = manifest.verify(self.d)
        self.assertTrue(res["ok"])
        self.assertEqual((res["tampered"], res["missing"], res["extra"]), ([], [], []))

    def test_verify_detects_tamper(self):
        manifest.build(self.d)
        self._w("raw/x.txt", "HELLO")
        res = manifest.verify(self.d)
        self.assertFalse(res["ok"])
        self.assertEqual(res["tampered"], ["raw/x.txt"])

    def test_verify_detects_missing(self):
        manifest.build(self.d)
        os.remove(os.path.join(self.d, "raw/x.txt"))
        res = manifest.verify(self.d)
        self.assertFalse(res["ok"])
        self.assertEqual(res["missing"], ["raw/x.txt"])

    def test_verify_detects_extra(self):
        manifest.build(self.d)
        self._w("raw/new.txt", "late")
        res = manifest.verify(self.d)
        self.assertFalse(res["ok"])
        self.assertEqual(res["extra"], ["raw/new.txt"])

    def test_verify_detects_tampered_sha256sums_itself(self):
        manifest.build(self.d)
        p = os.path.join(self.d, "SHA256SUMS")
        s = open(p).read().replace("evidence.jsonl", "evidence.jsonl", 1)
        # delete a line: file now 'extra' relative to the sums
        lines = s.splitlines()
        open(p, "w").write("\n".join(l for l in lines if "raw/x.txt" not in l) + "\n")
        res = manifest.verify(self.d)
        self.assertFalse(res["ok"])
        self.assertIn("raw/x.txt", res["extra"])

    def test_verify_without_sums_fails_not_passes(self):
        res = manifest.verify(self.d)
        self.assertFalse(res["ok"])
        self.assertTrue(res["errors"])

    def test_empty_dir_does_not_vacuously_pass(self):
        e = tempfile.mkdtemp(prefix="manifest-empty-")
        self.addCleanup(shutil.rmtree, e, True)
        with self.assertRaises(manifest.ManifestError):
            manifest.build(e)

    def test_rebuild_is_idempotent(self):
        manifest.build(self.d)
        a = open(os.path.join(self.d, "SHA256SUMS")).read()
        manifest.build(self.d)
        b = open(os.path.join(self.d, "SHA256SUMS")).read()
        self.assertEqual(a, b)

    def test_cli_verify_exit_codes(self):
        manifest.build(self.d)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(manifest.main(["verify", self.d]), 0)
            self._w("evidence.jsonl", "x")
            self.assertEqual(manifest.main(["verify", self.d]), 1)


if __name__ == "__main__":
    unittest.main()
