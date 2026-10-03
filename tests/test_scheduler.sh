#!/usr/bin/env bash
# test_scheduler.sh - dry-run scheduler: co-residency start, refusal with
# alternative, LRU eviction in `auto`, enabled-service protection, switch.
# All service actions are dry-run; reservation state lives in a temp dir.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"

# --- 1. co-resident start fits ------------------------------------------------
out="$("${LLMCTL}" start fast small 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "start fast small (co-resident) exit code"
assert_contains "${out}" "started fast" "fast started"
assert_contains "${out}" "started small" "small started"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "fast reservation written"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "small reservation written"
out="$("${LLMCTL}" status)"
assert_contains "${out}" "fast" "status lists fast"
assert_contains "${out}" "small" "status lists small"

# --- 1b. LLMCTL-F1: machine-readable `status --json` -------------------------
json_out="$("${LLMCTL}" status --json 2>&1)" || true
json_ok="$(printf '%s' "${json_out}" | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
    assert isinstance(rows, list), "top level must be a JSON array"
    names = sorted(r["profile"] for r in rows)
    assert names == ["fast", "small"], "expected exactly fast+small, got %r" % names
    for r in rows:
        assert set(r.keys()) == {"profile","port","mode","ram_mb","vram_mb","enabled","state","last_log_line"}, r
        assert r["state"] == "running", r
        assert r["last_log_line"] is None, r
        assert isinstance(r["enabled"], bool), r
    print("ok")
except Exception as exc:
    print("FAIL: %s" % exc)
' 2>&1)" || true
assert_eq "ok" "${json_ok}" "status --json: valid JSON array, exact field set, fast+small both state=running with no log line"

out_text="$("${LLMCTL}" status)"
out_json_names="$(printf '%s' "${json_out}" | python3 -c 'import json,sys
try:
    print(" ".join(sorted(r["profile"] for r in json.load(sys.stdin))))
except Exception as exc:
    print("FAIL: %s" % exc)
' 2>&1)" || true
text_names="$(printf '%s' "${out_text}" | tail -n +2 | awk '{print $1}' | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "fast small" "${out_json_names}" "status --json's profile set matches the plain-text table's (single source of truth, not a second parse)"
assert_eq "fast small" "${text_names}" "sanity: the plain-text table itself still lists exactly fast+small (unchanged by the refactor)"

# --- 2. refusal with suggested alternative ------------------------------------
# fast+small reserve 9689/10444 MiB VRAM; vision needs 4210 -> must refuse.
sleep 1  # ensure distinct LRU epochs
out="$("${LLMCTL}" start vision 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "start vision refused (exit 1)"
assert_contains "${out}" "cannot start 'vision'" "refusal message"
assert_contains "${out}" "suggested alternative" "alternative suggested"
assert_contains "${out}" "llmctl switch vision" "switch fallback suggested"
# nothing changed
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "fast kept after refusal"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "small kept after refusal"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision.run" "vision not started after refusal"

# --- 3. auto evicts the LRU non-enabled service --------------------------------
out="$("${LLMCTL}" auto vision 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "auto vision exit code"
assert_contains "${out}" "evicting 'fast'" "LRU eviction of fast announced"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/fast.run" "fast reservation removed after eviction"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "small kept after eviction"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/vision.run" "vision running after eviction"

# --- 4. enabled services are never evicted -------------------------------------
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-constrained.json"
test_teardown_env; test_setup_env   # fresh state for the new fixture
out="$("${LLMCTL}" start fast 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "constrained: start fast"
touch "${LLMCTL_SERVICES_DIR}/fast.enabled"   # mark enabled (protected)
# VRAM budget 6963 MiB; fast holds 5716; vision needs 4210 -> only eviction of
# fast could make room, but it is enabled.
out="$("${LLMCTL}" auto vision 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "constrained: auto vision fails (exit 1)"
assert_contains "${out}" "enabled (protected)" "protection message"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "protected service untouched"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision.run" "vision not started (protected)"

# --- 5. switch always works ----------------------------------------------------
out="$("${LLMCTL}" switch moe-fast 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "switch moe-fast exit code"
running=""
for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do
  [[ -e "${f}" ]] || continue
  running="${running}${running:+ }$(basename "${f}" .run)"
done
assert_eq "moe-fast" "${running}" "switch leaves exactly one service running"

# --- 6. dry-run never calls systemctl ------------------------------------------
out="$("${LLMCTL}" stop all 2>&1)"
assert_contains "${out}" "[dry-run] systemctl --user stop" "stop is a dry-run action"

# --- 7. `llmctl auto coder vision` co-residency (spec.md US1 Acceptance
# Scenario 3: "Given multiple models downloaded, When running `llmctl auto
# coder vision`, Then co-residency is computed and services start if
# budgets allow"). tests/fixtures/hw-workstation.json (64 cores / 256 GiB
# RAM / 32 GiB VRAM / 2 TiB free) classifies as "datacenter" tier per
# catalog_classify_tier's actual thresholds (cores>=32 AND ram>=96GiB AND
# free>=400GiB - all three hold here), NOT "workstation" - the filename
# predates that threshold and is left as-is (a naming nit, not a defect);
# this test verifies the REAL computed behavior against it, not an assumed
# "workstation" classification. ------------------------------------------------
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-workstation.json"
test_teardown_env; test_setup_env   # fresh state for the new fixture

out="$("${LLMCTL}" auto coder vision 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "auto coder vision exit code (US1 Acceptance Scenario 3)"
assert_contains "${out}" "capability 'coder' -> profile" "co-residency computation: coder capability resolved to a profile"
assert_contains "${out}" "capability 'vision' -> profile" "co-residency computation: vision capability resolved to a profile"
assert_contains "${out}" "started" "at least one service started (budgets allow on this abundant fixture)"
# Ample budget on this fixture (datacenter tier: 235904 MiB RAM / 27852 MiB
# VRAM available) means BOTH resolved profiles fit without any eviction.
eviction_count="$(echo "${out}" | grep -c "evicting" || true)"
assert_eq 0 "${eviction_count}" "no eviction needed - both profiles fit the abundant budget directly"
running_count=0
for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do
  [[ -e "${f}" ]] || continue
  running_count=$((running_count + 1))
done
assert_eq 2 "${running_count}" "both resolved profiles (coder + vision capabilities) ended up running"

# --- 8. LLMCTL_SEED enforces deterministic --seed/--temp 0 on llama launches
# (Phase 5 T029, spec.md FR-012/SC-008: "Live challenges MUST be deterministic
# ... Use temperature 0 AND fixed seed (--seed <fixed_value>) for llama.cpp").
# Opt-in via an env var (matching the project's existing LLMCTL_DRY_RUN
# idiom) rather than baked into every default launch: an always-on fixed
# seed would make every interactive coding-assistant session identically
# non-creative, which the spec does not ask for - FR-012 scopes determinism
# to "live challenges" (the manual release-gating procedure, US4), not
# everyday interactive use. -----------------------------------------------
source "${LLMCTL_ROOT}/lib/scheduler.sh"

# LLMCTL_DRY_RUN=1 so sched_build_launch's model-file-exists check (line 130
# of scheduler.sh) doesn't require a real downloaded model on disk.
export LLMCTL_DRY_RUN=1

sched_build_launch fast cpu 8080 8192 99 1 auto
seed_present=0
for a in "${SCHED_ARGS[@]}"; do [[ "${a}" == "--seed" ]] && seed_present=1; done
assert_eq 0 "${seed_present}" "LLMCTL_SEED unset: no --seed flag added (default interactive behavior unchanged)"

export LLMCTL_SEED=42
sched_build_launch fast cpu 8080 8192 99 1 auto
assert_contains "${SCHED_ARGS[*]}" "--seed 42" "LLMCTL_SEED=42: llama launch includes --seed 42"
assert_contains "${SCHED_ARGS[*]}" "--temp 0" "LLMCTL_SEED set: llama launch includes --temp 0 (FR-012 fixed-seed + temperature-0 pair)"
unset LLMCTL_SEED

# --- 9. LLMCTL_SLOT_SAVE_PATH opt-in wires --slot-save-path on llama
# launches (003-kv-cache-replication T015, spec.md FR-006/User Story 2:
# the real llama-server engine's own --slot-save-path +
# /slots/:id_slot?action=save|restore mechanism, T060's confirmed-real
# finding). Opt-in via an env var (matching LLMCTL_SEED's own idiom)
# rather than baked into every default launch - see scheduler.sh's own
# comment for the Constitution §11.4.133 host-safety rationale
# (unbounded engine-cache disk growth must be an explicit deployment
# choice, never a forced-on default). ---------------------------------
sched_build_launch fast cpu 8080 8192 99 1 auto
slot_save_present=0
for a in "${SCHED_ARGS[@]}"; do [[ "${a}" == "--slot-save-path" ]] && slot_save_present=1; done
assert_eq 0 "${slot_save_present}" "LLMCTL_SLOT_SAVE_PATH unset: no --slot-save-path flag added (default launch unchanged)"

slot_save_base="$(mktemp -d)"
export LLMCTL_SLOT_SAVE_PATH="${slot_save_base}"
sched_build_launch fast cpu 8080 8192 99 1 auto
assert_contains "${SCHED_ARGS[*]}" "--slot-save-path ${slot_save_base}/fast" "LLMCTL_SLOT_SAVE_PATH set: llama launch includes a per-profile --slot-save-path subdirectory"
dir_created=0; [[ -d "${slot_save_base}/fast" ]] && dir_created=1
assert_eq 1 "${dir_created}" "the per-profile slot-save directory is created before the engine is launched"
unset LLMCTL_SLOT_SAVE_PATH
rm -rf "${slot_save_base}"

# --- 10. Admission-control double-count regression (independent review,
# 2026-10-03): with a REAL free-VRAM measurement (gpu_free_vram_mb
# present, vram_live true in the plan), the budget already reflects
# whatever the currently-running 'small' is using. Adding
# sched_reserved_field's sum of that SAME reservation on top of the
# budget AGAIN double-subtracts it, wrongly refusing a second profile
# ('vision') that genuinely fits the real remaining headroom. Fixed via
# _sched_initial_used (scheduler.sh): it starts VRAM's accumulator at 0
# whenever vram_live is true, never at sched_reserved_field's sum.
# Fixture: 12288 MiB total / 6000 MiB real free VRAM -> budget
# int(6000*0.85)=5100. 'small' alone needs 2949 MiB VRAM (fits
# standalone, 2949<=5100). 'vision' alone needs 4210 MiB VRAM (also fits
# standalone, 4210<=5100) -- genuinely, once 'small' is running, since
# gpu_free_vram_mb already excludes what 'small' holds. The OLD,
# buggy arithmetic computed used_vram(2949) + vision's 4210 = 7159 >
# 5100 and wrongly refused it. ------------------------------------------------
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-vram-contended-coresident.json"
test_teardown_env; test_setup_env   # fresh state for the new fixture

out="$("${LLMCTL}" start small 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "co-resident double-count regression: starting 'small' alone succeeds"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "small reservation written"

out="$("${LLMCTL}" start vision 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "co-resident double-count regression: 'vision' is NOT wrongly refused while 'small' is already running (would be 7159 > 5100 under the old double-count; is 4210 <= 5100 under the fix)"
assert_contains "${out}" "started vision" "vision genuinely started alongside small"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/vision.run" "vision reservation written"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "small's own reservation is untouched by starting vision"

# --- 10b. Same-call multi-profile accounting must still work: starting
# TWO profiles in ONE 'llmctl start a b' call, from a clean (nothing
# running) state, must still refuse the pair if the SECOND one's own
# demand plus the FIRST one's (selected earlier in this same call, so
# not yet reflected in any fresh hw re-probe) would exceed the real
# budget -- this accounting is UNCONDITIONAL (always needed, live
# budget or not) and must not have been broken by removing the OTHER,
# currently-running-profile double-count above. 'small' (2949) +
# 'vision' (4210) = 7159 > 5100 -- must still be refused when requested
# TOGETHER, from a clean start, in one call. _sched_start_impl validates
# the WHOLE requested batch before starting ANYTHING (two-phase:
# validate all, then start all), so a refusal anywhere in validation
# means NOTHING from this call starts -- not even 'small', which would
# have fit on its own. That atomicity is correct, pre-existing design,
# not something this fix changes; the regression this case actually
# guards is the ACCOUNTING total (7159) staying right, not which half
# gets blamed. --------------------------------------------------------
test_teardown_env; test_setup_env   # clean state, nothing running

out="$("${LLMCTL}" start small vision 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "10b: same-call multi-profile demand (small+vision=7159) still correctly exceeds the 5100 budget and is refused"
assert_contains "${out}" "cannot start 'vision'" "10b: the SECOND profile in the call is the one named as refused (small, selected first, already fit on its own)"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "10b: nothing starts when the batch's validation phase refuses any member (atomic start, pre-existing design)"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision.run" "10b: vision (the one that overflows the combined demand) is correctly refused, never started"

# --- 10c. Round-2 independent review (2026-10-03): _sched_auto_impl's
# eviction loop never converged once _sched_initial_used started
# returning 0 for a live budget (10b's own fix, this same session) --
# ram_budget is probed ONCE before the loop and never re-probed after an
# eviction, so nothing an eviction freed was ever reflected, and the
# loop evicted every evictable service and still failed with a FALSE
# "remaining services are enabled (protected)" message even when
# nothing was enabled. Reproduced directly against the unfixed code
# with this exact fixture/scenario before writing this fix: 'small'
# (ram 2949) running alone, 'auto chat vision' resolves to fast(5716)+
# vision(4210)=9926 against a live 9904 RAM budget -- 'small' gets
# evicted (the only evictable candidate) and the call STILL failed. ---
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-ram-contended-auto-eviction.json"
test_teardown_env; test_setup_env   # fresh state for the new fixture

out="$("${LLMCTL}" start small 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "10c: 'small' starts alone"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "10c: small reservation written"

out="$("${LLMCTL}" auto chat vision 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "10c: auto chat vision succeeds after evicting small (9904 RAM budget + 2949 credited back >= fast(5716)+vision(4210)=9926)"
assert_contains "${out}" "evicting 'small'" "10c: small is the one evicted (LRU, not enabled, not in the wanted set)"
assert_contains "${out}" "started fast" "10c: fast genuinely started"
assert_contains "${out}" "started vision" "10c: vision genuinely started"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "10c: small's reservation removed by the eviction"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "10c: fast reservation written"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/vision.run" "10c: vision reservation written"

# --- 10d. Round-3 independent review (2026-10-03): a FAILED svc_stop must
# NOT credit the evicted profile's memory as freed -- it is still running
# and still holding it. 10c's own credit mechanism incremented the credit
# unconditionally, before even calling svc_stop, which would have made the
# final admission check in the delegated _sched_start_impl call believe
# more memory is free than genuinely is (the over-admission direction).
# Uses LLMCTL_TEST_FORCE_STOP_FAIL (new, test-only, inert outside
# LLMCTL_DRY_RUN=1) to make 'small's stop genuinely fail. Same fixture and
# scenario as 10c, but the credit must never be granted, 'small' must
# still be reported as running (its .run file must survive), and the auto
# call should fail cleanly rather than wrongly succeed. ---
test_teardown_env; test_setup_env   # fresh state

out="$("${LLMCTL}" start small 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "10d: 'small' starts alone"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "10d: small reservation written"

export LLMCTL_TEST_FORCE_STOP_FAIL=small
out="$("${LLMCTL}" auto chat vision 2>&1)" && rc=0 || rc=$?
unset LLMCTL_TEST_FORCE_STOP_FAIL
assert_contains "${out}" "stopping 'small' failed" "10d: the forced stop failure is reported, not silently swallowed"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "10d: small's reservation SURVIVES -- it is still running, never credited as freed"
assert_eq 1 "${rc}" "10d: auto chat vision does NOT wrongly succeed via a bogus credit for memory that was never actually freed"
# round-4 independent review, 2026-10-03 (F2, test-instrumentation):
# the assertion above only proved the FINAL rc; it never proved the loop
# itself failed closed rather than merely being rescued by
# _sched_start_impl's own independent re-check after a 16-attempt
# exhaustion. With 'small' excluded from LRU re-selection after its first
# failed stop (this same fix), the ONLY evictable candidate is gone after
# attempt 0, so this now fails via the loop's own lru-empty branch on
# attempt 1, not via 16 repeated identical failures papered over by
# _sched_start_impl. The exact, new, loop-level message proves this.
assert_contains "${out}" "could not stop enough services to make room (failed to stop: small)" "10d: fails via the LOOP's own exclusion-aware message, not merely _sched_start_impl's independent rescue"

# --- 10e. Round-4 independent review (2026-10-03), blocking F1: the
# eviction loop can also end by EXHAUSTING every attempt without ever
# setting ok=1 (never converging), as opposed to running out of evictable
# candidates (10d's lru-empty path). Pre-fix, that fell straight through
# to the delegated _sched_start_impl call with no loop-level proof the
# wanted set fits -- correct only by the accident of _sched_start_impl's
# own fresh re-check happening to catch it. Genuinely reaching this via
# >=16 distinct, always-successfully-evicted candidates is impractical in
# a focused fixture (and, combined with 10d's own fix, a single
# repeatedly-failing candidate no longer gets to cause this at all -- it
# is excluded after one failure instead). LLMCTL_TEST_AUTO_MAX_ATTEMPTS
# (new, test-only, inert when unset) lowers the loop bound to 1 so a
# single successful-but-insufficient eviction can force genuine
# exhaustion without needing 16 fixture candidates: 'small' evicts fine
# (credited), but the loop ends before it ever gets to re-check whether
# fast+vision now fits with that credit -- converged must stay 0, and the
# call must fail cleanly, NEVER reaching _sched_start_impl at all (proven
# by fast/vision never starting, not merely by the final rc). ---------------
test_teardown_env; test_setup_env   # fresh state, same contended fixture

out="$("${LLMCTL}" start small 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "10e: 'small' starts alone"

export LLMCTL_TEST_AUTO_MAX_ATTEMPTS=1
out="$("${LLMCTL}" auto chat vision 2>&1)" && rc=0 || rc=$?
unset LLMCTL_TEST_AUTO_MAX_ATTEMPTS
assert_eq 1 "${rc}" "10e: with only 1 attempt allowed, the call fails cleanly rather than falling through unverified"
assert_contains "${out}" "could not make room after 1 eviction attempts" "10e: the new loop-level exhaustion message fires, naming the real attempt bound"
assert_contains "${out}" "evicting 'small'" "10e: small WAS evicted (the single allowed attempt's eviction genuinely ran)"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "10e: small's reservation is gone -- the eviction itself succeeded"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/fast.run" "10e: fast was NEVER started -- _sched_start_impl must not be reached on the non-converged path"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision.run" "10e: vision was NEVER started, for the same reason"

test_finish
