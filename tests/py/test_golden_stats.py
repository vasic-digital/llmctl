"""Unit tests for scripts/golden/stats.py (golden-set statistics, SC-003 / FR-080).

Every expected number below was worked out by hand; the working is in the comments.
"""
import unittest

from scripts.golden import stats


def rec(i, typ="noul", exp=True, pred=True, family="f", **kw):
    r = {"id": i, "type": typ, "family": family, "expected": exp, "predicted": pred,
         "well_formed": pred is not None, "variant": "orig"}
    r.update(kw)
    return r


class WilsonTests(unittest.TestCase):
    def test_known_values(self):
        # Hand calculation for k=8, n=10, z=1.96:
        #   p=0.8, z^2=3.8416, denom=1+z^2/n=1.38416
        #   centre=(0.8+z^2/(2n))/denom=(0.8+0.19208)/1.38416=0.71672
        #   half=z*sqrt(p(1-p)/n+z^2/(4n^2))/denom=1.96*sqrt(0.016+0.009604)/1.38416=0.22659
        #   interval = [0.4902, 0.9433]   (the textbook Wilson 8/10 interval)
        lo, hi = stats.wilson(8, 10)
        self.assertAlmostEqual(lo, 0.4902, places=3)
        self.assertAlmostEqual(hi, 0.9433, places=3)
        # 0/10 -> [0, 0.2775] and 10/10 -> [0.7225, 1] (published reference values)
        lo, hi = stats.wilson(0, 10)
        self.assertAlmostEqual(lo, 0.0, places=6)
        self.assertAlmostEqual(hi, 0.2775, places=3)
        lo, hi = stats.wilson(10, 10)
        self.assertAlmostEqual(lo, 0.7225, places=3)
        self.assertAlmostEqual(hi, 1.0, places=6)
        # 50/100 -> [0.4038, 0.5962]
        lo, hi = stats.wilson(50, 100)
        self.assertAlmostEqual(lo, 0.4038, places=3)
        self.assertAlmostEqual(hi, 0.5962, places=3)

    def test_empty_sample_is_uninformative(self):
        self.assertEqual(stats.wilson(0, 0), (0.0, 1.0))

    def test_mutation_wald_interval_would_fail(self):
        # Mutation-style guard: a naive Wald interval gives [1,1] for 10/10 and [0,0] for 0/10.
        # Wilson must stay informative; this test fails if wilson() is mutated to p +/- z*sqrt(p(1-p)/n).
        lo, _ = stats.wilson(10, 10)
        self.assertLess(lo, 0.75)
        _, hi = stats.wilson(0, 10)
        self.assertGreater(hi, 0.25)

    def test_mutation_wrong_z_detected(self):
        # With z=1.0 instead of 1.96 the 8/10 lower bound would be ~0.65, not 0.49.
        lo_wrong, _ = stats.wilson(8, 10, z=1.0)
        lo, _ = stats.wilson(8, 10)
        self.assertGreater(lo_wrong, lo + 0.05)

    def test_lower_bound_vs_baseline(self):
        # 95/100 -> lower 0.8882 > 0.85 ; 90/100 -> lower 0.8256 <= 0.85 (the "79% majority trap" shape)
        self.assertTrue(stats.lower_exceeds_baseline(stats.wilson(95, 100)[0], 0.85))
        self.assertFalse(stats.lower_exceeds_baseline(stats.wilson(90, 100)[0], 0.85))
        # A strict inequality: equality is not "exceeds".
        self.assertFalse(stats.lower_exceeds_baseline(0.5, 0.5))


class BaselineTests(unittest.TestCase):
    def test_majority(self):
        # 17 false / 3 true -> majority false at 0.85
        label, share = stats.majority([False] * 17 + [True] * 3)
        self.assertIs(label, False)
        self.assertAlmostEqual(share, 0.85)
        self.assertEqual(stats.majority([]), (None, 0.0))

    def test_majority_tie_is_deterministic(self):
        a = stats.majority(["x", "y", "x", "y"])
        b = stats.majority(["y", "x", "y", "x"])
        self.assertEqual(a, b)

    def test_imbalanced_item_always_false_matches_baseline_not_beats_it(self):
        # 20 items, 17 false: a model that always says false scores 17/20 = 0.85 exactly the majority share.
        recs = [rec("a%d" % i, exp=False, pred=False, family="is_urgent") for i in range(17)]
        recs += [rec("b%d" % i, exp=True, pred=False, family="is_urgent") for i in range(3)]
        rep = stats.report(recs)
        fam = rep["per_family"]["is_urgent"]
        self.assertAlmostEqual(fam["accuracy"], 0.85)
        self.assertAlmostEqual(fam["majority_share"], 0.85)
        self.assertFalse(fam["lower_bound_exceeds_majority"])
        # per-class accuracy exposes the trap: 100% on false, 0% on true
        self.assertAlmostEqual(rep["per_class"]["noul:False"]["accuracy"], 1.0)
        self.assertAlmostEqual(rep["per_class"]["noul:True"]["accuracy"], 0.0)

    def test_type_baseline_is_larger_of_majority_and_chance(self):
        # 4 choice items with 4 options each: chance 0.25; expected labels a,a,a,b -> majority 0.75
        recs = [rec("c%d" % i, typ="choice", exp=e, pred=e, option_count=4) for i, e in enumerate("aaab")]
        row = stats.report(recs)["by_type"]["choice"]
        self.assertAlmostEqual(row["majority_share"], 0.75)
        self.assertAlmostEqual(row["chance_level"], 0.25)
        self.assertAlmostEqual(row["baseline"], 0.75)
        self.assertEqual(row["baseline_kind"], "majority")


class AccuracyTests(unittest.TestCase):
    def test_malformed_counts_as_wrong(self):
        recs = [rec("1", pred=True), rec("2", pred=None), rec("3", exp=False, pred=False)]
        rep = stats.report(recs)
        self.assertEqual(rep["well_formed"]["ok"], 2)
        self.assertEqual(rep["by_type"]["noul"]["correct"], 2)   # items 1 and 3
        self.assertEqual(rep["by_type"]["noul"]["n"], 3)

    def test_score_within_one(self):
        recs = [rec("s1", typ="score", exp=3, pred=3, scale=5), rec("s2", typ="score", exp=3, pred=4, scale=5),
                rec("s3", typ="score", exp=3, pred=0, scale=5)]
        row = stats.report(recs)["by_type"]["score"]
        self.assertAlmostEqual(row["accuracy"], 1 / 3.0)
        self.assertAlmostEqual(row["within_one_level"], 2 / 3.0)

    def test_accuracy_by_option_count_table(self):
        recs = [rec("a", typ="choice", exp="x", pred="x", option_count=2),
                rec("b", typ="choice", exp="x", pred="y", option_count=2),
                rec("c", typ="choice", exp="x", pred="x", option_count=8)]
        t = stats.report(recs)["accuracy_by_option_count"]
        self.assertEqual(sorted(t), ["2", "8"])
        self.assertAlmostEqual(t["2"]["accuracy"], 0.5)
        self.assertAlmostEqual(t["8"]["accuracy"], 1.0)

    def test_permuted_variants_do_not_inflate_accuracy(self):
        recs = [rec("c1", typ="choice", exp="x", pred="y", option_count=2, perm_group="g"),
                rec("c1", typ="choice", exp="x", pred="x", option_count=2, perm_group="g", variant="perm")]
        rep = stats.report(recs)
        self.assertEqual(rep["by_type"]["choice"]["n"], 1)
        self.assertAlmostEqual(rep["by_type"]["choice"]["accuracy"], 0.0)


class FlipTests(unittest.TestCase):
    def test_flip_rate(self):
        # group g1 answers x,x (stable); g2 answers x,y (flip); g3 has only one answer (not counted)
        recs = [rec("1", typ="choice", pred="x", perm_group="g1"), rec("1p", typ="choice", pred="x", perm_group="g1", variant="perm"),
                rec("2", typ="choice", pred="x", perm_group="g2"), rec("2p", typ="choice", pred="y", perm_group="g2", variant="perm"),
                rec("3", typ="choice", pred="x", perm_group="g3")]
        fl = stats.flip_rate(recs)
        self.assertEqual((fl["groups"], fl["flipped"]), (2, 1))
        self.assertAlmostEqual(fl["flip_rate"], 0.5)

    def test_flip_rate_none_when_no_groups(self):
        self.assertIsNone(stats.flip_rate([rec("1", typ="choice", pred="x", perm_group="g")])["flip_rate"])

    def test_malformed_answer_is_not_a_flip(self):
        recs = [rec("1", typ="choice", pred="x", perm_group="g"), rec("1p", typ="choice", pred=None, perm_group="g", variant="perm")]
        self.assertIsNone(stats.flip_rate(recs)["flip_rate"])

    def test_pair_consistency(self):
        recs = [rec("a", pred=True, pair_id="A"), rec("b", pred=True, pair_id="A"),
                rec("c", pred=True, pair_id="B"), rec("d", pred=False, pair_id="B")]
        pc = stats.pair_consistency(recs)
        self.assertEqual((pc["pairs"], pc["agree"]), (2, 1))


class CalibrationTests(unittest.TestCase):
    def _pairs(self, correct_low):
        # 100 answers at confidence 0.95 (bin 9) of which 95 correct,
        # 100 answers at confidence 0.65 (bin 6) of which `correct_low` correct.
        return [(0.95, 1)] * 95 + [(0.95, 0)] * 5 + [(0.65, 1)] * correct_low + [(0.65, 0)] * (100 - correct_low)

    def test_insufficient_below_200(self):
        c = stats.calibration(self._pairs(65)[:199])
        self.assertEqual(c["status"], "insufficient for calibration")
        self.assertEqual(c["n"], 199)
        self.assertNotIn("ece", c)

    def test_perfectly_calibrated_at_200(self):
        # bins: |0.95-0.95|=0 and |0.65-0.65|=0 -> ECE 0, MCE 0
        # Brier = mean over 200 of (p-correct)^2
        #   0.95 group: (95*0.05^2 + 5*0.95^2)/100 = (0.2375+4.5125)/100 = 0.0475
        #   0.65 group: (65*0.35^2 + 35*0.65^2)/100 = (7.9625+14.7875)/100 = 0.2275
        #   mean = 0.1375
        c = stats.calibration(self._pairs(65))
        self.assertEqual(c["status"], "ok")
        self.assertAlmostEqual(c["ece"], 0.0, places=9)
        self.assertAlmostEqual(c["mce"], 0.0, places=9)
        self.assertAlmostEqual(c["brier"], 0.1375, places=9)

    def test_mutation_overconfident_group_is_caught(self):
        # Only 45 of the 100 answers at confidence 0.65 are correct: gap 0.20 in bin 6.
        # ECE = (100/200)*0.20 = 0.10 ; MCE = 0.20
        c = stats.calibration(self._pairs(45))
        self.assertAlmostEqual(c["ece"], 0.10, places=9)
        self.assertAlmostEqual(c["mce"], 0.20, places=9)

    def test_report_gates_calibration_on_label_count(self):
        recs = [rec("i%d" % i, pred=True, p_pred=0.9) for i in range(199)]
        self.assertEqual(stats.report(recs)["calibration"]["status"], "insufficient for calibration")
        recs.append(rec("i199", pred=True, p_pred=0.9))
        self.assertEqual(stats.report(recs)["calibration"]["status"], "ok")

    def test_unlabelled_items_do_not_count_toward_calibration_minimum(self):
        recs = [rec("i%d" % i, exp=None, pred=True, p_pred=0.9) for i in range(250)]
        self.assertEqual(stats.report(recs)["calibration"]["status"], "insufficient for calibration")

    def test_a_calibrated_gateway_cannot_flatter_its_own_evaluation(self):
        # 200 answers whose raw winner probability is 0.9 but only 60% are right (overconfident raw).
        # The calibrated gateway SERVES confidence 0.6 and says so; ECE must still be computed from the
        # raw p_pred: |0.9 - 0.6| = 0.30, not |0.6 - 0.6| = 0.
        recs = [rec("a%d" % i, pred=True, p_pred=0.9, confidence=0.6, confidence_raw=0.8,
                    calibration={"method": "temperature", "n": 240, "profile_id": "p"}) for i in range(120)]
        recs += [rec("b%d" % i, exp=True, pred=False, p_pred=0.9, confidence=0.6, confidence_raw=0.8,
                     calibration={"method": "temperature", "n": 240, "profile_id": "p"}) for i in range(80)]
        rep = stats.report(recs)
        self.assertEqual(rep["calibration"]["status"], "ok")
        self.assertAlmostEqual(rep["calibration"]["ece"], 0.30, places=9)
        self.assertEqual(rep["calibrated_records"], 200)
        self.assertIn("p_pred", rep["calibration_input"])
        self.assertIn("raw", rep["calibration_input"])
        self.assertIn("served confidence is not used", stats.render(rep))

    def test_uncalibrated_run_reports_zero_calibrated_records(self):
        rep = stats.report([rec("1", pred=True, p_pred=0.9)])
        self.assertEqual(rep["calibrated_records"], 0)
        self.assertNotIn("served confidence is not used", stats.render(rep))

    def test_render_prints_the_insufficiency_text(self):
        text = stats.render(stats.report([rec("1", pred=True, p_pred=0.9)]))
        self.assertIn("insufficient for calibration", text)


class RefusalTests(unittest.TestCase):
    """G-160: a gateway limit refusal (422 validation_failed on a choice item with more options than the
    profile's max_options) is reported separately and is not scored as a malformed answer."""

    def test_well_formed_excludes_refused_and_reports_them(self):
        recs = [rec("1", pred=True), rec("2", pred=None, refused=True, refusal_reason="max_options"),
                rec("3", pred=None)]
        rep = stats.report(recs)
        self.assertEqual(rep["well_formed"]["n"], 2)       # 3 originals minus 1 refused
        self.assertEqual(rep["well_formed"]["ok"], 1)
        self.assertEqual(rep["refused"], {"n": 1, "reasons": {"max_options": 1}})
        self.assertEqual(rep["by_type"]["noul"]["n"], 3)   # accuracy denominator unchanged
        self.assertEqual(rep["by_type"]["noul"]["correct"], 1)
        self.assertIn("refused (limit): 1", stats.render(rep))

    def test_old_records_without_field_unchanged(self):
        rep = stats.report([rec("1", pred=True), rec("2", pred=None)])
        self.assertEqual(rep["well_formed"]["n"], 2)
        self.assertEqual(rep["refused"], {"n": 0, "reasons": {}})
        self.assertNotIn("refused (limit)", stats.render(rep))

    def test_refused_false_is_not_refused(self):
        rep = stats.report([rec("1", pred=None, refused=False)])
        self.assertEqual(rep["well_formed"]["n"], 1)
        self.assertEqual(rep["refused"]["n"], 0)

    def test_refused_not_in_accuracy_by_option_count(self):
        recs = [rec("1", typ="choice", exp="a", pred="a", option_count=20),
                rec("2", typ="choice", exp="a", pred=None, option_count=20, refused=True, refusal_reason="max_options"),
                rec("3", typ="choice", exp="a", pred="b", option_count=4)]
        rep = stats.report(recs)
        self.assertEqual(rep["accuracy_by_option_count"]["20"]["n"], 1)
        self.assertEqual(rep["accuracy_by_option_count"]["20"]["correct"], 1)
        self.assertEqual(rep["refused"]["n"], 1)

    def test_old_results_render_identically(self):
        import json, os
        root = os.path.join(os.path.dirname(__file__), "..", "..", "specs", "009-jev-decision-models",
                            "evidence", "live-models", "nezha-decide-2b-2026-10-08")
        res = os.path.join(root, "golden", "results.json")
        txt = os.path.join(root, "golden-stats.txt")
        if not (os.path.exists(res) and os.path.exists(txt)):
            self.skipTest("stored evidence not present")
        old = json.load(open(res))
        rendered = stats.render(stats.report(old["records"]))
        self.assertEqual(rendered.strip(), open(txt).read().strip())



if __name__ == "__main__":
    unittest.main()
