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
import gzip
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import time

DEF = {
    "PSI_FULL": 25.0,        # memory.full avg10 threshold (percent)
    "PSI_SOME": 10.0,        # memory.some avg10 needed together with low swap
    "SWAP_FREE_PCT": 10.0,   # swap free <= this percent counts as "swap exhausted"
    "CONSECUTIVE": 2,        # consecutive triggered runs before acting
    "COOLDOWN_S": 20,        # no second action within this window
    "PROC_WEIGHT_KB": 2048,  # each process adds this much "cost" (fork storms)
    "TASKS_STORM": 2500,     # tasks_storm: one user scope / group with more tasks than this (while PSI full >= PSI_FULL) is the victim candidate
    "STORM_MIN_COST_FRAC": 0.5,  # a tasks_storm victim must cost >= this fraction of the PSI-ranked best victim, else the PSI pick stands
    "LOG_MAX_BYTES": 5242880,  # guard.log is rotated (gzip) when it exceeds this
    "LOG_KEEP": 3,           # number of gz archives kept: guard.log.1.gz (newest) .. guard.log.N.gz
    "VICTIM_FILE_MAX_BYTES": 1048576,  # cap of the ARM=1 forensic victim state file (guard-victim.json)
    "TMPFS_WARN_PCT": 60.0,  # /tmp (tmpfs = RAM) fuller than this: report-only event (docs/host-safety.md, GNOME "Application Stopped")
    # pressure advisory (pressure.json, report-only, read by agent admission control; 2026-10-14 hang).  warn if ANY warn_* holds,
    # critical if ANY crit_* holds.
    "ADV_WARN_TMPFS_PCT": 40.0,
    "ADV_CRIT_TMPFS_PCT": 60.0,
    "ADV_WARN_APP_RATIO": 0.85,
    "ADV_CRIT_APP_RATIO": 0.95,
    "ADV_WARN_PSI_SOME": 15.0,
    "ADV_CRIT_PSI_FULL": 10.0,
    "ADV_APP_RATIO_BASIS": "pinned",   # pinned = (anon+shmem)/memory.high ; current = memory.current/memory.high (counts page cache)
    "TOP_WRITERS_TIMEOUT_S": 2.0,      # hard cap of the du scan attached to a tmpfs-high event (all directories together)
    "SCAN_DEADLINE_S": 10.0,           # the decision /proc walk gives up (visibly) before the unit's TimeoutStartSec=15
}

ADV_SCHEMA = "hostsafety.pressure/1"
DU_ARGV = [shutil.which("du") or "/usr/bin/du"]     # replaced by the fixture suite (TW3) with a deliberately slow command
TOP_WRITERS_N = 5

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


class ScanDeadline(Exception):
    """the /proc walk passed its deadline; a partial process table is never returned (an unread member of a group could be
    protected, so no decision may be based on it)."""

    def __init__(self, read, total):
        super().__init__("scan deadline exceeded after %d of %d entries" % (read, total))
        self.read, self.total = read, total


def scan(proc_root, deadline=None):
    """read every /proc/<pid>.  deadline: time.monotonic() value after which ScanDeadline is raised (checked every 32 entries)."""
    procs = {}
    try:
        names = os.listdir(proc_root)
    except OSError:
        return procs
    for i, n in enumerate(names):
        if deadline is not None and i % 32 == 0 and time.monotonic() > deadline:
            raise ScanDeadline(i, len(names))
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
def cgroup_storms(root, threshold, slices=("app.slice", "background.slice"), depth=2):
    """O(cgroups) storm detector: read pids.current of the user manager's app.slice / background.slice descendants (never a
    per-pid /proc walk).  Returns [{"cg": 'app.slice/x.scope', "pids": n}] for every cgroup with more than `threshold` tasks,
    largest first.  The slices themselves are never reported, and a cgroup is dropped when a descendant is also over the
    threshold (pids.current of a parent includes its children: report the deepest, i.e. the actual storm)."""
    found = {}

    def walk(rel, level):
        try:
            with os.scandir(os.path.join(root, rel)) as it:
                kids = sorted(e.name for e in it if e.is_dir(follow_symlinks=False))
        except OSError:
            return
        for k in kids:
            r = rel + "/" + k
            try:
                n = int(read(os.path.join(root, r, "pids.current")).strip())
            except ValueError:
                n = 0
            if n > threshold:
                found[r] = n
            if level < depth:
                walk(r, level + 1)
    for sl in slices:
        walk(sl, 1)
    deepest = [r for r in found if not any(o != r and o.startswith(r + "/") for o in found)]
    return sorted(({"cg": r, "pids": found[r]} for r in deepest), key=lambda x: (-x["pids"], x["cg"]))


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


def _int_or_none(txt):
    try:
        return int(txt.strip())
    except (ValueError, AttributeError):
        return None


def app_slice_memory(cg_root):
    """app.slice memory of the user manager: current/high bytes (high None when 'max' or unreadable), anon and shmem from
    memory.stat.  O(1): three small cgroup files, no /proc walk."""
    a = os.path.join(cg_root, "app.slice")
    cur = _int_or_none(read(os.path.join(a, "memory.current"), ""))
    high = _int_or_none(read(os.path.join(a, "memory.high"), ""))           # 'max' -> None
    st = {}
    for line in read(os.path.join(a, "memory.stat"), "").splitlines():
        k, _, v = line.partition(" ")
        if k in ("anon", "shmem", "file"):
            st[k] = _int_or_none(v)
    return {"current": cur, "high": high if high and high > 0 else None, "anon": st.get("anon"), "shmem": st.get("shmem")}


def pressure_advisory(env, psi_ok, some10, full10, tmpp, tmp_dir, app):
    """level ok|warn|critical from PSI, /tmp fullness and app.slice memory vs its MemoryHigh.  Report-only: nothing in the guard
    acts on it; agent admission control reads the file.  Signals that cannot be read are listed in "unknown" and never count
    as healthy evidence - the level is then computed from the remaining signals only."""
    th = {"warn_tmpfs_pct": cfg("ADV_WARN_TMPFS_PCT", env), "crit_tmpfs_pct": cfg("ADV_CRIT_TMPFS_PCT", env),
          "warn_app_ratio": cfg("ADV_WARN_APP_RATIO", env), "crit_app_ratio": cfg("ADV_CRIT_APP_RATIO", env),
          "warn_psi_some_avg10": cfg("ADV_WARN_PSI_SOME", env), "crit_psi_full_avg10": cfg("ADV_CRIT_PSI_FULL", env)}
    basis = cfg("ADV_APP_RATIO_BASIS", env)
    if basis not in ("pinned", "current"):
        basis = DEF["ADV_APP_RATIO_BASIS"]
    high = app.get("high")
    cur_ratio = round(app["current"] / high, 4) if high and app.get("current") is not None else None
    pinned_ratio = round((app["anon"] + app["shmem"]) / high, 4) if high and app.get("anon") is not None and app.get("shmem") is not None else None
    ratio = pinned_ratio if basis == "pinned" else cur_ratio
    crit, warn, unknown = [], [], []
    if psi_ok:
        if full10 >= th["crit_psi_full_avg10"]:
            crit.append("psi_mem_full_avg10=%.2f>=%g" % (full10, th["crit_psi_full_avg10"]))
        if some10 >= th["warn_psi_some_avg10"]:
            warn.append("psi_mem_some_avg10=%.2f>=%g" % (some10, th["warn_psi_some_avg10"]))
    else:
        unknown.append("psi")
    if tmpp is None:
        unknown.append("tmpfs_used_pct")
    elif tmpp >= th["crit_tmpfs_pct"]:
        crit.append("tmpfs_used_pct=%.1f>=%g" % (tmpp, th["crit_tmpfs_pct"]))
    elif tmpp >= th["warn_tmpfs_pct"]:
        warn.append("tmpfs_used_pct=%.1f>=%g" % (tmpp, th["warn_tmpfs_pct"]))
    if ratio is None:
        unknown.append("app_slice_ratio")
    elif ratio >= th["crit_app_ratio"]:
        crit.append("app_slice_%s_ratio=%.3f>=%g" % (basis, ratio, th["crit_app_ratio"]))
    elif ratio >= th["warn_app_ratio"]:
        warn.append("app_slice_%s_ratio=%.3f>=%g" % (basis, ratio, th["warn_app_ratio"]))
    now = time.time()
    return {"schema": ADV_SCHEMA, "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)), "ts_epoch": round(now, 3),
            "level": "critical" if crit else ("warn" if warn else "ok"), "reasons": crit + warn, "unknown": unknown,
            "psi_available": psi_ok, "psi_mem_some_avg10": some10 if psi_ok else None, "psi_mem_full_avg10": full10 if psi_ok else None,
            "tmpfs_used_pct": tmpp, "tmpfs_path": tmp_dir,
            "app_slice_current_bytes": app.get("current"), "app_slice_high_bytes": high, "app_slice_anon_bytes": app.get("anon"),
            "app_slice_shmem_bytes": app.get("shmem"), "app_slice_current_ratio": cur_ratio, "app_slice_pinned_ratio": pinned_ratio,
            "app_slice_ratio_basis": basis, "thresholds": th}


def write_json_atomic(path, doc):
    """tmp file (0600) in the same directory, fsync, rename: a reader sees the old or the new document, never a torn one."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(_finite(doc), sort_keys=True, allow_nan=False) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except (OSError, ValueError):
        try:
            os.unlink(tmp)
        except OSError:
            pass


def top_writers(dirs, timeout_s, n=TOP_WRITERS_N):
    """largest children of each directory by allocated bytes: `du -x -a -d 1 -B1 DIR` (du -sx of each child), all directories
    in parallel, killed at the shared deadline.  Our own child processes only (Popen.kill on the child we started).
    shmem is charged to the cgroup that first touched a page and outlives the writer: no per-process attribution exists."""
    procs, out, deadline = {}, {}, time.monotonic() + max(0.1, timeout_s)
    for d in dirs:
        if not d or d in procs or not os.path.isdir(d):
            continue
        try:
            procs[d] = subprocess.Popen(DU_ARGV + ["-x", "-a", "-d", "1", "-B1", d], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        stdin=subprocess.DEVNULL, text=True)
        except OSError as e:
            out[d] = {"error": str(e)[:200]}
    for d, p in procs.items():
        timed_out = False
        try:
            txt, _ = p.communicate(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            timed_out = True
            p.kill()
            try:
                txt, _ = p.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                txt = ""
        ents = []
        for line in (txt or "").splitlines():
            sz, _, pth = line.partition("\t")
            if pth and pth.rstrip("/") != d.rstrip("/") and sz.isdigit():
                ents.append({"path": pth, "bytes": int(sz)})
        ents.sort(key=lambda e: (-e["bytes"], e["path"]))
        out[d] = {"entries": ents[:n], "timed_out": timed_out}
    return out


def cfg(name, env):
    try:
        t = type(DEF[name])
        val = t(env.get("HOSTSAFETY_" + name, DEF[name]))
        if t is float and not math.isfinite(val):       # "nan"/"inf" parse as floats: never let them into a comparison or a record
            return DEF[name]
        return val
    except ValueError:
        return DEF[name]


LOG_LIMITS = {"max_bytes": DEF["LOG_MAX_BYTES"], "keep": DEF["LOG_KEEP"]}     # main() overrides from HOSTSAFETY_LOG_*


def _same_content(gz_path, src_path, chunk=1 << 20):
    """True iff gz_path decompresses to exactly the bytes of src_path (chunked, bounded memory)."""
    with gzip.open(gz_path, "rb") as g1, open(src_path, "rb") as f1:
        while True:
            a = g1.read(chunk)
            b = f1.read(len(a) if a else 1)
            if a != b:
                return False
            if not a:
                return True


def rotate_log(path, max_bytes, keep):
    """size-capped rotation without logrotate: path -> path.1.gz -> .2.gz ... .keep.gz (oldest dropped).  Streams through gzip
    (a 100 MB legacy log never sits in memory).  The new archive is written to a pid-unique tmp file COMPLETELY and verified
    (its decompressed bytes must equal the source, compared chunk by chunk) BEFORE any existing archive is shifted or deleted;
    on any failure the tmp is removed and every archive and the live log stay as they were.  A non-blocking flock on
    path.lock makes overlapping runs skip (a systemd oneshot cannot overlap itself, a manual run can).  Best effort."""
    try:
        if keep < 1 or os.path.getsize(path) <= max_bytes:
            return
    except OSError:
        return
    lockf = None
    tmp = "%s.1.gz.%d.tmp" % (path, os.getpid())
    try:
        lockf = os.fdopen(os.open(path + ".lock", os.O_WRONLY | os.O_CREAT, 0o600), "a")
        try:
            fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            lockf.close()
            return                      # another rotation is running: skip this tick
        if os.path.getsize(path) <= max_bytes:
            return                      # the other run already rotated
        os.close(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))   # create private; gzip.open keeps the mode
        with open(path, "rb") as fi, gzip.open(tmp, "wb", compresslevel=1) as fo:
            shutil.copyfileobj(fi, fo, 1 << 20)
        if not _same_content(tmp, path):
            raise OSError("archive verification failed: content differs")
        oldest = "%s.%d.gz" % (path, keep)
        if os.path.exists(oldest):
            os.unlink(oldest)
        for i in range(keep - 1, 0, -1):
            src = "%s.%d.gz" % (path, i)
            if os.path.exists(src):
                os.replace(src, "%s.%d.gz" % (path, i + 1))
        os.replace(tmp, path + ".1.gz")
        os.unlink(path)
    except (OSError, EOFError, ValueError):
        try:
            os.unlink(tmp)
        except OSError:
            pass
    finally:
        if lockf is not None and not lockf.closed:
            lockf.close()
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _finite(x):
    """records must be strict JSON: non-finite floats (nan/inf from a hostile PSI file or env) become null."""
    if isinstance(x, float):
        return x if math.isfinite(x) else None
    if isinstance(x, dict):
        return {k: _finite(val) for k, val in x.items()}
    if isinstance(x, (list, tuple)):
        return [_finite(val) for val in x]
    return x


def log(logfile, rec, max_bytes=None, keep=None):
    rec = _finite(rec)
    rec["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    line = json.dumps(rec, sort_keys=True, allow_nan=False)
    print(line, flush=True)
    if logfile:
        try:
            os.makedirs(os.path.dirname(logfile), exist_ok=True)
            rotate_log(logfile, LOG_LIMITS["max_bytes"] if max_bytes is None else max_bytes,
                       LOG_LIMITS["keep"] if keep is None else keep)
            fd = os.open(logfile, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a") as f:
                os.fchmod(f.fileno(), 0o600)       # an older 0644/0664 log becomes private on its next write
                f.write(line + "\n")
        except OSError:
            pass


LOG_PIDS_EDGE = 20       # a logged victim shows only this many first / last pids


def compact_victim(v, edge=LOG_PIDS_EDGE):
    """what goes into guard.log / the journal: counts + first/last `edge` pids.  The full pid list and the starttimes map
    (~150 KB for a 6,000-process storm) never go there.  NOT an input to anything: kill_victim() takes the in-memory victim
    and re-reads every pid + starttime from /proc before each signal."""
    c = {k: val for k, val in v.items() if k not in ("pids", "starttimes")}
    pids = v.get("pids", [])
    c.update({"pid_count": len(pids), "pids_first": pids[:edge], "pids_last": pids[-edge:] if len(pids) > edge else [],
              "starttimes_count": len(v.get("starttimes") or {})})
    if len(c.get("cgroups", [])) > edge:
        c["cgroups_count"] = len(c["cgroups"]); c["cgroups"] = c["cgroups"][:edge]
    return c


def write_victim_state(path, v, max_bytes):
    """ARM=1 only: the full victim (pids + starttimes) for post-mortem, mode 0600, bounded by max_bytes, previous one kept as .1.
    Forensics only - the kill path never reads it."""
    doc = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "victim": v}
    data = json.dumps(doc, sort_keys=True)
    if len(data) > max_bytes:
        keep = max(0, (max_bytes - 2048) // 40)      # ~40 bytes per pid + starttime entry
        t = dict(v)
        t["pids"] = v["pids"][:keep]
        t["starttimes"] = {str(k): (v.get("starttimes") or {}).get(str(k)) for k in t["pids"]}
        doc = {"ts": doc["ts"], "victim": t, "truncated": True, "pid_count_total": len(v["pids"])}
        data = json.dumps(doc, sort_keys=True)
        while len(data) > max_bytes and t["pids"]:
            t["pids"] = t["pids"][:len(t["pids"]) // 2]
            t["starttimes"] = {str(k): t["starttimes"].get(str(k)) for k in t["pids"]}
            data = json.dumps(doc, sort_keys=True)
    tmp = path + ".tmp"
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return
    had_old = os.path.exists(path)
    try:
        if had_old:
            os.replace(path, path + ".1")
        os.replace(tmp, path)
    except OSError:
        # keep the previous record: put it back if the swap failed half way, drop the tmp
        if had_old and not os.path.exists(path) and os.path.exists(path + ".1"):
            try:
                os.replace(path + ".1", path)
            except OSError:
                pass
        try:
            os.unlink(tmp)
        except OSError:
            pass


def kill_victim(v, my_uid, self_pid, only_cg_re=None, own_pgrp=None, proc_root="/proc", scan_fn=None,
                killpg=None, kill=None, pidfd_open=None, sleep=time.sleep, sig_delay=2.0):
    """Signal the selected victim.  Before EACH signal the target is re-read and must still be exactly what was
    selected (same pids, same start times) and still individually eligible; see the module docstring.
    scan_fn/killpg/kill/pidfd_open/sleep are injectable so tests never signal a real process."""
    if proc_root != "/proc" and scan_fn is None and killpg is None and kill is None and os.environ.get("HOSTSAFETY_TEST_ALLOW_FIXTURE_PROC") != "1":
        # a fixture /proc must never lead to a real signal: its pids are not the host's pids
        return [("-", "refused-fixture-proc-root")]
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
    ap.add_argument("--cgroup-root", default=None, help="user manager cgroup dir (default /sys/fs/cgroup/user.slice/user-UID.slice/user@UID.service)")
    ap.add_argument("--state-file", default=None)
    ap.add_argument("--log-file", default=None)
    ap.add_argument("--select-only", action="store_true", help="print the victim selection and exit")
    ap.add_argument("--force-trigger", action="store_true", help="treat the host as under pressure (tests)")
    ap.add_argument("--tmp-dir", default="/tmp", help="directory whose filesystem fullness is reported (tmpfs_used_pct)")
    ap.add_argument("--tmpfs-used-pct-fixture", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--pressure-file", default=None, help="pressure advisory (default: pressure.json beside the log; env HOSTSAFETY_PRESSURE_FILE)")
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

    lm, lk = cfg("LOG_MAX_BYTES", env), cfg("LOG_KEEP", env)
    LOG_LIMITS["max_bytes"] = DEF["LOG_MAX_BYTES"] if lm <= 0 else max(lm, 1048576)     # garbage/0/negative => default; tiny => 1 MiB
    LOG_LIMITS["keep"] = DEF["LOG_KEEP"] if lk <= 0 else min(lk, 10)
    own_pgrp = os.getpgrp() if a.self_pid == os.getpid() else None   # independent of the /proc snapshot
    if a.select_only:
        procs = scan(a.proc_root)
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
    cg_root = a.cgroup_root or "/sys/fs/cgroup/user.slice/user-%d.slice/user@%d.service" % (a.uid, a.uid)
    storms = cgroup_storms(cg_root, cfg("TASKS_STORM", env))
    top = storms[0] if storms else None
    if full10 >= cfg("PSI_FULL", env):
        why.append("psi_full_avg10=%.2f>=%.1f" % (full10, cfg("PSI_FULL", env)))
        for sg in storms[:3]:      # only while PSI full is high: a big scope alone (a build, a test fleet) is not an emergency
            why.append("tasks_storm=%s:%d>%d" % (sg["cg"], sg["pids"], cfg("TASKS_STORM", env)))
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
    # observability only: the largest scope above the storm threshold (None when no scope exceeds it)
    status_extra = {"max_scope_tasks": top["pids"] if top else None, "max_scope_cg": top["cg"] if top else None}
    # pressure advisory: written on EVERY pass and BEFORE anything slow (du, the /proc walk), so it survives a guard that is
    # killed at TimeoutStartSec under thrash (fixture PA7).  Report-only: the guard never acts on the level.
    adv = pressure_advisory(env, psi_ok, some10, full10, tmpp, a.tmp_dir, app_slice_memory(cg_root))
    write_json_atomic(a.pressure_file or env.get("HOSTSAFETY_PRESSURE_FILE") or os.path.join(os.path.dirname(log_file) or ".", "pressure.json"), adv)
    # report-only: a RAM-backed /tmp that is filling up charges its writers' cgroups (unreclaimable) - one event per crossing, never a kill
    if tmpp is not None and tmpp > cfg("TMPFS_WARN_PCT", env):
        if not st.get("tmpfs_high_logged"):
            ev_t = {"event": "tmpfs-high", "tmpfs_used_pct": tmpp, "threshold_pct": cfg("TMPFS_WARN_PCT", env), "tmp_dir": a.tmp_dir,
                    "note": "report only: no action taken; /tmp is RAM-backed - move big artifacts to disk-backed TMPDIR (bounded-run does this by "
                            "default). Killing a process does NOT free tmpfs pages: only deleting the files does."}
            if psi_ok and full10 >= cfg("ADV_CRIT_PSI_FULL", env):
                ev_t["top_writers_skipped"] = "psi_mem_full_avg10=%.2f>=%g: no du on a stalling host" % (full10, cfg("ADV_CRIT_PSI_FULL", env))
            else:
                ev_t["top_writers"] = top_writers([a.tmp_dir, env.get("XDG_RUNTIME_DIR")], cfg("TOP_WRITERS_TIMEOUT_S", env))
            log(log_file, ev_t)
            st["tmpfs_high_logged"] = True
    else:
        st.pop("tmpfs_high_logged", None)
    # heartbeat: a silent guard is indistinguishable from a dead one (11.4.201)
    _save(os.path.join(os.path.dirname(log_file), "guard.status") if log_file else state_file + ".status",
          {"last_run": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "armed": armed, "streak": st["streak"],
           "triggered": bool(why), "psi_available": psi_ok, **status_extra, **metrics})
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
    # the /proc walk (~0.8 s with ~7,000 processes) happens ONLY here: PSI said "sustained pressure" and no cooldown is running.
    # Every healthy / building / cooldown run returns above without touching /proc/<pid> (incident 2026-10-13).
    try:
        procs = scan(a.proc_root, deadline=time.monotonic() + cfg("SCAN_DEADLINE_S", env))
    except ScanDeadline as e:
        # under thrash the walk can outlast TimeoutStartSec; a deadline below it makes the miss VISIBLE (it used to be a silent
        # unit timeout, 2026-10-14 14:28).  No decision on a partial table: an unread group member could be protected.
        log(log_file, {"event": "scan-deadline-exceeded", "reasons": why, "read": e.read, "total": e.total,
                       "deadline_s": cfg("SCAN_DEADLINE_S", env), "note": "no decision: a partial process table is never used", **metrics})
        _save(state_file, st)
        return 0
    v, ev, rule, rejected = None, {}, "psi", []
    pv, pev = select_victim(procs, a.uid, a.self_pid, only, cfg("PROC_WEIGHT_KB", env), own_pgrp=own_pgrp)   # the PSI-ranked pick
    v, ev = pv, pev
    if not only and any(r.startswith("tasks_storm") for r in why):
        # group-size rule: the storm scope itself is the preferred candidate.  The scope only NARROWS which processes may anchor
        # a victim; every eligibility / protection check (uid, protected comm, cgroup allowlist, own group) is unchanged.
        # It is used only when it is not a much smaller victim than the PSI pick (cost >= STORM_MIN_COST_FRAC of it).
        frac = cfg("STORM_MIN_COST_FRAC", env)
        rejected = []
        best_sv = None
        for sg in storms[:3]:       # try EVERY storm scope: a rejected one must not hide an acceptable next one
            sv, sev = select_victim(procs, a.uid, a.self_pid, "^" + re.escape(sg["cg"]) + "$", cfg("PROC_WEIGHT_KB", env), own_pgrp=own_pgrp)
            if not sv:
                continue
            if pv is None or sv["cost_kb"] >= frac * pv["cost_kb"]:
                if best_sv is None or sv["cost_kb"] > best_sv[0]["cost_kb"]:
                    best_sv = (sv, sev)
            else:
                rejected.append({"cgroup": sg["cg"], "storm_cost_kb": sv["cost_kb"], "psi_cost_kb": pv["cost_kb"], "min_cost_frac": frac})
        if best_sv:
            v, ev, rule = best_sv[0], best_sv[1], "tasks_storm"
    if not v:
        log(log_file, {"event": "no-killable-victim", "reasons": why, "evidence": ev,
                       "note": ev.get("storm_in_protected_group", "no eligible process"), **metrics})
        _save(state_file, st)
        return 0
    rec = {"event": "would-kill" if not armed else "kill", "armed": armed, "reasons": why, "rule": rule,
           **({"tasks_storm_rejected": rejected} if rejected else {}), "victim": compact_victim(v), "evidence": ev, **metrics}
    if armed:
        write_victim_state(os.path.join(os.path.dirname(log_file), "guard-victim.json"), v, cfg("VICTIM_FILE_MAX_BYTES", env))
        rec["signals"] = kill_victim(v, a.uid, a.self_pid, only, own_pgrp, proc_root=a.proc_root)
        st["last_action"] = now
        st["streak"] = 0
    log(log_file, rec)
    _save(state_file, st)
    return 0


def _save(path, st):
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(st, f)
        os.replace(tmp, path)
        os.chmod(path, 0o600)
    except OSError:
        pass


if __name__ == "__main__":
    sys.exit(main())
