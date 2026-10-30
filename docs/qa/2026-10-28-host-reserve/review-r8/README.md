# Review round 8 record (host reserve, llmctl 3.4.0)

Evidence for the fixes made after the round-8 review of `d16e205` (NO-GO, 5 source-defects). Linked from [`../README.md`](../README.md).
Evidence class (§11.4.289): everything here is UNIT-CLASS (fixture cgroup trees, stubs, text scans). No live run was repeated at this HEAD.

## Fixes

| # | Finding | Change | Test (UNIT-CLASS) |
|---|---|---|---|
| 1 | MEDIUM: `LLMCTL_HOST_RESERVE=0` was persisted into the unit env record, so later boots and restarts ran unreserved | `_svc_write_reserve_dropin` never writes the override line; a stale line is dropped on every start. (Incomplete: the other reserve-derived state was still derived from the invoking shell; closed in round 9, see [review-r9](../review-r9/README.md)) | review9 R1 (kills OWN4) |
| 2 | LOW: memo key ignored the cgroup chain | key includes the chain scan, `LLMCTL_CGROUP_ROOT`, `LLMCTL_CGROUP_FS` | review9 R2 |
| 3 | LOW: false "reserved 0" CPU warning at `RESERVE_CPU_PCT=100` | warning prints the real reserved and usable CPUs; STRICT=1 still refuses | review9 R3 |
| 4 | LOW: chain value 2^64-1 wrapped into a false refusal | 16+ digit values bound nothing; 1 MiB floor kept | review9 R4 (kills OWN2) |
| 5 | LOW: malformed stricter knobs fell back to a looser default | refuse rc 75 with the fallback line and the variable named | review9 R5 |
| 6 | docs | capacity.md, user-manual.md and a code comment corrected; finding 10 documented | none |

Finding 10 (hk_gate start-time race) was analysed, not fixed and not reproduced: the gate runs inside the unit cgroup, which other gates count, so the usual outcome of two simultaneous starts is that both refuse (fail closed). The remaining window (empty cgroup between ExecStartPre and ExecStart) is UNCONFIRMED. Documented in capacity.md.
F5 and F6: the reviewer's wording was not available to the author (searched the reviewer evidence directory); they stay documented as the limits the author could verify. This is an open gap.

## RED / GREEN

`tests/test_host_reserve_review9.sh` was written first and failed with 13 assertion failures against `d16e205`; it passes at HEAD. One assertion (the refusal message names the variable) was added after a mutant survived.

## Regression at HEAD (`regression-chain-r9.log`)

20 files (the 11 reserve suites plus review9, capacity, decision, start-gate, services, gate-wiring x3, restart-policy, doc-reachability): 20 of 20 `RESULT: PASS`.

## Mutants

- New R9 mutants: 8. First run alone (`mutants-r9-new8-first-run.log`): 7 killed, `R9-bad-knob-name-dropped` survived; the missing assertion was added and it is then killed.
- Full harness (`mutants-r9.json`, `mutants-r9.log`): control green, 201 mutants, 199 killed, 2 `not-applied`, `all_killed` false as recorded. The two (`M12-reserve-memo-key-drops-topology`, `R8-F3-non-numeric-reserve-accepted`) had their target text changed by these fixes; their patterns in `scripts/qa/host_reserve_mutants.py` were updated afterwards and each was run alone against its suite: both killed. The full harness was NOT re-run after that pattern edit, so no single run shows 201 of 201.

## Not proven

Live harness not re-run at this HEAD (live evidence is one 16-CPU host at `536d65e`); 1-CPU, chain-bound, hostile-cgroup, cgroup-v1 paths are unit-class only; finding 10 window unmeasured; manual QA not done; M8/M9 stay documented fail-open follow-ups backstopped by hk_gate.
