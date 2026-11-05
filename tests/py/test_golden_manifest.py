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

    # basis: golden-master of the shipped fixtures against their shipped MANIFEST.json (docs/golden-set.md:14); both files are repo data produced by the same builder
    # oracle: CHARACTERIZATION
    def test_shipped_manifest_is_consistent(self):
        self.assertEqual(vm.verify(vm.DEFAULT_DIR), [])

    # basis: rebuilding the manifest from unchanged inputs reproduces the shipped MANIFEST.json byte for byte; the shipped file came from the same builder, so this is idempotence, not an independent check
    # oracle: INVARIANT
    def test_rebuild_is_deterministic(self):
        before = open(os.path.join(self.d, "MANIFEST.json")).read()
        build_manifest.build(self.d)
        self.assertEqual(open(os.path.join(self.d, "MANIFEST.json")).read(), before)

    # basis: specs/009-jev-decision-models/tasks.md:92 (T063: the golden set is hash-pinned); the message wording hash drift is the verifier's own
    # oracle: SPECIFIED
    def test_one_byte_drift_is_detected(self):
        p = os.path.join(self.d, "questions.jsonl")
        data = open(p, "rb").read()
        open(p, "wb").write(data.replace(b"rm -rf /", b"rm -rf ./", 1))
        self.assertIn("hash drift: questions.jsonl", vm.verify(self.d))

    # basis: pins the verifier's own counts check even when the hash is refreshed; docs/golden-set.md:14 lists counts in the manifest
    # oracle: CHARACTERIZATION
    def test_counts_drift_detected_even_when_hash_is_refreshed(self):
        p = os.path.join(self.d, "questions.jsonl")
        lines = open(p).read().splitlines()
        open(p, "w").write("\n".join(lines[:-1]) + "\n")           # drop the last item
        man = json.load(open(os.path.join(self.d, "MANIFEST.json")))
        man["files"]["questions.jsonl"]["sha256"] = vm.sha256_file(p)   # attacker refreshes the hash only
        json.dump(man, open(os.path.join(self.d, "MANIFEST.json"), "w"))
        self.assertIn("counts drift: questions.jsonl", vm.verify(self.d))

    # basis: pins the verifier's own unlisted and missing file messages; no spec text
    # oracle: CHARACTERIZATION
    def test_unlisted_and_missing_files_detected(self):
        open(os.path.join(self.d, "extra.jsonl"), "w").write("{}\n")
        os.remove(os.path.join(self.d, "probes.jsonl"))
        pr = vm.verify(self.d)
        self.assertIn("unlisted data file: extra.jsonl", pr)
        self.assertIn("missing file: probes.jsonl", pr)

    # basis: the per-type minimum of 30 is the repo's choice; specs/009-jev-decision-models/spec.md:384 (SC-003) requires 30 questions across the three types, not 30 per type
    # oracle: CHARACTERIZATION
    def test_minimums_enforced(self):
        p = os.path.join(self.d, "questions.jsonl")
        items = [i for i in vm.read_items(p) if i["type"] != "score"]
        with open(p, "w") as f:
            for i in items:
                f.write(json.dumps(i) + "\n")
        build_manifest.build(self.d)
        self.assertTrue(any("fewer than 30 score" in x for x in vm.verify(self.d)))

    # basis: pins the verifier's refusal of a labeled_by value without the honest provenance string; docs/golden-set.md:39-41 states the rule
    # oracle: CHARACTERIZATION
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
    # basis: golden-master of the shipped sets against the similarity thresholds chosen in this repo (0.5 on same-label); docs/golden-set.md:185-186 records the reference values
    # oracle: CHARACTERIZATION
    def test_shipped_sets_have_no_breach(self):
        items = similarity.load([os.path.join(vm.DEFAULT_DIR, n) for n in vm.DATA_FILES])
        rep = similarity.analyse(items)
        self.assertEqual(rep["breaches"], [])
        self.assertLess(rep["max_similarity_same_label"], 0.5)

    # basis: hand-constructed near-duplicate (one added trailing full stop) so similarity is close to 1 by construction; the breach threshold is the tool's own
    # oracle: DERIVED
    def test_planted_duplicate_is_found(self):
        a = {"id": "a", "type": "noul", "state": "Please review my pull request this week", "expected": False}
        b = dict(a, id="b", state="Please review my pull request this week.")
        rep = similarity.analyse([a, b])
        self.assertEqual(len(rep["breaches"]), 1)
        self.assertGreater(rep["max_similarity_same_label"], 0.9)

    # basis: a deliberately differing SQL pair must not breach; docs/golden-set.md:185-186 describes the intentional contrast pair; threshold is the tool's own
    # oracle: CHARACTERIZATION
    def test_contrast_pair_is_listed_not_failed_below_any_threshold(self):
        a = {"id": "a", "type": "noul", "state": "SELECT * FROM users WHERE age > 30;", "expected": True}
        b = {"id": "b", "type": "noul", "state": "SELECT * FROM users WHERE age >= 30 ORDER BY id;", "expected": False}
        self.assertEqual(similarity.analyse([a, b])["breaches"], [])

    # basis: pins that similarity never compares items of different types (max 0.0); tool design
    # oracle: CHARACTERIZATION
    def test_different_types_never_compared(self):
        a = {"id": "a", "type": "noul", "state": "same text", "expected": True}
        b = dict(a, id="b", type="choice")
        self.assertEqual(similarity.analyse([a, b])["max_similarity_any"], 0.0)


if __name__ == "__main__":
    unittest.main()
