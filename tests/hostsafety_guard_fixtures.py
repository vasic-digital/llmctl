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

print("RESULT: %d failed" % len(fails))
sys.exit(1 if fails else 0)
