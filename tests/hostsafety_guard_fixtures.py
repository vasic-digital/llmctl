#!/usr/bin/env python3
"""Fixture suite for scripts/hostsafety/guard.py (run by tests/test_hostsafety.sh).

usage: hostsafety_guard_fixtures.py <path-to-guard.py> [only-fixture-name-prefix]
Prints "ok: <name>" / "FAIL: <name>" per fixture; exit 0 iff all pass.  The guard under test is loaded from the given
path so the same suite runs against the real guard and against deliberately mutated scratch copies (each mutation must
make a NAMED fixture fail - see test_hostsafety.sh section 4b).

Everything is synthetic: process tables are dicts, and the kill path gets injected kill functions, so no fixture can
signal a real process (constitution 11.4.263).  All pids/pgids are above the kernel pid_max anyway.
"""
import importlib.util
import os
import sys
import tempfile

path = sys.argv[1]
only = sys.argv[2] if len(sys.argv) > 2 else ""
spec = importlib.util.spec_from_file_location("guard_under_test", path)
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

ME, B = 1000, 4200000
GUARD_PID = B + 900
fails = []


def proc(pid, name, pgrp, rss_mb, cg, uid=ME, ppid=1, start=None, cmd=None):
    return {"pid": pid, "name": name, "ppid": ppid, "uid": uid, "rss_kb": rss_mb * 1024, "swap_kb": 0,
            "pgrp": pgrp, "sid": pgrp, "start": start if start is not None else pid, "cmd": cmd or [name],
            "cg": cg}


def table(*ps):
    return {p["pid"]: p for p in ps}


def guard_ancestry(cg="app.slice/tmx-x.scope", pgrp=B + 800):
    return [proc(B + 800, "bash", pgrp, 3, cg, ppid=1), proc(GUARD_PID, "python3", pgrp, 20, cg, ppid=B + 800, cmd=["python3", "guard.py"])]


def check(name, cond, detail=""):
    if only and not name.startswith(only):
        return
    if cond:
        print("ok: " + name)
    else:
        print("FAIL: %s %s" % (name, detail))
        fails.append(name)


def sel(procs, **kw):
    return g.select_victim(procs, ME, GUARD_PID, **kw)


# ---------------------------------------------------------------- selection
runaway = [proc(B + 5000, "sh", B + 5000, 20, "app.slice/bounded-run-x.scope")] + \
          [proc(B + 5000 + i, "git", B + 5000, 90, "app.slice/bounded-run-x.scope", ppid=B + 5000) for i in range(1, 31)]
decoys = [proc(B + 104, "tmux: server", B + 104, 9000, "app.slice/tmx-l.scope"),
          proc(B + 105, "claude", B + 104, 9000, "app.slice/tmx-l.scope", ppid=B + 104),
          proc(B + 100, "gnome-shell", B + 100, 9000, "session.slice/org.gnome.Shell@ubuntu.service"),
          proc(B + 103, "memhog", B + 103, 9000, "app.slice/foreign.scope", uid=4242)]
v, ev = sel(table(*guard_ancestry(), *decoys, *runaway))
check("S1 runaway group is chosen over bigger protected/foreign processes",
      v and v["kind"] == "group" and v["pgrp"] == B + 5000 and len(v["pids"]) == 31, repr(v and (v["kind"], v["pgrp"])))

# T1 (reviewer BLOCKING-2): 40 x 200 MB git sharing claude's process group + an idle 5 MB pane shell elsewhere
t1 = guard_ancestry() + [proc(B + 600, "claude", B + 600, 600, "app.slice/tmx-a.scope", ppid=B + 104)] + \
     [proc(B + 700 + i, "git", B + 600, 200, "app.slice/tmx-a.scope", ppid=B + 600) for i in range(40)] + \
     [proc(B + 650, "bash", B + 650, 5, "app.slice/tmx-b.scope")]
v, ev = sel(table(*t1))
check("T1 a storm sharing claude's group never loses to an idle 5 MB group",
      v is not None and v["kind"] == "process" and v["leader_comm"] == "git" and v["cost_kb"] > 100 * 1024, repr(v and (v["kind"], v["leader_comm"], v["cost_kb"])))
check("T1 the protected group itself is never the target", v is not None and v["pgrp"] is None)

# T1b: many TINY storm members in claude's group vs an unrelated 20 MB group: the larger skipped group dominates
t1b = guard_ancestry() + [proc(B + 600, "claude", B + 600, 600, "app.slice/tmx-a.scope")] + \
      [proc(B + 700 + i, "git", B + 600, 5, "app.slice/tmx-a.scope", ppid=B + 600) for i in range(1000)] + \
      [proc(B + 650, "bash", B + 650, 20, "app.slice/tmx-b.scope")]
v, ev = sel(table(*t1b))
check("T1b dominant protected group => victim is a single member of that group, not the unrelated group",
      v is not None and v["kind"] == "process" and v.get("member_of_skipped_group") == B + 600 and "dominant_skipped_group" in ev, repr(v and v["pids"]))

# T1c: the only consumer is a fully protected group => no victim, explicit note (never the protected group itself)
t1c = guard_ancestry() + [proc(B + 600, "claude", B + 600, 9000, "app.slice/tmx-a.scope")]
v, ev = sel(table(*t1c))
check("T1c a fully-protected group is the only consumer: no victim and the note says why",
      v is None and "no safe victim" in ev.get("storm_in_protected_group", ""), repr((v, ev.get("storm_in_protected_group"))))
# T1c2: claude's own big footprint is NOT a storm: a real runaway elsewhere is still chosen (documented behaviour)
v, ev = sel(table(*t1c, proc(B + 650, "bash", B + 650, 20, "app.slice/tmx-b.scope")))
check("T1c2 a big protected process alone does not disable the guard", v is not None and v["pgrp"] == B + 650)

# non-dominant protected group does not disable the guard
t1d = guard_ancestry() + [proc(B + 600, "claude", B + 600, 100, "app.slice/tmx-a.scope")] + [proc(B + 650, "bash", B + 650, 80, "app.slice/tmx-b.scope")]
v, ev = sel(table(*t1d))
check("T1d a small protected group does not block a real runaway", v is not None and v["pgrp"] == B + 650)

# golden-FALSE carrier + argv0 spoof (MINOR): arguments / argv[0] named like protected programs stay killable
carrier = guard_ancestry() + [proc(B + 6000, "bash", B + 6000, 400, "app.slice/run-u1.scope", cmd=["bash", "-c", "echo tmux gnome-shell claude conmon"]),
                              proc(B + 6001, "sleep", B + 6001, 500, "app.slice/run-u2.scope", cmd=["/tmp/t/claude", "300"])]
v, ev = sel(table(*carrier))
check("S2 argv[0]=/tmp/t/claude (comm sleep) is killable, argument carrier too", v is not None and v["pgrp"] == B + 6001)
check("S3 real claude is protected", sel(table(*guard_ancestry(), proc(B + 6000, "claude", B + 6000, 400, "app.slice/run-u1.scope")))[0] is None)

# gnome-terminal / vscode scope contents are killable (MINOR); the shell and session by cgroup name are not
gt = guard_ancestry() + [proc(B + 7000, "node", B + 7000, 900, "app.slice/app-gnome-gnome\\x2dterminal-1.scope"),
                         proc(B + 7001, "code", B + 7001, 800, "app.slice/app-gnome-code-2.scope")]
v, ev = sel(table(*gt))
check("S4 a runaway inside a gnome-terminal scope is killable", v is not None and v["pgrp"] == B + 7000)
check("S5 anything in an app-gnome-shell/gnome-session scope is not",
      sel(table(*guard_ancestry(), proc(B + 7002, "x", B + 7002, 900, "app.slice/app-gnome-shell-3.scope"),
                proc(B + 7003, "y", B + 7003, 900, "app.slice/gnome-session-4.scope")))[0] is None)

# A: pgid <= 1 may only ever be a single-pid victim
v, ev = sel(table(*guard_ancestry(), proc(B + 109, "hog", 1, 9000, "app.slice/pgid1.scope")))
check("A pgid<=1 only ever a single-pid victim", v is not None and v["kind"] == "process" and v["pgrp"] is None)
# B: a group spanning a protected cgroup is never signalled as a group
spanning = guard_ancestry() + [proc(B + 8000, "worker", B + 8000, 100, "app.slice/job.scope"),
                               proc(B + 8001, "worker2", B + 8000, 100, "session.slice/xterm.scope", ppid=B + 8000)]
v, ev = sel(table(*spanning))
check("B group spanning a non-allowlisted cgroup is not signalled as a group", v is None or v["kind"] != "group", repr(v and v["kind"]))
spanning2 = guard_ancestry() + [proc(B + 8010, "worker", B + 8010, 100, "app.slice/job.scope"),
                                proc(B + 8011, "worker2", B + 8010, 100, "app.slice/app-gnome-shell-9.scope", ppid=B + 8010)]
v, ev = sel(table(*spanning2))
check("B2 group with a member in a protected (app-gnome-shell) cgroup is not signalled as a group", v is None or v["kind"] != "group", repr(v and v["kind"]))
# C: the guard's own process group (own_pgrp known independently of the snapshot, self absent from it)
hidden_self = [proc(B + 800, "bash", B + 800, 3, "app.slice/tmx-x.scope"), proc(B + 801, "bigsibling", B + 800, 900, "app.slice/tmx-x.scope", ppid=B + 800)]
v, ev = g.select_victim(table(*hidden_self), ME, GUARD_PID, own_pgrp=B + 800)
check("C the guard's own process group is never a group victim", v is None or v["kind"] != "group", repr(v and v["kind"]))
# D: a group with a foreign-uid member is never signalled as a group
foreign = guard_ancestry() + [proc(B + 8100, "mine", B + 8100, 500, "app.slice/f.scope"), proc(B + 8101, "theirs", B + 8100, 1, "app.slice/f.scope", uid=4242)]
v, ev = sel(table(*foreign))
check("D group with a foreign member is not signalled as a group", v is None or v["kind"] != "group", repr(v and v["kind"]))
# I: cgroup allowlist: a huge process outside app/background slice is never a candidate
v, ev = sel(table(*guard_ancestry(), proc(B + 8200, "xterm", B + 8200, 9000, "session.slice/xterm.scope")))
check("I cgroup allowlist: session.slice process is never a candidate", v is None, repr(v and v["cgroup"]))
v, ev = sel(table(*guard_ancestry(), proc(B + 8201, "weird", B + 8201, 9000, "user.slice/libpod-x.scope")))
check("I2 user.slice (podman) process is never a candidate", v is None)
# J: self / ancestors
anc = [proc(B + 810, "wrapper", B + 810, 9000, "app.slice/tmx-x.scope", ppid=1),
       proc(B + 811, "bash", B + 811, 3, "app.slice/tmx-x.scope", ppid=B + 810),
       proc(GUARD_PID, "python3", B + 811, 20, "app.slice/tmx-x.scope", ppid=B + 811)]
v, ev = sel(table(*anc))
check("J an ancestor of the guard (its own group, single) is never selected", v is None or B + 810 not in v["pids"], repr(v and v["pids"]))
anc2 = [proc(B + 810, "wrapper", B + 810, 9000, "app.slice/tmx-x.scope", ppid=1),
        proc(B + 811, "helper", B + 810, 100, "app.slice/tmx-x.scope", ppid=B + 810),
        proc(GUARD_PID, "python3", B + 899, 20, "app.slice/tmx-x.scope", ppid=B + 810)]
v, ev = sel(table(*anc2))
check("J2 a GROUP containing an ancestor of the guard is never signalled as a group", v is None or v["kind"] != "group", repr(v and (v["kind"], v["pids"])))

# ---------------------------------------------------------------- kill path (injected, never real)


class Rec:
    def __init__(self):
        self.calls = []

    def killpg(self, n, sig):
        self.calls.append(("killpg", n, int(sig)))

    def kill(self, n, sig):
        self.calls.append(("kill", n, int(sig)))


def victim_from(procs, pgrp=B + 5000):
    v, _ = sel(table(*procs))
    return v


def run_kill(v, scans, rec=None, **kw):
    """scans: list of process-tables returned by successive re-reads (last one repeats)."""
    rec = rec or Rec()
    it = {"i": 0}

    def scan_fn(_root):
        t = scans[min(it["i"], len(scans) - 1)]
        it["i"] += 1
        return t
    res = g.kill_victim(v, ME, GUARD_PID, scan_fn=scan_fn, killpg=rec.killpg, kill=rec.kill,
                        pidfd_open=False, sleep=lambda s: None, **kw)
    return res, rec


base = table(*guard_ancestry(), *runaway)
v = victim_from(guard_ancestry() + runaway)
res, rec = run_kill(v, [base])
check("K0 unchanged victim: SIGTERM then SIGKILL to the group", [c[:2] for c in rec.calls] == [("killpg", B + 5000)] * 2 and [c[2] for c in rec.calls] == [15, 9], repr(rec.calls))

# E: re-check between TERM and KILL: a member became protected / changed owner
mut = dict(base); mut[B + 5003] = dict(base[B + 5003], name="claude")
res, rec = run_kill(v, [base, mut])
check("E member turns protected between SIGTERM and SIGKILL => SIGKILL withheld", [c[2] for c in rec.calls] == [15], repr((res, rec.calls)))
mut = dict(base); mut[B + 5003] = dict(base[B + 5003], uid=4242)
res, rec = run_kill(v, [base, mut])
check("E2 member changes owner between SIGTERM and SIGKILL => SIGKILL withheld", [c[2] for c in rec.calls] == [15])
mut = dict(base); mut[B + 5003] = dict(base[B + 5003], cg="session.slice/x.scope")
res, rec = run_kill(v, [mut])
check("E3 member leaves the cgroup allowlist before SIGTERM => nothing sent", rec.calls == [], repr(rec.calls))
mut = dict(base); mut[B + 5003] = dict(base[B + 5003], cg="app.slice/app-gnome-shell-1.scope")
res, rec = run_kill(v, [mut])
check("E4 member enters a protected cgroup before SIGTERM => nothing sent", rec.calls == [])
# ancestor appears: the guard's parent chain now reaches into the group
mut = dict(base); mut[GUARD_PID] = dict(base[GUARD_PID], ppid=B + 5003)
res, rec = run_kill(v, [mut])
check("E5 the group now contains an ancestor of the guard => nothing sent", rec.calls == [], repr(rec.calls))

# F (reviewer IMPORTANT-5): pgid reuse - the same pgid number now names a different group (new pids / new start times)
reused = {p["pid"]: p for p in guard_ancestry()}
for i in range(5):
    reused[B + 9000 + i] = proc(B + 9000 + i, "git", B + 5000, 90, "app.slice/bounded-run-x.scope")
res, rec = run_kill(v, [reused])
check("F pgid reused by a different group => identity-changed, nothing sent", rec.calls == [] and "identity-changed" in repr(res), repr((res, rec.calls)))
# same pids, but one was restarted (new start time) between TERM and KILL
restarted = dict(base); restarted[B + 5003] = dict(base[B + 5003], start=999999)
res, rec = run_kill(v, [base, restarted])
check("F2 a member whose start time changed => SIGKILL withheld", [c[2] for c in rec.calls] == [15], repr((res, rec.calls)))
# subset of the group exited: fine, still signalled
fewer = {k: x for k, x in base.items() if k not in (B + 5001, B + 5002)}
res, rec = run_kill(v, [base, fewer])
check("F3 members exiting between signals does not block SIGKILL of the rest", [c[2] for c in rec.calls] == [15, 9])

# single-process victim: kill by pid (pidfd unavailable => os.kill injected), same re-checks
sv = {"kind": "process", "pgrp": None, "pids": [B + 5003], "starttimes": {str(B + 5003): B + 5003}}
res, rec = run_kill(sv, [base])
check("K1 single-process victim signalled by pid", [c[:2] for c in rec.calls] == [("kill", B + 5003)] * 2)
pr = dict(base); pr[B + 5003] = dict(base[B + 5003], start=1)
res, rec = run_kill(sv, [pr])
check("K2 single-process victim with a different start time (pid reuse) => nothing sent", rec.calls == [])
for bad in (1, 0, -5):
    try:
        g.kill_victim({"kind": "group", "pgrp": bad, "pids": [], "starttimes": {}}, ME, GUARD_PID, scan_fn=lambda r: {}, killpg=lambda *a: 1 / 0)
        check("K3 refuses pgid %d" % bad, False)
    except SystemExit:
        check("K3 refuses pgid %d" % bad, True)

# K4: the kill path itself refuses the guard's OWN process group, even when the selection step is bypassed
rec4 = Rec()
try:
    g.kill_victim(v, ME, GUARD_PID, own_pgrp=B + 5000, scan_fn=lambda r: base, killpg=rec4.killpg, kill=rec4.kill,
                  pidfd_open=False, sleep=lambda s: None)
    refused4 = False
except SystemExit:
    refused4 = True
check("K4 victim group == the guard's own pgrp => refused on the kill path (SystemExit), nothing signalled",
      refused4 and rec4.calls == [], repr((refused4, rec4.calls)))

# K5: a group whose pgid equals the pid of an ANCESTOR of the guard is refused on the kill path (every member is
# individually eligible and none is itself an ancestor, so only the group-id check can stop it)
anc = {p["pid"]: p for p in guard_ancestry(pgrp=B + 700)}          # bash(B+800) now lives in pgrp B+700, not B+800
for i in range(1, 4):
    anc[B + 8000 + i] = proc(B + 8000 + i, "git", B + 800, 90, "app.slice/bounded-run-x.scope", ppid=1)
v5 = {"kind": "group", "pgrp": B + 800, "pids": [B + 8001, B + 8002, B + 8003],
      "starttimes": {str(B + 8000 + i): B + 8000 + i for i in range(1, 4)}}
res5, rec5 = run_kill(v5, [anc])
check("K5 group whose pgid == an ancestor's pid => refused (self-or-ancestor), nothing sent",
      rec5.calls == [] and "self-or-ancestor" in repr(res5), repr((res5, rec5.calls)))

# ---------------------------------------------------------------- scan(): start time + comm parsing from a fake /proc
with tempfile.TemporaryDirectory() as d:
    pd = os.path.join(d, str(B + 1))
    os.makedirs(pd)
    open(os.path.join(pd, "status"), "w").write("Name:\ttmux: server\nUid:\t1000\t1000\t1000\t1000\nPPid:\t1\nVmRSS:\t100 kB\n")
    # comm containing spaces and a ')' : fields after the LAST ')' must still be found; starttime = field 22
    fields = ["S", "1", "55", "55"] + ["0"] * 15 + ["777"] + ["0"] * 10
    open(os.path.join(pd, "stat"), "w").write("%d (tmux: ser) ver) %s\n" % (B + 1, " ".join(fields)))
    open(os.path.join(pd, "cgroup"), "w").write("0::/user.slice/user-1000.slice/user@1000.service/app.slice/x.scope\n")
    open(os.path.join(pd, "cmdline"), "wb").write(b"tmux\0-L\0x\0")
    sc = g.scan(d)
    p = sc.get(B + 1, {})
    check("P1 scan parses pgrp/sid/starttime past a comm with spaces and parentheses", (p.get("pgrp"), p.get("sid"), p.get("start")) == (55, 55, 777), repr((p.get("pgrp"), p.get("sid"), p.get("start"))))

# PSI parser robustness
with tempfile.TemporaryDirectory() as d:
    f = os.path.join(d, "mem")
    open(f, "w").write("some avg10=1.00 avg60=2.00 avg300=3.00 total=9\nfull avg10=7.50 total=4\nbogus line\n\nfull avg10=x avg60=1\n")
    r = g.psi(f)
    check("P2 PSI tolerates a missing avg60, garbage and blank lines", r.get("some", {}).get("avg10") == 1.0 and r.get("full", {}).get("avg10") == 7.5, repr(r))
    check("P3 PSI of a missing file is empty (and main reports psi_available=false)", g.psi(os.path.join(d, "nope")) == {})

# ---------------------------------------------------------------- main(): the /proc walk is lazy (incident 2026-10-13)
def run_main(psi_text, procs, extra=None, env=None, pre_state=None, pre_log=None, meminfo="MemTotal: 32000000 kB\nSwapTotal: 8000000 kB\nSwapFree: 8000000 kB\n"):
    """run g.main() against a synthetic psi file with g.scan replaced by a counting fake; returns (scan_calls, log_lines, dir)."""
    d = tempfile.mkdtemp(prefix="hsfx")
    open(os.path.join(d, "psi"), "w").write(psi_text)
    open(os.path.join(d, "mi"), "w").write(meminfo)
    if pre_state is not None:
        import json as _j
        open(os.path.join(d, "st"), "w").write(_j.dumps(pre_state))
    if pre_log is not None:
        os.makedirs(os.path.join(d, "log")); open(os.path.join(d, "log", "guard.log"), "w").write(pre_log)
    calls = []
    real_scan = g.scan
    g.scan = lambda root, **kw: (calls.append(root), procs)[1]
    old_env = dict(os.environ)
    os.environ["XDG_RUNTIME_DIR"] = d
    for k in [k for k in os.environ if k.startswith("HOSTSAFETY_")]:
        del os.environ[k]
    os.environ.update(env or {})
    try:
        g.main(["--psi-file", os.path.join(d, "psi"), "--meminfo", os.path.join(d, "mi"), "--log-file", os.path.join(d, "log", "guard.log"),
                "--state-file", os.path.join(d, "st"), "--uid", str(ME), "--self-pid", str(GUARD_PID), "--tmpfs-used-pct-fixture", "1"] + (extra or []))
    finally:
        g.scan = real_scan
        os.environ.clear(); os.environ.update(old_env)
    lp = os.path.join(d, "log", "guard.log")
    lines = open(lp).read().splitlines() if os.path.exists(lp) else []
    return calls, lines, d


CALM = "some avg10=1.00 avg60=1.00 avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n"
BAD = "some avg10=90.00 avg60=80.00 avg300=50.00 total=1\nfull avg10=81.05 avg60=70.00 avg300=50.00 total=1\n"
storm_tbl = table(*guard_ancestry(), *runaway)
calls, lines, _ = run_main(CALM, storm_tbl)
check("M1 calm PSI: the /proc walk is skipped entirely", calls == [], repr(calls))
calls, lines, _ = run_main(BAD, storm_tbl)
check("M2 first triggered run only builds the streak: no /proc walk", calls == [] and any('pressure-building' in l for l in lines), repr((calls, lines)))
calls, lines, _ = run_main(BAD, storm_tbl, pre_state={"streak": 1})
check("M3 sustained pressure (streak reached): exactly one /proc walk, decision logged", len(calls) == 1 and any('would-kill' in l for l in lines), repr((calls, lines)))
calls, lines, _ = run_main(BAD, storm_tbl, extra=["--select-only"])
check("M4 --select-only still walks /proc (diagnostic path unchanged)", len(calls) == 1)

# ---------------------------------------------------------------- bounded log detail (incident: ~152 KB per would-kill record, 96.8 MB log)
# real captured shape (guard.log 2026-10-13T22:27): group pgrp 546537 'bash p1.sh' in app.slice/tmx-notes-8580.scope, 6,182 members
SC = "app.slice/tmx-notes-8580.scope"
big = [proc(B + 546537 + i, "bash" if i == 0 else "sleep", B + 546537, 8, SC, ppid=B + 800 if i == 0 else B + 546537, cmd=["bash", "p1.sh"]) for i in range(6182)]
big_tbl = table(*guard_ancestry(cg="app.slice/tmx-x.scope"), *big)
calls, lines, d = run_main(BAD, big_tbl, pre_state={"streak": 1})
wk = [l for l in lines if '"would-kill"' in l]
import json as _json
rec = _json.loads(wk[0]) if wk else {}
vv = rec.get("victim", {})
check("L1 would-kill record is bounded (<4 KB, was ~152 KB) for a 6,182-process victim", bool(wk) and len(wk[0]) < 4096, repr(len(wk[0]) if wk else None))
check("L2 record carries counts + first/last 20 pids, no full pid list / starttimes map",
      vv.get("pid_count") == 6182 and len(vv.get("pids_first", [])) == 20 and len(vv.get("pids_last", [])) == 20
      and vv.get("pids_first")[0] == B + 546537 and "pids" not in vv and "starttimes" not in vv and vv.get("starttimes_count") == 6182, repr(sorted(vv)))
check("L3 dry-run (ARM=0) writes NO victim state file", not os.path.exists(os.path.join(d, "log", "guard-victim.json")))
calls, lines, d = run_main(BAD, big_tbl, pre_state={"streak": 1}, env={"HOSTSAFETY_GUARD_ARM": "1"})
vf = os.path.join(d, "log", "guard-victim.json")
full = _json.load(open(vf)) if os.path.exists(vf) else {}
check("L4 ARM=1 writes the full pid list + starttimes to a state file", len(full.get("victim", {}).get("pids", [])) == 6182 and len(full.get("victim", {}).get("starttimes", {})) == 6182, repr(list(full)))
check("L5 victim state file is mode 0600", os.path.exists(vf) and (os.stat(vf).st_mode & 0o777) == 0o600)
armed_line = [l for l in lines if '"kill"' in l][0]
check("L6 armed kill record in the log is bounded too", len(armed_line) < 4096 and "pids_first" in armed_line, repr(len(armed_line)))
# bounded + rotated state file
calls, lines, d2 = run_main(BAD, big_tbl, pre_state={"streak": 1}, env={"HOSTSAFETY_GUARD_ARM": "1", "HOSTSAFETY_VICTIM_FILE_MAX_BYTES": "20000"})
vf2 = os.path.join(d2, "log", "guard-victim.json")
check("L7 victim state file is size-bounded (limit 20000 bytes) and says so", os.path.exists(vf2) and os.path.getsize(vf2) <= 20000 and _json.load(open(vf2)).get("truncated") is True,
      repr(os.path.getsize(vf2) if os.path.exists(vf2) else None))
# the kill path revalidates from /proc, never from the log or the state file
reads = []
real_read = g.read
g.read = lambda path, default="": (reads.append(path), real_read(path, default))[1]
try:
    g.kill_victim(vv_full := full.get("victim", {"kind": "group", "pgrp": B + 546537, "pids": [], "starttimes": {}}), ME, GUARD_PID,
                  scan_fn=lambda r: big_tbl, killpg=lambda *a: None, kill=lambda *a: None, pidfd_open=False, sleep=lambda s: None)
finally:
    g.read = real_read
check("L8 kill_victim never reads guard.log / the victim state file", not any(("guard-victim" in x or x.endswith("guard.log")) for x in reads), repr(reads[:3]))

# ---------------------------------------------------------------- cheap cgroup-level storm rule: tasks_storm (O(cgroups), no per-pid walk)
def mk_cgroups(root, counts):
    """counts: {'app.slice/x.scope': 6182, ...}; parents get pids.current = sum of descendants like the kernel does."""
    tot = {}
    for rel, n in counts.items():
        parts = rel.split("/")
        for i in range(1, len(parts) + 1):
            tot["/".join(parts[:i])] = tot.get("/".join(parts[:i]), 0) + n
    for rel, n in tot.items():
        os.makedirs(os.path.join(root, rel), exist_ok=True)
        open(os.path.join(root, rel, "pids.current"), "w").write("%d\n" % n)
    return root


with tempfile.TemporaryDirectory() as cg:
    mk_cgroups(cg, {"app.slice/tmx-notes-8580.scope": 6182, "app.slice/app-llmctl.slice/llama.scope": 3000,
                    "app.slice/tmx-small.scope": 600, "background.slice/job.service": 40})
    os.makedirs(os.path.join(cg, "app.slice", "garbage.scope")); open(os.path.join(cg, "app.slice", "garbage.scope", "pids.current"), "w").write("not-a-number")
    os.makedirs(os.path.join(cg, "app.slice", "nofile.scope"))
    st_ = g.cgroup_storms(cg, 2500) if hasattr(g, "cgroup_storms") else None
    names = [x["cg"] for x in (st_ or [])]
    check("TS1 cgroup_storms: scopes over the threshold, largest first, parent slices not reported, garbage/missing pids.current tolerated",
          names == ["app.slice/tmx-notes-8580.scope", "app.slice/app-llmctl.slice/llama.scope"], repr(st_))
    check("TS1b cgroup_storms of a missing cgroup root is empty", hasattr(g, "cgroup_storms") and g.cgroup_storms(os.path.join(cg, "nope"), 1) == [])

STORM_CG = "app.slice/tmx-notes-8580.scope"
OTHER_CG = "app.slice/bounded-run-big.scope"
storm_grp = [proc(B + 546537 + i, "bash" if i == 0 else "sleep", B + 546537, 8, STORM_CG, ppid=B + 546537 if i else 1, cmd=["bash", "p1.sh"]) for i in range(60)]
other_grp = [proc(B + 700000 + i, "python3", B + 700000, 198, OTHER_CG, ppid=B + 700000 if i else 1) for i in range(5)]   # costs ~1.7x the storm: cost ranking alone picks it, the storm rule (cost ratio 0.6 >= 0.5) still wins
hog_grp = [proc(B + 710000 + i, "python3", B + 710000, 4000, "app.slice/hog.scope", ppid=B + 710000 if i else 1) for i in range(5)]   # ~20 GB
storm_tbl2 = table(*guard_ancestry(), *storm_grp, *other_grp)


def storm_run(psi, counts, env=None, tbl=storm_tbl2, pre={"streak": 1}):
    cg = tempfile.mkdtemp(prefix="hscg")
    mk_cgroups(cg, counts)
    calls, lines, d = run_main(psi, tbl, extra=["--cgroup-root", cg], env=env, pre_state=pre)
    wk = [_json.loads(l) for l in lines if '"would-kill"' in l]
    return calls, lines, d, (wk[0] if wk else {})


calls, lines, d, rec = storm_run(BAD, {STORM_CG: 6182, OTHER_CG: 5})
check("TS2 tasks_storm: a >2500-task scope under PSI-full is the would-kill candidate even though another group costs more (but < 2x)",
      rec.get("victim", {}).get("pgrp") == B + 546537 and any(r.startswith("tasks_storm") for r in rec.get("reasons", [])) and rec.get("rule") == "tasks_storm", repr(rec.get("victim", {}).get("pgrp")) + repr(rec.get("reasons")))
calls, lines, d, rec = storm_run(BAD, {STORM_CG: 6182, OTHER_CG: 5}, env={"HOSTSAFETY_TASKS_STORM": "10000"})
check("TS3 HOSTSAFETY_TASKS_STORM raises the threshold: no tasks_storm, cost ranking (the other group) wins",
      rec.get("victim", {}).get("pgrp") == B + 700000 and not any(r.startswith("tasks_storm") for r in rec.get("reasons", [])), repr(rec.get("reasons")))
calls, lines, d, rec = storm_run(CALM, {STORM_CG: 6182, OTHER_CG: 5}, pre={"streak": 5})
check("TS4 big scope WITHOUT PSI pressure: no tasks_storm, no /proc walk, nothing logged", calls == [] and lines == [], repr((calls, lines)))
st_status = _json.load(open(os.path.join(d, "log", "guard.status")))
check("TS4b heartbeat reports the largest scope task count (cheap observability)", st_status.get("max_scope_tasks") == 6182 and st_status.get("max_scope_cg") == STORM_CG, repr(st_status))
# same protections: the storm scope's group holds a protected process => never chosen as a group; no unsafe fallback into it
prot_grp = [proc(B + 546537, "bash", B + 546537, 8, STORM_CG, ppid=1, cmd=["bash", "p1.sh"]), proc(B + 546538, "claude", B + 546537, 900, STORM_CG, ppid=B + 546537)] + \
           [proc(B + 546539 + i, "sleep", B + 546537, 8, STORM_CG, ppid=B + 546537) for i in range(5)]
calls, lines, d, rec = storm_run(BAD, {STORM_CG: 6182, OTHER_CG: 5}, tbl=table(*guard_ancestry(), *prot_grp, *other_grp))
vic = rec.get("victim", {})
check("TS5 storm scope sharing a process group with claude: the group is NEVER the victim (protections unchanged)",
      vic.get("kind") != "group" or vic.get("pgrp") != B + 546537, repr(vic.get("pgrp")))
check("TS5b ... and no claude pid is ever in the victim", B + 546538 not in (vic.get("pids_first", []) + vic.get("pids_last", [])))
foreign = [dict(p, uid=4242) for p in storm_grp]
calls, lines, d, rec = storm_run(BAD, {STORM_CG: 6182, OTHER_CG: 5}, tbl=table(*guard_ancestry(), *foreign, *other_grp))
check("TS6 storm scope owned by another uid is never the victim", rec.get("victim", {}).get("pgrp") != B + 546537, repr(rec.get("victim", {}).get("pgrp")))
gnome = [dict(p, cg="app.slice/app-gnome-shell-1.scope", name="gnome-shell") for p in storm_grp]
calls, lines, d, rec = storm_run(BAD, {"app.slice/app-gnome-shell-1.scope": 6182, OTHER_CG: 5}, tbl=table(*guard_ancestry(), *gnome, *other_grp))
check("TS7 storm scope that is protected by cgroup/name (gnome-shell) is never the victim", rec.get("victim", {}).get("pgrp") != B + 546537, repr(rec.get("victim", {}).get("pgrp")))

# ---------------------------------------------------------------- guard.log rotation (was 96.8 MB, never rotated)
import gzip
with tempfile.TemporaryDirectory() as d:
    lp = os.path.join(d, "guard.log")
    line = '{"event": "would-kill", "pad": "%s"}\n' % ("x" * 900)
    open(lp, "w").write(line * 3500)                       # ~3.2 MB synthetic big log
    orig = open(lp).read()
    g.log(lp, {"event": "ok"}, max_bytes=1000000, keep=3)
    cur = open(lp).read() if os.path.exists(lp) else ""
    r1 = os.path.join(d, "guard.log.1.gz")
    check("R1 log over the cap is rotated: live file restarts small, content lands in guard.log.1.gz byte-identical",
          os.path.exists(r1) and gzip.open(r1, "rt").read() == orig and len(cur) < 1000 and '"event": "ok"' in cur, repr((os.listdir(d), len(cur))))
    for i in range(6):                                       # refill + rotate repeatedly: never more than keep=3 archives
        open(lp, "a").write(line * 1200)
        g.log(lp, {"event": "ok"}, max_bytes=1000000, keep=3)
    arch = sorted(f for f in os.listdir(d) if f.startswith("guard.log.") and not f.endswith(".lock"))
    check("R2 at most N=3 gz archives are kept (.1 .2 .3), older ones are dropped", arch == ["guard.log.1.gz", "guard.log.2.gz", "guard.log.3.gz"], repr(arch))
    check("R3 live log + archives stay bounded (cap + 3 compressed archives, < 1.2 MB total here)", sum(os.path.getsize(os.path.join(d, f)) for f in os.listdir(d)) < 1200000, repr(os.listdir(d)))
    g.log(lp, {"event": "again"}, max_bytes=10 ** 9, keep=3)
    check("R4 under the cap: plain append, no rotation", "again" in open(lp).read() and sorted(f for f in os.listdir(d) if f.startswith("guard.log.") and not f.endswith(".lock")) == arch)
    check("R5 live log keeps mode of a normal append (a rotation never leaves the live log missing)", os.path.exists(lp))
# main() wires the cap from HOSTSAFETY_LOG_MAX_BYTES (the log pre-exists with 5 KB of old records)
calls, lines, d = run_main(BAD, storm_tbl, pre_state={"streak": 1}, env={"HOSTSAFETY_LOG_MAX_BYTES": "1048576"}, pre_log="x" * 1100000 + "\n")
check("R6 main() honours HOSTSAFETY_LOG_MAX_BYTES (old log rotated to .1.gz before the new record)",
      os.path.exists(os.path.join(d, "log", "guard.log.1.gz")) and any('would-kill' in l for l in lines), repr(os.listdir(os.path.join(d, "log"))))

# ---------------------------------------------------------------- review F1: storm victim must not be a much smaller victim than the PSI rule's
calls, lines, d, rec = storm_run(BAD, {STORM_CG: 3000, "app.slice/hog.scope": 5}, tbl=table(*guard_ancestry(), *storm_grp, *hog_grp))
check("TS8 storm scope costs ~3% of the PSI-ranked hog => the hog is the victim, rule=psi, rejection recorded",
      rec.get("victim", {}).get("pgrp") == B + 710000 and rec.get("rule") == "psi" and "tasks_storm_rejected" in rec, repr((rec.get("victim", {}).get("pgrp"), rec.get("rule"), rec.get("tasks_storm_rejected"))))
calls, lines, d, rec = storm_run(BAD, {STORM_CG: 3000, "app.slice/hog.scope": 5}, tbl=table(*guard_ancestry(), *storm_grp, *hog_grp), env={"HOSTSAFETY_STORM_MIN_COST_FRAC": "0.01"})
check("TS9 HOSTSAFETY_STORM_MIN_COST_FRAC is honoured (0.01 => the storm scope wins again)", rec.get("victim", {}).get("pgrp") == B + 546537 and rec.get("rule") == "tasks_storm", repr((rec.get("victim", {}).get("pgrp"), rec.get("rule"))))
calls, lines, d, rec = storm_run(BAD, {STORM_CG: 6182, OTHER_CG: 5})
check("TS10 storm scope with comparable cost (>= 0.5 of the PSI pick) still wins (the p1.sh case)", rec.get("rule") == "tasks_storm" and rec.get("victim", {}).get("pgrp") == B + 546537)

# ---------------------------------------------------------------- review F2: rotation must never lose archives
import errno
with tempfile.TemporaryDirectory() as d:
    lp = os.path.join(d, "guard.log")
    arch = {}
    for i in (1, 2, 3):
        with gzip.open("%s.%d.gz" % (lp, i), "wb") as f:
            f.write(b"archive %d\n" % i)
        arch[i] = open("%s.%d.gz" % (lp, i), "rb").read()
    open(lp, "w").write("y" * 2000000)
    real_gz = gzip.open
    def boom(*a, **k):
        raise OSError(errno.ENOSPC, "No space left on device")
    gzip.open = boom
    try:
        g.rotate_log(lp, 1000000, 3)
    finally:
        gzip.open = real_gz
    same = all(os.path.exists("%s.%d.gz" % (lp, i)) and open("%s.%d.gz" % (lp, i), "rb").read() == arch[i] for i in (1, 2, 3))
    check("R7 ENOSPC while compressing: all 3 archives intact, live log intact, no tmp left",
          same and os.path.exists(lp) and os.path.getsize(lp) == 2000000 and not [f for f in os.listdir(d) if f.endswith(".tmp")], repr(sorted(os.listdir(d))))
# clamps (HOSTSAFETY_LOG_MAX_BYTES >= 1 MiB, LOG_KEEP 1..10, garbage/0/negative => defaults)
def eff(env):
    run_main(CALM, storm_tbl, env=env)
    return g.LOG_LIMITS["max_bytes"], g.LOG_LIMITS["keep"]
check("R8 LOG_MAX_BYTES: 10 => clamped to 1 MiB", eff({"HOSTSAFETY_LOG_MAX_BYTES": "10"})[0] == 1048576, repr(eff({"HOSTSAFETY_LOG_MAX_BYTES": "10"})))
check("R8b LOG_MAX_BYTES garbage/0/negative => default 5 MiB", all(eff({"HOSTSAFETY_LOG_MAX_BYTES": v})[0] == 5242880 for v in ("abc", "0", "-5")))
check("R8c LOG_KEEP: 99 => 10, 0/-2/garbage => 3, 4 stays", eff({"HOSTSAFETY_LOG_KEEP": "99"})[1] == 10 and all(eff({"HOSTSAFETY_LOG_KEEP": v})[1] == 3 for v in ("0", "-2", "x")) and eff({"HOSTSAFETY_LOG_KEEP": "4"})[1] == 4)

# ---------------------------------------------------------------- review F4: private files
calls, lines, d = run_main(BAD, storm_tbl, pre_state={"streak": 1}, pre_log="old\n")
os.chmod(os.path.join(d, "log", "guard.log"), 0o644)
open(os.path.join(d, "log", "guard.status"), "w").write("{}"); os.chmod(os.path.join(d, "log", "guard.status"), 0o664)
calls, lines, d = run_main(BAD, storm_tbl, pre_state={"streak": 1}, env={"HOSTSAFETY_LOG_MAX_BYTES": "1048576"}, pre_log="z" * 1100000 + "\n")
m = lambda n: oct(os.stat(os.path.join(d, "log", n)).st_mode & 0o777)
check("P4 guard.log, guard.status and the rotated .gz are 0600", (m("guard.log"), m("guard.status"), m("guard.log.1.gz")) == ("0o600",) * 3, repr((m("guard.log"), m("guard.status"), m("guard.log.1.gz"))))
calls, lines, d = run_main(BAD, storm_tbl, pre_state={"streak": 1}, pre_log="old\n")
lp = os.path.join(d, "log", "guard.log"); os.chmod(lp, 0o644)
g.log(lp, {"event": "x"})
check("P4b an existing 0644 guard.log is chmod-ed 0600 on the next write", oct(os.stat(lp).st_mode & 0o777) == "0o600")

# ---------------------------------------------------------------- review F5: a fixture proc root can never reach a real pid
def armed_main(env):
    sent = []
    rk, rkp = os.kill, os.killpg
    os.kill = lambda *a: sent.append(("kill",) + a)
    os.killpg = lambda *a: sent.append(("killpg",) + a)
    try:
        calls, lines, d = run_main(BAD, storm_tbl, pre_state={"streak": 1}, env=dict({"HOSTSAFETY_GUARD_ARM": "1"}, **env), extra=["--proc-root", "/nonexistent-fixture-root"])
    finally:
        os.kill, os.killpg = rk, rkp
    return sent, lines, calls
sent, lines, calls = armed_main({})
check("X1 armed + fixture --proc-root, no test hook: nothing is signalled and the refusal is logged",
      sent == [] and any("refused-fixture-proc-root" in l for l in lines), repr((sent, [l[:80] for l in lines])))
sent, lines, calls = armed_main({"HOSTSAFETY_TEST_ALLOW_FIXTURE_PROC": "1"})
check("X2 with the explicit test hook the kill path re-validates against the SAME fixture proc root", calls.count("/nonexistent-fixture-root") >= 2, repr(calls))

# ---------------------------------------------------------------- review F6: victim state file is replaced atomically
with tempfile.TemporaryDirectory() as d:
    vf = os.path.join(d, "guard-victim.json")
    open(vf, "w").write("OLD-CONTENT")
    real_replace, real_fsync, fs = os.replace, os.fsync, []
    def bad_replace(src, dst):
        if str(src).endswith(".tmp"):
            raise OSError(errno.EIO, "io")
        return real_replace(src, dst)
    os.replace = bad_replace
    try:
        g.write_victim_state(vf, {"kind": "group", "pgrp": B + 1, "pids": [B + 1], "starttimes": {str(B + 1): 1}}, 100000)
    finally:
        os.replace = real_replace
    check("V1 a failing replace keeps the previous victim state file", os.path.exists(vf) and open(vf).read() == "OLD-CONTENT", repr(os.listdir(d)))
    os.fsync = lambda fd: (fs.append(fd), real_fsync(fd))[1]
    try:
        g.write_victim_state(vf, {"kind": "group", "pgrp": B + 1, "pids": [B + 1], "starttimes": {str(B + 1): 1}}, 100000)
    finally:
        os.fsync = real_fsync
    check("V2 the new state file is fsync-ed before it replaces the old one", len(fs) >= 1 and "pgrp" in open(vf).read(), repr(fs))

# ---------------------------------------------------------------- re-review: all storm scopes tried, strict JSON, content-verified + locked rotation
SMALL_CG = "app.slice/tmx-small-build.scope"
small_grp = [proc(B + 720000 + i, "git", B + 720000, 8, SMALL_CG, ppid=B + 720000 if i else 1) for i in range(3)]     # biggest task count, tiny cost
calls, lines, d, rec = storm_run(BAD, {SMALL_CG: 9000, STORM_CG: 3000, "app.slice/hog.scope": 5}, tbl=table(*guard_ancestry(), *small_grp, *storm_grp, *hog_grp),
                                 env={"HOSTSAFETY_STORM_MIN_COST_FRAC": "0.02"})
check("TS11 the first (largest) storm scope is rejected by the cost fraction: the NEXT acceptable storm scope is still tried and wins",
      rec.get("rule") == "tasks_storm" and rec.get("victim", {}).get("pgrp") == B + 546537, repr((rec.get("rule"), rec.get("victim", {}).get("pgrp"), rec.get("tasks_storm_rejected"))))
check("TS11b every rejected storm scope is logged compactly", isinstance(rec.get("tasks_storm_rejected"), list) and [x["cgroup"] for x in rec["tasks_storm_rejected"]] == [SMALL_CG], repr(rec.get("tasks_storm_rejected")))

def strict(l):
    def bad(c):
        raise ValueError("non-JSON constant " + c)
    return _json.loads(l, parse_constant=bad)
NANPSI = "some avg10=nan avg60=1 avg300=1 total=1\nfull avg10=inf avg60=70.00 avg300=50.00 total=1\n"
calls, lines, d, rec = storm_run(NANPSI, {STORM_CG: 3000, "app.slice/hog.scope": 5}, tbl=table(*guard_ancestry(), *storm_grp, *hog_grp), env={"HOSTSAFETY_STORM_MIN_COST_FRAC": "nan"})
try:
    for l in lines: strict(l)
    ok_strict = bool(lines)
except ValueError as e:
    ok_strict = False
check("J1 nan/inf (PSI file, env) never appear as bare NaN/Infinity in any record", ok_strict, repr(lines[:2]))
g_tmp = tempfile.mkdtemp()
g.log(os.path.join(g_tmp, "guard.log"), {"event": "x", "v": float("nan"), "w": [float("inf")], "n": {"k": float("-inf")}})
try:
    strict(open(os.path.join(g_tmp, "guard.log")).read()); ok2 = True
except ValueError:
    ok2 = False
check("J2 g.log sanitises non-finite floats recursively", ok2)

def seed_rot(d, size=200000):
    lp = os.path.join(d, "guard.log")
    arch = {}
    for i in (1, 2, 3):
        with gzip.open("%s.%d.gz" % (lp, i), "wb") as f:
            f.write(b"archive %d\n" % i)
        arch[i] = open("%s.%d.gz" % (lp, i), "rb").read()
    open(lp, "wb").write(os.urandom(size))
    return lp, arch
with tempfile.TemporaryDirectory() as d:
    lp, arch = seed_rot(d)
    live = open(lp, "rb").read()
    real_cp = g.shutil.copyfileobj
    def wrong(fi, fo, n=0):                      # same LENGTH, wrong bytes
        data = fi.read()
        fo.write(b"X" * len(data))
    g.shutil.copyfileobj = wrong
    try:
        g.rotate_log(lp, 1000, 3)
    finally:
        g.shutil.copyfileobj = real_cp
    same = all(open("%s.%d.gz" % (lp, i), "rb").read() == arch[i] for i in (1, 2, 3)) and open(lp, "rb").read() == live
    check("R9 an archive with the right length but wrong content is NOT accepted (archives + live log untouched)", same and not [f for f in os.listdir(d) if f.endswith(".tmp")], repr(sorted(os.listdir(d))))
with tempfile.TemporaryDirectory() as d:
    import fcntl as _fc
    lp, arch = seed_rot(d)
    live = open(lp, "rb").read()
    lk = open(lp + ".lock", "w"); _fc.flock(lk, _fc.LOCK_EX | _fc.LOCK_NB)
    g.rotate_log(lp, 1000, 3)
    skipped = os.path.exists(lp) and open(lp, "rb").read() == live and all(open("%s.%d.gz" % (lp, i), "rb").read() == arch[i] for i in (1, 2, 3))
    lk.close()
    check("R10 rotation lock held by another run => this tick skips rotation (non-blocking)", skipped)
    g.rotate_log(lp, 1000, 3)
    check("R10b lock free => rotation happens", not os.path.exists(lp) or open(lp, "rb").read() != live)
import subprocess
with tempfile.TemporaryDirectory() as d:
    lp, arch = seed_rot(d, 50000)
    code = "import importlib.util,sys;sp=importlib.util.spec_from_file_location('g',sys.argv[1]);m=importlib.util.module_from_spec(sp);sp.loader.exec_module(m);m.rotate_log(sys.argv[2],1000,3)"
    ps = [subprocess.Popen([sys.executable, "-I", "-c", code, path, lp]) for _ in range(3)]
    for p_ in ps:
        p_.wait(timeout=60)
    names = sorted(os.listdir(d))
    ok = not [f for f in names if f.endswith(".tmp")] and all(n in ("guard.log", "guard.log.lock") or n in ("guard.log.%d.gz" % i for i in (1, 2, 3)) for n in names)
    try:
        for i in (1, 2, 3):
            if os.path.exists("%s.%d.gz" % (lp, i)):
                gzip.open("%s.%d.gz" % (lp, i), "rb").read()
    except Exception:
        ok = False
    check("R11 three concurrent rotations leave only live log + <=3 valid archives, no tmp files", ok, repr(names))

# ---------------------------------------------------------------- pressure advisory (2026-10-14 hang: tmpfs shmem 0.33G -> 8.1G)
# report-only file for agent admission control; written on EVERY pass, BEFORE any /proc walk, atomically.
ADV_KEYS = {"schema", "ts", "ts_epoch", "level", "reasons", "unknown", "psi_mem_some_avg10", "psi_mem_full_avg10", "psi_available",
            "tmpfs_used_pct", "tmpfs_path", "app_slice_current_bytes", "app_slice_high_bytes", "app_slice_anon_bytes",
            "app_slice_shmem_bytes", "app_slice_current_ratio", "app_slice_pinned_ratio", "app_slice_ratio_basis", "thresholds"}


def mk_app(root, current, high, anon, shmem, file_=None):
    """fixture user-manager cgroup root with app.slice memory files (bytes); high may be 'max'."""
    a = os.path.join(root, "app.slice")
    os.makedirs(a, exist_ok=True)
    open(os.path.join(a, "memory.current"), "w").write("%d\n" % current)
    open(os.path.join(a, "memory.high"), "w").write("%s\n" % high)
    open(os.path.join(a, "memory.stat"), "w").write("anon %d\nfile %d\nshmem %d\n" % (anon, file_ if file_ is not None else max(current - anon, 0), shmem))
    return root


GiB = 1 << 30


def adv_run(psi_text=CALM, tmpfs="1", app=(10 * GiB, 20 * GiB, 4 * GiB, 1 * GiB), env=None, pre=None, extra=None):
    cg = tempfile.mkdtemp(prefix="hsadv")
    if app is not None:
        mk_app(cg, *app)
    ex = ["--cgroup-root", cg] + (extra or [])
    if tmpfs != "1":
        ex = [x for x in ex] + ["--tmpfs-used-pct-fixture", tmpfs]
    calls, lines, d = run_main(psi_text, storm_tbl, extra=ex, env=env, pre_state=pre)
    pf = os.path.join(d, "log", "pressure.json")
    try:
        doc = _json.load(open(pf))
    except (OSError, ValueError):
        doc = {}
    return (doc if isinstance(doc, dict) else {}), pf, d, lines


doc, pf, d, _ = adv_run()
check("PA1 calm pass writes pressure.json: level ok, every documented key, strict JSON, mode 0600, no tmp left",
      doc.get("level") == "ok" and ADV_KEYS <= set(doc) and doc.get("schema") == "hostsafety.pressure/1"
      and os.path.exists(pf) and (os.stat(pf).st_mode & 0o777) == 0o600 and not [f for f in os.listdir(os.path.dirname(pf)) if f.endswith(".tmp")],
      repr((doc.get("level"), sorted(ADV_KEYS - set(doc)))))
check("PA1b freshness: ts_epoch is the time of this pass (consumers detect a stale/dead guard by age)",
      isinstance(doc.get("ts_epoch"), (int, float)) and abs(doc["ts_epoch"] - __import__("time").time()) < 30, repr(doc.get("ts_epoch")))
doc45 = adv_run(tmpfs="45")[0]
doc65 = adv_run(tmpfs="65")[0]
check("PA2 tmpfs 45% -> warn, 65% -> critical, each with a named reason",
      doc45.get("level") == "warn" and any(r.startswith("tmpfs_used_pct") for r in doc45.get("reasons", []))
      and doc65.get("level") == "critical" and any(r.startswith("tmpfs_used_pct") for r in doc65.get("reasons", [])), repr((doc45.get("level"), doc65.get("level"), doc65.get("reasons"))))
SOME20 = "some avg10=20.00 avg60=1.00 avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n"
FULL12 = "some avg10=30.00 avg60=1.00 avg300=1.00 total=1\nfull avg10=12.00 avg60=0.00 avg300=0.00 total=1\n"
ds, df_ = adv_run(psi_text=SOME20)[0], adv_run(psi_text=FULL12)[0]
check("PA3 PSI some 20 -> warn; PSI full 12 -> critical",
      ds.get("level") == "warn" and df_.get("level") == "critical" and ds.get("psi_mem_some_avg10") == 20.0 and df_.get("psi_mem_full_avg10") == 12.0, repr((ds.get("level"), df_.get("level"))))
# app.slice: (anon+shmem)/high is the level input by default; page cache at MemoryHigh is normal reclaim, not pressure.
# Live 2026-10-14 15:00: current 22.01G / high 22.74G = 0.968 with PSI 0 (anon 11.2G, file 9.1G) - a current/high basis is a false critical.
dw = adv_run(app=(19 * GiB, 20 * GiB, 17 * GiB, 1 * GiB))[0]           # pinned 0.90
dc = adv_run(app=(19.6 * GiB, 20 * GiB, 11 * GiB, 8.2 * GiB))[0]      # pinned 0.96 (the incident: shmem 8.1G)
dcache = adv_run(app=(int(19.4 * GiB), 20 * GiB, 9 * GiB, int(0.06 * GiB)))[0]   # current 0.97, pinned 0.45: cache-full, healthy
dcur = adv_run(app=(int(19.4 * GiB), 20 * GiB, 9 * GiB, int(0.06 * GiB)), env={"HOSTSAFETY_ADV_APP_RATIO_BASIS": "current"})[0]
check("PA4 app.slice pinned ratio 0.90 -> warn, 0.96 -> critical", dw.get("level") == "warn" and dc.get("level") == "critical"
      and abs((dc.get("app_slice_pinned_ratio") or 0) - 0.96) < 0.01, repr((dw.get("level"), dc.get("level"), dc.get("app_slice_pinned_ratio"))))
check("PA4b golden-FALSE: app.slice full of reclaimable page cache (current 0.97, pinned 0.45) is ok, not critical",
      dcache.get("level") == "ok" and (dcache.get("app_slice_current_ratio") or 0) > 0.95, repr((dcache.get("level"), dcache.get("app_slice_current_ratio"))))
check("PA4c HOSTSAFETY_ADV_APP_RATIO_BASIS=current uses memory.current/memory.high (operator's literal basis)",
      dcur.get("level") == "critical" and dcur.get("app_slice_ratio_basis") == "current", repr((dcur.get("level"), dcur.get("app_slice_ratio_basis"))))
dt = adv_run(tmpfs="45", env={"HOSTSAFETY_ADV_WARN_TMPFS_PCT": "90", "HOSTSAFETY_ADV_CRIT_TMPFS_PCT": "95"})[0]
dbad = adv_run(tmpfs="45", env={"HOSTSAFETY_ADV_WARN_TMPFS_PCT": "nan"})[0]
check("PA5 thresholds are env-tunable (warn 90: 45% is ok); a non-finite value falls back to the default",
      dt.get("level") == "ok" and dt.get("thresholds", {}).get("warn_tmpfs_pct") == 90.0 and dbad.get("level") == "warn", repr((dt.get("level"), dbad.get("level"))))
dmax = adv_run(app=(10 * GiB, "max", 4 * GiB, 1 * GiB))[0]
dnone = adv_run(app=None)[0]
check("PA6 memory.high 'max' or no app.slice: ratio null, listed as unknown, level from the other signals (no crash)",
      dmax.get("level") == "ok" and dmax.get("app_slice_pinned_ratio") is None and "app_slice_ratio" in dmax.get("unknown", [])
      and dnone.get("level") == "ok" and "app_slice_ratio" in dnone.get("unknown", []), repr((dmax.get("unknown"), dnone.get("unknown"))))
dpsi_missing = {}
_cg = mk_app(tempfile.mkdtemp(prefix="hsadv"), 1 * GiB, 20 * GiB, 1 * GiB, 0)
with tempfile.TemporaryDirectory() as dd:
    _envb = dict(os.environ)
    try:
        os.environ["XDG_RUNTIME_DIR"] = dd
        g.main(["--psi-file", os.path.join(dd, "nope"), "--meminfo", os.path.join(dd, "nope2"), "--log-file", os.path.join(dd, "log", "guard.log"),
                "--state-file", os.path.join(dd, "st"), "--uid", str(ME), "--self-pid", str(GUARD_PID), "--tmpfs-used-pct-fixture", "1", "--cgroup-root", _cg])
        dpsi_missing = _json.load(open(os.path.join(dd, "log", "pressure.json")))
    except (OSError, ValueError, SystemExit) as e:
        dpsi_missing = {"err": repr(e)}
    finally:
        os.environ.clear(); os.environ.update(_envb)
check("PA6b PSI unreadable: psi values null, psi_available false, 'psi' in unknown (blind, not healthy)",
      dpsi_missing.get("psi_available") is False and dpsi_missing.get("psi_mem_full_avg10") is None and "psi" in dpsi_missing.get("unknown", []), repr(dpsi_missing))

# PA7: the advisory and heartbeat are written BEFORE the /proc walk, so they survive a walk that never finishes (the guard
# killed at TimeoutStartSec under thrash, 2026-10-14 14:28).  The walk is made to hang deterministically: /proc/<pid>/status
# is a FIFO with no writer, so open() blocks forever.  The child is our own Popen; it is killed after 3 s.
import subprocess
import time as _time
with tempfile.TemporaryDirectory() as d7:
    pr = os.path.join(d7, "proc", str(B + 1))
    os.makedirs(pr)
    os.mkfifo(os.path.join(pr, "status"))
    open(os.path.join(d7, "psi"), "w").write(BAD)
    open(os.path.join(d7, "mi"), "w").write("MemTotal: 32000000 kB\nSwapTotal: 8000000 kB\nSwapFree: 8000000 kB\n")
    open(os.path.join(d7, "st"), "w").write('{"streak": 1}')
    cg7 = mk_app(os.path.join(d7, "cg"), 1 * GiB, 20 * GiB, 1 * GiB, 0)
    env7 = {k: v for k, v in os.environ.items() if not k.startswith("HOSTSAFETY_")}
    env7["XDG_RUNTIME_DIR"] = d7
    t0 = _time.time()
    p7 = subprocess.Popen([sys.executable, "-I", path, "--proc-root", os.path.join(d7, "proc"), "--psi-file", os.path.join(d7, "psi"),
                           "--meminfo", os.path.join(d7, "mi"), "--log-file", os.path.join(d7, "log", "guard.log"), "--state-file", os.path.join(d7, "st"),
                           "--uid", str(ME), "--self-pid", str(GUARD_PID), "--tmpfs-used-pct-fixture", "1", "--cgroup-root", cg7],
                          env=env7, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pj7 = os.path.join(d7, "log", "pressure.json")
    while not os.path.exists(pj7) and p7.poll() is None and _time.time() - t0 < 10:   # poll: deterministic and fast
        _time.sleep(0.05)
    _time.sleep(0.3)                    # past the advisory/heartbeat writes: the child must now be blocked in the walk
    hung = p7.poll() is None
    if hung:
        p7.kill()
    p7.wait(timeout=10)
    try:
        d7doc = _json.load(open(os.path.join(d7, "log", "pressure.json")))
    except (OSError, ValueError):
        d7doc = {}
    d7doc = d7doc if isinstance(d7doc, dict) else {}
    st7 = os.path.exists(os.path.join(d7, "log", "guard.status"))
    check("PA7 a /proc walk that never returns (guard killed at its timeout): pressure.json (critical) and guard.status were already written",
          hung and d7doc.get("level") == "critical" and d7doc.get("ts_epoch", 0) >= t0 - 1 and st7, repr((hung, d7doc.get("level"), st7)))

# TW: the tmpfs-high event names the largest children of /tmp and $XDG_RUNTIME_DIR (du -sx semantics, <= 2 s total, skipped when
# PSI is already critical).  Per-process attribution of shmem is impossible: a tmpfs page is charged to the cgroup that first
# touched it and outlives the writer - only file sizes can be named.
def tw_run(psi_text=CALM, du_argv=None, sizes=None, env=None):
    tdir = tempfile.mkdtemp(prefix="hstw")
    for name, n in (sizes or {"big.tar": 900000, "b": 500000, "c": 400000, "d": 300000, "e": 200000, "f": 100000, "g": 10}).items():
        if name.endswith("/"):
            os.makedirs(os.path.join(tdir, name), exist_ok=True)
            open(os.path.join(tdir, name, "x"), "wb").write(b"\0" * n)
        else:
            open(os.path.join(tdir, name), "wb").write(b"\0" * n)
    real = getattr(g, "DU_ARGV", None)
    if du_argv is not None:
        g.DU_ARGV = du_argv
    t0 = _time.time()
    try:
        _, lines, _d = run_main(psi_text, storm_tbl, env=env, extra=["--tmpfs-used-pct-fixture", "70", "--tmp-dir", tdir, "--cgroup-root", mk_app(tempfile.mkdtemp(), GiB, 20 * GiB, GiB, 0)])
    finally:
        if real is not None:
            g.DU_ARGV = real
    ev_ = [_json.loads(l) for l in lines if '"tmpfs-high"' in l]
    return (ev_[0] if ev_ else {}), tdir, _time.time() - t0


e1, tdir, _ = tw_run(sizes={"big.tar": 900000, "sub/": 500000, "c": 400000, "d": 300000, "e": 200000, "f": 100000, "g": 10})
tw = (e1.get("top_writers") or {}).get(tdir) or {}
ents = tw.get("entries") or []
check("TW1 tmpfs-high names the 5 largest children of the tmp dir, largest first, with byte sizes (report only)",
      [os.path.basename(x.get("path", "")) for x in ents] == ["big.tar", "sub", "c", "d", "e"] and ents[0].get("bytes", 0) >= 900000 and "report only" in e1.get("note", ""),
      repr((list(e1), ents)))
e2, _, _ = tw_run(psi_text=FULL12)
check("TW2 PSI already critical: the du scan is skipped (it would add IO to a stalling host) and the event says so",
      e2.get("top_writers") is None and "psi" in str(e2.get("top_writers_skipped", "")), repr({k: e2.get(k) for k in ("top_writers", "top_writers_skipped")}))
# the cap is exercised at 0.3 s (HOSTSAFETY_TOP_WRITERS_TIMEOUT_S) to keep the suite fast; the shipped default is checked separately
e3, _, el = tw_run(du_argv=[sys.executable, "-I", "-c", "import time; time.sleep(5)"], env={"HOSTSAFETY_TOP_WRITERS_TIMEOUT_S": "0.3"})
check("TW3 a du that does not finish is cut off at its cap (0.3 s here: whole pass < 2 s) and reported as timed_out, not hung",
      el < 2 and any(v.get("timed_out") for v in (e3.get("top_writers") or {}).values()), repr((round(el, 2), e3.get("top_writers"))))
check("TW3b shipped du cap is <= 2 s (spec: the whole top-writers scan costs at most 2 s)", 0 < g.DEF.get("TOP_WRITERS_TIMEOUT_S", 99) <= 2.0, repr(g.DEF.get("TOP_WRITERS_TIMEOUT_S")))

# SD: the decision walk has a deadline below TimeoutStartSec: under thrash a timeout must be VISIBLE, never a silent kill.
if hasattr(g, "ScanDeadline"):
    with tempfile.TemporaryDirectory() as d8:
        for i in range(50):
            os.makedirs(os.path.join(d8, str(B + i)))
            open(os.path.join(d8, str(B + i), "status"), "w").write("Name:\tx\nUid:\t1000\t1000\t1000\t1000\nPPid:\t1\n")
        real_read = g.read
        g.read = lambda p_, default="": (_time.sleep(0.001), real_read(p_, default))[1]
        try:
            g.scan(d8, deadline=_time.monotonic() + 0.01)
            sd1 = False
        except g.ScanDeadline as e:
            sd1 = getattr(e, "read", None) is not None and e.read < 50
        finally:
            g.read = real_read
    check("SD1 scan() past its deadline raises ScanDeadline (partial table is never returned)", sd1)

    def _slow(root, **kw):
        raise g.ScanDeadline(17, 6950)
    real_scan = g.scan
    g.scan = _slow
    try:
        d9 = tempfile.mkdtemp(prefix="hssd")
        open(os.path.join(d9, "psi"), "w").write(BAD); open(os.path.join(d9, "mi"), "w").write("MemTotal: 32000000 kB\n")
        open(os.path.join(d9, "st"), "w").write('{"streak": 1}')
        _env = dict(os.environ); os.environ["XDG_RUNTIME_DIR"] = d9
        for k in [k for k in os.environ if k.startswith("HOSTSAFETY_")]:
            del os.environ[k]
        g.main(["--psi-file", os.path.join(d9, "psi"), "--meminfo", os.path.join(d9, "mi"), "--log-file", os.path.join(d9, "log", "guard.log"),
                "--state-file", os.path.join(d9, "st"), "--uid", str(ME), "--self-pid", str(GUARD_PID), "--tmpfs-used-pct-fixture", "1",
                "--cgroup-root", mk_app(tempfile.mkdtemp(), GiB, 20 * GiB, GiB, 0)])
    finally:
        g.scan = real_scan
        os.environ.clear(); os.environ.update(_env)
    l9 = open(os.path.join(d9, "log", "guard.log")).read()
    check("SD2 a decision walk past the deadline logs scan-deadline-exceeded with counts and decides NOTHING",
          '"scan-deadline-exceeded"' in l9 and "would-kill" not in l9 and '"read": 17' in l9, l9[-300:])
else:
    check("SD1 scan() past its deadline raises ScanDeadline (partial table is never returned)", False, "no g.ScanDeadline")
    check("SD2 a decision walk past the deadline logs scan-deadline-exceeded with counts and decides NOTHING", False, "no g.ScanDeadline")

print("RESULT: %d failed" % len(fails))
sys.exit(1 if fails else 0)
