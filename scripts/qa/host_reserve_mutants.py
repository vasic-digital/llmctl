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
R2 = "tests/test_host_reserve_review2.sh"
R3 = "tests/test_host_reserve_review3.sh"
R4 = "tests/test_host_reserve_review4.sh"
RSV = "lib/reserve.sh"
HW = "lib/hardware.sh"
C = "tests/test_capacity.sh"
CAP = "lib/capacity.sh"

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
    ("M7-leak-key-value", "lib/capacity.sh", '"key_variable": keyvar}\nelse:', '"key_variable": keyvar, "value": E.get(keyvar)}\nelse:',
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
    ("R-S3-restart-skips-admission", "lib/scheduler.sh", 'sched_restart_admit "$1" || return $?; svc_restart', "svc_restart", R),
    ("R-S4-instance-suffix-not-mapped", "lib/capacity.sh",
     'return m.group(1) if m and m.group(1) in known else n', "return n", R),
    ("R-S5-fallback-local-without-decision-model", "lib/capacity.sh",
     "decision_local = largest is not None or", "decision_local = True or", R),
    ("R-S6-chat-pct-loosens-cap", "lib/reserve.sh", '"${LLMCTL_CHAT_CPU_PCT:-50}" 50 1 50', '"${LLMCTL_CHAT_CPU_PCT:-50}" 50 1 100', R),
    ("R-S7-dotted-name-stripped", "lib/reserve.sh", '[[ "${set}" == *" ${n} "* ]] && { echo "${n}"; return 0; }',
     'n="${n%.[0-9]*}"; echo "${n}"; return 0', R),
    ("R-restart-same-profile-treated-running", "lib/capacity.sh",
     "is_running = inst_key(p) in unit_keys and not ((new_inst or replace) and p in wanted)",
     "is_running = inst_key(p) in unit_keys", R),
    # review round 2: the reviewer's surviving mutants (M03..M22) and the F1/F2/F4/F5/F6 fixes
    ("R2-M03-replaced-rss-not-in-cgroup-room", "lib/capacity.sh", 'cg["memory_current_mb"] + rep_cur', 'cg["memory_current_mb"]', R2),
    ("R2-M04-scale-k-forced-1", "lib/capacity.sh", "k = new_inst if (new_inst and p in wanted) else 1", "k = 1", R2),
    ("R2-M05-scale-one-allows-reduced-threads", "lib/capacity.sh", "elif k > 1 or (new_inst and p in wanted):", "elif k > 1:", R2),
    ("R2-M06-named-refused-never", "lib/capacity.sh", "named_refused = bool(wanted) and (", "named_refused = False and (", R2),
    ("R2-M07-degraded-decide-unit-local", "lib/capacity.sh", 'u["base_profile"] in decide_set and u["status"] == "ok"',
     'u["base_profile"] in decide_set', R2),
    ("R2-M10-empty-doc-not-refused", "lib/capacity.sh", '|| [[ -z "${doc}" ]]; then', "; then", R2),
    ("R2-M16-scale-passes-no-instance-count", "lib/scheduler.sh", 'capacity_admit "${profile}" "${need}"', 'capacity_admit "${profile}"', R2),
    ("R2-M20-template-mem-floor-removed", "lib/service_linux.sh", "    (( lim < 256 )) && lim=256\n", "\n", R2),
    ("R2-M21-py-tenant-strip-removed", "lib/capacity.sh", '    if "--" in n: n = n.rsplit("--", 1)[1]\n', "\n", R2),
    ("R2-M22-scale-skips-pressure-gate", "lib/scheduler.sh", '    hw_pressure_gate "$(( ram * need ))" "${profile}" ||', "    true ||", R2),
    ("R2-F1-running-by-base-profile", "lib/capacity.sh", "is_running = inst_key(p) in unit_keys and",
     'is_running = any(u["base_profile"] == p for u in units) and', R2),
    ("R2-F1-tenant-key-ignored", "lib/capacity.sh", 'def inst_key(p): return ("%s--%s" % (tenant, p)) if tenant else p',
     "def inst_key(p): return p", R2),
    ("R2-F2-no-probe-bound", "lib/capacity.sh", '_cap_bounded "${CAP_PT}" "${plan_file}" _cap_plan_probe || prc=$?',
     '_cap_plan_probe > "${plan_file}" || prc=$?', R2),
    ("R2-F2-no-whole-bound", "lib/capacity.sh", '_CAP_TMPDIR="${tdir}" _cap_bounded "${CAP_T}" "${out}" _cap_measure "$@" || rc=$?',
     '_CAP_TMPDIR="${tdir}" _cap_measure "$@" > "${out}" || rc=$?', R2),
    ("R2-F2-tree-not-killed", "lib/capacity.sh", "      _cap_kill_tree \"${pid}\"\n", "      kill -KILL \"${pid}\" 2>/dev/null\n", R2),
    ("R2-F2-probe-ceiling-loosened", "lib/capacity.sh", '"${LLMCTL_CAPACITY_PROBE_TIMEOUT:-}" 3 1 30', '"${LLMCTL_CAPACITY_PROBE_TIMEOUT:-}" 3 0 9999', R2),
    ("R2-F2-undetermined-admitted", "lib/capacity.sh", "    undetermined)\n", "    undetermined) return 0 ;;\n    xundetermined)\n", R2),
    ("R2-F2-exit-code-ignores-measurement", "lib/capacity.sh",
     'if not (d.get("measurement") or {}).get("ok", True): sys.exit(75)', "pass", R2),
    ("R2-F2-cli-no-fallback-line", "bin/llmctl", "        printf 'llmctl-fallback: %s\\n' \"${_cfb:-none}\" >&2", "        :", R2),
    ("R2-F4-verdict-class-map", "lib/capacity.sh", '"fits_with_reduced_threads": "fits_reduced"', '"fits_with_reduced_threads": "fits"', R2),
    ("R2-F4-route-cloud-not-hosted", "lib/capacity.sh", '"recommended": "cloud", "route": "hosted"', '"recommended": "cloud", "route": "cloud"', R2),
    ("R2-F5-sched-no-tenant-strip", "lib/scheduler.sh", '  [[ "${k}" == *--* ]] && k="${k##*--}"\n  if catalog_exists', "  if catalog_exists", R2),
    ("R2-F5-sched-suffix-before-full-name", "lib/scheduler.sh",
     '  if catalog_exists "${k}" 2>/dev/null; then printf \'%s\\n\' "${k}"; return 0; fi\n  if [[ "${k}" =~ ^(.+)\\.([2-9]|[1-9][0-9]+)$ ]]; then',
     '  if [[ "${k}" =~ ^(.+)\\.([0-9]+)$ ]]; then', R2),
    ("R2-F6-plan-failure-is-unknown", "lib/capacity.sh",
     '    _cap_undetermined_doc "the hardware/plan probe failed (llmctl plan --json); the capacity cannot be judged without it" "$@"\n    return 0',
     "    echo '{}' > \"${plan_file}\"", R2),
    # --- the round-3 reviewer's mutants X01-X15, ported to the round-3 code (X09 and X15 re-targeted: their original
    # text was replaced by the fix; the mapping is in docs/qa/2026-10-28-host-reserve/review-r3/README.md) ---
    ("X01-probe-clamp-floor-0", CAP, '"${LLMCTL_CAPACITY_PROBE_TIMEOUT:-}" 3 1 30', '"${LLMCTL_CAPACITY_PROBE_TIMEOUT:-}" 3 0 30', R2),
    ("X02-whole-clamp-ceiling-300", CAP, '"${LLMCTL_CAPACITY_TIMEOUT:-}" 5 2 30', '"${LLMCTL_CAPACITY_TIMEOUT:-}" 5 2 300', R2),
    ("X03-kill-without-starttime-match", CAP,
     '[[ "$(_cap_pid_start "${all[i]}" 2>/dev/null || true)" == "${st[i]}" ]] && kill -KILL', "kill -KILL", R3),
    ("X04-kill-tree-no-stop", CAP, '      kill -STOP "${p}" 2>/dev/null || true   # no new children while the tree is collected\n', "\n", R3),
    ("X05-undetermined-doc-recommends-local", CAP,
     'fb = {"recommended": "cloud" if keyvar else "none", "route": "hosted" if keyvar else "none",',
     'fb = {"recommended": "local", "route": "hosted" if keyvar else "none",', R3),
    ("X06-degraded-exit-3-dropped", CAP, 'sys.exit(3 if d["degraded"] else 0)', "sys.exit(0)", C),
    ("X07-cpu-free-boundary-le", CAP, "        if cpu_free < 100:", "        if cpu_free <= 100:", R3),
    ("X08-reduced-threads-boundary-le", CAP, "        elif cpu_free < cap * 100:", "        elif cpu_free <= cap * 100:", R3),
    ("X09-bound-plus-3s", CAP, "    if (( $(_cap_now_ms) >= deadline )); then", "    if (( $(_cap_now_ms) >= deadline + 3000 )); then", R3),
    ("X10-kill-wrong-pid", CAP, '      _cap_kill_tree "${pid}"\n', "      _cap_kill_tree 999999999\n", R2),
    ("X11-mem-reserve-pressure-off", CAP, "if enabled and live_avail is not None and live_avail < Rm:",
     "if enabled and live_avail is not None and live_avail < 0:", R3),
    ("X12-mem-after-footprint-le", CAP, "live_avail - fp < (Rm if enabled else 4096):", "live_avail - fp < 0:", C),
    ("X13-exit-75-to-1", CAP, "    sys.exit(75 if bad else 0)", "    sys.exit(1 if bad else 0)", C),
    ("X14-running-admit-sets-no-threads-check", CAP, "    fits|fits_with_reduced_threads|running)",
     "    fits|fits_with_reduced_threads|running|does_not_fit)", C),
    ("X15-other-tenant-decide-counts-local", CAP, 'any(own_unit(u) and u["base_profile"]', 'any(u["base_profile"]', R3),
    # --- round-3 author mutants (one per new mechanism) ---
    ("R3-placeholder-key-accepted", CAP, '  (( ${#k} >= 16 )) || return 1\n', "\n", R3),
    ("R3-placeholder-list-dropped", CAP,
     '    x|xx|xxx|changeme|change-me|replace-me|replaceme|your-key-here|your_api_key|placeholder|dummy|test|none|null|todo|empty|"<"*">") return 1 ;;',
     '    __never__) return 1 ;;', R3),
    ("R3-collect-no-recheck", CAP, 'if [[ "${k2}" != "${k}" ]]; then kill -CONT', "if false; then kill -CONT", R3),
    ("R3-collect-no-cont", CAP, 'then kill -CONT "${p}" 2>/dev/null || true; continue; fi', "then continue; fi", R3),
    ("R3-nproc-check-off", CAP, "if enabled and nproc_headroom is not None and nproc_headroom < cap:",
     "if enabled and nproc_headroom is not None and nproc_headroom < 0:", R3),
    ("R3-nproc-counts-other-uids", CAP, "if _uidl == str(_uid) and _thr", "if _thr", R3),
    ("R3-nproc-override-raises", CAP, "nproc_soft = int(_lim) if nproc_soft is None else min(nproc_soft, int(_lim))",
     "nproc_soft = int(_lim)", R3),
    ("R3-footprint-labelled-measured", CAP, '"footprint_provenance": "declared"', '"footprint_provenance": "measured"', R3),
    ("R3-input-unreadable-reported-readable", CAP, '"readable": _f[1] == "1"', '"readable": True', R3),
    ("R3-unit-cpu-stat-dropped", CAP, '"cpu_stat": ustat,', '"cpu_stat": None,', R3),
    ("R3-scope-cpu-stat-dropped", CAP, '"cpu_stat": cpu_stat(E.get("CAP_CG_CSTAT"))}', '"cpu_stat": None}', R3),
    # --- review round 4 (F1 fail-open per input, F2/F3/F4, reviewer mutants Y03/Y04/Y05/Y09/Y11/Y13 ported) ---
    ("R4-F1-meminfo-not-critical", CAP, "if avail is None: critical.append(", "if False: critical.append(", R4),
    ("R4-F1-mem-psi-not-critical", CAP, 'if psi["memory"]["some"] is None or psi["memory"]["full"] is None:',
     "if False:", R4),
    ("R4-F1-cpu-psi-not-critical", CAP, '    if psi["cpu"]["some"] is None: critical.append(',
     "    if False: critical.append(", R4),
    ("R4-F1-load-not-critical", CAP, "    if load is None: critical.append(", "    if False: critical.append(", R4),
    ("R4-F1-cgroot-not-critical", CAP, 'if enabled and not os.path.isdir(E.get("CAP_CG_ROOT") or ""):', "if False:", R4),
    ("R4-F1-procdir-not-critical", CAP, "if enabled and not nproc_ok: critical.append(",
     "if False: critical.append(", R4),
    ("R4-F1-strict-forced-off", CAP, 'strict = E.get("CAP_STRICT") == "1"', "strict = False", R4),
    ("R4-F1-garbage-load-parsed", CAP, "if load is not None and None in load: load = None", "pass", R4),
    ("R4-F1-garbage-psi-parsed", CAP, 'return float(x) if re.fullmatch(r"[0-9]+(\\.[0-9]+)?", x or "") else None',
     "return num_or_none(x)\ndef num_or_none(x):\n    try: return float(x)\n    except Exception: return 0.0", R4),
    ("R4-F1-gate-mem-psi-skip", HW, 'if (( strict )) && [[ -z "${some}" || -z "${full}" ]]; then', "if false; then", R4),
    ("R4-F1-gate-meminfo-skip", HW, "    if (( strict )); then\n      printf 'refusing to %s %s: the memory input",
     "    if false; then\n      printf 'refusing to %s %s: the memory input", R4),
    ("R4-F1-gate-cpu-psi-skip", RSV, "    if (( strict )); then\n      printf 'refusing to %s %s: the CPU pressure input",
     "    if false; then\n      printf 'refusing to %s %s: the CPU pressure input", R4),
    ("R4-F1-gate-load-skip", RSV, "    if (( strict )); then\n      printf 'refusing to %s %s: the load input",
     "    if false; then\n      printf 'refusing to %s %s: the load input", R4),
    ("R4-F1-avg10-accepts-anything", RSV,
     "  [[ \"${v}\" =~ ^[0-9]+(\\.[0-9]+)?$ ]] || return 1\n  printf '%s' \"${v}\"\n}\n\n# _rsv_load1",
     "  printf '%s' \"${v}\"\n}\n\n# _rsv_load1", R4),
    ("R4-F1-strict-never", RSV, '_rsv_inputs_strict() { [[ "$(uname -s 2>/dev/null)" == Linux ]]; }',
     "_rsv_inputs_strict() { false; }", R4),
    ("R4-F2-json-first-only", "bin/llmctl", "          --json) _cj=1 ;;",
     '          --json) [[ "${_ca}" == "${1:-}" ]] && _cj=1 ;;', R4),
    ("R4-F2-unknown-option-is-profile", "bin/llmctl",
     "          -*) err \"usage: llmctl capacity [--json] [profile...] (unknown option '${_ca}')\"; exit 2 ;;\n", "", R4),
    ("R4-F3-scope-dropped", CAP, '"consumption_scope": {"cgroup_root"', '"consumption_scope_x": {"cgroup_root"', R4),
    ("R4-F4-restart-outside-lock", "lib/scheduler.sh",
     'sched_restart() { scheduler::with_lock _sched_restart_impl "$@"; }', 'sched_restart() { _sched_restart_impl "$@"; }',
     R4),
    ("R4-F4-cli-bypasses-lock", "bin/llmctl", '*) sched_restart "$1" || exit $?;',
     '*) sched_restart_admit "$1" || exit $?; svc_restart "$1";', R4),
    ("Y03-tenant-prefix-without-separator", CAP, 'return u["profile"].startswith(tenant + "--") if tenant',
     'return u["profile"].startswith(tenant) if tenant', R4),
    ("Y04-gpu-floor-python", CAP, "        if m < 6144: m = 6144", "        if m < 614: m = 614", R4),
    ("Y04-gpu-floor-bash", "lib/service_linux.sh", "(( m < 6144 )) && m=6144", "(( m < 614 )) && m=614", R4),
    ("Y05-load-threshold-x10-python", CAP, 'load[0] > num("CAP_LOAD_K", 3) * N:',
     'load[0] > num("CAP_LOAD_K", 3) * N * 10:', R4),
    ("Y05-load-threshold-x10-bash", RSV, "'BEGIN{exit !(v>k*n)}'", "'BEGIN{exit !(v>k*n*10)}'", R4),
    ("Y09-tree-collect-one-pass", CAP, "  for pass in 1 2 3 4 5; do", "  for pass in 1; do", R4),
    ("Y11-mem-full-x10-python", CAP, 'psi["memory"]["full"] > num("CAP_MEM_FULL_MAX", 2):',
     'psi["memory"]["full"] > num("CAP_MEM_FULL_MAX", 2) * 10:', R4),
    ("Y11-mem-full-x10-bash", HW, "[[ -n \"${full}\" ]] && awk -v v=\"${full}\" -v m=\"${fmax}\" 'BEGIN{exit !(v>m)}'",
     "[[ -n \"${full}\" ]] && awk -v v=\"${full}\" -v m=\"${fmax}\" 'BEGIN{exit !(v>m*10)}'", R4),
    ("Y13-allowedcpus-all-cpus", RSV, '"${RSV_CPUSET//,/ }" "${RSV_CPUSET}" "${cap}"',
     '"${RSV_CPUSET//,/ }" "0-$(( RSV_N - 1 ))" "${cap}"', R4),
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
