# nezha pinned-tree provenance bundle (2026-10-09)

Shared provenance for every `nezha-pinned-*` run directory (they reference this directory as `PROVENANCE.txt` / `pins.txt`). It contains data, not a result: `PROVENANCE.txt`, `pins.txt` (model sha256 pins, `sha256sum -c` all OK), `tree.diff` (`git diff HEAD` at HEAD c5301defb73a949536fe741b597d3bd089df4109), `tree.manifest` (per-file sha256 of the 1082-file snapshot), `runner/` (the wrapper scripts used, outside the llmctl tree), `all.log` / `all-run0.log` (driver logs), `SHA256SUMS`.

## Provenance caveat (added 2026-10-09 after independent review)

- The pinned snapshot (HEAD c5301de + `tree.diff`, sha256 of `git diff HEAD` `4019682088fa...24bb`) is a MID-DEVELOPMENT tree that equals NO single commit.
- Relative to later commits: the gateway `letter.go`, `letter_test.go`, `resolver.go`, `resolver_test.go` and `models/catalog.json` equal those committed in `5184565`; `internal/server/handlers.go`, `internal/server/server_test.go`, `scripts/golden/run_golden.py`, the `contracts/*` files and the hostsafety files DIFFER from `5184565`, `c00da7b` and HEAD. The `handlers.go` that ran is the earlier inline 502 marker; the `run_golden.py` that ran retried `deadline_exceeded` 502 responses.
- The binary `llmctl-decide` (sha256 `2da8d639...8922`) was cross-compiled locally; its equivalence to the snapshot is UNCONFIRMED.
- The pinned snapshot excludes `.git`, submodules, `specs/*/evidence` and model weights; the llama-server used is `0.5.0-dev (build 1, commit 1537a0a)` built in `~/llmctl-work-live`.
