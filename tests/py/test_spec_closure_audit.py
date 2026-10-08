"""Tests for scripts/spec_closure_audit.py (T129 / SC-004).

Each test builds a scratch repo tree, so no repository state is read.  The
control needle (test_planted_row_without_evidence_is_reported) proves the
instrument can see an unclosed finding; test_closure_citing_missing_test_fails
proves a citation of a test that does not exist is a FAIL, not a pass.
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import spec_closure_audit as sca  # noqa: E402


FINDINGS = """# findings
## B. Defects
| ID | Sev | Finding | Evidence | Status |
|---|---|---|---|---|
| D-01 | H | a high defect | x | OPEN |
| D-02 | H | another high defect | x | OPEN |
| D-03 | M | medium defect | x | OPEN |
| D-04 | H | not-reproduced one | x | OPEN |
"""
NEWFILES = """| ID | Sev | Status | Where | Note |
|---|---|---|---|---|
| N-01 | H | CONFIRMED | x | planted without any evidence |
"""


class Scratch(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="sca-")
        self.addCleanup(shutil.rmtree, self.d, True)
        self.spec = os.path.join(self.d, "specs", "009")
        os.makedirs(os.path.join(self.spec, "evidence", "p1-red-original"))
        os.makedirs(os.path.join(self.spec, "research"))
        os.makedirs(os.path.join(self.d, "tests"))
        self.w("specs/009/source-findings.md", FINDINGS)
        self.w("specs/009/research/jev-llmctl-new-files.md", NEWFILES)
        self.w("specs/009/evidence/p1-red-original/r.jsonl",
               "".join('{"id":"%s"}\n' % i for i in ("D-01", "D-02", "D-03", "D-04", "N-01")))
        self.w("tests/test_real.sh", "ok: the real guard name\n")
        self.w("specs/009/evidence/make-test.log",
               "TEST: test_real.sh\nOUTPUT:\n  ok: the real guard name\nRESULT: PASS\n")

    def w(self, rel, text):
        p = os.path.join(self.d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)

    def register(self, by_id, rmap):
        self.w("specs/009/evidence/p1-red-register.json", json.dumps({
            "by_id": by_id, "files": {k: "r.jsonl" for k in by_id}}))
        self.w("specs/009/evidence/red-to-green-map.json", json.dumps({"map": rmap}))

    def run_audit(self):
        return sca.audit(self.d, "specs/009", green_log="specs/009/evidence/make-test.log")


class AuditTests(Scratch):
    def rows(self, res):
        return {r["id"]: r for r in res["rows"]}

    def test_fixed_with_real_test(self):
        self.register({"D-01": "RED", "D-02": "RED", "D-03": "RED", "D-04": "NOT-REPRODUCED", "N-01": "RED"},
                      {"D-01": {"disposition": "regression-test", "guard": ["tests/test_real.sh::the real guard name"]},
                       "D-04": {"disposition": "N/A", "guard": "not a defect: reason"}})
        r = self.rows(self.run_audit())
        self.assertEqual(r["D-01"]["closure"], "FIXED")
        self.assertTrue(r["D-01"]["green"].startswith("PASS"))

    def test_planted_row_without_evidence_is_reported(self):
        # control needle: N-01 (H) has no register entry and no map entry
        self.register({"D-01": "RED"}, {"D-01": {"disposition": "regression-test",
                                                 "guard": ["tests/test_real.sh::the real guard name"]}})
        res = self.run_audit()
        r = self.rows(res)
        self.assertEqual(r["N-01"]["closure"], "OPEN")
        self.assertIn("N-01", [x["id"] for x in res["open_high"]])
        self.assertNotEqual(res["exit_code"], 0)

    def test_closure_citing_missing_test_fails(self):
        self.register({"D-01": "RED", "D-02": "RED", "D-04": "RED", "N-01": "RED"},
                      {"D-01": {"disposition": "regression-test", "guard": ["tests/test_ghost.sh::nothing"]},
                       "D-02": {"disposition": "regression-test", "guard": ["tests/test_real.sh::a name that is not in the file"]}})
        r = self.rows(self.run_audit())
        self.assertEqual(r["D-01"]["closure"], "OPEN")
        self.assertIn("missing file", r["D-01"]["reason"])
        self.assertEqual(r["D-02"]["closure"], "OPEN")
        self.assertIn("name not found", r["D-02"]["reason"])

    def test_not_reproduced_is_demoted_with_reason(self):
        self.register({"D-04": "NOT-REPRODUCED"}, {"D-04": {"disposition": "N/A", "guard": "no loader exists"}})
        r = self.rows(self.run_audit())
        self.assertEqual(r["D-04"]["closure"], "DEMOTED")

    def test_demotion_without_reason_is_open(self):
        self.register({"D-04": "NOT-REPRODUCED"}, {})
        r = self.rows(self.run_audit())
        self.assertEqual(r["D-04"]["closure"], "OPEN")

    def test_medium_rows_do_not_gate_exit(self):
        self.register({"D-01": "RED", "D-02": "RED", "D-04": "NOT-REPRODUCED", "N-01": "RED"},
                      {x: {"disposition": "regression-test", "guard": ["tests/test_real.sh::the real guard name"]}
                       for x in ("D-01", "D-02", "N-01")})
        self.w("specs/009/evidence/red-to-green-map.json", json.dumps({"map": {
            **{x: {"disposition": "regression-test", "guard": ["tests/test_real.sh::the real guard name"]}
               for x in ("D-01", "D-02", "N-01")},
            "D-04": {"disposition": "N/A", "guard": "reason"}}}))
        res = self.run_audit()
        self.assertEqual(res["exit_code"], 0)   # D-03 (M) has no evidence yet is not gating
        self.assertEqual(self.rows(res)["D-03"]["closure"], "OPEN")

    def test_override_requires_existing_evidence(self):
        self.register({"D-01": "SKIP"}, {})
        self.w("specs/009/evidence/sc004-overrides.json", json.dumps({"D-01": {
            "closure": "DEMOTED", "reason": "x", "evidence": ["specs/009/evidence/nope.txt"]}}))
        r = self.rows(self.run_audit())
        self.assertEqual(r["D-01"]["closure"], "OPEN")
        self.assertIn("missing file", r["D-01"]["reason"])
        self.w("specs/009/evidence/real.txt", "captured\n")
        self.w("specs/009/evidence/sc004-overrides.json", json.dumps({"D-01": {
            "closure": "DEMOTED", "reason": "x", "evidence": ["specs/009/evidence/real.txt"]}}))
        r = self.rows(self.run_audit())
        self.assertEqual(r["D-01"]["closure"], "DEMOTED")

    def test_render_marks_generated_and_counts(self):
        self.register({"D-01": "RED"}, {"D-01": {"disposition": "regression-test",
                                                 "guard": ["tests/test_real.sh::the real guard name"]}})
        res = self.run_audit()
        md = sca.render(res)
        self.assertIn("GENERATED", md)
        self.assertIn("scripts/spec_closure_audit.py", md)
        self.assertIn("| D-01 |", md)


if __name__ == "__main__":
    unittest.main()
