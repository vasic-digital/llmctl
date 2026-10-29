#!/usr/bin/env bash
# class_inventory.sh - review round 5, §11.4.276(C): every "count X under a source" instrument in the start/admission
# paths, run twice through its real code: once on a readable source holding ONE known item (the control needle - the
# instrument must see it) and once on a missing or unreadable source. A member whose second line reads like "0 items,
# admitted" fails open. Hermetic (tests/helpers.sh world, fixture trees, a fake systemctl on PATH); starts no process
# other than the shells and the fake systemctl it runs. Usage: bash class_inventory.sh <llmctl checkout>
set -uo pipefail
cd "${1:?usage: class_inventory.sh <llmctl checkout>}"
source tests/helpers.sh; test_setup_env
trap 'chmod -R u+rwx "${TEST_TMP:?}" 2>/dev/null || true; test_teardown_env' EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" LLMCTL_HOST_MEM_MB=32768 LLMCTL_GATE_WAIT=0
for l in common os_detect hardware catalog reserve capacity svc_hook scheduler; do source "lib/${l}.sh" 2>/dev/null; done
reserve_compute
echo "commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)  dirty: $(git status --porcelain -- lib bin | wc -l) changed code paths"
R="${TEST_TMP}/cg"; d="${R}/app.slice/llmctl-llama@big.service"; mkdir -p "${d}"
printf 'populated 1\n' > "${d}/cgroup.events"; printf '%s 100000\n' $(( RSV_BC * 100000 )) > "${d}/cpu.max"
printf '%s\n' $(( RSV_BM * 1048576 )) > "${d}/memory.max"; echo 0 > "${d}/memory.current"
rc() { local r=0; "$@" >/dev/null 2>&1 || r=$?; echo "${r}"; }
cap() { python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print("ok=%s verdict=%s units=%d fallback=%s" % (d["measurement"]["ok"],d["profiles"]["decide-tiny"]["verdict"],len(d["llmctl"]["units"]),d["fallback"]["recommended"]))' "$1"; }
echo "M1 reserve_running_units (cgroup tree): needle=$(LLMCTL_CGROUP_ROOT=$R reserve_running_units | wc -l) unit(s) rc=$(rc env LLMCTL_CGROUP_ROOT=$R bash -c 'true');" \
     "missing rc=$( ( LLMCTL_CGROUP_ROOT=/nonexistent/cg reserve_running_units >/dev/null ); echo $? )"
chmod 000 "${R}"; echo "   mode-000 rc=$( ( LLMCTL_CGROUP_ROOT=$R reserve_running_units >/dev/null ); echo $? )"; chmod 700 "${R}"
echo "M2 reserve_combined_check: needle(full budget)=$(LLMCTL_CGROUP_ROOT=$R rc reserve_combined_check 100 512 x) missing=$(LLMCTL_CGROUP_ROOT=/nonexistent/cg rc reserve_combined_check 100 512 x)"
chmod 000 "${R}"; echo "   mode-000=$(LLMCTL_CGROUP_ROOT=$R rc reserve_combined_check 100 512 x)"; chmod 700 "${R}"
echo "M3 hk_gate (ExecStartPre): needle=$(LLMCTL_CGROUP_ROOT=$R rc hk_gate '') missing=$(LLMCTL_CGROUP_ROOT=/nonexistent/cg rc hk_gate '')"
echo "M4 hw_pressure_gate (start gate): empty-root=$(LLMCTL_CGROUP_ROOT=${TEST_TMP}/cgroup-root rc hw_pressure_gate 0 x) missing=$(LLMCTL_CGROUP_ROOT=/nonexistent/cg rc hw_pressure_gate 0 x)"
echo "M5 capacity_json units: needle: $(cap "$(LLMCTL_CGROUP_ROOT=$R capacity_json decide-tiny)")"
chmod 000 "${R}"; echo "   mode-000: $(cap "$(LLMCTL_CGROUP_ROOT=$R capacity_json decide-tiny)")"; chmod 700 "${R}"
echo "M6 reserve_report: needle units_readable=$(LLMCTL_CGROUP_ROOT=$R reserve_report --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["units_readable"],len(d["units"]))') missing=$(LLMCTL_CGROUP_ROOT=/nonexistent/cg reserve_report --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["units_readable"],len(d["units"]))')"
P="${TEST_TMP}/proc1"; t_proc_self "${P}"; mkdir -p "${P}/4242"; printf 'Name:\tx\nUid:\t%s\t0\t0\t0\nThreads:\t7\n' "$(id -u)" > "${P}/4242/status"
echo "M7 /proc thread census: needle(7 threads + self) $(LLMCTL_PROC_DIR=$P capacity_json decide-tiny | python3 -c 'import json,sys;d=json.load(sys.stdin);print("ok=%s user_threads=%s" % (d["measurement"]["ok"],d["host"]["nproc"]["user_threads"]))')" \
     "empty dir $(LLMCTL_PROC_DIR=${TEST_TMP}/emptyproc capacity_json decide-tiny 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print("ok=%s user_threads=%s" % (d["measurement"]["ok"],d["host"]["nproc"]["user_threads"]))')"
# M8: the planner's per-unit memory list (lib/catalog.sh _catalog_unit_mem_mb, systemctl list-units). Outside the reserve.
FB="${TEST_TMP}/fakebin"; mkdir -p "${FB}"
cat > "${FB}/systemctl" <<'SH'
#!/usr/bin/env bash
case "${FAKE_SC:-ok}:$*" in
  ok:*list-units*) echo "llmctl-llama@big.service loaded active running x" ;;
  ok:*MemoryCurrent*) echo 2147483648 ;; ok:*MemoryMax*) echo 4294967296 ;; ok:*MemoryHigh*) echo 3221225472 ;;
  fail:*) exit 1 ;;
esac
SH
chmod +x "${FB}/systemctl"
echo "M8 catalog _catalog_unit_mem_mb (systemctl list-units): needle='$(PATH="${FB}:${PATH}" LLMCTL_FAKE_HW= LLMCTL_FAKE_UNIT_MEM= _catalog_unit_mem_mb | tr '\n' ';')'" \
     "systemctl failing='$(FAKE_SC=fail PATH="${FB}:${PATH}" LLMCTL_FAKE_HW= LLMCTL_FAKE_UNIT_MEM= _catalog_unit_mem_mb | tr '\n' ';')' (empty = counted as no unit: FAIL-OPEN, scoped out)"
# M9: the scheduler's reservation sum (lib/scheduler.sh sched_reserved_field, $LLMCTL_RUNTIME_DIR/*.run). Outside the reserve.
mkdir -p "${LLMCTL_RUNTIME_DIR}"; printf 'ram_mb=2048\n' > "${LLMCTL_RUNTIME_DIR}/big.run"
echo "M9 sched_reserved_field (runtime dir *.run): needle=$(sched_reserved_field ram_mb) MiB" \
     "runtime dir missing=$(LLMCTL_RUNTIME_DIR=/nonexistent/rt sched_reserved_field ram_mb) MiB (0 = FAIL-OPEN, scoped out)"
chmod 000 "${LLMCTL_RUNTIME_DIR}"; echo "   runtime dir mode-000=$(sched_reserved_field ram_mb) MiB"; chmod 700 "${LLMCTL_RUNTIME_DIR}"
# M10 (F3): the HOST census (LLMCTL_CGROUP_ROOT unset): a fixture cgroup v2 mount with another user's llmctl unit as the
# needle, then that user's manager at mode 000 (part of the host tree unreadable).
FS="${TEST_TMP}/cgfs"; U="$(id -u)"; O=4242; [[ "${U}" != 4242 ]] || O=4243
mkdir -p "${FS}/user.slice/user-${U}.slice/user@${U}.service/app.slice"; : > "${FS}/cgroup.controllers"
od="${FS}/user.slice/user-${O}.slice/user@${O}.service/app.slice/app-llmctl\\x2dllama.slice/llmctl-llama@big.service"; mkdir -p "${od}"
printf 'populated 1\n' > "${od}/cgroup.events"; printf '%s 100000\n' $(( RSV_BC * 100000 )) > "${od}/cpu.max"
printf '%s\n' $(( RSV_BM * 1048576 )) > "${od}/memory.max"; echo 0 > "${od}/memory.current"
echo "M10 host census (every owner): needle='$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS=${FS} reserve_running_units | awk '{print $1, $4}')' combined=$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS=${FS} rc reserve_combined_check 100 512 x)"
chmod 000 "${FS}/user.slice/user-${O}.slice/user@${O}.service"
echo "    other user's manager mode-000: census rc=$( ( LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS=${FS} reserve_running_units >/dev/null ); echo $? ) combined=$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS=${FS} rc reserve_combined_check 100 512 x) hk_gate=$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS=${FS} rc hk_gate '')"
chmod 700 "${FS}/user.slice/user-${O}.slice/user@${O}.service"
