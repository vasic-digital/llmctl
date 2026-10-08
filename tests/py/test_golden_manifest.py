"""Unit tests for scripts/golden verify_manifest / build_manifest / similarity on the shipped fixtures."""
import json
import os
import shutil
import tempfile
import unittest

from scripts.golden import build_manifest, similarity, verify_manifest as vm


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="golden-man-")
        self.addCleanup(shutil.rmtree, self.d, True)
        for n in ("questions.jsonl", "probes.jsonl", "MANIFEST.json"):
            shutil.copy(os.path.join(vm.DEFAULT_DIR, n), self.d)

    def test_shipped_manifest_is_consistent(self):
        self.assertEqual(vm.verify(vm.DEFAULT_DIR), [])

    def test_rebuild_is_deterministic(self):
        before = open(os.path.join(self.d, "MANIFEST.json")).read()
        build_manifest.build(self.d)
        self.assertEqual(open(os.path.join(self.d, "MANIFEST.json")).read(), before)

    def test_one_byte_drift_is_detected(self):
        p = os.path.join(self.d, "questions.jsonl")
        data = open(p, "rb").read()
        open(p, "wb").write(data.replace(b"rm -rf /", b"rm -rf ./", 1))
        self.assertIn("hash drift: questions.jsonl", vm.verify(self.d))

    def test_counts_drift_detected_even_when_hash_is_refreshed(self):
        p = os.path.join(self.d, "questions.jsonl")
        lines = open(p).read().splitlines()
        open(p, "w").write("\n".join(lines[:-1]) + "\n")           # drop the last item
        man = json.load(open(os.path.join(self.d, "MANIFEST.json")))
        man["files"]["questions.jsonl"]["sha256"] = vm.sha256_file(p)   # attacker refreshes the hash only
        json.dump(man, open(os.path.join(self.d, "MANIFEST.json"), "w"))
        self.assertIn("counts drift: questions.jsonl", vm.verify(self.d))

    def test_unlisted_and_missing_files_detected(self):
        open(os.path.join(self.d, "extra.jsonl"), "w").write("{}\n")
        os.remove(os.path.join(self.d, "probes.jsonl"))
        pr = vm.verify(self.d)
        self.assertIn("unlisted data file: extra.jsonl", pr)
        self.assertIn("missing file: probes.jsonl", pr)

    def test_minimums_enforced(self):
        p = os.path.join(self.d, "questions.jsonl")
        items = [i for i in vm.read_items(p) if i["type"] != "score"]
        with open(p, "w") as f:
            for i in items:
                f.write(json.dumps(i) + "\n")
        build_manifest.build(self.d)
        self.assertTrue(any("fewer than 30 score" in x for x in vm.verify(self.d)))

    def test_dishonest_label_provenance_rejected(self):
        p = os.path.join(self.d, "questions.jsonl")
        items = vm.read_items(p)
        items[0]["labeled_by"] = "gold standard"
        with open(p, "w") as f:
            for i in items:
                f.write(json.dumps(i) + "\n")
        build_manifest.build(self.d)
        self.assertTrue(any("no honest labeled_by" in x for x in vm.verify(self.d)))


class SimilarityTests(unittest.TestCase):
    def test_shipped_sets_have_no_breach(self):
        items = similarity.load([os.path.join(vm.DEFAULT_DIR, n) for n in vm.DATA_FILES])
        rep = similarity.analyse(items)
        self.assertEqual(rep["breaches"], [])
        self.assertLess(rep["max_similarity_same_label"], 0.5)

    def test_planted_duplicate_is_found(self):
        a = {"id": "a", "type": "noul", "state": "Please review my pull request this week", "expected": False}
        b = dict(a, id="b", state="Please review my pull request this week.")
        rep = similarity.analyse([a, b])
        self.assertEqual(len(rep["breaches"]), 1)
        self.assertGreater(rep["max_similarity_same_label"], 0.9)

    def test_contrast_pair_is_listed_not_failed_below_any_threshold(self):
        a = {"id": "a", "type": "noul", "state": "SELECT * FROM users WHERE age > 30;", "expected": True}
        b = {"id": "b", "type": "noul", "state": "SELECT * FROM users WHERE age >= 30 ORDER BY id;", "expected": False}
        self.assertEqual(similarity.analyse([a, b])["breaches"], [])

    def test_different_types_never_compared(self):
        a = {"id": "a", "type": "noul", "state": "same text", "expected": True}
        b = dict(a, id="b", type="choice")
        self.assertEqual(similarity.analyse([a, b])["max_similarity_any"], 0.0)


if __name__ == "__main__":
    unittest.main()
