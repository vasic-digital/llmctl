#!/usr/bin/env python3
"""host_reserve_mutants.py - paired mutation check for the 3.4.0 host reserve and capacity gate.

usage: python3 -I scripts/qa/host_reserve_mutants.py <llmctl-root> <out-file.json>

Each mutant is applied to a FRESH copy of the tree (the tree itself is never written), then its paired suite runs. A
mutant must turn the suite RED (non-zero exit); a mutant that stays GREEN is a gap in the tests. A copy whose
replacement text is not found is reported as "not-applied" (also a failure: the mutant tests nothing). The unmutated
copy must be GREEN first (the control). Tests are unit-class (hermetic fixtures); the live counterpart is
scripts/qa/host_reserve_live.sh.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

SH = ["bash"]
R = "tests/test_host_reserve_review.sh"

MUTANTS = [
    ("M1-drop-cpu-quota", "lib/reserve.sh", "printf '[Service]\\nCPUQuota=%s%%\\n", "printf '[Service]\\nX=%s%%\\n",
     "tests/test_host_reserve.sh"),
    ("M2-drop-cpu-reserve-floor", "lib/reserve.sh", '"${LLMCTL_RESERVE_CPU_PCT:-25}" 25 25 100', '"${LLMCTL_RESERVE_CPU_PCT:-25}" 25 0 100',
     "tests/test_host_reserve.sh"),
    ("M3-invert-combined-cpu-check", "lib/reserve.sh", "if (( ucpu + ncpu > bcpu )); then", "if (( ucpu + ncpu < 0 )); then",
     "tests/test_host_reserve.sh"),
    ("M4-remove-gate-clamp", "lib/reserve.sh", '"${LLMCTL_GATE_CPU_SOME_MAX:-80}" 80 0 80', '"${LLMCTL_GATE_CPU_SOME_MAX:-80}" 80 0 100',
     "tests/test_host_reserve.sh"),
    ("M5-drop-oom-score-adjust", "lib/service_linux.sh", "CPUWeight=20\\nOOMScoreAdjust=800", "CPUWeight=20\\nOOMScoreAdjust=0",
     "tests/test_host_reserve.sh"),
    ("M6-capacity-admit-always-pass", "lib/capacity.sh", "capacity_admit() {\n  CAP_THREADS=\"\"\n",
     "capacity_admit() {\n  CAP_THREADS=\"\"\n  return 0\n", "tests/test_capacity.sh"),
    ("M7-leak-key-value", "lib/capacity.sh", '"key_variable": keyvar}', '"key_variable": keyvar, "value": E.get(keyvar)}',
     "tests/test_capacity.sh"),
    ("M8-no-cpu-left-check", "lib/capacity.sh", "if cpu_free < 100:", "if cpu_free < 0:", "tests/test_capacity.sh"),
    ("M9-drop-memory-reserve-floor", "lib/reserve.sh", '"${LLMCTL_RESERVE_MEM_MIN_MB:-4096}" 4096 4096', '"${LLMCTL_RESERVE_MEM_MIN_MB:-4096}" 4096 0',
     "tests/test_host_reserve.sh"),
    ("M10-drop-threads-arg", "lib/scheduler.sh", 'SCHED_ARGS+=(--threads "${_thr}" --threads-batch "${_thr}")', ':',
     "tests/test_host_reserve.sh"),
    # the two memos (3.4.0 latency fix): a key that misses an input returns a stale answer
    ("M12-reserve-memo-key-drops-topology", "lib/reserve.sh", "printf '%s|' \"${topo}\" ", "printf '%s|' ",
     "tests/test_host_reserve.sh"),
    ("M13-decide-memo-key-drops-catalog-content", "lib/reserve.sh",
     '"${_RSV_DECIDE_MEMO_KEY}" == "${LLMCTL_CATALOG}:${cat}"', '"${_RSV_DECIDE_MEMO_KEY%%:*}" == "${LLMCTL_CATALOG}"',
     "tests/test_host_reserve.sh"),
    # review round 1 (cb6adb8 NO-GO): each mutant restores one reviewed defect; tests/test_host_reserve_review.sh kills it
    ("R-M01-cpu-reserve-floor-not-ceil", "lib/reserve.sh", "(RSV_N * RSV_CPU_PCT + 99) / 100", "(RSV_N * RSV_CPU_PCT) / 100", R),
    ("R-M02-combined-ram-boundary", "lib/reserve.sh", "if (( umem + nmem > RSV_BM )); then", "if (( umem + nmem >= RSV_BM )); then", R),
    ("R-M03-bash-unlimited-unit-counts-zero", "lib/reserve.sh", '|| mem="${RSV_BM}"', "|| mem=0", R),
    ("R-M09-python-unlimited-unit-counts-zero", "lib/capacity.sh", "mem_v = int(mem) if mem.isdigit() else Bm",
     "mem_v = int(mem) if mem.isdigit() else 0", R),
    ("R-M06-small-host-not-refused", "lib/reserve.sh", "(( RSV_BM < 512 )) && RSV_MEM_SHORT=1", ":", R),
    ("R-M10-admit-fails-open-on-measure-error", "lib/capacity.sh",
     '_cap_refuse "${p}" "the host capacity could not be measured', 'return 0; _cap_refuse "${p}" "the host capacity could not be measured', R),
    ("R-M11-admit-fails-open-on-unknown", "lib/capacity.sh", "    unknown) _cap_refuse", "    unknown) return 0; _cap_refuse", R),
    ("R-M18-unit-gate-skips-combined-budget", "lib/svc_hook.sh",
     'msg="$(reserve_combined_check "${ncpu}" "${nmem}" "${inst:-service}" 2>&1 >/dev/null)" || rc=$?', 'msg=""', R),
    ("R-M21-reduced-threads-ignored", "lib/reserve.sh",
     '&& (( _RSV_CAP_OVERRIDE < cap )); then cap="${_RSV_CAP_OVERRIDE}"; fi', '&& false; then :; fi', R),
    ("R-M22-decision-smoke-uses-chat-cap", "lib/download.sh",
     'args+=(--threads "${RSV_DECIDE_CPUS}" --threads-batch "${RSV_DECIDE_CPUS}")',
     'args+=(--threads "${RSV_CHAT_CPUS}" --threads-batch "${RSV_CHAT_CPUS}")', R),
    ("R-S1-decide-scale-skips-capacity", "lib/scheduler.sh",
     'capacity_admit "${profile}" "${need}" || { local _crc=$?; rm -f "${plan_file}"; return "${_crc}"; }', ":", R),
    ("R-S3-restart-skips-admission", "bin/llmctl", 'sched_restart_admit "$1" || exit $?; svc_restart', "svc_restart", R),
    ("R-S4-instance-suffix-not-mapped", "lib/capacity.sh",
     'return m.group(1) if m and m.group(1) in known else n', "return n", R),
    ("R-S5-fallback-local-without-decision-model", "lib/capacity.sh",
     "decision_local = largest is not None or", "decision_local = True or", R),
    ("R-S6-chat-pct-loosens-cap", "lib/reserve.sh", '"${LLMCTL_CHAT_CPU_PCT:-50}" 50 1 50', '"${LLMCTL_CHAT_CPU_PCT:-50}" 50 1 100', R),
    ("R-S7-dotted-name-stripped", "lib/reserve.sh", '[[ "${set}" == *" ${n} "* ]] && { echo "${n}"; return 0; }',
     'n="${n%.[0-9]*}"; echo "${n}"; return 0', R),
    ("R-restart-same-profile-treated-running", "lib/capacity.sh",
     "is_running = p in running and not ((new_inst or replace) and p in wanted)", "is_running = p in running", R),
]


def run(tree, suite):
    env = dict(os.environ)
    env["GOMAXPROCS"] = "2"
    r = subprocess.run(SH + [os.path.join(tree, suite)], cwd=tree, env=env, capture_output=True, text=True, timeout=900)
    tail = (r.stdout + r.stderr).strip().splitlines()[-3:]
    return r.returncode, tail


def copy_tree(src, dst):
    shutil.copytree(src, dst, symlinks=True,
                    ignore=shutil.ignore_patterns(".git", "submodules", "constitution", "node_modules"))


def main():
    root, out = os.path.abspath(sys.argv[1]), sys.argv[2]
    results = {"control": {}, "mutants": []}
    with tempfile.TemporaryDirectory(prefix="llmctl-mut-") as tmp:
        ctl = os.path.join(tmp, "control")
        copy_tree(root, ctl)
        for suite in sorted({m[4] for m in MUTANTS}):
            rc, tail = run(ctl, suite)
            results["control"][suite] = {"rc": rc, "tail": tail}
        for name, rel, old, new, suite in MUTANTS:
            d = os.path.join(tmp, name)
            copy_tree(root, d)
            p = os.path.join(d, rel)
            s = open(p).read()
            if old not in s:
                results["mutants"].append({"mutant": name, "file": rel, "suite": suite, "verdict": "not-applied"})
                continue
            open(p, "w").write(s.replace(old, new, 1))
            rc, tail = run(d, suite)
            results["mutants"].append({"mutant": name, "file": rel, "suite": suite, "rc": rc,
                                       "verdict": "killed" if rc != 0 else "SURVIVED", "tail": tail})
            shutil.rmtree(d)
    results["control_green"] = all(v["rc"] == 0 for v in results["control"].values())
    results["all_killed"] = all(m["verdict"] == "killed" for m in results["mutants"])
    with open(out, "w") as f:
        json.dump(results, f, indent=2)
    print(json.dumps({"control_green": results["control_green"], "all_killed": results["all_killed"],
                      "mutants": [(m["mutant"], m["verdict"]) for m in results["mutants"]]}, indent=1))
    sys.exit(0 if results["control_green"] and results["all_killed"] else 1)


if __name__ == "__main__":
    main()
