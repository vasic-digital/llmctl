#!/usr/bin/env bash
# test_supply_chain_ramcap.sh - RED-first (independent review 2026-10-14, finding 10).
#  * 10 profiles download from the moving revision "main" and 6 colibri config files have no sha256: nothing listed them
#    and nothing warned. `llmctl models pins` is now the gate (exit 1 while any is unpinned) and a download from a moving
#    revision warns loudly. No value was invented: none of them could be verified offline (docs/validation.md), so the
#    known set is a RATCHET (tests/fixtures/catalog_unpinned_allowlist.txt) - a NEW unpinned entry fails this test.
#  * the RAM admission budget was MemAvailable - 4 GiB only; Constitution 12.6 caps llmctl at 60% of MemTotal. The budget
#    is now the tighter of the two, and the cap counts the RAM the running llmctl profiles already reserve.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
L="${SUPPLY_ROOT_UNDER_TEST:-${LLMCTL_ROOT}}/bin/llmctl"   # override: a mutant tree (tests/test_validation_mutants.sh)
run_rc() { local rc=0; "$@" >"${TEST_TMP}/last.out" 2>&1 || rc=$?; echo "${rc}"; }

echo "== 1. llmctl models pins: the gate lists every unpinned revision / sha256"
assert_eq 1 "$(run_rc "${L}" models pins)" "the shipped catalog still has unpinned entries -> exit 1"
got="$(grep '^UNPINNED ' "${TEST_TMP}/last.out" | sort)"
want="$(grep -v '^#' "${LLMCTL_ROOT}/tests/fixtures/catalog_unpinned_allowlist.txt" | sed '/^$/d' | sort)"
new="$(comm -23 <(printf '%s\n' "${got}") <(printf '%s\n' "${want}"))"
assert_eq "" "${new}" "no NEW unpinned entry beyond the recorded ratchet (pin it, or record why it cannot be pinned)"
assert_eq 16 "$(grep -c '^UNPINNED ' "${TEST_TMP}/last.out")" "today: 10 moving revisions + 6 config files without sha256"
assert_contains "$(cat "${TEST_TMP}/last.out")" "UNPINNED revision fast unsloth/Llama-3.1-8B-Instruct-GGUF@main" "a moving revision is named with its repo"
assert_contains "$(cat "${TEST_TMP}/last.out")" "UNPINNED sha256 colibri-qwen36 config.hf.json" "a file without sha256 is named"
python3 -I - "${LLMCTL_ROOT}/models/catalog.json" "${TEST_TMP}/pinned.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for p in d["profiles"].values():
    p["hf_revision"] = "0" * 40
    for f in p["files"]:
        f["sha256"] = f.get("sha256") or "1" * 64
json.dump(d, open(sys.argv[2], "w"))
PY
assert_eq 0 "$(run_rc env LLMCTL_CATALOG="${TEST_TMP}/pinned.json" "${L}" models pins)" "control: a fully pinned catalog -> exit 0"
assert_contains "$(cat "${TEST_TMP}/last.out")" "unpinned: 0" "...and says so"
w="$(bash -c 'for l in common os_detect hardware catalog download; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done; _dl_warn_unpinned fast' 2>&1)"
assert_contains "${w}" "UNPINNED: 'fast' downloads from the moving revision 'main'" "a download from a moving revision warns loudly"
w="$(bash -c 'for l in common os_detect hardware catalog download; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done; _dl_warn_unpinned decide' 2>&1)"
assert_eq "" "${w}" "control: a profile pinned to a commit does not warn"

echo "== 2. RAM budget = min(MemAvailable - 4 GiB, 60% of MemTotal - RAM reserved by running llmctl profiles)"
HW="${TEST_TMP}/hw.json"
python3 -I - "${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" "${HW}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["memory"]["total_mb"] = 32768; d["memory"]["available_mb"] = 30720
json.dump(d, open(sys.argv[2], "w"))
PY
export LLMCTL_FAKE_HW="${HW}"
b() { "${L}" plan --json | python3 -I -c 'import json,sys; b=json.load(sys.stdin)["budgets"]; print(b["ram_mb"], b["ram_cap_mb"], b["ram_reserved_mb"], b["ram_avail_budget_mb"])'; }
assert_eq "19660 19660 0 26624" "$(b)" "32 GiB host, 30 GiB available: budget 19660 MiB (60% cap), not 26624 (MemAvailable - 4 GiB)"
printf 'profile=small\nmode=gpu\nport=1\nram_mb=12000\nvram_mb=0\nstarted_epoch=1\n' > "${LLMCTL_RUNTIME_DIR}/small.run"
assert_eq "7660 19660 12000 26624" "$(b)" "a running profile reserving 12000 MiB leaves 7660 MiB under the cap"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run"
assert_eq "16384 16384 0 26624" "$(LLMCTL_RAM_CAP_PCT=50 b)" "LLMCTL_RAM_CAP_PCT may LOWER the cap (50% -> 16384)"
assert_eq "19660 19660 0 26624" "$(LLMCTL_RAM_CAP_PCT=90 b)" "...but never raise it above 60%"
assert_eq "19660 19660 0 26624" "$(LLMCTL_RAM_CAP_PCT=abc b)" "...and a malformed value keeps 60%"
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["memory"]["available_mb"]=8192; json.dump(d,open(p,"w"))' "${HW}"
assert_eq "4096 19660 0 4096" "$(b)" "control: when MemAvailable - 4 GiB is tighter, it still wins (4096)"

echo "== 3. admission refuses a profile that fits MemAvailable but not the 60% cap (and admits it one MiB earlier)"
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["memory"]["available_mb"]=30720; json.dump(d,open(p,"w"))' "${HW}"
export LLMCTL_DRY_RUN=1
need="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["profiles"]["small"]["ram_mb"])' < <("${L}" plan --json))"
printf 'profile=coder\nmode=gpu\nport=1\nram_mb=%s\nvram_mb=0\nstarted_epoch=1\n' "$(( 19660 - need + 1 ))" > "${LLMCTL_RUNTIME_DIR}/coder.run"
rc="$(run_rc "${L}" start small)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "small (${need} MiB) next to $(( 19660 - need + 1 )) MiB reserved: 1 MiB over the 60% cap -> refused (MemAvailable alone would admit it)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "60% of MemTotal" "the refusal names the 60% cap"
printf 'profile=coder\nmode=gpu\nport=1\nram_mb=%s\nvram_mb=0\nstarted_epoch=1\n' "$(( 19660 - need ))" > "${LLMCTL_RUNTIME_DIR}/coder.run"
rc="$(run_rc "${L}" start small)"
assert_eq 0 "${rc}" "control: exactly at the cap -> admitted (dry-run)"
rm -f "${LLMCTL_RUNTIME_DIR}"/*.run
test_finish
