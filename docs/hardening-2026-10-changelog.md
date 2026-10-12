# Changelog entry: bounded restarts, pressure gates, one engine per profile

| Field | Value |
|---|---|
| Revision | 1 |
| Branch | `fix/bounded-restart-and-pressure-gates` |
| Details | `docs/host-safety.md` (section *llmctl service limits and gates*) |

### Fixed
- **service**: per-profile `MemoryHigh`/`MemoryMax` (1.25x / 1.5x of the plan footprint) replace `MemoryHigh=MemoryMax=total RAM`; `MemorySwapMax=0`, `Nice`, `IOWeight`, `CPUWeight`, `OOMScoreAdjust`, `TimeoutStopSec=20`, `KillMode=control-group`.
- **service**: `Restart=on-failure`, 3 starts per 900 s, no restart after SIGKILL / SIGTERM / port-in-use (98); stale installed units are reported and refused.
- **scheduler / hooks**: memory-pressure start gate (exit 75) for start, restart (unit `ExecStartPre`), enable, switch.
- **hooks**: `prestart` refuses fast (98) when the port is already served and never rotates the key under a live server; `unregister` is bounded and the registration waiter is killed on stop.
- **registry**: a live row is never dropped by another unit's `ExecStopPost`.
- **service**: one enabled engine unit per profile; `doctor` FAILs on duplicates and on a live engine without a registry row.
- **security**: profile names are data, never spliced into eval'd JSON expressions (`valid_id`, `argv[i]`, restricted evaluator).
- **docs**: `docs/host-safety.md` now states the real systemd-oomd vendor rule on `user@.service`.

### Operator notes
- Run `llmctl install` to regenerate units; the live `decide-nli` duplicate enabled state is NOT remediated by this change.
- `tests/helpers.sh` gained hermetic PSI/meminfo fixtures (it also carries uncommitted edits in another working tree).
