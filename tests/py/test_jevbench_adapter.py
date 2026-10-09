"""Unit tests for scripts/bench/jevbench_adapter.py (spec 009 T065 part a).

A loopback stand-in gateway answers /v1/systemone; a tiny fake harness (written to a temp dir, NOT the real
upstream harness) drives it exactly like `python -m jevbench.cli run` would and writes upstream-shaped result
records.  No network beyond 127.0.0.1.  Hand-worked numbers are in the comments.
"""
import csv
import hashlib
import shutil
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

from scripts.bench import jevbench_adapter as ja

FAKE_HARNESS = r'''
import json, os, sys, urllib.request, urllib.error
a = sys.argv[1:]
assert a[0] == "run"
opt = {a[i]: a[i + 1] for i in range(1, len(a) - 1, 2) if a[i].startswith("--")}
key = os.environ.get(opt["--key-env"], "")
out = open(opt["--results"], "x")
json.dump({k: os.environ.get(k) for k in ("SSL_CERT_FILE", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE")},
          open(opt["--results"] + ".env", "w"))
stop = False
for path in opt["--tasks"].split(","):
    if stop:
        break
    for line in open(path):
        t = json.loads(line)
        req = urllib.request.Request(opt["--endpoint"] + "/v1/systemone",
            data=json.dumps({"state": t["state"], "model": opt["--model"]}).encode(),
            headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"}, method="POST")
        rec = {"task_id": t["id"], "ok": False, "valid": False, "correct": False, "predicted": None,
               "probs": None, "status_code": None, "model": None, "error": None}
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                body = json.loads(r.read()); rec["status_code"] = r.status
        except urllib.error.HTTPError as e:
            rec["status_code"] = e.code; rec["error"] = "HTTP %d" % e.code; body = None
        if body is not None:
            rec["model"] = body.get("model")
            d = (body.get("answers") or {}).get("decision")
            if not isinstance(d, dict) or not isinstance(d.get("noul"), (int, float)):
                rec["error"] = "answer parse failed"
            else:
                p = float(d["noul"]); probs = {"yes": p, "no": 1 - p}
                pred = "yes" if p >= .5 else "no"
                rec.update(ok=True, valid=True, probs=probs, predicted=pred, correct=(pred == t["expected"]))
        out.write(json.dumps(rec) + "\n")
        if t["state"].startswith("BADLINE"):
            out.write("{not json\n")
        if t["state"].startswith("DUPRESULT"):
            out.write(json.dumps(rec) + "\n")
        if rec["status_code"] in (401, 403, 429):   # upstream Runner.run_all stop rule
            stop = True
            break
out.close()
'''


class Gateway(BaseHTTPRequestHandler):
    seen_auth = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(n))
        Gateway.seen_auth.append(self.headers.get("Authorization"))
        st = body["state"]
        if st.startswith("R422"):
            return self._send(422, {"error": "too long"})
        if st.startswith("R503"):
            return self._send(503, {"error": "busy"})
        for code in (401, 403, 429):
            if st.startswith("R%d" % code):
                return self._send(code, {"error": "x"})
        if st.startswith("MALFORMED"):
            return self._send(200, {"model": "served-x", "answers": {"decision": {"type": "noul"}}})
        p = 0.9 if st.startswith("A:yes") else 0.1
        self._send(200, {"model": "served-x", "answers": {"decision": {"type": "noul", "noul": p}}})

    def _send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def task(i, state, expected, lic="MIT", exclude=None):
    return {"id": "t%03d" % i, "family": "policy", "state": state, "expected": expected, "labels": ["no", "yes"],
            "provenance": {"license": lic, "exclude_reason": exclude}, "split": "public", "group": None,
            "question": {"type": "noul"}}


class AdapterBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = HTTPServer(("127.0.0.1", 0), Gateway)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.endpoint = "http://127.0.0.1:%d" % cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        os.environ["JB_TEST_KEY"] = "k-test"
        self.addCleanup(os.environ.pop, "JB_TEST_KEY", None)
        self.harness = os.path.join(self.root, "fake_harness.py")
        with open(self.harness, "w") as fh:
            fh.write(FAKE_HARNESS)

    def make_repo(self, tasks, split="original", manifest_sha=None, extra_splits=None, files=None):
        repo = os.path.join(self.root, "jevbench")
        os.makedirs(os.path.join(repo, "datasets", "public"))
        splits = [(split, tasks)] + list((extra_splits or {}).items())
        entries = []
        for name, ts in splits:
            data = "".join(json.dumps(t) + "\n" for t in ts).encode()
            with open(os.path.join(repo, "datasets", "public", name + ".jsonl"), "wb") as fh:
                fh.write(data)
            entries.append({"name": name, "n": len(ts), "sha256": (manifest_sha if name == split and manifest_sha
                                                                   else hashlib.sha256(data).hexdigest())})
        with open(os.path.join(repo, "datasets", "manifest.json"), "w") as fh:
            json.dump({"protocol": "t", "splits": entries}, fh)
        for rel, content in (files or {}).items():
            os.makedirs(os.path.dirname(os.path.join(repo, rel)) or repo, exist_ok=True)
            with open(os.path.join(repo, rel), "w") as fh:
                fh.write(content)
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        for cmd in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "x"]):
            subprocess.run(["git", "-C", repo] + cmd, check=True, env=env, capture_output=True)
        self.commit = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        return repo

    def run_adapter(self, repo, flags=(), commit=None, run="run1", public=True):
        argv = ["--jevbench-dir", repo, "--expect-commit", commit or self.commit, "--run-dir", os.path.join(self.root, run),
                "--endpoint", self.endpoint, "--model", "m", "--key-env", "JB_TEST_KEY",
                "--harness-cmd", "%s %s" % (sys.executable, self.harness)]
        if public:
            argv.append("--public-tier")
        rc = ja.main(argv + list(flags))
        path = os.path.join(self.root, run, "summary.json")
        summ = None
        if os.path.exists(path):
            with open(path) as fh:
                summ = json.load(fh)
        return rc, summ


class LabelAndGuardTests(AdapterBase):
    def test_public_tier_flag_required(self):
        repo = self.make_repo([task(0, "A:yes", "yes")])
        rc, summ = self.run_adapter(repo, public=False)
        self.assertEqual(2, rc)
        self.assertIsNone(summ)  # nothing was run

    def test_summary_labels(self):
        repo = self.make_repo([task(0, "A:yes", "yes")])
        rc, s = self.run_adapter(repo)
        self.assertEqual(0, rc)
        self.assertEqual("public-tier", s["tier"])
        self.assertEqual("possible", s["contamination"])
        self.assertIs(False, s["official_score"])
        self.assertEqual(self.commit, s["jevbench_commit"])
        self.assertEqual("served-x", s["served_model"])
        self.assertIn("Bearer k-test", Gateway.seen_auth)  # the key reached the gateway via the env var

    def test_commit_pin_mismatch_fails_closed(self):
        repo = self.make_repo([task(0, "A:yes", "yes")])
        rc, s = self.run_adapter(repo, commit="0" * 40)
        self.assertEqual(2, rc)
        self.assertIsNone(s)

    def test_dataset_hash_mismatch_fails_closed(self):
        repo = self.make_repo([task(0, "A:yes", "yes")], manifest_sha="f" * 64)
        rc, s = self.run_adapter(repo)
        self.assertEqual(2, rc)
        self.assertIsNone(s)

    def test_dirty_checkout_fails_closed(self):
        repo = self.make_repo([task(0, "A:yes", "yes")])
        with open(os.path.join(repo, "datasets", "public", "original.jsonl"), "a") as fh:
            fh.write("\n")
        rc, s = self.run_adapter(repo)
        self.assertEqual(2, rc)


class CountTests(AdapterBase):
    def test_refusals_tallied_separately_from_wrong(self):
        # 6 items: 2 correct, 1 wrong, 1 x 422, 1 x 503, 1 malformed.
        ts = [task(0, "A:yes", "yes"), task(1, "A:no", "no"), task(2, "A:yes", "no"),
              task(3, "R422", "yes"), task(4, "R503", "no"), task(5, "MALFORMED", "yes")]
        rc, s = self.run_adapter(self.make_repo(ts))
        c = s["counts"]
        self.assertEqual((6, 3, 2, 1, 2, 1), (c["n"], c["answered"], c["refused"], c["malformed"], c["correct"], c["wrong"]))
        self.assertEqual({"422": 1, "503": 1}, s["refused_by_status"])
        # accuracy over scored items: 2/6; over answered: 2/3 (hand: Wilson low for 2/3 n=3 is 0.208)
        self.assertAlmostEqual(2 / 6, s["accuracy_all"]["value"])
        self.assertAlmostEqual(2 / 3, s["accuracy_answered"]["value"])
        self.assertAlmostEqual(0.2077, s["accuracy_answered"]["wilson_low"], places=3)

    def test_baseline_and_verdict(self):
        ts = [task(i, "A:yes", "yes") for i in range(10)]
        rc, s = self.run_adapter(self.make_repo(ts))
        self.assertAlmostEqual(1.0, s["baseline"]["majority_share"])
        self.assertFalse(s["verdict_lower_exceeds_baseline"])  # 10/10 lower bound 0.72 < baseline 1.0

    def test_excluded_items_not_in_headline(self):
        ts = [task(0, "A:yes", "yes"), task(1, "A:yes", "yes", exclude="ambiguous"), task(2, "A:yes", None)]
        rc, s = self.run_adapter(self.make_repo(ts))
        self.assertEqual(1, s["counts"]["n"])
        self.assertEqual(2, s["counts"]["excluded_from_headline"])


class CalibrationTests(AdapterBase):
    def many(self, n_clean, n_unlicensed=0):
        ts = []
        for i in range(n_clean):  # alternate correct / wrong so p_pred=0.9 is right half the time
            ts.append(task(i, "A:yes", "yes" if i % 2 == 0 else "no"))
        for j in range(n_unlicensed):
            ts.append(task(n_clean + j, "A:yes", "yes", lic="CC-BY-NC-4.0"))
        return ts

    def test_below_200_refused_no_csv(self):
        rc, s = self.run_adapter(self.make_repo(self.many(199)))
        self.assertEqual("insufficient: 199<200", s["calibration"])
        self.assertIsNone(s["calibration_csv"])
        self.assertFalse(os.path.exists(os.path.join(self.root, "run1", "calibration.csv")))

    def test_at_200_writes_csv_with_columns(self):
        rc, s = self.run_adapter(self.make_repo(self.many(200)))
        self.assertTrue(s["calibration"].startswith("ok: 200"))
        with open(os.path.join(self.root, "run1", "calibration.csv")) as fh:
            rows = list(csv.reader(fh))
        self.assertEqual(["p_pred", "correct"], rows[0])
        self.assertEqual(201, len(rows))
        self.assertEqual(["0.900000", "1"], rows[1])   # item 0: p(yes)=0.9, expected yes -> correct
        self.assertEqual(["0.900000", "0"], rows[2])   # item 1: expected no -> wrong

    def test_unlicensed_counted_in_accuracy_not_in_calibration(self):
        # 150 clean + 100 unlicensed: accuracy sees 250 items, calibration only 150 -> insufficient
        rc, s = self.run_adapter(self.make_repo(self.many(150, 100)))
        self.assertEqual(250, s["counts"]["n"])
        self.assertEqual("insufficient: 150<200", s["calibration"])

    def test_csv_writer_has_its_own_guard(self):
        with self.assertRaises(ValueError):
            ja.write_calibration_csv(os.path.join(self.root, "x.csv"), [(0.5, True)] * 199)


class EvidenceTests(AdapterBase):
    def test_evidence_has_ids_and_aggregates_only(self):
        ts = [task(0, "A:yes", "yes"), task(1, "R422", "no")]
        ev = os.path.join(self.root, "ev")
        rc, s = self.run_adapter(self.make_repo(ts), flags=["--evidence-dir", ev, "--profile", "p"])
        blob = ""
        for f in ("summary.json", "items.jsonl"):
            with open(os.path.join(ev, f)) as fh:
                blob += fh.read()
        self.assertNotIn("A:yes", blob)       # item text never reaches tracked evidence
        self.assertIn('"status": "refused"', blob)
        with open(os.path.join(ev, "README.md")) as fh:
            self.assertIn("stay outside git (the run directory) unless EVERY item", fh.read())

    def test_verify_only_runs_nothing(self):
        repo = self.make_repo([task(0, "A:yes", "yes")])
        rc = ja.main(["--public-tier", "--jevbench-dir", repo, "--expect-commit", self.commit,
                      "--run-dir", os.path.join(self.root, "v"), "--verify-only"])
        self.assertEqual(0, rc)
        self.assertFalse(os.path.exists(os.path.join(self.root, "v")))


import contextlib
import io
from unittest import mock


def run_capturing(argv):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = ja.main(argv)
    return rc, err.getvalue()


class ReviewFixTests(AdapterBase):
    """Findings of the independent review (J1-J9 surviving mutants, J-c..J-g)."""

    # J1: a dirty tree whose dataset hash is intact must still fail
    def test_dirty_tree_with_intact_dataset_hash_fails(self):
        repo = self.make_repo([task(0, "A:yes", "yes")], files={"README.md": "x\n"})
        commit = self.commit
        with open(os.path.join(repo, "README.md"), "a") as fh:
            fh.write("tampered\n")
        rc, _ = self.run_adapter(repo, commit=commit)
        self.assertEqual(2, rc)

    def test_untracked_file_in_checkout_fails(self):
        repo = self.make_repo([task(0, "A:yes", "yes")])
        with open(os.path.join(repo, "evil.py"), "w") as fh:
            fh.write("x=1\n")
        rc, _ = self.run_adapter(repo)
        self.assertEqual(2, rc)

    # J-e: gitignored files count (they can still change the harness), bytecode caches do not
    def test_ignored_non_cache_file_fails_but_pycache_is_tolerated(self):
        repo = self.make_repo([task(0, "A:yes", "yes")], files={".gitignore": "*.cfg\n__pycache__/\n"})
        commit = self.commit
        os.makedirs(os.path.join(repo, "pkg", "__pycache__"))
        with open(os.path.join(repo, "pkg", "__pycache__", "m.cpython-312.pyc"), "wb") as fh:
            fh.write(b"\0")
        rc, s = self.run_adapter(repo, commit=commit)
        self.assertEqual(0, rc, "a bytecode cache must not block a run")
        with open(os.path.join(repo, "evil.cfg"), "w") as fh:
            fh.write("x\n")
        rc, _ = self.run_adapter(repo, commit=commit, run="run2")
        self.assertEqual(2, rc, "an ignored non-cache file must block the run")

    # J3: absent / null / empty licence is never clean
    def test_missing_or_null_licence_is_not_clean(self):
        ts = []
        for i in range(200):
            t = task(i, "A:yes", "yes")
            if i % 3 == 0:
                t["provenance"] = {"license": None, "exclude_reason": None}
            elif i % 3 == 1:
                t["provenance"] = {"exclude_reason": None}       # key absent
            else:
                t["provenance"] = {"license": "", "exclude_reason": None}
            ts.append(t)
        rc, s = self.run_adapter(self.make_repo(ts))
        self.assertEqual("insufficient: 0<200", s["calibration"])
        self.assertFalse(ja.licence_clean({"expected": "yes", "provenance": {"license": None}}, ("MIT",)))
        self.assertFalse(ja.licence_clean({"expected": "yes"}, ("MIT",)))

    # J4: no shell, argv lists only
    def test_no_shell_true_and_argv_lists(self):
        calls = []
        real = subprocess.run

        def spy(cmd, *a, **kw):
            calls.append((cmd, kw))
            return real(cmd, *a, **kw)
        with mock.patch.object(ja.subprocess, "run", side_effect=spy):
            rc, _ = self.run_adapter(self.make_repo([task(0, "A:yes", "yes")]))
        self.assertEqual(0, rc)
        self.assertTrue(calls)
        for cmd, kw in calls:
            self.assertIsInstance(cmd, list)
            self.assertFalse(kw.get("shell", False))
        self.assertTrue(any("run" in c[0] and "--endpoint" in c[0] for c in calls), "the harness call was seen")

    # J6: SSL_CERT_FILE reaches the child only
    def test_ssl_cert_file_child_only(self):
        os.environ.pop("SSL_CERT_FILE", None)
        repo = self.make_repo([task(0, "A:yes", "yes")])
        rc, s = self.run_adapter(repo, flags=["--ssl-cert-file", "/tmp/ca-test.pem"])
        self.assertEqual(0, rc)
        self.assertNotIn("SSL_CERT_FILE", os.environ)
        with open(os.path.join(self.root, "run1", "results.jsonl.env")) as fh:
            self.assertEqual("/tmp/ca-test.pem", json.load(fh)["SSL_CERT_FILE"])

    # J-e: inherited PYTHONPATH is dropped for the child; bytecode writing is off
    def test_pythonpath_is_not_inherited(self):
        os.environ["PYTHONPATH"] = "/evil/path"
        self.addCleanup(os.environ.pop, "PYTHONPATH", None)
        rc, _ = self.run_adapter(self.make_repo([task(0, "A:yes", "yes")]))
        self.assertEqual(0, rc)
        with open(os.path.join(self.root, "run1", "results.jsonl.env")) as fh:
            env = json.load(fh)
        self.assertIsNone(env["PYTHONPATH"])
        self.assertEqual("1", env["PYTHONDONTWRITEBYTECODE"])

    def test_default_launcher_ignores_python_env_and_user_site(self):
        ns = ja.parse_args(["--jevbench-dir", "x", "--expect-commit", "0" * 40, "--run-dir", "y"])
        cmd = ja.build_harness_cmd(ns, "t.jsonl", "r", "raw", "l")
        self.assertEqual([sys.executable, "-E", "-s", "-m", "jevbench.cli", "run"], cmd[:6])

    # J-e: realpath for the run-dir containment check
    def test_run_dir_symlink_into_checkout_refused(self):
        repo = self.make_repo([task(0, "A:yes", "yes")])
        link = os.path.join(self.root, "linkdir")
        os.symlink(repo, link)
        rc, err = run_capturing(["--public-tier", "--jevbench-dir", repo, "--expect-commit", self.commit,
                                 "--run-dir", os.path.join(link, "out"), "--verify-only"])
        self.assertEqual(2, rc)
        self.assertIn("outside the jevbench checkout", err)

    # J8: timeouts are refusals, with their own bucket
    def test_timeouts_counted_as_refused(self):
        for err in ("TimeoutError: timed out", "ConnectionError: timeout while reading", "socket.timeout: The read operation timed out"):
            self.assertEqual("refused", ja.classify({"ok": False, "status_code": None, "error": err}), err)
        self.assertEqual("failed_other", ja.classify({"ok": False, "status_code": None, "error": "ConnectionError: Connection refused"}))

    # J9: the pin must be exactly 40 hex digits
    def test_commit_must_be_40_hex(self):
        repo = self.make_repo([task(0, "A:yes", "yes")])
        for bad in ("z" * 40, self.commit[:39], self.commit + "0", self.commit[:39] + "g", ""):
            rc, err = run_capturing(["--public-tier", "--jevbench-dir", repo, "--expect-commit", bad,
                                     "--run-dir", os.path.join(self.root, "x"), "--verify-only"])
            self.assertEqual(2, rc, bad)
            self.assertIn("40-hex", err, bad)
        rc, _ = self.run_adapter(repo, commit=self.commit.upper())
        self.assertEqual(0, rc, "upper-case hex of the right commit is accepted")

    # J-c: empty allowlist entries
    def test_empty_licence_allowlist_entry_rejected(self):
        repo = self.make_repo([task(0, "A:yes", "yes", lic="")])
        for bad in ("", "  "):
            rc, err = run_capturing(["--public-tier", "--jevbench-dir", repo, "--expect-commit", self.commit,
                                     "--run-dir", os.path.join(self.root, "x"), "--verify-only", "--allow-licence", bad])
            self.assertEqual(2, rc, repr(bad))
            self.assertIn("allow-licence", err)

    # J-d: the override is recorded
    def test_harness_override_recorded(self):
        rc, s = self.run_adapter(self.make_repo([task(0, "A:yes", "yes")]))
        self.assertIs(True, s["harness_override"])

    # access / rate-limit stop: exit 3 explicitly, even when the stop is on the last item
    def test_access_stop_exits_3_and_is_named(self):
        for code in (401, 403, 429):
            ts = [task(0, "A:yes", "yes"), task(1, "R%d" % code, "no"), task(2, "A:yes", "yes")]
            rc, s = self.run_adapter(self.make_repo(ts), run="run%d" % code)
            self.assertEqual(3, rc, code)
            self.assertFalse(s["complete"])
            self.assertEqual([code], s["access_stop"]["status_codes"])
            self.assertEqual(2, s["attempted"])
            shutil.rmtree(os.path.join(self.root, "jevbench"))

    def test_access_stop_on_last_item_still_exits_3(self):
        ts = [task(0, "A:yes", "yes"), task(1, "R401", "no")]
        rc, s = self.run_adapter(self.make_repo(ts))
        self.assertTrue(s["complete"])          # every item attempted ...
        self.assertEqual(3, rc)                 # ... but the run was cut by an access / rate-limit answer
        self.assertEqual([401], s["access_stop"]["status_codes"])

    # J-g: 429 is tallied as failed_other (not a gateway refusal), and named
    def test_429_is_failed_other_not_refused(self):
        self.assertEqual("failed_other", ja.classify({"ok": False, "status_code": 429, "error": "HTTP 429"}))
        rc, s = self.run_adapter(self.make_repo([task(0, "R429", "no")]))
        self.assertEqual(1, s["counts"]["failed_other"])
        self.assertEqual(0, s["counts"]["refused"])

    # J-f: an unparseable results line -> summary written, marked incomplete, exit 3
    def test_bad_results_line_exit_3_incomplete(self):
        ts = [task(0, "BADLINE", "yes"), task(1, "A:yes", "yes")]
        rc, s = self.run_adapter(self.make_repo(ts))
        self.assertEqual(3, rc)
        self.assertFalse(s["complete"])
        self.assertEqual(1, s["results_unparseable_lines"])

    def test_duplicate_result_ids_exit_3_incomplete(self):
        rc, s = self.run_adapter(self.make_repo([task(0, "DUPRESULT", "yes")]))
        self.assertEqual(3, rc)
        self.assertFalse(s["complete"])
        self.assertEqual(1, s["results_duplicate_ids"])

    # J-f: duplicate ids across splits are refused before anything runs
    def test_duplicate_task_ids_across_splits_refused(self):
        repo = self.make_repo([task(0, "A:yes", "yes")], extra_splits={"easy": [task(0, "A:no", "no")]})
        rc, err = run_capturing(["--public-tier", "--jevbench-dir", repo, "--expect-commit", self.commit,
                                 "--run-dir", os.path.join(self.root, "dup"), "--splits", "original,easy",
                                 "--endpoint", self.endpoint, "--model", "m", "--key-env", "JB_TEST_KEY",
                                 "--harness-cmd", "%s %s" % (sys.executable, self.harness)])
        self.assertEqual(2, rc)
        self.assertIn("duplicate", err)
        self.assertFalse(os.path.exists(os.path.join(self.root, "dup", "results.jsonl")))


UPSTREAM = os.path.expanduser("~/.cache/jb/jevbench")
UPSTREAM_COMMIT = "bb05a335bc809e61b20c0f745d25499a82b326fc"


def _upstream_head():
    try:
        return subprocess.run(["git", "-C", UPSTREAM, "rev-parse", "HEAD"], capture_output=True, text=True,
                              check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


class RealGateway(BaseHTTPRequestHandler):
    """Answers like the decide gateway for the three question types of the public items."""

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        q = body["questions"]["decision"]
        t = q["type"]
        crit = q.get("criteria")
        if t == "noul":
            ans = {"type": "noul", "noul": 0.7}
        elif t == "choice":
            keys = list(crit)
            probs = {k: (0.6 if i == 0 else 0.4 / (len(keys) - 1)) for i, k in enumerate(keys)}
            ans = {"type": "choice", "choice": keys[0], "probabilities": probs}
        else:
            n = len(crit)
            ans = {"type": "score", "probabilities": {str(i): (0.5 if i == 0 else 0.5 / (n - 1)) for i in range(n)}}
        raw = json.dumps({"model": "stand-in", "answers": {"decision": ans}, "usage": {}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


@unittest.skipUnless(_upstream_head() == UPSTREAM_COMMIT,
                     "real JevBench checkout %s at %s not available (git clone --depth 1 "
                     "https://github.com/fstandhartinger/jevbench there and check out the pinned commit)"
                     % (UPSTREAM, UPSTREAM_COMMIT[:12]))
class RealHarnessContractTests(unittest.TestCase):
    """Runs the REAL upstream harness (stdlib only) against a stand-in gateway: proves the CLI flags, the
    result field names and the scoring contract the adapter relies on."""

    def test_real_harness_end_to_end(self):
        srv = HTTPServer(("127.0.0.1", 0), RealGateway)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        os.environ["JB_REAL_KEY"] = "k"
        self.addCleanup(os.environ.pop, "JB_REAL_KEY", None)
        with tempfile.TemporaryDirectory() as tmp:
            run = os.path.join(tmp, "run")
            rc = ja.main(["--public-tier", "--jevbench-dir", UPSTREAM, "--expect-commit", UPSTREAM_COMMIT,
                          "--splits", "original", "--endpoint", "http://127.0.0.1:%d" % srv.server_address[1],
                          "--model", "m", "--key-env", "JB_REAL_KEY", "--run-dir", run, "--limit", "30"])
            self.assertEqual(0, rc)
            with open(os.path.join(run, "summary.json")) as fh:
                s = json.load(fh)
            with open(os.path.join(run, "results.jsonl")) as fh:
                recs = [json.loads(line) for line in fh]
        self.assertEqual(30, len(recs))
        for field in ("task_id", "ok", "valid", "correct", "predicted", "probs", "status_code", "model", "error"):
            self.assertIn(field, recs[0])
        self.assertEqual(30, s["counts"]["n"])
        self.assertEqual(30, s["counts"]["answered"])
        self.assertEqual(0, s["counts"]["malformed"] + s["counts"]["failed_other"] + s["counts"]["refused"])
        self.assertEqual("stand-in", s["served_model"])
        self.assertIs(False, s["harness_override"])
        self.assertTrue(s["complete"])
        self.assertEqual(0, s["harness_rc"])


if __name__ == "__main__":
    unittest.main()
