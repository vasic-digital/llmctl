"""Unit tests for scripts/maturity_from_golden.py (spec 009 T138, OD-24).

Stand-ins are allowed here (unit tier): the stats text is a fixture in the exact format
scripts/golden/stats.py prints.  A control needle proves the parser can SEE a status flip.
"""
import copy
import importlib.util
import json
import os
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SPEC = importlib.util.spec_from_file_location("maturity_from_golden", os.path.join(ROOT, "scripts", "maturity_from_golden.py"))
mfg = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mfg)

STATS = """records=173 orig=132 perm=41 well_formed=132/132
noul   n=60 acc=0.817 CI95=[0.701,0.894] baseline=0.667 (majority) lower>baseline=True
choice n=41 acc=0.878 CI95=[0.745,0.947] baseline=0.235 (chance) lower>baseline=True
score  n=31 acc=0.290 CI95=[0.161,0.466] baseline=0.290 (majority) lower>baseline=False
per-class:
  noul:False             n=40 acc=0.975
"""


class ParseStats(unittest.TestCase):
    def test_reads_every_type_with_numbers(self):
        r = mfg.parse_stats(STATS)
        self.assertEqual(sorted(r), ["choice", "noul", "score"])
        self.assertEqual(r["noul"], {"n": 60, "lower_bound": 0.701, "baseline": 0.667})
        self.assertEqual(r["score"]["n"], 31)

    def test_status_rule_is_strictly_greater(self):
        self.assertEqual(mfg.status_for(0.701, 0.667), "measured")
        self.assertEqual(mfg.status_for(0.667, 0.667), "experimental")  # equal does not clear
        self.assertEqual(mfg.status_for(0.161, 0.290), "experimental")

    def test_control_needle_flip_is_visible(self):
        # the SAME text with the noul lower bound moved below the baseline must flip noul and only noul
        flipped = STATS.replace("CI95=[0.701,0.894]", "CI95=[0.601,0.894]").replace("lower>baseline=True\nchoice", "lower>baseline=False\nchoice", 1)
        a = {t: mfg.status_for(v["lower_bound"], v["baseline"]) for t, v in mfg.parse_stats(STATS).items()}
        b = {t: mfg.status_for(v["lower_bound"], v["baseline"]) for t, v in mfg.parse_stats(flipped).items()}
        self.assertEqual(a["noul"], "measured")
        self.assertEqual(b["noul"], "experimental")
        self.assertEqual(a["choice"], b["choice"])

    def test_disagreement_between_numbers_and_printed_verdict_is_an_error(self):
        bad = STATS.replace("baseline=0.290 (majority) lower>baseline=False", "baseline=0.290 (majority) lower>baseline=True")
        with self.assertRaises(ValueError):
            mfg.parse_stats(bad)

    def test_missing_type_is_an_error(self):
        with self.assertRaises(ValueError):
            mfg.parse_stats("\n".join(l for l in STATS.splitlines() if not l.startswith("score")))


class Derive(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.addCleanup(self.tmp.cleanup)
        live = os.path.join(self.root, mfg.LIVE_REL)
        os.makedirs(os.path.join(live, "decide-a"))
        with open(os.path.join(live, "decide-a", "golden-stats.txt"), "w") as f:
            f.write(STATS)
        os.makedirs(os.path.join(live, "nezha", "decide-b"))
        with open(os.path.join(live, "nezha", "decide-b", "golden-stats.txt"), "w") as f:
            f.write(STATS)
        self.cat = {"profiles": {
            "decide-a": {"capability": ["decide"], "decision": {"protocol": "systemone-native"}},
            "decide-b": {"capability": ["decide"], "decision": {"protocol": "systemone-native"}},
            "decide-c": {"capability": ["decide"], "decision": {"protocol": "letter-logit"}},
            "fast": {"capability": ["chat"]},
        }}

    def test_profile_with_a_golden_run_is_measured_or_experimental_per_type(self):
        m = mfg.derive(self.cat, self.root)
        self.assertEqual({t: m["decide-a"][t]["status"] for t in ("noul", "choice", "score")},
                         {"noul": "measured", "choice": "measured", "score": "experimental"})
        self.assertEqual(m["decide-a"]["noul"]["evidence"], mfg.LIVE_REL + "/decide-a/golden-stats.txt")
        self.assertEqual(m["decide-a"]["noul"]["n"], 60)

    def test_nezha_location_is_used_when_the_primary_one_is_absent(self):
        m = mfg.derive(self.cat, self.root)
        self.assertEqual(m["decide-b"]["choice"]["evidence"], mfg.LIVE_REL + "/nezha/decide-b/golden-stats.txt")

    def test_profile_without_a_run_is_unmeasured_with_the_reason(self):
        m = mfg.derive(self.cat, self.root)
        for t in ("noul", "choice", "score"):
            self.assertEqual(m["decide-c"][t], {"status": "unmeasured", "reason": "not yet measured"})

    def test_non_decision_profiles_get_nothing(self):
        self.assertNotIn("fast", mfg.derive(self.cat, self.root))

    def test_check_detects_a_hand_typed_status_and_write_repairs_it(self):
        derived = mfg.derive(self.cat, self.root)
        for name, m in derived.items():
            self.cat["profiles"][name]["maturity"] = copy.deepcopy(m)
        self.assertEqual(mfg.check(self.cat, self.root), [])
        self.cat["profiles"]["decide-a"]["maturity"]["score"]["status"] = "measured"   # hand-typed lie
        diffs = mfg.check(self.cat, self.root)
        self.assertEqual(len(diffs), 1)
        self.assertIn("decide-a", diffs[0])
        mfg.apply(self.cat, self.root)
        self.assertEqual(mfg.check(self.cat, self.root), [])

    def test_check_detects_a_missing_maturity_object_and_a_vanished_evidence_file(self):
        self.assertTrue(any("decide-a" in d for d in mfg.check(self.cat, self.root)))
        mfg.apply(self.cat, self.root)
        os.remove(os.path.join(self.root, mfg.LIVE_REL, "decide-a", "golden-stats.txt"))
        self.assertTrue(any("decide-a" in d for d in mfg.check(self.cat, self.root)))


class Recompute(unittest.TestCase):
    """--check recomputes from golden/results.json with the real stats.py: a doctored golden-stats.txt that
    still agrees with ITSELF (so parse_stats accepts it) is caught here."""

    def _run_dir(self, stats_text):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        d = os.path.join(tmp.name, mfg.LIVE_REL, "decide-a")
        os.makedirs(os.path.join(d, "golden"))
        with open(os.path.join(d, "golden-stats.txt"), "w") as f:
            f.write(stats_text)
        recs = ([{"id": "n%d" % i, "type": "noul", "expected": True, "predicted": True, "well_formed": True, "variant": "orig"} for i in range(60)] +
                [{"id": "c%d" % i, "type": "choice", "expected": "a", "predicted": "a", "well_formed": True, "variant": "orig", "option_count": 4} for i in range(41)] +
                [{"id": "s%d" % i, "type": "score", "expected": 3, "predicted": 3, "well_formed": True, "variant": "orig", "scale": 5} for i in range(31)])
        with open(os.path.join(d, "golden", "results.json"), "w") as f:
            json.dump({"records": recs}, f)
        return tmp.name

    def test_agreeing_text_passes_and_doctored_text_is_caught(self):
        sys_path = os.path.join(ROOT, "scripts", "golden")
        import sys
        sys.path.insert(0, sys_path)
        import stats
        with open(os.path.join(self._run_dir(STATS), mfg.LIVE_REL, "decide-a", "golden", "results.json")) as f:
            recs = json.load(f)["records"]
        rep = stats.report(recs)["by_type"]
        honest = "\n".join("%-6s n=%d acc=1.000 CI95=[%.3f,1.000] baseline=%.3f (majority) lower>baseline=%s" % (
            t, rep[t]["n"], rep[t]["wilson_low"], rep[t]["baseline"], rep[t]["wilson_low"] > rep[t]["baseline"]) for t in mfg.TYPES)
        root = self._run_dir(honest)
        cat = {"profiles": {"decide-a": {"capability": ["decide"]}}}
        self.assertEqual(mfg.check(cat, root), [x for x in mfg.check(cat, root) if "maturity differs" in x])  # only the missing maturity object
        self.assertFalse([d for d in mfg.check(cat, root) if "recomputed" in d])
        doctored = honest.replace("n=60", "n=61", 1)
        root2 = self._run_dir(doctored)
        self.assertTrue([d for d in mfg.check(cat, root2) if "recomputed" in d and "n is 61" in d])


if __name__ == "__main__":
    unittest.main()
