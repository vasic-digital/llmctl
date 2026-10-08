# Protocol verification of every decision profile (2026-10-08)

Produced by an independent agent: each catalogued decision profile's `decision.protocol` was checked
against the vendor's own readout files at the pinned revision (no weights downloaded). `verification.json`
holds the per-row file:line evidence; `SHA256SUMS` covers the fetched vendor files (`sha256sum -c`).

## What was taken into the product (and where)
* `decide-2b` / `decide-max` (JevK5, letters A..P only): `max_options` 20 -> 16 (commit 9367d90, with a validator rule + mutation).
* `decide-tiny` (vendor `readout: verdict`, no gateway driver): non-servable, ranked last, never the default (79268f5).

## What is NOT taken, and why (read before reusing `unmerged-worktree/`)
* The agent marked `decide-nli` **not servable** ("2-label head needs a contradiction column"). That was true of the
  gateway at base d856e69 and is **superseded**: commit 79268f5 makes the decoder accept the real
  `{entailment, not_entailment}` head, proven against a byte-exact live fixture and a live run. Do not re-apply
  `decision.not_servable` for decide-nli.
* `unmerged-worktree/aad90.tracked.patch` is the agent's complete uncommitted diff (planner `servable:false`,
  `models list` tags, docs moved to decide-kev-08b with `LLMCTL_DECIDE_NATIVE=1`, a docs-audit rule that runnable
  examples never use an unservable profile, CHANGELOG). It is kept verbatim for a deliberate follow-up merge; it is
  based on d856e69 and overlaps later commits, so it must be re-applied by hand, not blindly.
* `verification.json` rows marked `live: FAIL` for decide-nli describe d856e69, not the current tree.
* Still untested live (per the agent): decide, decide-2b, decide-pro, decide-max. kev-9b ran out of GPU memory at start
  (the memory-booking fix in 78bd5e1 addresses this; live confirmation pending).
