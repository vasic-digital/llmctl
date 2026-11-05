"""Unit tests for tests/evidence/leak_scan.py (SC-005, evidence-schema rule 4)."""
import contextlib
import io
import os
import shutil
import tarfile
import tempfile
import unittest
import zipfile

from tests.evidence import leak_scan

SECRET = "zQ9-unit-test-secret-value-4417"


def _pem():
    return "-----BEGIN " + "RSA PRIVATE KEY-----\nabc\n-----END " + "RSA PRIVATE KEY-----\n"


class LeakScanTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="leakscan-")
        self.addCleanup(shutil.rmtree, self.d, True)

    def _w(self, name, data):
        p = os.path.join(self.d, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode())
        return p

    # basis: negative control on a constructed clean file; no spec text beyond specs/009-jev-decision-models/spec.md:386 (zero key values found)
    # oracle: CHARACTERIZATION
    def test_clean_tree_reports_no_findings(self):
        self._w("a.log", "nothing to see here\n")
        self.assertEqual(leak_scan.scan_paths([self.d], [SECRET]), [])

    # basis: specs/009-jev-decision-models/spec.md:386 (SC-005: an automated scan finds key values) and specs/009-jev-decision-models/contracts/evidence-schema.md:35; not echoing the value is the scanner's design
    # oracle: SPECIFIED
    def test_literal_secret_found_without_echoing_value(self):
        self._w("sub/out.txt", "x " + SECRET + " y")
        f = leak_scan.scan_paths([self.d], [SECRET])
        self.assertEqual(len(f), 1)
        self.assertNotIn(SECRET, repr(f))
        self.assertEqual(f[0]["kind"], "literal")

    # basis: specs/009-jev-decision-models/contracts/evidence-schema.md:35 (private keys must not appear: the PEM header is the spec'd class); the sk- key-like pattern is the scanner's own heuristic
    # oracle: SPECIFIED
    def test_pem_and_key_like_tokens(self):
        self._w("k.pem", _pem())
        self._w("t.txt", "token=" + "sk-" + "A1b2C3d4E5f6G7h8I9j0K1l2")
        kinds = {x["kind"] for x in leak_scan.scan_paths([self.d], [])}
        self.assertIn("pem-private-key", kinds)
        self.assertIn("key-like-token", kinds)

    # basis: pins the scanner's own tar.gz and zip descent into entries; specs/009-jev-decision-models/spec.md:386 says across the whole run but does not name archives
    # oracle: CHARACTERIZATION
    def test_archives_are_scanned(self):
        tp = os.path.join(self.d, "a.tar.gz")
        with tarfile.open(tp, "w:gz") as t:
            data = SECRET.encode()
            ti = tarfile.TarInfo("inner/x.txt")
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
        zp = os.path.join(self.d, "b.zip")
        with zipfile.ZipFile(zp, "w") as z:
            z.writestr("y.txt", "pre " + SECRET)
        paths = {x["path"] for x in leak_scan.scan_paths([self.d], [SECRET])}
        self.assertTrue(any("a.tar.gz" in p and "inner/x.txt" in p for p in paths))
        self.assertTrue(any("b.zip" in p and "y.txt" in p for p in paths))

    # basis: pins that a file path, not only a directory, is accepted; scanner design
    # oracle: CHARACTERIZATION
    def test_single_file_path_supported(self):
        p = self._w("one.txt", SECRET)
        self.assertEqual(len(leak_scan.scan_paths([p], [SECRET])), 1)

    # basis: pins the scanner's own minimum secret length rule; no spec text
    # oracle: CHARACTERIZATION
    def test_short_secret_ignored_to_avoid_false_positives(self):
        self._w("a.txt", "abc abc abc")
        self.assertEqual(leak_scan.scan_paths([self.d], ["abc"]), [])

    # basis: specs/009-jev-decision-models/contracts/evidence-schema.md:34 (rule 4: the scan records its control-needle result); exit code 0 is the tool's design
    # oracle: SPECIFIED
    def test_run_clean_exit_zero_and_needle_checked(self):
        self._w("a.txt", "fine")
        rc, report = leak_scan.run([self.d], [SECRET])
        self.assertEqual(rc, 0)
        self.assertTrue(report["control_needle_found"])

    # basis: pins exit code 1 on a leak and that the report omits the secret value; tool design
    # oracle: CHARACTERIZATION
    def test_run_leak_exit_one(self):
        self._w("a.txt", SECRET)
        rc, report = leak_scan.run([self.d], [SECRET])
        self.assertEqual(rc, 1)
        self.assertNotIn(SECRET, repr(report))

    # basis: specs/009-jev-decision-models/contracts/evidence-schema.md:34 (a blind scan must fail the run); exit code 3 and the BLIND INSTRUMENT label are the tool's design; the blind scanner is a lambda stand-in defined in the test
    # oracle: SPECIFIED
    def test_blind_scanner_detected_exit_three(self):
        """Mutation: remove the detection logic -> self-test must flag BLIND."""
        self._w("a.txt", SECRET)
        rc, report = leak_scan.run([self.d], [SECRET], scanner=lambda p, s: [])
        self.assertEqual(rc, 3)
        self.assertEqual(report["status"], "BLIND INSTRUMENT")

    # basis: specs/009-jev-decision-models/contracts/evidence-schema.md:34 (a scan path that cannot find the planted decoy is blind); the literal-only scanner is a stand-in built in the test
    # oracle: SPECIFIED
    def test_regex_blind_scanner_detected(self):
        """A scanner finding literals but no regex classes is also blind."""
        real = leak_scan.scan_paths

        def literal_only(paths, secrets):
            return [f for f in real(paths, secrets) if f["kind"] == "literal"]

        rc, _ = leak_scan.run([self.d], [SECRET], scanner=literal_only)
        self.assertEqual(rc, 3)

    # basis: the temp directory listing before and after run has no leakscan-needle entry
    # oracle: INVARIANT
    def test_needle_never_left_on_disk(self):
        before = set(os.listdir(tempfile.gettempdir()))
        leak_scan.run([self.d], [SECRET])
        after = set(os.listdir(tempfile.gettempdir()))
        self.assertEqual([x for x in after - before if x.startswith("leakscan-needle")], [])

    # basis: pins the --secrets-file CLI option and exit 1 as designed; no spec text
    # oracle: CHARACTERIZATION
    def test_cli_secrets_from_env_file(self):
        self._w("a.txt", SECRET)
        sf = self._w("secrets.lst", SECRET + "\n")
        with contextlib.redirect_stdout(io.StringIO()):
            rc = leak_scan.main(["--secrets-file", sf, os.path.join(self.d, "a.txt")])
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
