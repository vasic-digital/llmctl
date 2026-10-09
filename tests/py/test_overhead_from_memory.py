"""Unit tests for scripts/overhead_from_memory.py (spec 009 T139, G-137/G-138).

Hand-computed examples pin the rule  overhead = ceil(1.10 x (peak - weights))  with exact rational arithmetic.
Stand-ins (temp evidence files) are allowed only in this unit tier.
"""
import copy
import importlib.util
import json
import os
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SPEC = importlib.util.spec_from_file_location("overhead_from_memory", os.path.join(ROOT, "scripts", "overhead_from_memory.py"))
ofm = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ofm)

MIB = 1048576
WEIGHTS_BYTES = 100 * MIB          # exactly 100 MiB


def summary_json(peak_kb_list, ctx=2048):
    return json.dumps({"profile": "decide-x", "ctx": ctx, "model_bytes": WEIGHTS_BYTES,
                       "memory": [{"label": "l%d" % i, "VmHWM_kB": kb, "VmRSS_kB": kb} for i, kb in enumerate(peak_kb_list)]})


class Rule(unittest.TestCase):
    def test_hand_computed_overhead(self):
        # peak 600 MiB = 614400 kB, weights 100 MiB: (600-100)*1.10 = 550 exactly -> 550
        self.assertEqual(ofm.overhead_from_peak(ofm.Fraction(614400, 1024), ofm.Fraction(WEIGHTS_BYTES, MIB)), 550)
        # peak 600.5 MiB: (500.5)*1.10 = 550.55 -> ceil 551
        self.assertEqual(ofm.overhead_from_peak(ofm.Fraction(614912, 1024), ofm.Fraction(WEIGHTS_BYTES, MIB)), 551)
        # peak below the weights (mmap not yet touched): never negative
        self.assertEqual(ofm.overhead_from_peak(ofm.Fraction(50), ofm.Fraction(100)), 0)

    def test_vram_rule_is_the_same_margin_on_the_peak_pid_vram(self):
        self.assertEqual(ofm.vram_overhead(2382), 2621)   # ceil(2382 x 1.10) = ceil(2620.2)
        self.assertEqual(ofm.vram_overhead(100), 110)     # exactly 110.0 stays 110


class Parsers(unittest.TestCase):
    def test_memory_summary_peak_is_the_max_hwm(self):
        peak, ctx = ofm.parse_summary_json(summary_json([100000, 614400, 300000], ctx=2048))
        self.assertEqual((peak, ctx), (ofm.Fraction(614400, 1024), 2048))

    def test_ctx_peak_txt_selects_model_and_ctx(self):
        txt = ("# header\nmodel=A-Q8_0.gguf ctx=1024 idleHWM_kB=1 peakHWM_kB=2048\n"
               "model=A-Q8_0.gguf ctx=2048 idleHWM_kB=1 peakHWM_kB=4096\nmodel=B-Q8_0.gguf ctx=1024 idleHWM_kB=1 peakHWM_kB=9999\n")
        self.assertEqual(ofm.parse_ctx_peak(txt, "A-Q8_0.gguf", 2048), ofm.Fraction(4096, 1024))
        with self.assertRaises(ValueError):
            ofm.parse_ctx_peak(txt, "A-Q8_0.gguf", 4096)     # no such line: an error, never a guess

    def test_pid_vram_txt_takes_the_maximum(self):
        txt = "## s\nVmHWM: 1 kB\nvram(MiB) pid=1: 126\nvram(MiB) pid=1: 176\nvram(MiB) pid=1: 150\n"
        self.assertEqual(ofm.parse_pid_vram(txt), 176)
        with self.assertRaises(ValueError):
            ofm.parse_pid_vram("nothing here\n")

    def test_cpu_mode_apps_txt_takes_the_pid_the_transcript_names(self):
        # T139/G-138: a cpu-mode (-ngl 0) run recorded as an nvidia-smi compute-apps listing plus the operator's
        # "=> engine pid P holds N MiB" line.  The vision pid at the SAME binary path must NOT be picked.
        txt = ("cmd: llmctl start x (mode=cpu)\n"
               "6608, 3069 MiB, /opt/other/llama-server\n"
               "3160295, 3752 MiB, /repo/build/bin/llama-server\n"
               "1842432, 4460 MiB, /repo/build/bin/llama-server\n"
               "=> engine pid 1842432 holds 4460 MiB VRAM in cpu mode (-ngl 0); scheduler booked 0 MiB VRAM\n")
        self.assertEqual(ofm.parse_cpu_mode_apps(txt), 4460)
        # the named pid's row is the authority: a conclusion line that disagrees with the listing is refused
        with self.assertRaises(ValueError):
            ofm.parse_cpu_mode_apps(txt.replace("holds 4460 MiB", "holds 4000 MiB"))
        # a named pid with no listing row, and a transcript with no conclusion line, are errors, never a guess
        with self.assertRaises(ValueError):
            ofm.parse_cpu_mode_apps(txt.replace("=> engine pid 1842432", "=> engine pid 999"))
        with self.assertRaises(ValueError):
            ofm.parse_cpu_mode_apps("1842432, 4460 MiB, /x/llama-server\n")


class Derive(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "ev"))
        with open(os.path.join(self.root, "ev", "mem.json"), "w") as f:
            f.write(summary_json([614400]))
        with open(os.path.join(self.root, "ev", "vram.txt"), "w") as f:
            f.write("vram(MiB) pid=9: 1000\nvram(MiB) pid=9: 1200\n")
        self.cat = {"profiles": {
            "decide-x": {"capability": ["decide"], "files": [{"name": "m.gguf", "size": WEIGHTS_BYTES, "role": "model"}],
                         "defaults": {"ctx": 2048},
                         "memory": {"ram": {"status": "measured", "format": "memory-summary-json", "evidence": "ev/mem.json", "host": "t"},
                                    "vram": {"status": "measured", "format": "pid-vram-txt", "evidence": "ev/vram.txt", "host": "t"}}},
            "decide-y": {"capability": ["decide"], "files": [{"name": "m.gguf", "size": WEIGHTS_BYTES, "role": "model"}],
                         "defaults": {"ctx": 4096},
                         "memory": {"ram": {"status": "unmeasured", "reason": "no model on the measuring host"},
                                    "vram": {"status": "unmeasured", "reason": "no GPU on the measuring host"}}},
            "fast": {"capability": ["chat"]}}}

    def test_measured_profile_numbers(self):
        d = ofm.derive(self.cat, self.root)
        self.assertEqual(d["decide-x"]["defaults"], {"overhead_mb": 550, "overhead_vram_mb": 1320, "window_tokens": 2048})
        self.assertEqual(d["decide-x"]["memory"]["ram"]["peak_hwm_mib"], 600.0)
        self.assertEqual(d["decide-x"]["memory"]["ram"]["weights_mib"], 100.0)
        self.assertEqual(d["decide-x"]["memory"]["vram"]["peak_mib"], 1200)

    def test_cpu_mode_apps_format_derives_the_same_margin(self):
        with open(os.path.join(self.root, "ev", "cpu.txt"), "w") as f:
            f.write("1, 4460 MiB, /x/llama-server\n=> engine pid 1 holds 4460 MiB VRAM in cpu mode\n")
        cat = copy.deepcopy(self.cat)
        cat["profiles"]["decide-x"]["memory"]["vram"] = {"status": "measured", "format": "cpu-mode-apps-txt",
                                                         "evidence": "ev/cpu.txt", "host": "t"}
        d = ofm.derive(cat, self.root)
        self.assertEqual(d["decide-x"]["defaults"]["overhead_vram_mb"], 4906)   # ceil(4460 x 1.10) = 4906
        self.assertEqual(d["decide-x"]["memory"]["vram"]["peak_mib"], 4460)

    def test_unmeasured_profile_declares_no_numbers(self):
        d = ofm.derive(self.cat, self.root)
        self.assertEqual(d["decide-y"]["defaults"], {})
        self.assertEqual(d["decide-y"]["memory"]["ram"]["status"], "unmeasured")

    def test_non_decision_profiles_are_skipped(self):
        self.assertNotIn("fast", ofm.derive(self.cat, self.root))

    def test_check_passes_after_apply_and_catches_each_tamper(self):
        ofm.apply(self.cat, self.root)
        self.assertEqual(ofm.check(self.cat, self.root), [])
        for mutate in (lambda c: c["profiles"]["decide-x"]["defaults"].__setitem__("overhead_mb", 100),
                       lambda c: c["profiles"]["decide-x"]["defaults"].__setitem__("overhead_vram_mb", 0),
                       lambda c: c["profiles"]["decide-x"]["defaults"].__setitem__("window_tokens", 1),
                       lambda c: c["profiles"]["decide-x"]["memory"]["ram"].__setitem__("peak_hwm_mib", 1.0),
                       lambda c: c["profiles"]["decide-x"]["memory"]["ram"].__setitem__("evidence", "ev/missing.json"),
                       lambda c: c["profiles"]["decide-x"].pop("memory"),
                       lambda c: c["profiles"]["decide-y"]["defaults"].__setitem__("overhead_mb", 5)):  # unmeasured must carry none
            bad = copy.deepcopy(self.cat)
            mutate(bad)
            self.assertTrue(ofm.check(bad, self.root), "a tampered catalog must be rejected")

    def test_control_needle_changing_the_evidence_changes_the_number(self):
        before = ofm.derive(self.cat, self.root)["decide-x"]["defaults"]["overhead_mb"]
        with open(os.path.join(self.root, "ev", "mem.json"), "w") as f:
            f.write(summary_json([716800]))        # 700 MiB
        after = ofm.derive(self.cat, self.root)["decide-x"]["defaults"]["overhead_mb"]
        self.assertEqual((before, after), (550, 660))   # (700-100)*1.1


if __name__ == "__main__":
    unittest.main()
