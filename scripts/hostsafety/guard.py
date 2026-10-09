#!/usr/bin/env python3
"""hostsafety guard - user-level memory-pressure guard (see docs/host-safety.md).

Runs once per invocation (a systemd --user timer fires it every ~10 s).  Reads
/proc/pressure/memory and swap usage; when the host is under SUSTAINED memory
pressure it selects the most expensive *killable* process group owned by the
current user and (only when armed) kills it.  The default is DRY-RUN: decisions
are logged with evidence but nothing is signalled.

Safety rules (constitution 11.4.201 / 11.4.263 / 12):
  * only processes whose real uid == ours, in cgroups under app.slice or
    background.slice of the user manager (an ALLOWLIST - everything else,
    including session.slice/gnome-shell, podman/conmon/libpod, login
    sessions and user.slice, is never a candidate);
  * protection is decided on the kernel process *name* (/proc/<pid>/comm) only,
    never on argv[0] or a substring of the command line: a test runner whose
    arguments merely mention "tmux", or that was started as /tmp/x/claude, is
    still killable (golden-FALSE carrier) while the real thing is not.  (comm can
    be set by any process via prctl(PR_SET_NAME): a process that names itself
    "claude" makes itself unkillable - fail-safe direction, accident protection,
    not a defence against a hostile process);
  * the guard's own pid, its ancestors and its process group are never selected;
  * process groups and single processes are ranked TOGETHER.  A group that holds
    a protected process is never signalled as a group, but if the unprotected
    cost inside it dominates everything else (a storm sharing claude's process
    group) the victim is the best individually-eligible *single process* of that
    group - never a small unrelated group - or, when there is none, the decision
    is "storm inside protected group: no safe victim" with evidence;
  * a process-group signal is only sent when pgid > 1 (never kill(-1)), every
    member is ours and unprotected, and BEFORE EACH signal (SIGTERM and again
    before SIGKILL) the whole group is re-read and must still be exactly the
    selected processes (same pids, same start times: a reused pgid fails this),
    each still owned by us, unprotected, in the cgroup allowlist, and neither the
    guard nor an ancestor of it.
"""
import argparse
import fcntl
import json
import os
import re
import signal
import sys
import time

DEF = {
    "PSI_FULL": 25.0,        # memory.full avg10 threshold (percent)
    "PSI_SOME": 10.0,        # memory.some avg10 needed together with low swap
    "SWAP_FREE_PCT": 10.0,   # swap free <= this percent counts as "swap exhausted"
    "CONSECUTIVE": 2,        # consecutive triggered runs before acting
    "COOLDOWN_S": 20,        # no second action within this window
    "PROC_WEIGHT_KB": 2048,  # each process adds this much "cost" (fork storms)
    "TMPFS_WARN_PCT": 60.0,  # /tmp (tmpfs = RAM) fuller than this: report-only event (docs/host-safety.md, GNOME "Application Stopped")
}

PROTECTED_COMM = re.compile(
    r"^(systemd|\(sd-pam\)|gnome-shell.*|gnome-session.*|gnome-keyring.*|gnome-terminal.*|ptyxis.*|Xwayland|gjs|"
    r"sshd|sshd-session|sshd-auth|tmux.*|claude|podman|conmon|crun|runc|netavark|aardvark-dns|slirp4netns|"
    r"pasta.*|rootlessport.*|dbus-daemon|dbus-broker.*|pipewire.*|wireplumber|"
    r"ibus.*|gsd-.*|gvfs.*|localsearch.*|tracker-.*|at-spi.*|xdg-.*|"
    r"mutter.*|login|agetty|Xorg|polkit.*|goa-.*)$")

# cgroup path (after 'user@N.service/') must start with one of these ...
KILLABLE_PREFIX = ("app.slice/", "background.slice/")
# ... and must not contain any of these components.  Precise on purpose: only the shell/session themselves are
# protected by cgroup name; a gnome-terminal / vscode scope (app-gnome-gnome\x2dterminal-*.scope) holds ordinary
# user programs whose runaways must be killable.
PROTECTED_CG = re.compile(
    r"(^|/)(session-\d+\.scope|init\.scope|libpod-[^/]*|podman[^/]*|conmon[^/]*|"
    r"app-gnome-shell[^/]*|gnome-shell[^/]*|gnome-session[^/]*|app-gnome-session[^/]*|org\.gnome\.Shell[^/]*|"
    r"[^/]*dbus[^/]*|[^/]*pipewire[^/]*|wireplumber[^/]*|"
    r"xdg-[^/]*|gvfs[^/]*|ibus[^/]*|at-spi[^/]*|[^/]*tracker[^/]*|"
    r"[^/]*localsearch[^/]*|hostsafety-[^/]*|systemd-[^/]*)(/|$)")

# a protected group's unprotected cost must exceed this multiple of the best other candidate to "dominate" it
DOMINANCE = 2.0


def read(path, default=""):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return default


def parse_status(txt):
    d = {}
    for line in txt.splitlines():
        k, _, v = line.partition(":")
        d[k.strip()] = v.strip()
    return d


def kb(v):
    m = re.match(r"\s*(\d+)", v or "")
    return int(m.group(1)) if m else 0


def parse_stat(txt):
    """return (pgrp, sid, starttime) from /proc/<pid>/stat; comm may contain spaces/parens."""
    i = txt.rfind(")")
    if i < 0:
        return None, None, None
    f = txt[i + 2:].split()
    try:
        st = int(f[19]) if len(f) > 19 else None
        return int(f[2]), int(f[3]), st
    except (IndexError, ValueError):
        return None, None, None


def cg_rel(cgroup_txt):
    """cgroup v2 line '0::/user.slice/.../user@1000.service/app.slice/x.scope'
    -> 'app.slice/x.scope' (path below the user manager) or None."""
    for line in cgroup_txt.splitlines():
        if line.startswith("0::"):
            p = line[3:]
            m = re.search(r"/user@\d+\.service/(.*)$", p)
            return m.group(1).strip("/") if m else None
    return None


def scan(proc_root):
    procs = {}
    try:
        names = os.listdir(proc_root)
    except OSError:
        return procs
    for n in names:
        if not n.isdigit():
            continue
        base = os.path.join(proc_root, n)
        st = read(os.path.join(base, "status"))
        if not st:
            continue
        s = parse_status(st)
        pgrp, sid, start = parse_stat(read(os.path.join(base, "stat")))
        cmd = read(os.path.join(base, "cmdline")).split("\0")
        cmd = [c for c in cmd if c != ""]
        uid = (s.get("Uid", "").split() or ["-1"])[0]
        procs[int(n)] = {
            "pid": int(n), "name": s.get("Name", ""), "ppid": int(kb(s.get("PPid", "0"))),
            "uid": int(uid) if uid.lstrip("-").isdigit() else -1,
            "rss_kb": kb(s.get("VmRSS")), "swap_kb": kb(s.get("VmSwap")),
            "pgrp": pgrp, "sid": sid, "start": start, "cmd": cmd,
            "cg": cg_rel(read(os.path.join(base, "cgroup"))),
        }
    return procs


def protected_name(p):
    """kernel process name only (see module docstring): argv[0] and the command line are never consulted."""
    return bool(PROTECTED_COMM.match(p["name"]))


def cg_class(cg):
    """cost multiplier: prefer test-runner / agent scopes, spare long-lived services."""
    last = cg.rsplit("/", 1)[-1]
    if last.startswith("bounded-run-"):
        return 4.0
    if last.endswith(".scope"):
        return 2.0
    if last.endswith(".service"):
        return 0.5
    return 1.0


def ancestors_of(procs, self_pid):
    out = set()
    q = self_pid
    while q and q in procs and q not in out:
        out.add(q)
        q = procs[q]["ppid"]
    out.add(self_pid)
    return out


def ineligible_reason(p, my_uid, protect_pids):
    """None if this single process may be signalled, else the reason it may not.  The ONE predicate used both when
    selecting a victim and when re-validating immediately before each signal."""
    if p["uid"] != my_uid:
        return "not-owned"
    if p["pid"] <= 1 or p["pid"] in protect_pids:
        return "self-or-ancestor"
    cg = p["cg"]
    if cg is None:
        return "outside-user-manager"
    if not cg.startswith(KILLABLE_PREFIX):
        return "cgroup-not-allowlisted"
    if PROTECTED_CG.search(cg):
        return "cgroup-protected"
    if protected_name(p):
        return "protected-process"
    return None


def _cost(p, proc_weight_kb):
    return p["rss_kb"] + p["swap_kb"] + proc_weight_kb


def _entity(kind, members, pgrp, proc_weight_kb, extra=None):
    cost = sum(_cost(p, proc_weight_kb) for p in members)
    top = max(members, key=lambda p: p["rss_kb"] + p["swap_kb"])
    lead = next((p for p in members if p["pid"] == pgrp), members[0])
    e = {"kind": kind, "pgrp": pgrp if kind == "group" else None, "pids": sorted(p["pid"] for p in members),
         "starttimes": {str(p["pid"]): p.get("start") for p in members},
         "cost_kb": cost, "score": cost * cg_class(top["cg"]), "cgroup": top["cg"],
         "cgroups": sorted({p["cg"] for p in members}),
         "leader_cmd": " ".join(lead["cmd"])[:200], "leader_comm": lead["name"]}
    if extra:
        e.update(extra)
    return e


def select_victim(procs, my_uid, self_pid, only_cg_re=None, proc_weight_kb=DEF["PROC_WEIGHT_KB"], own_pgrp=None):
    """Pure function: returns (victim_or_None, evidence_dict).  Groups and single processes compete in ONE ranking."""
    protect_pids = ancestors_of(procs, self_pid)
    if own_pgrp is None:
        own_pgrp = procs.get(self_pid, {}).get("pgrp")
    ev = {"considered": 0, "skipped": {}}

    def skip(why):
        ev["skipped"][why] = ev["skipped"].get(why, 0) + 1

    by_group = {}
    for p in procs.values():
        by_group.setdefault(p["pgrp"], []).append(p)
    pool = []                 # candidates: eligible groups + individually-eligible members of non-eligible groups
    skipped_groups = []       # non-eligible groups, for the dominance check

    ev["considered"] = len(procs)
    indiv = {pid: ineligible_reason(p, my_uid, protect_pids) for pid, p in procs.items()}

    def in_scope(p):          # test-only knob: it narrows which processes may ANCHOR a victim, never relaxes a safety check
        if not only_cg_re or re.search(only_cg_re, p["cg"] or ""):
            return True
        skip("outside-test-restriction")
        return False

    for pid, why in indiv.items():
        if why and why not in ("protected-process", "self-or-ancestor"):
            skip(why)

    label = {"not-owned": "group-has-foreign-member", "self-or-ancestor": "group-has-self-or-ancestor",
             "protected-process": "group-has-protected-process", "cgroup-not-allowlisted": "group-spans-protected-cgroup",
             "outside-user-manager": "group-spans-protected-cgroup", "cgroup-protected": "group-spans-protected-cgroup"}
    for pgrp, allm in by_group.items():
        mine = [p for p in allm if indiv[p["pid"]] is None and in_scope(p)]
        gwhy = None
        if pgrp is None or pgrp <= 1:
            gwhy = "pgid<=1"
        elif pgrp == own_pgrp:
            gwhy = "own-process-group"
        else:
            bad = next((indiv[p["pid"]] for p in allm if indiv[p["pid"]] is not None), None)
            if bad:
                gwhy = label.get(bad, "group-has-ineligible-member")
        if gwhy is None:
            if mine:
                pool.append(_entity("group", allm, pgrp, proc_weight_kb))
            continue
        skip(gwhy)
        # only the part of a group that lies inside OUR killable region counts as a competing consumer: a group such as
        # pgrp 1 or a root daemon's group must not "dominate" and thereby disable the guard
        ours = [p for p in allm if p["uid"] == my_uid and p["cg"] and p["cg"].startswith(KILLABLE_PREFIX) and not PROTECTED_CG.search(p["cg"])]
        if not ours:
            continue
        skipped_groups.append({"pgrp": pgrp, "why": gwhy, "members": allm, "eligible": mine,
                               "total_kb": sum(_cost(p, proc_weight_kb) for p in ours),
                               "storm_kb": sum(_cost(p, proc_weight_kb) for p in mine),
                               "names": sorted({p["name"] for p in allm if protected_name(p)})[:6]})
        for p in mine:     # tier 2: a single process (never the group) of a skipped group
            pool.append(_entity("process", [p], None, proc_weight_kb, {"member_of_skipped_group": pgrp, "skipped_because": gwhy}))

    best = max(pool, key=lambda e: e["score"]) if pool else None
    best_cost = best["cost_kb"] if best else 0
    if skipped_groups:
        big = max(skipped_groups, key=lambda g: g["total_kb"])
        ev["largest_skipped_group"] = {"pgrp": big["pgrp"], "why": big["why"], "total_cost_kb": big["total_kb"],
                                       "members": len(big["members"]), "protected_names": big["names"]}
    # dominance: a skipped group whose UNPROTECTED members (the storm - not claude's own footprint) cost far more than
    # the best candidate is the real problem; an unrelated small group must not be chosen instead
    # (T1: 40 x 200 MB git sharing claude's process group vs an idle 5 MB pane shell)
    dom = max(skipped_groups, key=lambda g: g["storm_kb"], default=None)
    if dom and dom["storm_kb"] > DOMINANCE * best_cost and not (best and best.get("member_of_skipped_group") == dom["pgrp"]):
        ev["dominant_skipped_group"] = dict(ev["largest_skipped_group"], pgrp=dom["pgrp"], why=dom["why"], storm_cost_kb=dom["storm_kb"],
                                            eligible_members=len(dom["eligible"]), best_other_cost_kb=best_cost)
        inside = [e for e in pool if e.get("member_of_skipped_group") == dom["pgrp"]]
        if inside:
            v = max(inside, key=lambda e: e["score"])
            v["partial"] = "one member of skipped group %s (%s); the rest of the storm stays - the next tick may take another" % (dom["pgrp"], dom["why"])
            return v, ev
        ev["storm_in_protected_group"] = "storm inside protected group: no safe victim"
        return None, ev
    if best is None and skipped_groups:
        ev["storm_in_protected_group"] = "the only consumers are protected groups (%s): no safe victim" % ",".join(ev["largest_skipped_group"]["protected_names"] or ["-"])
    return best, ev


# ---------------------------------------------------------------------------
def psi(path):
    """parse /proc/pressure/memory; tolerant of missing file, odd lines, extra fields.  Returns {} when unavailable."""
    out = {}
    for line in read(path).splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[0] not in ("some", "full"):
            continue
        kv = {}
        for x in parts[1:]:
            k, sep, v = x.partition("=")
            if sep:
                kv[k] = v
        try:
            out[parts[0]] = {"avg10": float(kv["avg10"]), "avg60": float(kv.get("avg60", "0"))}
        except (KeyError, ValueError):
            continue
    return out


def swap_free_pct(meminfo_path):
    d = {}
    for line in read(meminfo_path).splitlines():
        k, _, v = line.partition(":")
        d[k] = kb(v)
    tot = d.get("SwapTotal", 0)
    return None if tot <= 0 else 100.0 * d.get("SwapFree", 0) / tot


def tmpfs_used_pct(path="/tmp", fixture=None):
    """percent of the filesystem at `path` in use (used/(used+avail), df semantics); None if unreadable.  /tmp is RAM-backed on this host."""
    if fixture is not None:
        return float(fixture)
    try:
        st = os.statvfs(path)
    except OSError:
        return None
    used = (st.f_blocks - st.f_bfree) * st.f_frsize
    avail = st.f_bavail * st.f_frsize
    return None if used + avail <= 0 else round(100.0 * used / (used + avail), 1)


def cfg(name, env):
    try:
        t = type(DEF[name])
        return t(env.get("HOSTSAFETY_" + name, DEF[name]))
    except ValueError:
        return DEF[name]


def log(logfile, rec):
    rec["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    line = json.dumps(rec, sort_keys=True)
    print(line, flush=True)
    if logfile:
        try:
            os.makedirs(os.path.dirname(logfile), exist_ok=True)
            with open(logfile, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass


def kill_victim(v, my_uid, self_pid, only_cg_re=None, own_pgrp=None, proc_root="/proc", scan_fn=None,
                killpg=None, kill=None, pidfd_open=None, sleep=time.sleep, sig_delay=2.0):
    """Signal the selected victim.  Before EACH signal the target is re-read and must still be exactly what was
    selected (same pids, same start times) and still individually eligible; see the module docstring.
    scan_fn/killpg/kill/pidfd_open/sleep are injectable so tests never signal a real process."""
    scan_fn = scan_fn or scan
    killpg = killpg or os.killpg
    kill = kill or os.kill
    if pidfd_open is None:
        pidfd_open = getattr(os, "pidfd_open", None)
    elif pidfd_open is False:          # tests: fall back to kill-by-pid (an injected function, never a real signal)
        pidfd_open = None
    results = []
    group = v["kind"] == "group"
    n = v["pgrp"] if group else v["pids"][0]
    if not isinstance(n, int) or n <= 1:
        raise SystemExit("refusing to signal id<=1")
    if group and n == own_pgrp:
        raise SystemExit("refusing to signal the guard's own process group")
    want = {int(k): val for k, val in (v.get("starttimes") or {}).items()}
    for sig in (signal.SIGTERM, signal.SIGKILL):
        fd = None
        if not group and pidfd_open is not None:
            try:
                fd = pidfd_open(n)            # pin the process BEFORE re-reading it: the fd cannot be redirected by pid reuse
            except OSError:
                results.append((sig.name, "already-gone")); break
        try:
            fresh = scan_fn(proc_root)
            protect = ancestors_of(fresh, self_pid)
            members = [p for p in fresh.values() if (p["pgrp"] == n if group else p["pid"] == n)]
            if not members:
                results.append((sig.name, "already-gone")); break
            bad = None
            for p in members:
                if p["pid"] not in want or want[p["pid"]] is None or p.get("start") != want[p["pid"]]:
                    bad = "identity-changed(pid=%d)" % p["pid"]; break
                why = ineligible_reason(p, my_uid, protect)
                if why:
                    bad = "%s(pid=%d)" % (why, p["pid"]); break
            if bad is None and group and n in protect:
                bad = "self-or-ancestor"
            if bad:
                results.append((sig.name, "revalidation-failed:" + bad)); break
            try:
                if group:
                    killpg(n, sig)
                elif fd is not None:
                    signal.pidfd_send_signal(fd, sig)
                else:
                    kill(n, sig)
                results.append((sig.name, "sent"))
            except ProcessLookupError:
                results.append((sig.name, "gone")); break
            except PermissionError:
                results.append((sig.name, "eperm")); break
        finally:
            if fd is not None:
                os.close(fd)
        if sig == signal.SIGTERM:
            sleep(sig_delay)
    return results


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--proc-root", default="/proc")
    ap.add_argument("--psi-file", default="/proc/pressure/memory")
    ap.add_argument("--meminfo", default="/proc/meminfo")
    ap.add_argument("--state-file", default=None)
    ap.add_argument("--log-file", default=None)
    ap.add_argument("--select-only", action="store_true", help="print the victim selection and exit")
    ap.add_argument("--force-trigger", action="store_true", help="treat the host as under pressure (tests)")
    ap.add_argument("--tmp-dir", default="/tmp", help="directory whose filesystem fullness is reported (tmpfs_used_pct)")
    ap.add_argument("--tmpfs-used-pct-fixture", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--uid", type=int, default=os.getuid())
    ap.add_argument("--self-pid", type=int, default=os.getpid())
    a = ap.parse_args(argv)
    env = os.environ
    armed = env.get("HOSTSAFETY_GUARD_ARM", "0") == "1"
    only = env.get("HOSTSAFETY_ONLY_CGROUP_RE") or None
    xdg = env.get("XDG_RUNTIME_DIR", "/tmp")
    state_file = a.state_file or os.path.join(xdg, "hostsafety-guard.state")
    log_file = a.log_file or env.get("HOSTSAFETY_GUARD_LOG") or os.path.join(
        env.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")), "hostsafety", "guard.log")

    procs = scan(a.proc_root)
    own_pgrp = os.getpgrp() if a.self_pid == os.getpid() else None   # independent of the /proc snapshot
    if a.select_only:
        v, ev = select_victim(procs, a.uid, a.self_pid, only, own_pgrp=own_pgrp)
        print(json.dumps({"victim": v, "evidence": ev}, sort_keys=True))
        return 0

    lockf = open(os.path.join(xdg, "hostsafety-guard.lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # another instance is running

    p = psi(a.psi_file)
    psi_ok = bool(p)
    full10 = p.get("full", {}).get("avg10", 0.0)
    some10 = p.get("some", {}).get("avg10", 0.0)
    swapf = swap_free_pct(a.meminfo)
    why = []
    if full10 >= cfg("PSI_FULL", env):
        why.append("psi_full_avg10=%.2f>=%.1f" % (full10, cfg("PSI_FULL", env)))
    if swapf is not None and swapf <= cfg("SWAP_FREE_PCT", env) and some10 >= cfg("PSI_SOME", env):
        why.append("swap_free=%.1f%%<=%.1f%%&psi_some_avg10=%.2f>=%.1f" % (swapf, cfg("SWAP_FREE_PCT", env), some10, cfg("PSI_SOME", env)))
    if a.force_trigger:
        why.append("forced")

    try:
        st = json.loads(read(state_file, "{}") or "{}")
    except ValueError:
        st = {}
    st["streak"] = (int(st.get("streak", 0)) + 1) if why else 0
    now = time.time()
    tmpp = tmpfs_used_pct(a.tmp_dir, a.tmpfs_used_pct_fixture)
    metrics = {"psi_full_avg10": full10, "psi_some_avg10": some10, "swap_free_pct": swapf, "tmpfs_used_pct": tmpp}
    # report-only: a RAM-backed /tmp that is filling up charges its writers' cgroups (unreclaimable) - one event per crossing, never a kill
    if tmpp is not None and tmpp > cfg("TMPFS_WARN_PCT", env):
        if not st.get("tmpfs_high_logged"):
            log(log_file, {"event": "tmpfs-high", "tmpfs_used_pct": tmpp, "threshold_pct": cfg("TMPFS_WARN_PCT", env), "tmp_dir": a.tmp_dir,
                           "note": "report only: no action taken; /tmp is RAM-backed - move big artifacts to disk-backed TMPDIR (bounded-run does this by default)"})
            st["tmpfs_high_logged"] = True
    else:
        st.pop("tmpfs_high_logged", None)
    # heartbeat: a silent guard is indistinguishable from a dead one (11.4.201)
    _save(os.path.join(os.path.dirname(log_file), "guard.status") if log_file else state_file + ".status",
          {"last_run": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "armed": armed, "streak": st["streak"],
           "triggered": bool(why), "psi_available": psi_ok, **metrics})
    if not psi_ok and not st.get("psi_missing_logged"):
        log(log_file, {"event": "psi-unavailable", "psi_file": a.psi_file,
                       "note": "memory pressure cannot be read: no PSI rule can fire, the guard is blind until the file is readable"})
        st["psi_missing_logged"] = True
    elif psi_ok:
        st.pop("psi_missing_logged", None)
    if not why or st["streak"] < cfg("CONSECUTIVE", env):
        action = "ok" if not why else "pressure-building"
        if why:
            log(log_file, {"event": action, "reasons": why, "streak": st["streak"], **metrics})
        _save(state_file, st)
        return 0
    if now - float(st.get("last_action", 0)) < cfg("COOLDOWN_S", env):
        log(log_file, {"event": "cooldown", "reasons": why, **metrics})
        _save(state_file, st)
        return 0
    v, ev = select_victim(procs, a.uid, a.self_pid, only, cfg("PROC_WEIGHT_KB", env), own_pgrp=own_pgrp)
    if not v:
        log(log_file, {"event": "no-killable-victim", "reasons": why, "evidence": ev,
                       "note": ev.get("storm_in_protected_group", "no eligible process"), **metrics})
        _save(state_file, st)
        return 0
    rec = {"event": "would-kill" if not armed else "kill", "armed": armed, "reasons": why,
           "victim": v, "evidence": ev, **metrics}
    if armed:
        rec["signals"] = kill_victim(v, a.uid, a.self_pid, only, own_pgrp)
        st["last_action"] = now
        st["streak"] = 0
    log(log_file, rec)
    _save(state_file, st)
    return 0


def _save(path, st):
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, path)
    except OSError:
        pass


if __name__ == "__main__":
    sys.exit(main())
