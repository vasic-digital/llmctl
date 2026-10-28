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
GO = ["go", "test", "-count=1", "./internal/isolation/"]

MUTANTS = [
    ("M1-drop-cpu-quota", "lib/reserve.sh", "printf '[Service]\\nCPUQuota=%s%%\\n", "printf '[Service]\\nX=%s%%\\n",
     "tests/test_host_reserve.sh"),
    ("M2-drop-cpu-reserve-floor", "lib/reserve.sh", '"${LLMCTL_RESERVE_CPU_PCT:-25}" 25 25 90', '"${LLMCTL_RESERVE_CPU_PCT:-25}" 25 0 90',
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
    ("M11-go-decide-equals-chat", "llmctld/internal/isolation/reserve.go",
     "b.DecideCPUs = min(b.ChatCPUs, max(1, bc*pol.DecidePct/100))", "b.DecideCPUs = b.ChatCPUs", "GO"),
    # the two memos (3.4.0 latency fix): a key that misses an input returns a stale answer
    ("M12-reserve-memo-key-drops-topology", "lib/reserve.sh", "printf '%s|' \"${topo}\" ", "printf '%s|' ",
     "tests/test_host_reserve.sh"),
    ("M13-decide-memo-key-drops-catalog-content", "lib/reserve.sh",
     '"${_RSV_DECIDE_MEMO_KEY}" == "${LLMCTL_CATALOG}:${cat}"', '"${_RSV_DECIDE_MEMO_KEY%%:*}" == "${LLMCTL_CATALOG}"',
     "tests/test_host_reserve.sh"),
]


def run(tree, suite):
    env = dict(os.environ)
    env["GOMAXPROCS"] = "2"
    if suite == "GO":
        r = subprocess.run(GO, cwd=os.path.join(tree, "llmctld"), env=env, capture_output=True, text=True, timeout=900)
    else:
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
