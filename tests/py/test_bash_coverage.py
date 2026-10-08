"""Unit + end-to-end tests for scripts/coverage/bash_line_coverage.py (+ trace_init.sh).

Test-first / control-needle design (Constitution 11.4.224, 11.4.201(7)): a fixture bash
script with KNOWN covered and uncovered lines is traced through the REAL pipeline
(BASH_ENV -> xtrace -> FIFO -> collector -> report). The needle: a function body that is
never called MUST be reported uncovered, and a called one covered, so a blind or
always-100% instrument cannot pass.
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL = os.path.join(ROOT, "scripts", "coverage", "bash_line_coverage.py")
INIT = os.path.join(ROOT, "scripts", "coverage", "trace_init.sh")

FIXTURE = textwrap.dedent('''\
    #!/usr/bin/env bash
    # comment line
    set -euo pipefail

    called_fn() {
      local x=1
      echo "called ${x}"
    }

    never_called_fn() {
      local y=2
      echo "never ${y}"
      return 3
    }

    mode="${1:-a}"
    case "${mode}" in
      a)
        echo "arm-a"
        ;;
      b)
        echo "arm-b"
        ;;
    esac

    if [[ "${mode}" == "a" ]]; then
      called_fn
    else
      echo "else-arm"
    fi

    cat <<EOT >/dev/null
    heredoc body line
    EOT

    long_cmd=$(echo one \\
      two)
    msg="multi
    line string"
    echo "${long_cmd} ${msg}" >/dev/null
''')


def line_of(text, needle, nth=1):
    seen = 0
    for i, ln in enumerate(text.split("\n"), 1):
        if needle in ln:
            seen += 1
            if seen == nth:
                return i
    raise AssertionError("needle %r not in fixture" % needle)


class ClassifierTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="covtest.")
        self.fx = os.path.join(self.tmp, "fixture.sh")
        with open(self.fx, "w") as fh:
            fh.write(FIXTURE)
        sys.path.insert(0, os.path.dirname(TOOL))
        import bash_line_coverage as blc  # noqa: E402
        self.blc = blc

    def tearDown(self):
        sys.path.remove(os.path.dirname(TOOL))
        for n in os.listdir(self.tmp):
            os.unlink(os.path.join(self.tmp, n))
        os.rmdir(self.tmp)

    def test_non_executable_lines_are_excluded(self):
        ex, owner, n, warn = self.blc.classify(self.fx)
        self.assertEqual(warn, [])
        for needle, nth in (("# comment line", 1), ("called_fn() {", 1), ("never_called_fn() {", 1),
                            ("a)", 1), (";;", 1), ("esac", 1), ("else", 1), ("fi", 1),
                            ("heredoc body line", 1), ("EOT", 2), ("two)", 1), ("line string", 1)):
            ln = line_of(FIXTURE, needle, nth)
            self.assertNotIn(ln, ex, "line %d (%r) must not be executable" % (ln, needle))

    def test_executable_lines_are_included(self):
        ex = self.blc.classify(self.fx)[0]
        for needle in ("set -euo", 'local y=2', 'echo "arm-a"', 'case "${mode}"', "  called_fn"):
            ln = line_of(FIXTURE, needle)
            self.assertIn(ln, ex, "line %d (%r) must be executable" % (ln, needle))
        # the heredoc start line is a command; the multi-line statements start lines too
        self.assertIn(line_of(FIXTURE, "cat <<EOT"), ex)
        self.assertIn(line_of(FIXTURE, "long_cmd=$("), ex)
        self.assertIn(line_of(FIXTURE, 'msg="multi'), ex)

    def test_function_ranges(self):
        fns = {n: (s, e) for n, s, e in self.blc.functions(self.fx)}
        self.assertEqual(set(fns), {"called_fn", "never_called_fn"})
        self.assertEqual(fns["called_fn"][0], line_of(FIXTURE, "called_fn() {"))


class EndToEndTraceTest(unittest.TestCase):
    """Real pipeline: BASH_ENV -> xtrace -> FIFO -> collector -> report."""

    def run_pipeline(self, argv):
        tmp = tempfile.mkdtemp(prefix="covtest.")
        self.addCleanup(self._rm, tmp)
        fx = os.path.join(tmp, "fixture.sh")
        with open(fx, "w") as fh:
            fh.write(FIXTURE)
        fifo = os.path.join(tmp, "trace.fifo")
        os.mkfifo(fifo)
        hits, rep = os.path.join(tmp, "hits.json"), os.path.join(tmp, "rep.json")
        coll = subprocess.Popen([sys.executable, "-B", TOOL, "collect", "--fifo", fifo, "--out", hits,
                                 "--root", tmp])
        try:
            env = dict(os.environ, BASH_ENV=INIT, LLMCTL_COV_FIFO=fifo)
            p = subprocess.run(["bash", fx] + argv, cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(p.returncode, 0, p.stderr)
            # tracing must not pollute the script's own stdout/stderr
            self.assertNotIn("+COV:", p.stdout + p.stderr)
        finally:
            coll.send_signal(signal.SIGTERM)
            coll.wait(timeout=30)
        subprocess.run([sys.executable, "-B", TOOL, "report", "--hits", hits, "--out", rep, fx], check=True)
        with open(rep) as fh:
            return fx, json.load(fh)[fx]

    @staticmethod
    def _rm(d):
        for n in os.listdir(d):
            os.unlink(os.path.join(d, n))
        os.rmdir(d)

    def test_called_function_covered_uncalled_function_uncovered(self):
        fx, rep = self.run_pipeline([])
        self.assertTrue(rep["had_any_hit"], "instrument saw nothing - blind, a zero here would be meaningless")
        unc = set(rep["uncovered_lines"])
        # control needle: never_called_fn body lines MUST be uncovered
        for needle in ("local y=2", 'echo "never ${y}"', "return 3"):
            self.assertIn(line_of(FIXTURE, needle), unc, needle)
        # called_fn body MUST be covered
        for needle in ("local x=1", 'echo "called ${x}"'):
            self.assertNotIn(line_of(FIXTURE, needle), unc, needle)
        # arm-b / else arm never ran with default args; arm-a did
        self.assertIn(line_of(FIXTURE, 'echo "arm-b"'), unc)
        self.assertIn(line_of(FIXTURE, 'echo "else-arm"'), unc)
        self.assertNotIn(line_of(FIXTURE, 'echo "arm-a"'), unc)
        # multi-line statements are credited to their first line
        self.assertNotIn(line_of(FIXTURE, "long_cmd=$("), unc)
        self.assertNotIn(line_of(FIXTURE, 'msg="multi'), unc)
        funcs = {f["name"]: f for f in rep["functions"]}
        self.assertEqual(funcs["never_called_fn"]["covered"], 0)
        self.assertGreater(funcs["never_called_fn"]["uncovered"], 0)
        self.assertEqual(funcs["called_fn"]["uncovered"], 0)

    def test_other_argument_flips_the_arms(self):
        fx, rep = self.run_pipeline(["b"])
        unc = set(rep["uncovered_lines"])
        self.assertNotIn(line_of(FIXTURE, 'echo "arm-b"'), unc)
        self.assertNotIn(line_of(FIXTURE, 'echo "else-arm"'), unc)
        self.assertIn(line_of(FIXTURE, 'echo "arm-a"'), unc)
        self.assertIn(line_of(FIXTURE, "local x=1"), unc)  # called_fn not called on this path

    def test_without_fifo_the_hook_is_inert(self):
        env = {k: v for k, v in os.environ.items() if k != "LLMCTL_COV_FIFO"}
        env["BASH_ENV"] = INIT
        p = subprocess.run(["bash", "-c", "echo ok"], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual((p.returncode, p.stdout, p.stderr), (0, "ok\n", ""))


if __name__ == "__main__":
    unittest.main()
