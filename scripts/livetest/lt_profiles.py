#!/usr/bin/env python3
"""lt_profiles.py - profile eligibility + pass criteria of the guarded live test (stdlib only, read-only).

Nothing here starts, stops or signals anything. The driver (vision_live_test.sh) and the runner (run_profiles.sh)
call it with `python3 -I` so that the allow-list is DERIVED at run time from the model catalog, `llmctl plan --json`
and the validation suites of THIS host, never from a hard-coded list of model names or sizes.

Subcommands (all print `key=value` lines or a plain list, exit 0; a refusal is a `refusal=<reason>` line):
  info     --catalog F --suites-root D --profile P [--override SUITE=DIR]...
           static facts + static refusals (not in catalog, no validation suite, unsupported engine, bad name)
  fits     --plan F --profile P --footprint-mb N
           what `llmctl plan --json` says about the profile (fits?) and the pre-gate numbers derived from the footprint
  fitting  --catalog F --suites-root D --plan F [--allow-large] [--models-dir D] [--override SUITE=DIR]...
           ordered list (smallest footprint first) of the profiles the runner may run on this host
  prior    --status FILE [--exclude NAME]...
           the profiles `llmctl status --json` shows running (restorable set, base names, status order), their reserved RAM/VRAM,
           and scaled instances (`p.N`, which `llmctl start p` cannot bring back)
  check    --report FILE --suites-root D --suite NAME [--suite NAME]... [--override SUITE=DIR]...
           judge the captured `--json` output of `llmctl validate`; prints OK or the reason it is not a PASS
"""
import argparse
import json
import os
import re
import sys

MIB = 1024 * 1024
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
# Pre-gate floor of the original (vision-only) driver; a derived threshold is NEVER lower than this.
GATE_MIN_MEM_FLOOR_MB = 12000
GATE_RAM_HEADROOM_MB = 4096        # the same 4 GiB RAM headroom `llmctl plan` subtracts (lib/catalog.sh ram_budget)
GATE_RAM_EXTRA_MB = 2048           # on top of it: the live test's own headroom
GATE_VRAM_MARGIN_MB = 1024
LARGE_FOOTPRINT_MB = 10240         # a catalog footprint at/above this needs --allow-large (as does a workstation/datacenter min_tier)
LARGE_TIERS = ("workstation", "datacenter")
SUPPORTED_ENGINES = ("llama",)     # the driver hashes the `-m`/`--mmproj` files of the unit env file: llama-server only


def die(msg):
    print("lt_profiles: " + msg, file=sys.stderr)
    sys.exit(2)


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as e:  # unreadable / not JSON: the caller treats an empty answer as a refusal
        die("cannot read %s: %s" % (path, e))


def parse_overrides(items):
    out = {}
    for it in items or []:
        if "=" not in it:
            die("bad --override %r" % it)
        k, v = it.split("=", 1)
        out[k] = v
    return out


def suite_spec(root, name, overrides):
    """(dir, spec_path, kind, suite_json) of a suite, or (dir, None, None, None) when unusable."""
    d = overrides.get(name) or os.path.join(root, name)
    for fname in ("expectations.json", "suite.json"):
        p = os.path.join(d, fname)
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            try:
                data = load_json(p)
            except SystemExit:
                return d, None, None, None
            return d, p, data.get("kind"), data
    return d, None, None, None


def footprint_mb(p):
    total = 0
    for f in p.get("files") or []:
        total += int(f.get("size") or 0)
    return (total + MIB - 1) // MIB


def needs_large(p):
    return p.get("min_tier") in LARGE_TIERS or footprint_mb(p) >= LARGE_FOOTPRINT_MB


def static_refusal(cat, name, root, overrides):
    if not NAME_RE.match(name or ""):
        return "profile name '%s' is not a valid profile id" % name
    profiles = (cat or {}).get("profiles") or {}
    p = profiles.get(name)
    if p is None:
        return "profile '%s' is not in the model catalog" % name
    if p.get("engine") not in SUPPORTED_ENGINES:
        return "profile '%s' uses engine '%s': the live test supports only %s (it hashes the -m/--mmproj files of the unit)" % (
            name, p.get("engine"), "/".join(SUPPORTED_ENGINES))
    suites = (p.get("validation") or {}).get("suites") or []
    if not suites:
        return "profile '%s' has no validation suite in the catalog (nothing to judge its answers against)" % name
    for s in suites:
        d, spec, kind, _ = suite_spec(root, s, overrides)
        if spec is None:
            return "validation suite '%s' of profile '%s' is missing or unreadable under %s" % (s, name, d)
    return None


def cmd_info(a):
    cat = load_json(a.catalog)
    ov = parse_overrides(a.override)
    r = static_refusal(cat, a.profile, a.suites_root, ov)
    if r:
        print("refusal=" + r)
        return
    p = cat["profiles"][a.profile]
    suites = p["validation"]["suites"]
    kinds = [suite_spec(a.suites_root, s, ov)[2] for s in suites]
    print("engine=%s" % p.get("engine"))
    print("min_tier=%s" % p.get("min_tier"))
    print("footprint_mb=%d" % footprint_mb(p))
    print("port=%s" % (p.get("port") or ""))
    print("large=%d" % (1 if needs_large(p) else 0))
    print("mmproj=%d" % (1 if any(f.get("role") == "mmproj" for f in p.get("files") or []) else 0))
    print("suites=%s" % ",".join(suites))
    print("all_vision=%d" % (1 if kinds and all(k == "vision" for k in kinds) else 0))


def gate_numbers(foot_mb, vram_need_mb):
    """The pre-gate thresholds scale with the catalog footprint and never drop below the original vision gates."""
    return {
        "gate_min_mem_mb": max(GATE_MIN_MEM_FLOOR_MB, foot_mb + GATE_RAM_HEADROOM_MB + GATE_RAM_EXTRA_MB),
        "gate_min_free_vram_mb": (vram_need_mb + GATE_VRAM_MARGIN_MB) if vram_need_mb > 0 else 0,
        "vram_need_mb": vram_need_mb,
    }


def cmd_fits(a):
    plan = load_json(a.plan)
    row = (plan.get("profiles") or {}).get(a.profile)
    if row is None:
        print("refusal=`llmctl plan --json` does not list profile '%s'" % a.profile)
        return
    if row.get("fits") is not True:
        print("refusal=`llmctl plan` says profile '%s' does NOT fit this host (fits=%r, tier_ok=%r)" % (
            a.profile, row.get("fits"), row.get("tier_ok")))
        return
    vram = int(row.get("vram_mb") or 0)
    print("plan_ram_mb=%s" % (row.get("ram_mb") or 0))
    print("plan_tier_ok=%s" % row.get("tier_ok"))
    for k, v in gate_numbers(a.footprint_mb, vram).items():
        print("%s=%d" % (k, v))


def cmd_fitting(a):
    cat = load_json(a.catalog)
    plan = load_json(a.plan)
    ov = parse_overrides(a.override)
    rows = []
    for name, p in sorted((cat.get("profiles") or {}).items()):
        why = static_refusal(cat, name, a.suites_root, ov)
        if why:
            continue
        row = (plan.get("profiles") or {}).get(name) or {}
        if row.get("fits") is not True:
            continue
        if needs_large(p) and not a.allow_large:
            continue
        if a.models_dir and not os.path.isdir(os.path.join(a.models_dir, name)):
            continue          # not downloaded: the driver would refuse it anyway
        rows.append((footprint_mb(p), name))
    for _, name in sorted(rows):
        print(name)


def num(v):
    try:
        n = int(float(v))
        return n if n > 0 else 0
    except (TypeError, ValueError):
        return 0


def cmd_prior(a):
    try:
        rows = json.load(open(a.status))
        if not isinstance(rows, list):
            raise ValueError("not a list")
    except Exception as e:
        die("cannot read status json %s: %s" % (a.status, e))
    ex = set(a.exclude or [])
    seen, ram, vram = [], 0, 0
    for r in rows:
        name = str(r.get("profile", ""))
        if not str(r.get("state", "")).startswith("running") or name.split(".")[0] in ex:
            continue
        r_ram, r_vram = num(r.get("ram_mb")), num(r.get("vram_mb"))   # missing / non-numeric -> 0 (callers treat 0 as UNKNOWN)
        ram += r_ram
        vram += r_vram
        if "." in name:
            print("instance=%s" % name)
            continue
        if name not in seen:
            seen.append(name)
            print("profile=%s" % name)
            print("ram=%s:%d" % (name, r_ram))
    print("total_ram_mb=%d" % ram)
    print("total_vram_mb=%d" % vram)


def parse_reports(raw):
    """All JSON objects in the validate output, in order. Raises ValueError when one cannot be parsed."""
    starts = [m.start() for m in re.finditer(r"(?m)^\{", raw)] or ([raw.index("{")] if "{" in raw else [])
    if not starts:
        raise ValueError("no JSON object found")
    dec = json.JSONDecoder()
    reps, end = [], -1
    for s in starts:
        if s < end:
            continue
        obj, end = dec.raw_decode(raw[s:])
        end += s
        reps.append(obj)
    return reps


def expected_counts(spec):
    """(probes, controls, determinism) the real judge emits for a fully correct run of this suite
    (lib/validate_judge.py run(): one result per probe, one control per `discriminates` entry (vision only),
    one determinism entry per determinism_repeat key that names an asked probe; counts.pass is their SUM)."""
    kind = spec.get("kind")
    if kind == "vision":
        fx = spec["fixtures"]
        probes = sum(len(f.get("probes", [])) for f in fx)
        ctl = sum(len(f.get("discriminates", [])) for f in fx)
        keys = {"%s/%s" % (f["id"], p["id"]) for f in fx for p in f.get("probes", [])}
        det = len([k for k in spec.get("determinism_repeat", []) if k in keys])
        return probes, ctl, det
    if kind in ("chat", "coder"):
        ids = {c["id"] for c in spec["cases"]}
        return len(spec["cases"]), 0, len([k for k in spec.get("determinism_repeat", []) if k in ids])
    if kind == "embedding":
        return len(spec["cases"]), 0, 0
    raise ValueError("unknown suite kind %r" % kind)


def judge_one(rep, name, spec):
    exp_p, exp_c, exp_d = expected_counts(spec)
    res, c, ctl, det = rep.get("results"), rep.get("counts") or {}, rep.get("controls"), rep.get("determinism")
    tag = "suite %s: " % name
    if not isinstance(res, list) or not res:
        return tag + "validate output has no probe results"
    if not isinstance(ctl, list) or not isinstance(det, list):
        return tag + "validate output lacks controls/determinism lists"
    if rep.get("kind") != spec.get("kind"):
        return tag + "validate output kind %r != suite kind %r" % (rep.get("kind"), spec.get("kind"))
    if rep.get("verdict") != "PASS" or rep.get("exit_code") != 0:
        return tag + "validate output verdict=%r exit_code=%r" % (rep.get("verdict"), rep.get("exit_code"))
    if c.get("fail") or c.get("undetermined"):
        return tag + "validate output counts fail/undetermined non-zero: %r" % c
    bad = [r.get("key") for r in res if r.get("verdict") != "PASS"]
    if bad:
        return tag + "validate output has non-PASS probes: %s" % bad
    if len(res) != exp_p:
        return tag + "validate output probe count %d != suite %d" % (len(res), exp_p)
    if len(ctl) != exp_c:
        return tag + "validate output control count %d != suite discriminates %d" % (len(ctl), exp_c)
    badc = [x.get("key") for x in ctl if x.get("verdict") != "PASS"]
    if badc:
        return tag + "validate output has non-PASS controls: %s" % badc
    if len(det) != exp_d:
        return tag + "validate output determinism entries %d != determinism_repeat %d" % (len(det), exp_d)
    badd = [x.get("key") for x in det if x.get("identical") is not True]
    if badd:
        return tag + "validate output determinism not identical: %s" % badd
    want = exp_p + exp_c + exp_d
    if c.get("pass") != want or c.get("pass") != len(res) + len(ctl) + len(det):
        return tag + "validate output counts.pass=%r != expected probes+controls+determinism=%d" % (c.get("pass"), want)
    return None


def cmd_check(a):
    ov = parse_overrides(a.override)
    try:
        raw = open(a.report, errors="replace").read()
    except Exception as e:
        print("validate output is not readable (%s)" % e)
        return
    try:
        reps = parse_reports(raw)
    except Exception as e:
        print("validate output is not parseable JSON (%s)" % e)
        return
    for name in a.suite:
        _, spec_path, _, spec = suite_spec(a.suites_root, name, ov)
        if spec is None:
            print("validate output cannot be checked: suite %s unreadable" % name)
            return
        mine = [r for r in reps if r.get("suite") == name]
        if len(mine) != 1:
            print("suite %s: validate output has %d report(s) for it, expected exactly 1" % (name, len(mine)))
            return
        try:
            why = judge_one(mine[0], name, spec)
        except Exception as e:
            print("suite %s: validate output cannot be checked: suite unreadable (%s)" % (name, e))
            return
        if why:
            print(why)
            return
    if len(reps) != len(a.suite):
        print("validate output has %d reports, expected %d (one per suite)" % (len(reps), len(a.suite)))
        return
    print("OK")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("info")
    s.add_argument("--catalog", required=True); s.add_argument("--suites-root", required=True)
    s.add_argument("--profile", required=True); s.add_argument("--override", action="append")
    s.set_defaults(fn=cmd_info)
    s = sub.add_parser("fits")
    s.add_argument("--plan", required=True); s.add_argument("--profile", required=True)
    s.add_argument("--footprint-mb", type=int, required=True)
    s.set_defaults(fn=cmd_fits)
    s = sub.add_parser("fitting")
    s.add_argument("--catalog", required=True); s.add_argument("--suites-root", required=True)
    s.add_argument("--plan", required=True); s.add_argument("--allow-large", action="store_true")
    s.add_argument("--models-dir"); s.add_argument("--override", action="append")
    s.set_defaults(fn=cmd_fitting)
    s = sub.add_parser("prior")
    s.add_argument("--status", required=True); s.add_argument("--exclude", action="append")
    s.set_defaults(fn=cmd_prior)
    s = sub.add_parser("check")
    s.add_argument("--report", required=True); s.add_argument("--suites-root", required=True)
    s.add_argument("--suite", action="append", required=True); s.add_argument("--override", action="append")
    s.set_defaults(fn=cmd_check)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
