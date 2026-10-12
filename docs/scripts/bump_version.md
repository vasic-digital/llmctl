# scripts/release/bump_version.sh

**Purpose:** move every pinned release-version string from the current `VERSION` to a new `X.Y.Z` (the pins `tests/test_version_consistency.sh` checks).

**Usage:** `bash scripts/release/bump_version.sh [--root DIR] [--apply] X.Y.Z`. Dry run by default (prints file:line for every change); `--apply` writes the working tree only. Never commits, tags or pushes.

**Edits:** `VERSION`, `bin/llmctl` (`LLMCTL_VERSION`), `README.md` banner, every `llmctl X.Y.Z` in `docs/*.md`, OpenAPI `info.version` (strips `-draft`), the two contract-version mentions in `docs/calibration-tool-fields.md`.

**Does not edit (manual):** the new `CHANGELOG.md` section (the test requires its sub-headings), README prose, historical docs, `llmctld/cmd/llmctld/main.go` (its own `0.1.0`).

**Exit codes:** 0 ok; 1 refused (same or older version, or a pin not found); 2 usage.

**Related:** `docs/release-3.2.0-checklist.md` section 1, `tests/test_version_consistency.sh`.
