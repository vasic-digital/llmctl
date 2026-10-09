# nezha pinned-tree SMOKE only - decide-2b (2026-10-09)

- Smoke run only (3 choice questions, `C-001`..`C-003`), `RESULT.txt` = `smoke-only`: 3/3 well-formed, 3/3 correct (`smoke.log`). It is NOT a benchmark; no golden or probes set was run here (see `../nezha-pinned-decide-2b-2026-10-09` for the full run of the same profile).
- Host nezha.local (CPU engine, `-ngl 0`), same pinned snapshot as the other `nezha-pinned-*` runs: see `PROVENANCE.txt` and `../nezha-pinned-provenance-2026-10-09/`.

## Provenance caveat (added 2026-10-09 after independent review)

- The "pinned" snapshot (git HEAD c5301de + `git diff HEAD` with sha256 `4019682088fa...24bb`, 1082 files) is a MID-DEVELOPMENT working tree. It equals NO single commit; it differs from `5184565`, `c00da7b` and HEAD in `internal/server/handlers.go`, `internal/server/server_test.go`, `scripts/golden/run_golden.py`, the `contracts/*` files and the hostsafety files (the gateway `letter*.go` / `resolver*.go` files and `models/catalog.json` equal those of `5184565`).
- The binary `llmctl-decide` (sha256 `2da8d639...8922`) was cross-compiled locally; its equivalence to the snapshot is UNCONFIRMED.
- Three requests prove only that the wiring answered; they say nothing about accuracy, and the deadline used for the smoke is not recorded as the product default.
