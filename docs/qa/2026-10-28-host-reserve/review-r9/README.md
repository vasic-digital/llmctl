# Review round 9 (after the review of 4fedf0a): evidence

All results below are UNIT-CLASS (hermetic fixtures: a fake cgroup file system, fake PSI and meminfo files, scratch unit directories). None of them is live-class evidence (section 11.4.289); the live counterpart is `scripts/qa/host_reserve_live.sh` and was not re-run for this round.

| # | Finding | Fix | Test |
|---|---------|-----|------|
| F1 | MEDIUM: a start or install run with `LLMCTL_HOST_RESERVE=0` persisted reserve-off state: no `06-reserve.conf`, no `LLMCTL_RESERVE_CPU_PCT_UNIT` line, `LLMCTL_ARGS` without `--threads`, a larger `05-memory.conf` cap; a restart never re-derived it | `svc_install`, `svc_write_env` and `sched_build_launch` pin `local LLMCTL_HOST_RESERVE=1` (dynamic scope reaches every callee), so everything persisted is derived reserve-ON; the override only skips admission, reporting and non-persisted direct launches | `tests/test_host_reserve_review10.sh` F1: the complete state (all drop-ins, env record, launch args) is diffed for reserve-off start vs reserve-on start vs a reserve-off rewrite of a reserve-on unit |
| F2 | LOW: several numeric knobs fell back to a looser default when malformed | one validator `reserve_knobs_check` over `_RSV_KNOBS` (16 knobs); the start gate, `llmctl capacity` (undetermined), `llmctl install` and the unit-state write all refuse with exit 75, name the variable and print `llmctl-fallback:` | review10 F2: 16-knob matrix x {validator, start gate, capacity, install, write-env}, an inventory test with a control needle, a 20-digit and a two-point decimal case |
| F3 | survivors A1, B, D2, D5 (and C2) | tests added | review10 F3 |

## RED and GREEN

* F1: RED was observed before the fix (the reserve-on state had 9 files; the diff showed the missing `--threads 6 --threads-batch 6`, the missing `LLMCTL_RESERVE_CPU_PCT_UNIT=600`, `MemoryMax` 26215M vs 27852M, and `Nice=15`/`IOWeight=20`/`CPUWeight=20`/`OOMScoreAdjust=800`/`CPUQuota=600%`/`CPUAffinity=4-15` vs the reserve-off values); GREEN after commit d72a16c.
* F2: with `lib/` stashed back to the F1 state, review10 reported 168 failing assertions; with the validator it reports `RESULT: PASS`.
* An old assertion in `tests/test_host_reserve.sh` ("reserve off: no --threads") encoded the F1 defect and was changed to assert the new documented behaviour.

## Knob inventory (control-needled)

`knob-inventory.txt` lists the `${LLMCTL_X:-<number>}` knobs read by `lib/reserve.sh`, `lib/hardware.sh`, `lib/capacity.sh` and `lib/svc_hook.sh`, with a positive needle (1 hit, expected 1) and a negative needle (0 hits, expected 0). Classification:

* validated by `reserve_knobs_check`: the 16 entries of `_RSV_KNOBS`; review10 compares the knobs read by reserve.sh, hardware.sh and capacity.sh with its own written-out list, so a knob added to the code and not to the list fails the test.
* exempt, by design: `LLMCTL_HOST_RESERVE` (only the literal 0 turns the reserve off) and `LLMCTL_GATE_CPU_CHECKS` (only the literal 0 turns the CPU checks off; a malformed value keeps them ON, the safe direction).
* out of scope, NOT validated by this change: the legacy start-wait, registration, model-validation and dry-run knobs of `lib/svc_hook.sh` and elsewhere (`LLMCTL_DECIDE_PORT`, `LLMCTL_DRY_RUN`, `LLMCTL_REGISTER_*`, `LLMCTL_VALIDATE_*`, `LLMCTL_READY_TIMEOUT`, `LLMCTL_START_WAIT`, `LLMCTL_ADMIT_*`, `LLMCTL_QUARANTINE_TTL`, ...). They do not feed the host reserve or the pressure gate. This round did not audit them and does not claim they refuse malformed values.
* `LLMCTL_CAPACITY_TIMEOUT` and `LLMCTL_CAPACITY_PROBE_TIMEOUT` are in the list but do not match the numeric-default grep (different default syntax); they were added by reading the code.

## Mutants

Full harness at HEAD edd1ef1 (UNIT-CLASS): 223 mutants, 223 killed, 0 survived, 0 not-applied; control_green=true, all_killed=true.

## Not proven

* UNIT-CLASS only; no live run of the changed start path on a real systemd user manager in this round.
* The inventory covers knobs written as `${LLMCTL_X:-<digit>...}`; a knob read in another form could be missed (the two named above were). The scope-out list above is the honest statement of what was not audited.
* `llmctl install` with a malformed knob was tested through `svc_install` in a scratch unit directory, not through the CLI entry point.
