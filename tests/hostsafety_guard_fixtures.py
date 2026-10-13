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
def run_main(psi_text, procs, extra=None, env=None, pre_state=None, meminfo="MemTotal: 32000000 kB\nSwapTotal: 8000000 kB\nSwapFree: 8000000 kB\n"):
    """run g.main() against a synthetic psi file with g.scan replaced by a counting fake; returns (scan_calls, log_lines, dir)."""
    d = tempfile.mkdtemp(prefix="hsfx")
    open(os.path.join(d, "psi"), "w").write(psi_text)
    open(os.path.join(d, "mi"), "w").write(meminfo)
    if pre_state is not None:
        import json as _j
        open(os.path.join(d, "st"), "w").write(_j.dumps(pre_state))
    calls = []
    real_scan = g.scan
    g.scan = lambda root: (calls.append(root), procs)[1]
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
other_grp = [proc(B + 700000 + i, "python3", B + 700000, 4000, OTHER_CG, ppid=B + 700000 if i else 1) for i in range(5)]   # costs far more than the storm
storm_tbl2 = table(*guard_ancestry(), *storm_grp, *other_grp)


def storm_run(psi, counts, env=None, tbl=storm_tbl2, pre={"streak": 1}):
    cg = tempfile.mkdtemp(prefix="hscg")
    mk_cgroups(cg, counts)
    calls, lines, d = run_main(psi, tbl, extra=["--cgroup-root", cg], env=env, pre_state=pre)
    wk = [_json.loads(l) for l in lines if '"would-kill"' in l]
    return calls, lines, d, (wk[0] if wk else {})


calls, lines, d, rec = storm_run(BAD, {STORM_CG: 6182, OTHER_CG: 5})
check("TS2 tasks_storm: a >2500-task scope under PSI-full is the would-kill candidate even though another group costs more",
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

print("RESULT: %d failed" % len(fails))
sys.exit(1 if fails else 0)
